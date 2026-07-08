//! Machine-proof that a REAL, independent, third-party MQTT broker
//! (`rumqttd`, embedded here) and a REAL third-party MQTT subscriber client
//! (`rumqttc`) can receive the in-app pure-Dart MQTT/Sparkplug B PUBLISHER
//! client's (`mobile/lib/services/mqtt_host.dart`'s wire-level logic, driven
//! here by the headless fixture `mobile/tool/mqtt_host_probe.dart` — see that
//! file's doc comment for why it reimplements the socket loop against the
//! pure `mqtt_codec.dart`/`mqtt_publisher.dart` modules directly rather than
//! importing `MqttHost` itself) birth/telemetry/command traffic, in BOTH
//! payload formats (flat JSON and Sparkplug B protobuf), and that a
//! `prost`-decoded Sparkplug B NBIRTH/NDATA carries the exact metrics/
//! aliases/bdSeq this app's encoder (`mqtt_sparkplug.dart`) is documented to
//! produce.
//!
//! ROLE REVERSAL vs. `modbus_probe.rs`/`opcua_probe.rs`: those probes are
//! MQTT/Modbus/OPC UA *clients* dialing INTO an in-app Dart *server*. Here
//! the roles are inverted -- the app is an outbound MQTT *client*
//! (publisher), so THIS Rust binary hosts the broker (server role) itself,
//! then spawns the Dart fixture as a client that dials into it. Consequently
//! (unlike `tool/modbus_e2e.sh`/`tool/opcua_e2e.sh`, which start the Dart
//! side first and wait for its own "READY" stdout line before running the
//! Rust probe) ALL orchestration -- starting the broker, spawning each Dart
//! fixture run, subscribing, asserting, publishing remote-write commands --
//! happens inside this one binary; `tool/mqtt_e2e.sh` is a thin wrapper.
//!
//! Usage: `cargo run --manifest-path gateway/Cargo.toml --example mqtt_probe`
//! (no arguments -- the broker port and the Dart fixture's project shape are
//! fixed constants shared between this file and
//! `mobile/tool/mqtt_host_probe.dart`; see the doc comments below).
//!
//! Two sequential phases against ONE embedded broker instance (safe to
//! share: JSON traffic lives under `softplc/...`, Sparkplug B under
//! `spBv1.0/...` -- disjoint topic trees, so retained state from one phase
//! can never taint the other's assertions):
//!
//! Phase 1 (JSON): spawn the Dart fixture with `json` format, then assert:
//!   1. retained birth `softplc/PLC_E2E/status` == "ONLINE".
//!   2. a telemetry publish `softplc/PLC_E2E/tags/Forced_Bool` whose JSON
//!      body's `value` is `true` -- proof a forced tag's value (its live
//!      `value` is `false`) reaches MQTT telemetry, exactly like the
//!      Modbus/OPC UA probes' forced-read proofs.
//!   3. a telemetry publish `softplc/PLC_E2E/tags/Counter` with `value:4242`
//!      -- the fixture's own T+3s server-side mutation (independent of any
//!      client), proving report-by-exception telemetry reflects a live
//!      change, not a frozen snapshot.
//!   4. publish `softplc/PLC_E2E/tags/Speed/set` with `{"value":777}`, then
//!      observe the NEXT `softplc/PLC_E2E/tags/Speed` telemetry carries
//!      `value:777` -- the JSON remote-write round-trip proof.
//!
//! Phase 2 (Sparkplug B): kill the JSON fixture, spawn a FRESH Dart fixture
//! with `sparkplug` format, then assert:
//!   1. retained NBIRTH `spBv1.0/SoftPLC/NBIRTH/E2ENode`, `prost`-decoded:
//!      seq==0, one aliased metric per mapped tag (`Forced_Bool` alias 1
//!      boolean_value==true; `Counter` alias 2 int_value==100; `Speed`
//!      alias 3 int_value==10) plus a `bdSeq` metric (no alias,
//!      long_value==1 -- `willMessage()` advanced bdSeq to 1 before this
//!      birth, per `mqtt_publisher.dart`'s bdSeq-pairing convention).
//!   2. an NDATA whose metrics include alias 2 (`Counter`) with
//!      `int_value==4242` -- the T+3s server-side mutation reaching a
//!      Sparkplug NDATA.
//!   3. publish an NCMD (`spBv1.0/SoftPLC/NCMD/E2ENode`) with alias 3
//!      (`Speed`) `int_value=999`, then observe the NEXT NDATA carries
//!      alias 3 `int_value==999` -- the Sparkplug remote-write round-trip
//!      proof.
//!
//! Prints `MQTT PROBE PASS` and exits 0 only if EVERY assertion above (both
//! phases) passed; on any failure prints `MQTT PROBE FAIL: <reason>` and
//! exits 1 -- never panics past the top level.
#[path = "support/sparkplug_pb.rs"]
mod sparkplug_pb;

use std::collections::HashMap;
use std::net::SocketAddr;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use prost::Message as _;
use rumqttc::{AsyncClient, Event, MqttOptions, Packet, Publish, QoS};
use rumqttd::{Broker, Config, ConnectionSettings, RouterConfig, ServerSettings};
use serde_json::Value as Json;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::time::timeout;

use sparkplug_pb::{datatype, Metric as PbMetric, Payload as PbPayload};

/// Fixed TCP port for the embedded `rumqttd` broker. Distinct from
/// `modbus_probe`'s 48600 and `opcua_probe`'s 48400 so all three E2E probes
/// could in principle run concurrently without colliding.
const BROKER_PORT: u16 = 48700;

/// Must match `mobile/tool/mqtt_host_probe.dart`'s fixture project exactly
/// (controller name / group id / edge node id / base topic) -- these feed
/// directly into the topic strings asserted below.
const BASE_TOPIC: &str = "softplc";
const CONTROLLER_NAME: &str = "PLC_E2E";
const GROUP_ID: &str = "SoftPLC";
const EDGE_NODE: &str = "E2ENode";

/// The value `mobile/tool/mqtt_host_probe.dart` mutates its `Counter` tag to
/// at T+3s after CONNACK, entirely independently of this probe -- the
/// server-side-change proof (mirrors `modbus_probe.rs`'s
/// `SERVER_MUTATED_HOLDING_VALUE`).
const MUTATED_COUNTER_VALUE: i64 = 4242;

/// Value this probe writes to `Speed` via the JSON `/set` topic.
const JSON_WRITTEN_SPEED_VALUE: i64 = 777;
/// Value this probe writes to `Speed` via a Sparkplug NCMD.
const SPARKPLUG_WRITTEN_SPEED_VALUE: i64 = 999;

/// Generous bound for each individual wait -- the Dart fixture's own T+3s
/// mutation plus process startup/broker handshake overhead comfortably fits
/// well inside this on a slow CI/build machine.
const WAIT_BOUND: Duration = Duration::from_secs(15);

fn status_topic() -> String {
    format!("{BASE_TOPIC}/{CONTROLLER_NAME}/status")
}
fn tag_topic(metric: &str) -> String {
    format!("{BASE_TOPIC}/{CONTROLLER_NAME}/tags/{metric}")
}
fn tag_set_topic(metric: &str) -> String {
    format!("{BASE_TOPIC}/{CONTROLLER_NAME}/tags/{metric}/set")
}
fn nbirth_topic() -> String {
    format!("spBv1.0/{GROUP_ID}/NBIRTH/{EDGE_NODE}")
}
fn ndata_topic() -> String {
    format!("spBv1.0/{GROUP_ID}/NDATA/{EDGE_NODE}")
}
fn ncmd_topic() -> String {
    format!("spBv1.0/{GROUP_ID}/NCMD/{EDGE_NODE}")
}

/// Builds a minimal embedded-broker `Config`: one plain TCP (MQTT 3.1.1)
/// listener on `127.0.0.1:{port}`, no TLS/v5/websocket/cluster/console/
/// prometheus/metrics -- everything this probe needs and nothing it doesn't.
/// Built directly in code (no `rumqttd.toml`/`config` crate dependency).
fn broker_config(port: u16) -> Config {
    let mut v4 = HashMap::new();
    v4.insert(
        "1".to_string(),
        ServerSettings {
            name: "v4-1".to_string(),
            listen: SocketAddr::from(([127, 0, 0, 1], port)),
            tls: None,
            next_connection_delay_ms: 1,
            connections: ConnectionSettings {
                connection_timeout_ms: 60_000,
                max_payload_size: 5 * 1024 * 1024,
                max_inflight_count: 100,
                auth: None,
                external_auth: None,
                dynamic_filters: true,
            },
        },
    );

    Config {
        id: 0,
        router: RouterConfig {
            max_connections: 100,
            max_outgoing_packet_count: 200,
            max_segment_size: 104_857_600,
            max_segment_count: 10,
            custom_segment: None,
            initialized_filters: None,
            shared_subscriptions_strategy: Default::default(),
        },
        v4: Some(v4),
        v5: None,
        ws: None,
        cluster: None,
        console: None,
        bridge: None,
        prometheus: None,
        metrics: None,
    }
}

/// Spawns the Dart fixture host (`mobile/tool/mqtt_host_probe.dart`) as a
/// child process, connecting out to the embedded broker on `BROKER_PORT`
/// with the given payload `format` (`"json"` or `"sparkplug"`).
///
/// Windows note: `dart` on PATH resolves to `dart.bat` (a batch wrapper),
/// not a directly-executable PE image -- `cmd /C` is the reliable way to
/// invoke it from a native Win32 `CreateProcess` call (mirrors the
/// Windows-specific handling `tool/modbus_e2e.sh`/`tool/opcua_e2e.sh` already
/// need for the same underlying `dart.bat`-wrapper reason, just from Rust
/// instead of Bash).
fn spawn_dart_fixture(format: &str) -> Result<Child, String> {
    let mobile_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../mobile");
    let mut cmd = if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.args(["/C", "dart", "run", "tool/mqtt_host_probe.dart"]);
        c
    } else {
        let mut c = Command::new("dart");
        c.args(["run", "tool/mqtt_host_probe.dart"]);
        c
    };
    cmd.arg(BROKER_PORT.to_string())
        .arg(format)
        .current_dir(&mobile_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    cmd.spawn()
        .map_err(|e| format!("failed to spawn Dart fixture ({format}): {e}"))
}

/// Kills `child` and (on Windows) its whole process subtree via
/// `taskkill /F /T /PID` -- necessary because the immediate child is
/// `cmd.exe` (or, without the wrapper, an implicit one Windows creates to
/// run `dart.bat`), NOT the real `dart.exe` that does the actual work;
/// `Child::kill()` alone would only kill the batch-wrapper shell and leave
/// `dart.exe` running. Mirrors the same real-PID concern documented in
/// `tool/modbus_e2e.sh`'s "PID NOTE", just solved via `taskkill /T` instead
/// of a `netstat`-discovered listening-socket PID (this Dart process is an
/// outbound client, not a listener, so there's no port to discover it by).
fn kill_dart_fixture(child: &mut Child) {
    if cfg!(windows) {
        let _ = Command::new("taskkill")
            .args(["/F", "/T", "/PID", &child.id().to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// Waits (bounded by [WAIT_BOUND]) for the next `Publish` from `rx` matching
/// `pred`, discarding (and logging) anything that doesn't match -- messages
/// from the phase not currently under test, self-echoed `/set`/NCMD
/// publishes this probe itself sent, or an earlier heartbeat that hasn't yet
/// picked up a later mutation, all simply fail `pred` and are skipped.
async fn wait_for<F>(
    rx: &mut mpsc::UnboundedReceiver<Publish>,
    desc: &str,
    mut pred: F,
) -> Result<Publish, String>
where
    F: FnMut(&Publish) -> bool,
{
    let deadline = Instant::now() + WAIT_BOUND;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!("timed out after {WAIT_BOUND:?} waiting for {desc}"));
        }
        match timeout(remaining, rx.recv()).await {
            Ok(Some(p)) => {
                if pred(&p) {
                    return Ok(p);
                }
                println!(
                    "[probe] (ignoring {} bytes on {:?} while waiting for {desc})",
                    p.payload.len(),
                    p.topic
                );
            }
            Ok(None) => return Err(format!("subscriber event channel closed waiting for {desc}")),
            Err(_) => return Err(format!("timed out after {WAIT_BOUND:?} waiting for {desc}")),
        }
    }
}

fn json_body(p: &Publish) -> Result<Json, String> {
    serde_json::from_slice(&p.payload).map_err(|e| format!("payload on {:?} wasn't valid JSON: {e}", p.topic))
}

fn decode_sparkplug(p: &Publish) -> Result<PbPayload, String> {
    PbPayload::decode(&p.payload[..]).map_err(|e| format!("payload on {:?} wasn't a valid Sparkplug Payload: {e}", p.topic))
}

fn find_metric<'a>(payload: &'a PbPayload, alias: Option<u64>, name: Option<&str>) -> Option<&'a PbMetric> {
    payload.metrics.iter().find(|m| {
        (alias.is_some() && m.alias == alias) || (name.is_some() && m.name.as_deref() == name)
    })
}

/// Proves `topic` is genuinely RETAINED on the broker (not just "happened to
/// carry retain=1 on the wire") by connecting a BRAND-NEW subscriber
/// (`client_id`) that subscribes to `topic` for the first time — per MQTT
/// 3.1.1 section 3.3.1.3 (rule MQTT-3.3.1-9), a broker MUST set RETAIN=0 on
/// a live PUBLISH forwarded to a client whose subscription already existed
/// at publish time (which is why the primary subscriber's live view of the
/// birth/NBIRTH messages correctly sees `retain: false` — that is NOT a
/// bug), and MUST set RETAIN=1 when replaying the last retained message to
/// a client subscribing for the first time — exactly the case this
/// exercises. Bounded by [WAIT_BOUND].
async fn assert_retained(client_id: &str, topic: &str, desc: &str) -> Result<Publish, String> {
    let mut mqttoptions = MqttOptions::new(client_id, "127.0.0.1", BROKER_PORT);
    mqttoptions.set_keep_alive(Duration::from_secs(30));
    mqttoptions.set_clean_session(true);
    let (client, mut eventloop) = AsyncClient::new(mqttoptions, 16);
    client
        .subscribe(topic, QoS::AtLeastOnce)
        .await
        .map_err(|e| format!("(retention check) subscribe {topic} failed: {e}"))?;

    let deadline = Instant::now() + WAIT_BOUND;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "timed out after {WAIT_BOUND:?} waiting for a RETAINED replay of {desc} on a fresh subscribe to {topic:?}"
            ));
        }
        match timeout(remaining, eventloop.poll()).await {
            Ok(Ok(Event::Incoming(Packet::Publish(p)))) if p.topic == topic => {
                if !p.retain {
                    return Err(format!(
                        "fresh subscribe to {topic:?} received {desc} but RETAIN was not set (not actually retained on the broker)"
                    ));
                }
                let _ = client.disconnect().await;
                return Ok(p);
            }
            Ok(Ok(_)) => {}
            Ok(Err(e)) => return Err(format!("(retention check) eventloop error waiting for {desc}: {e}")),
            Err(_) => {
                return Err(format!(
                    "timed out after {WAIT_BOUND:?} waiting for a RETAINED replay of {desc} on a fresh subscribe to {topic:?}"
                ))
            }
        }
    }
}

async fn run() -> Result<(), String> {
    // --- Start the embedded rumqttd broker -------------------------------
    println!("[probe] starting embedded rumqttd broker on 127.0.0.1:{BROKER_PORT}...");
    let mut broker = Broker::new(broker_config(BROKER_PORT));
    std::thread::spawn(move || {
        if let Err(e) = broker.start() {
            eprintln!("[probe] (background) broker stopped: {e}");
        }
    });

    // Poll-connect until the broker's TCP listener is actually bound.
    let bind_deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match TcpStream::connect(("127.0.0.1", BROKER_PORT)).await {
            Ok(_) => break,
            Err(e) => {
                if Instant::now() >= bind_deadline {
                    return Err(format!("broker never started listening on port {BROKER_PORT}: {e}"));
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
    println!("[probe] broker is accepting connections.");

    // --- Connect the rumqttc subscriber (also used to publish commands) --
    let mut mqttoptions = MqttOptions::new("e2e-subscriber", "127.0.0.1", BROKER_PORT);
    mqttoptions.set_keep_alive(Duration::from_secs(30));
    mqttoptions.set_clean_session(true);
    let (client, mut eventloop) = AsyncClient::new(mqttoptions, 64);
    client
        .subscribe(format!("{BASE_TOPIC}/#"), QoS::AtLeastOnce)
        .await
        .map_err(|e| format!("subscribe softplc/# failed: {e}"))?;
    client
        .subscribe("spBv1.0/#", QoS::AtLeastOnce)
        .await
        .map_err(|e| format!("subscribe spBv1.0/# failed: {e}"))?;

    let (tx, mut rx) = mpsc::unbounded_channel::<Publish>();
    tokio::spawn(async move {
        loop {
            match eventloop.poll().await {
                Ok(Event::Incoming(Packet::Publish(p))) => {
                    let _ = tx.send(p);
                }
                Ok(_) => {}
                Err(e) => {
                    eprintln!("[probe] (background) subscriber eventloop error: {e}");
                    break;
                }
            }
        }
    });
    // Give the broker a moment to register the subscription before the
    // Dart fixture (spawned next) starts publishing.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // ======================================================================
    // Phase 1: JSON
    // ======================================================================
    println!("[probe] === Phase 1: JSON format ===");
    let mut json_child = spawn_dart_fixture("json")?;

    // NOTE: the PRIMARY subscriber already had a matching subscription
    // (`softplc/#`) in place before the Dart fixture connected, so per MQTT
    // 3.1.1 rule MQTT-3.3.1-9 the broker correctly delivers this live birth
    // with RETAIN cleared to 0 -- retention itself is proven separately
    // below via a brand-new subscriber (`assert_retained`), which the spec
    // requires the broker to set RETAIN=1 for.
    let birth = wait_for(&mut rx, "JSON birth ONLINE", |p| p.topic == status_topic()).await?;
    if birth.payload.as_ref() != b"ONLINE" {
        kill_dart_fixture(&mut json_child);
        return Err(format!("JSON birth payload was {:?}, expected b\"ONLINE\"", birth.payload));
    }
    println!("[probe] JSON birth OK: {} = ONLINE", status_topic());

    if let Err(e) = assert_retained("e2e-retain-check-json", &status_topic(), "JSON birth ONLINE").await {
        kill_dart_fixture(&mut json_child);
        return Err(e);
    }
    println!("[probe] JSON birth retention OK: a fresh subscribe to {} replays ONLINE with RETAIN=1", status_topic());

    let forced = wait_for(&mut rx, "JSON telemetry for Forced_Bool", |p| p.topic == tag_topic("Forced_Bool")).await;
    let forced = match forced {
        Ok(p) => p,
        Err(e) => {
            kill_dart_fixture(&mut json_child);
            return Err(e);
        }
    };
    let forced_body = match json_body(&forced) {
        Ok(v) => v,
        Err(e) => {
            kill_dart_fixture(&mut json_child);
            return Err(e);
        }
    };
    if forced_body.get("value") != Some(&Json::Bool(true)) || forced_body.get("forced") != Some(&Json::Bool(true)) {
        kill_dart_fixture(&mut json_child);
        return Err(format!(
            "expected Forced_Bool telemetry {{value:true, forced:true}}, got {forced_body:?}"
        ));
    }
    println!("[probe] JSON forced-tag telemetry OK: Forced_Bool = {forced_body:?}");

    let counter_changed = wait_for(&mut rx, "JSON telemetry Counter == 4242 (server-side mutation)", |p| {
        p.topic == tag_topic("Counter")
            && serde_json::from_slice::<Json>(&p.payload)
                .ok()
                .and_then(|v| v.get("value").cloned())
                == Some(Json::from(MUTATED_COUNTER_VALUE))
    })
    .await;
    if let Err(e) = counter_changed {
        kill_dart_fixture(&mut json_child);
        return Err(e);
    }
    println!("[probe] JSON server-side-mutation telemetry OK: Counter = {MUTATED_COUNTER_VALUE}");

    println!("[probe] publishing JSON remote-write: {} = {{\"value\":{JSON_WRITTEN_SPEED_VALUE}}}", tag_set_topic("Speed"));
    if let Err(e) = client
        .publish(
            tag_set_topic("Speed"),
            QoS::AtLeastOnce,
            false,
            format!("{{\"value\":{JSON_WRITTEN_SPEED_VALUE}}}").into_bytes(),
        )
        .await
    {
        kill_dart_fixture(&mut json_child);
        return Err(format!("publishing JSON /set failed: {e}"));
    }

    let speed_changed = wait_for(&mut rx, "JSON telemetry Speed == 777 (remote-write round-trip)", |p| {
        p.topic == tag_topic("Speed")
            && serde_json::from_slice::<Json>(&p.payload)
                .ok()
                .and_then(|v| v.get("value").cloned())
                == Some(Json::from(JSON_WRITTEN_SPEED_VALUE))
    })
    .await;
    kill_dart_fixture(&mut json_child);
    if let Err(e) = speed_changed {
        return Err(e);
    }
    println!("[probe] JSON remote-write round-trip OK: Speed = {JSON_WRITTEN_SPEED_VALUE}");

    // ======================================================================
    // Phase 2: Sparkplug B
    // ======================================================================
    println!("[probe] === Phase 2: Sparkplug B format ===");
    let mut sp_child = spawn_dart_fixture("sparkplug")?;

    let nbirth_pub = wait_for(&mut rx, "Sparkplug NBIRTH", |p| p.topic == nbirth_topic()).await;
    let nbirth_pub = match nbirth_pub {
        Ok(p) => p,
        Err(e) => {
            kill_dart_fixture(&mut sp_child);
            return Err(e);
        }
    };
    // Retention is proven separately below via a brand-new subscriber (see
    // `assert_retained`'s doc comment) -- this live delivery correctly has
    // RETAIN cleared per MQTT-3.3.1-9, same as the JSON birth above.
    let nbirth = match decode_sparkplug(&nbirth_pub) {
        Ok(v) => v,
        Err(e) => {
            kill_dart_fixture(&mut sp_child);
            return Err(e);
        }
    };
    if nbirth.seq != Some(0) {
        kill_dart_fixture(&mut sp_child);
        return Err(format!("expected NBIRTH seq == Some(0), got {:?}", nbirth.seq));
    }

    macro_rules! check_metric_or_fail {
        ($alias:expr, $name:expr, $datatype:expr, $field:ident, $expected:expr) => {{
            let m = match find_metric(&nbirth, Some($alias), Some($name)) {
                Some(m) => m,
                None => {
                    kill_dart_fixture(&mut sp_child);
                    return Err(format!("NBIRTH missing expected metric {} (alias {})", $name, $alias));
                }
            };
            if m.datatype != Some($datatype) || m.$field != Some($expected) {
                kill_dart_fixture(&mut sp_child);
                return Err(format!(
                    "NBIRTH metric {} = {:?} (datatype {:?}), expected datatype {} and {} == {:?}",
                    $name, m, m.datatype, $datatype, stringify!($field), $expected
                ));
            }
        }};
    }
    check_metric_or_fail!(1, "Forced_Bool", datatype::BOOLEAN, boolean_value, true);
    check_metric_or_fail!(2, "Counter", datatype::INT16, int_value, 100u32);
    check_metric_or_fail!(3, "Speed", datatype::INT16, int_value, 10u32);

    let bdseq = nbirth.metrics.iter().find(|m| m.name.as_deref() == Some("bdSeq"));
    match bdseq {
        Some(m) if m.alias.is_none() && m.datatype == Some(datatype::UINT64) && m.long_value == Some(1) => {
            println!("[probe] NBIRTH bdSeq OK: 1 (no alias, UInt64)");
        }
        other => {
            kill_dart_fixture(&mut sp_child);
            return Err(format!("expected NBIRTH bdSeq metric {{alias:None, datatype:UInt64, long_value:Some(1)}}, got {other:?}"));
        }
    }
    println!("[probe] Sparkplug NBIRTH OK: metrics/aliases + bdSeq all match.");

    if let Err(e) = assert_retained("e2e-retain-check-sparkplug", &nbirth_topic(), "Sparkplug NBIRTH").await {
        kill_dart_fixture(&mut sp_child);
        return Err(e);
    }
    println!("[probe] Sparkplug NBIRTH retention OK: a fresh subscribe to {} replays it with RETAIN=1", nbirth_topic());

    let ndata_mutated = wait_for(&mut rx, "Sparkplug NDATA carrying Counter == 4242", |p| {
        if p.topic != ndata_topic() {
            return false;
        }
        match decode_sparkplug(p) {
            Ok(payload) => find_metric(&payload, Some(2), None)
                .map(|m| m.int_value == Some(MUTATED_COUNTER_VALUE as u32))
                .unwrap_or(false),
            Err(_) => false,
        }
    })
    .await;
    if let Err(e) = ndata_mutated {
        kill_dart_fixture(&mut sp_child);
        return Err(e);
    }
    println!("[probe] Sparkplug server-side-mutation NDATA OK: alias 2 (Counter) = {MUTATED_COUNTER_VALUE}");

    let ncmd = PbPayload {
        timestamp: Some(0),
        seq: None,
        metrics: vec![PbMetric {
            name: None,
            alias: Some(3),
            datatype: Some(datatype::INT16),
            int_value: Some(SPARKPLUG_WRITTEN_SPEED_VALUE as u32),
            long_value: None,
            double_value: None,
            boolean_value: None,
            string_value: None,
        }],
    };
    println!("[probe] publishing Sparkplug NCMD: {} alias=3 (Speed) int_value={SPARKPLUG_WRITTEN_SPEED_VALUE}", ncmd_topic());
    if let Err(e) = client
        .publish(ncmd_topic(), QoS::AtLeastOnce, false, ncmd.encode_to_vec())
        .await
    {
        kill_dart_fixture(&mut sp_child);
        return Err(format!("publishing Sparkplug NCMD failed: {e}"));
    }

    let ndata_written = wait_for(&mut rx, "Sparkplug NDATA carrying Speed == 999 (remote-write round-trip)", |p| {
        if p.topic != ndata_topic() {
            return false;
        }
        match decode_sparkplug(p) {
            Ok(payload) => find_metric(&payload, Some(3), None)
                .map(|m| m.int_value == Some(SPARKPLUG_WRITTEN_SPEED_VALUE as u32))
                .unwrap_or(false),
            Err(_) => false,
        }
    })
    .await;
    kill_dart_fixture(&mut sp_child);
    if let Err(e) = ndata_written {
        return Err(e);
    }
    println!("[probe] Sparkplug remote-write round-trip OK: alias 3 (Speed) = {SPARKPLUG_WRITTEN_SPEED_VALUE}");

    Ok(())
}

#[tokio::main]
async fn main() -> std::process::ExitCode {
    match run().await {
        Ok(()) => {
            println!("MQTT PROBE PASS");
            std::process::ExitCode::SUCCESS
        }
        Err(reason) => {
            println!("MQTT PROBE FAIL: {reason}");
            std::process::ExitCode::FAILURE
        }
    }
}
