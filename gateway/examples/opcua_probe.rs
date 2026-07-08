//! Machine-proof that a REAL, independent, third-party OPC UA client (this
//! crate's own `opcua` client — not anything hand-rolled by the Dart side)
//! can connect to, browse, read from, and write to the in-app pure-Dart OPC
//! UA server (WS19 Tasks 1-4, `mobile/lib/protocols/opcua/*` +
//! `mobile/lib/services/opcua_host.dart`).
//!
//! Usage:
//!   cargo run --manifest-path gateway/Cargo.toml --example opcua_probe -- opc.tcp://127.0.0.1:<port>
//!
//! Talks to a server hosting a small fixture project with three mapped
//! tags (see `mobile/tool/opcua_host_probe.dart`, which this probe is
//! designed to run against via `tool/opcua_e2e.sh`):
//!   - `Start_PB` : BOOL, ReadWrite  -> ns=1;s=Start_PB
//!   - `Temp`     : FLOAT64, ReadOnly -> ns=1;s=Temp
//!   - `Counter`  : INT32, ReadWrite  -> ns=1;s=Counter
//!
//! Steps: connect (SecurityPolicy::None, anonymous) -> GetEndpoints ->
//! Read `NamespaceArray` (ns=0;i=2255) and verify index 1 is the project
//! namespace URI -> Browse top-down from `RootFolder` (i=84) through the
//! discovered `Objects` node and verify the fixture's tags are reachable
//! that way (not by addressing Objects directly) -> Browse the Objects
//! folder (i=85) -> Read `Temp`'s Value -> Write `Counter`'s Value -> Read
//! `Counter` back and verify the write landed.
//! Prints `PROBE PASS` and exits 0 on success; on any failure prints
//! `PROBE FAIL: <reason>` and exits 1 — never panics past the top level.

use std::env;
use std::process::ExitCode;
use std::str::FromStr;
use std::sync::mpsc;
use std::time::Duration;

use opcua::client::prelude::{
    AttributeService, ClientBuilder, DataChangeCallback, IdentityToken, MessageSecurityMode,
    MonitoredItemService, Session, SubscriptionService, UserTokenPolicy, ViewService,
};
use opcua::types::{
    AttributeId, BrowseDescription, BrowseDirection, DataValue, ExtensionObject,
    MonitoredItemCreateRequest, MonitoringMode, MonitoringParameters, NodeId, ObjectId,
    ReferenceTypeId, ReadValueId, TimestampsToReturn, Variant, WriteValue,
};

const NODE_TEMP: &str = "ns=1;s=Temp";
const NODE_COUNTER: &str = "ns=1;s=Counter";

/// The fixture project's OPC UA namespace URI (see
/// `mobile/tool/opcua_host_probe.dart`'s `_fixtureProject`), which must
/// appear at index 1 of the standard `Server_NamespaceArray` (ns=0;i=2255) —
/// index 0 is always the fixed OPC Foundation namespace
/// (`http://opcfoundation.org/UA/`).
const PROJECT_NAMESPACE_URI: &str = "urn:softplc:e2e-fixture";

/// Value the Dart fixture host (`mobile/tool/opcua_host_probe.dart`) writes
/// to `NODE_COUNTER` at T+4s after printing READY, purely as a server-side
/// mutation for the subscription half of this probe to observe (a real
/// SCADA-style "value changed on the device" push, not a client write).
const SUBSCRIPTION_EXPECTED_VALUE: i32 = 7777;

fn test_pki_dir() -> String {
    let mut dir = std::env::temp_dir();
    dir.push("soft-plc-opcua-probe-pki");
    dir.to_string_lossy().to_string()
}

/// Strips a trailing `opc.tcp://` scheme mismatch and returns the endpoint
/// exactly as given — `get_server_endpoints_from_url` and
/// `ClientBuilder::endpoint`/`connect_to_endpoint` both want the full
/// `opc.tcp://host:port` (optionally with a trailing path) string.
fn run(endpoint_url: &str) -> Result<(), String> {
    println!("[probe] target endpoint: {endpoint_url}");

    let mut client = ClientBuilder::new()
        .application_name("Soft PLC OPC UA E2E Probe")
        .application_uri("urn:softplc:opcua-e2e-probe")
        .pki_dir(test_pki_dir())
        .trust_server_certs(true)
        .session_retry_limit(1)
        .client()
        .ok_or_else(|| "client builder produced no client (invalid config)".to_string())?;

    // --- Step 1: GetEndpoints ---------------------------------------
    println!("[probe] GetEndpoints...");
    let endpoints = client
        .get_server_endpoints_from_url(endpoint_url)
        .map_err(|e| format!("GetEndpoints failed: {e}"))?;
    if endpoints.is_empty() {
        return Err("GetEndpoints returned zero endpoints".to_string());
    }
    println!("[probe] GetEndpoints OK: {} endpoint(s)", endpoints.len());
    let has_none_anonymous = endpoints.iter().any(|e| {
        e.security_policy_uri.as_ref().contains("#None")
            || e.security_policy_uri.as_ref().ends_with("None")
    });
    if !has_none_anonymous {
        return Err(format!(
            "no SecurityPolicy#None endpoint offered: {:?}",
            endpoints.iter().map(|e| e.security_policy_uri.as_ref().to_string()).collect::<Vec<_>>()
        ));
    }

    // --- Connect a session (SecurityPolicy::None, anonymous) --------
    println!("[probe] connecting session (None / anonymous)...");
    let endpoint: opcua::types::EndpointDescription = (
        endpoint_url,
        "None",
        MessageSecurityMode::None,
        UserTokenPolicy::anonymous(),
    )
        .into();

    let session_arc = client
        .connect_to_endpoint(endpoint, IdentityToken::Anonymous)
        .map_err(|e| format!("connect_to_endpoint failed: {e}"))?;
    println!("[probe] session connected.");

    let session = session_arc.read();

    // --- Step 1b: Read NamespaceArray (ns=0;i=2255) and verify index 1 ----
    //
    // Machine-proof for the WS19/Task 2 discovery fix: a strict OPC UA
    // client resolves what a `ns=1;...` NodeId actually means by reading the
    // standard `Server_NamespaceArray` variable and looking up index 1 (index
    // 0 is always the fixed OPC Foundation namespace URI). If this array is
    // missing or wrong, a real client cannot reliably address any of this
    // server's nodes even though ad hoc `ns=1;s=...` literals (as used
    // elsewhere in this probe) happen to still work.
    println!("[probe] Read NamespaceArray (ns=0;i=2255)...");
    let namespace_array_node = NodeId::new(0u16, 2255u32);
    let read_namespace_array = ReadValueId {
        node_id: namespace_array_node,
        attribute_id: AttributeId::Value as u32,
        index_range: opcua::types::UAString::null(),
        data_encoding: opcua::types::QualifiedName::null(),
    };
    let namespace_array_results = session
        .read(&[read_namespace_array], TimestampsToReturn::Neither, 0.0)
        .map_err(|e| format!("Read(NamespaceArray) failed: {e}"))?;
    let namespace_array_value = namespace_array_results
        .first()
        .ok_or_else(|| "Read(NamespaceArray) returned zero results".to_string())?
        .value
        .clone();
    let namespace_array_values = match namespace_array_value {
        Some(Variant::Array(arr)) => arr.values,
        other => {
            return Err(format!(
                "expected an Array Variant reading NamespaceArray, got {other:?}"
            ))
        }
    };
    if namespace_array_values.len() < 2 {
        return Err(format!(
            "NamespaceArray has fewer than 2 entries (expected index 1 = project namespace URI): {namespace_array_values:?}"
        ));
    }
    let namespace_1_uri = match &namespace_array_values[1] {
        Variant::String(s) => s.as_ref().to_string(),
        other => {
            return Err(format!(
                "NamespaceArray[1] is not a String Variant: {other:?}"
            ))
        }
    };
    if namespace_1_uri != PROJECT_NAMESPACE_URI {
        return Err(format!(
            "NamespaceArray[1] = {namespace_1_uri:?}, expected the project namespace URI {PROJECT_NAMESPACE_URI:?}"
        ));
    }
    println!("[probe] NamespaceArray[1] OK: {namespace_1_uri}");

    // --- Step 1c: Browse top-down: Root -> Objects -> variables -----------
    //
    // Machine-proof that the fixture's tags are reachable by walking the
    // address space from `RootFolder` (i=84), the way any generic/strict OPC
    // UA client browses (as opposed to jumping straight to a well-known
    // `ObjectsFolder` NodeId, which the *next* step below still does for its
    // own purposes). Deliberately does NOT reuse the `ObjectId::ObjectsFolder`
    // constant to reach Objects -- the NodeId used to browse for variables
    // here is the one this walk itself discovers as a reference off Root.
    println!("[probe] Browse RootFolder (i=84) top-down...");
    let root_node_id: NodeId = ObjectId::RootFolder.into();
    let root_browse_description = BrowseDescription {
        node_id: root_node_id,
        browse_direction: BrowseDirection::Forward,
        reference_type_id: ReferenceTypeId::Organizes.into(),
        include_subtypes: true,
        node_class_mask: 0,
        result_mask: 0x3F,
    };
    let root_browse_results = session
        .browse(&[root_browse_description])
        .map_err(|e| format!("Browse(RootFolder) failed: {e}"))?
        .ok_or_else(|| "Browse(RootFolder) returned no results at all".to_string())?;
    let root_references = root_browse_results
        .first()
        .and_then(|r| r.references.clone())
        .unwrap_or_default();
    let objects_reference = root_references
        .iter()
        .find(|r| r.browse_name.name.as_ref() == "Objects")
        .ok_or_else(|| {
            format!(
                "Browse(RootFolder) did not surface an 'Objects' child (top-down discovery broken); found {:?}",
                root_references
                    .iter()
                    .map(|r| r.browse_name.name.as_ref().to_string())
                    .collect::<Vec<_>>()
            )
        })?;
    let discovered_objects_node_id = objects_reference.node_id.node_id.clone();
    println!("[probe] Browse(RootFolder) OK: discovered Objects at {discovered_objects_node_id}");

    println!("[probe] Browse the discovered Objects node for the fixture's tags...");
    let objects_browse_description = BrowseDescription {
        node_id: discovered_objects_node_id,
        browse_direction: BrowseDirection::Forward,
        reference_type_id: ReferenceTypeId::Organizes.into(),
        include_subtypes: true,
        node_class_mask: 0,
        result_mask: 0x3F,
    };
    let discovered_browse_results = session
        .browse(&[objects_browse_description])
        .map_err(|e| format!("Browse(discovered Objects) failed: {e}"))?
        .ok_or_else(|| "Browse(discovered Objects) returned no results at all".to_string())?;
    let discovered_references = discovered_browse_results
        .first()
        .and_then(|r| r.references.clone())
        .unwrap_or_default();
    let discovered_names: std::collections::HashSet<String> = discovered_references
        .iter()
        .map(|r| r.browse_name.name.as_ref().to_string())
        .collect();
    for expected_tag in ["Start_PB", "Temp", "Counter"] {
        if !discovered_names.contains(expected_tag) {
            return Err(format!(
                "top-down browse (Root -> Objects -> variables) did not reach tag {expected_tag:?}; found {discovered_names:?}"
            ));
        }
    }
    println!(
        "[probe] top-down browse OK: reached {discovered_names:?} via Root -> Objects (not by addressing Objects directly)"
    );

    // --- Step 2: Browse the Objects folder ---------------------------
    println!("[probe] Browse Objects (i=85)...");
    let objects_node_id: NodeId = ObjectId::ObjectsFolder.into();
    let browse_description = BrowseDescription {
        node_id: objects_node_id,
        browse_direction: BrowseDirection::Forward,
        reference_type_id: ReferenceTypeId::Organizes.into(),
        include_subtypes: true,
        node_class_mask: 0,
        result_mask: 0x3F, // all defined ReferenceDescription fields
    };
    let browse_results = session
        .browse(&[browse_description])
        .map_err(|e| format!("Browse failed: {e}"))?
        .ok_or_else(|| "Browse returned no results at all".to_string())?;
    let references = browse_results
        .first()
        .and_then(|r| r.references.clone())
        .unwrap_or_default();
    if references.is_empty() {
        return Err("Browse of the Objects folder returned zero references (expected the 3 mapped tags)".to_string());
    }
    println!("[probe] Browse OK: {} reference(s) under Objects", references.len());
    for r in &references {
        println!("[probe]   -> {} ({})", r.browse_name.name.as_ref(), r.node_id.node_id);
    }

    // --- Step 3: Read a named ReadOnly variable's Value ---------------
    println!("[probe] Read {NODE_TEMP}.Value...");
    let temp_node = NodeId::from_str(NODE_TEMP).map_err(|_| format!("bad NodeId literal {NODE_TEMP}"))?;
    let read_temp = ReadValueId {
        node_id: temp_node,
        attribute_id: AttributeId::Value as u32,
        index_range: opcua::types::UAString::null(),
        data_encoding: opcua::types::QualifiedName::null(),
    };
    let read_results = session
        .read(&[read_temp], TimestampsToReturn::Neither, 0.0)
        .map_err(|e| format!("Read({NODE_TEMP}) failed: {e}"))?;
    let temp_value = read_results
        .first()
        .ok_or_else(|| "Read returned zero results".to_string())?
        .value
        .clone();
    println!("[probe] Read {NODE_TEMP} -> {temp_value:?}");
    match temp_value {
        Some(Variant::Double(_)) => {}
        other => return Err(format!("expected a Double Variant reading {NODE_TEMP}, got {other:?}")),
    }

    // --- Step 4: Write a ReadWrite variable ---------------------------
    println!("[probe] Write {NODE_COUNTER}.Value = 4242...");
    let counter_node = NodeId::from_str(NODE_COUNTER).map_err(|_| format!("bad NodeId literal {NODE_COUNTER}"))?;
    let write_value = WriteValue {
        node_id: counter_node.clone(),
        attribute_id: AttributeId::Value as u32,
        index_range: opcua::types::UAString::null(),
        value: DataValue::new_now(Variant::Int32(4242)),
    };
    let write_results = session
        .write(&[write_value])
        .map_err(|e| format!("Write({NODE_COUNTER}) failed: {e}"))?;
    let write_status = write_results
        .first()
        .ok_or_else(|| "Write returned zero results".to_string())?;
    if !write_status.is_good() {
        return Err(format!("Write({NODE_COUNTER}) returned non-Good status: {write_status:?}"));
    }
    println!("[probe] Write OK.");

    // --- Step 5: Read the ReadWrite variable back and verify ----------
    println!("[probe] Read {NODE_COUNTER}.Value back to verify...");
    let read_counter = ReadValueId {
        node_id: counter_node,
        attribute_id: AttributeId::Value as u32,
        index_range: opcua::types::UAString::null(),
        data_encoding: opcua::types::QualifiedName::null(),
    };
    let read_back = session
        .read(&[read_counter], TimestampsToReturn::Neither, 0.0)
        .map_err(|e| format!("Read-back({NODE_COUNTER}) failed: {e}"))?;
    let counter_value = read_back
        .first()
        .ok_or_else(|| "Read-back returned zero results".to_string())?
        .value
        .clone();
    println!("[probe] Read-back {NODE_COUNTER} -> {counter_value:?}");
    match counter_value {
        Some(Variant::Int32(4242)) => {}
        other => {
            return Err(format!(
                "expected Int32(4242) reading {NODE_COUNTER} back after the write, got {other:?}"
            ))
        }
    }

    // --- Step 6: Subscribe to data changes and observe a server-side push --
    //
    // This is the machine-proof that a real, independent OPC UA client
    // receives *pushed* data changes from the in-app Dart server's
    // subscription engine (WS20), as opposed to only ever polling with
    // Read. The Dart fixture host (`mobile/tool/opcua_host_probe.dart`)
    // mutates `NODE_COUNTER` server-side to `SUBSCRIPTION_EXPECTED_VALUE`
    // (7777) at T+4s after printing READY, entirely independently of this
    // client -- so a DataChangeNotification arriving with that value can
    // only have come from the server's own publish loop, not from anything
    // this probe wrote.
    //
    // The `opcua` client crate's synchronous service calls (`browse`,
    // `read`, `write` above, and `create_subscription`/
    // `create_monitored_items` below) all work against the `Session`
    // directly. But actually *receiving* publish responses (and thus
    // getting the `DataChangeCallback` invoked) requires the session's
    // background poll loop to be running -- see `Session::run_async` in
    // the vendored crate (`client/session/session.rs`), which spawns a
    // thread that repeatedly calls `session.poll()`. Without that running,
    // PublishRequests are never sent/serviced and no notifications ever
    // arrive, no matter how long we wait. So: create the subscription and
    // monitored item first (still fine synchronously on the read-locked
    // session), THEN start `run_async` on the shared `Arc<RwLock<Session>>`
    // to drive the actual publish/notify traffic.
    println!("[probe] creating subscription (publishing interval 500ms)...");
    let (tx, rx) = mpsc::channel::<Variant>();
    // `mpsc::Sender` is `Send` but not `Sync`, and `DataChangeCallback::new`
    // requires `Fn(..) + Send + Sync + 'static` (the crate may invoke the
    // callback from its poll thread, but the bound still demands `Sync`).
    // Wrap it in a `Mutex` so the whole captured closure is `Sync`.
    let tx = std::sync::Mutex::new(tx);
    let subscription_id = session
        .create_subscription(
            500.0, // publishing_interval (ms)
            30,    // lifetime_count
            10,    // max_keep_alive_count
            0,     // max_notifications_per_publish (0 = no limit)
            0,     // priority
            true,  // publishing_enabled
            DataChangeCallback::new(move |changed_monitored_items| {
                for item in changed_monitored_items {
                    let data_value = item.last_value();
                    if let Some(value) = data_value.value.clone() {
                        println!("[probe] data change callback: {value:?}");
                        if let Ok(sender) = tx.lock() {
                            let _ = sender.send(value);
                        }
                    }
                }
            }),
        )
        .map_err(|e| format!("create_subscription failed: {e}"))?;
    println!("[probe] subscription created: id={subscription_id}");

    println!("[probe] creating monitored item on {NODE_COUNTER} (queue size 10, no filter)...");
    let monitor_node = NodeId::from_str(NODE_COUNTER).map_err(|_| format!("bad NodeId literal {NODE_COUNTER}"))?;
    let item_to_monitor = ReadValueId {
        node_id: monitor_node,
        attribute_id: AttributeId::Value as u32,
        index_range: opcua::types::UAString::null(),
        data_encoding: opcua::types::QualifiedName::null(),
    };
    let create_request = MonitoredItemCreateRequest::new(
        item_to_monitor,
        MonitoringMode::Reporting,
        MonitoringParameters {
            client_handle: 0,
            sampling_interval: -1.0, // inherit the subscription's publishing interval
            filter: ExtensionObject::null(),
            queue_size: 10,
            discard_oldest: true,
        },
    );
    let create_results = session
        .create_monitored_items(subscription_id, TimestampsToReturn::Both, &[create_request])
        .map_err(|e| format!("create_monitored_items failed: {e}"))?;
    let create_result = create_results
        .first()
        .ok_or_else(|| "create_monitored_items returned zero results".to_string())?;
    if !create_result.status_code.is_good() {
        return Err(format!(
            "create_monitored_items returned non-Good status: {:?}",
            create_result.status_code
        ));
    }
    println!(
        "[probe] monitored item created: id={} revised_queue_size={}",
        create_result.monitored_item_id, create_result.revised_queue_size
    );

    // The session was only read-locked so far (fine for the synchronous
    // service calls above). Drop that guard before handing the shared Arc
    // to `Session::run_async`, which needs to take its own write lock on
    // every poll iteration.
    drop(session);

    println!("[probe] starting session poll loop (Session::run_async) to drive publishing...");
    let _run_handle = Session::run_async(session_arc.clone());

    println!(
        "[probe] waiting up to 10s for a DataChangeNotification with value {SUBSCRIPTION_EXPECTED_VALUE}..."
    );
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut observed_expected = false;
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match rx.recv_timeout(remaining) {
            Ok(Variant::Int32(v)) if v == SUBSCRIPTION_EXPECTED_VALUE => {
                observed_expected = true;
                break;
            }
            Ok(other) => {
                println!("[probe] (ignoring intermediate data change: {other:?})");
            }
            Err(mpsc::RecvTimeoutError::Timeout) => break,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("data change channel disconnected while waiting for subscription notification".to_string());
            }
        }
    }

    if !observed_expected {
        return Err(format!(
            "timed out after 10s waiting for a DataChangeNotification with value {SUBSCRIPTION_EXPECTED_VALUE} on {NODE_COUNTER}"
        ));
    }
    println!("[probe] observed pushed DataChangeNotification: {NODE_COUNTER} = {SUBSCRIPTION_EXPECTED_VALUE}");
    println!("SUBSCRIPTION PASS");

    let session = session_arc.read();
    session.disconnect();
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let endpoint_url = match args.get(1) {
        Some(u) => u.clone(),
        None => {
            eprintln!("usage: opcua_probe <opc.tcp://host:port>");
            eprintln!("PROBE FAIL: missing endpoint URL argument");
            return ExitCode::FAILURE;
        }
    };

    match run(&endpoint_url) {
        Ok(()) => {
            println!("PROBE PASS");
            ExitCode::SUCCESS
        }
        Err(reason) => {
            println!("PROBE FAIL: {reason}");
            ExitCode::FAILURE
        }
    }
}
