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
//! Browse the Objects folder (i=85) -> Read `Temp`'s Value -> Write
//! `Counter`'s Value -> Read `Counter` back and verify the write landed.
//! Prints `PROBE PASS` and exits 0 on success; on any failure prints
//! `PROBE FAIL: <reason>` and exits 1 — never panics past the top level.

use std::env;
use std::process::ExitCode;
use std::str::FromStr;

use opcua::client::prelude::{
    AttributeService, ClientBuilder, IdentityToken, MessageSecurityMode, UserTokenPolicy,
    ViewService,
};
use opcua::types::{
    AttributeId, BrowseDescription, BrowseDirection, DataValue, NodeId, ObjectId,
    ReferenceTypeId, ReadValueId, TimestampsToReturn, Variant, WriteValue,
};

const NODE_TEMP: &str = "ns=1;s=Temp";
const NODE_COUNTER: &str = "ns=1;s=Counter";

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

    let session = client
        .connect_to_endpoint(endpoint, IdentityToken::Anonymous)
        .map_err(|e| format!("connect_to_endpoint failed: {e}"))?;
    println!("[probe] session connected.");

    let session = session.read();

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
