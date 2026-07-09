//! Machine-proof that a REAL, independent, third-party DNP3 master (Step
//! Function I/O's `dnp3` crate's own master implementation -- not anything
//! hand-rolled by the Dart side) can perform a Class 0 integrity poll
//! against, and issue SELECT/DIRECT_OPERATE control on, the in-app pure-Dart
//! DNP3 OUTSTATION (WS26 DNP3 outstation Tasks 1-5:
//! `mobile/lib/models/dnp3_map.dart` +
//! `mobile/lib/protocols/dnp3/{dnp3_link,dnp3_transport,dnp3_app,dnp3_outstation}.dart`
//! + `mobile/lib/services/dnp3_host.dart`).
//!
//! This is the AUTHORITATIVE Task 6 validation of every real-master interop
//! concern the earlier tasks flagged for wire-level verification: CRC-16/DNP
//! correctness, the transport-segment header bit layout, the link-layer
//! response CONTROL byte (`0x44`), SELECT/OPERATE object matching, and the
//! g80v1 restart-clear IIN handshake (implicitly exercised -- the master's
//! own connection handshake tolerates the outstation's DEVICE_RESTART IIN
//! bit staying set, since this probe never issues the WRITE that clears it;
//! that IIN bit's own clear path is unit-tested in `dnp3_outstation_test.dart`).
//!
//! Usage:
//!   cargo run --manifest-path gateway/Cargo.toml --example dnp3_probe -- 127.0.0.1 <port>
//!
//! Talks to a server hosting a small fixture project with five mapped
//! points (see `mobile/tool/dnp3_host_probe.dart`, which this probe is
//! designed to run against via `tool/dnp3_e2e.sh`), outstation address 1024,
//! master address 1:
//!   - Binary Input   index 0 (g1v2)  `LimitSwitch`  = true
//!   - Analog Input   index 0 (g30v1) `Temperature`  = 4222 (32-bit int)
//!   - Analog Input   index 1 (g30v5) `FlowRate`     = 88.5 (float)
//!   - Binary Output  index 0 (g10v2/g12v1) `Motor`  -- FORCED: live value
//!     is `false`, forced value is `true`.
//!   - Analog Output  index 0 (g40v1/g41v1) `Setpoint` = 1000 (32-bit int),
//!     NOT forced.
//!
//! Steps:
//!   1. Spawn a `dnp3` master TCP channel + association (master address 1,
//!      outstation address 1024), `AssociationConfig::quiet()` (no automatic
//!      unsolicited-disable/startup-integrity/time-sync handshaking -- this
//!      v1 outstation doesn't implement unsolicited responses or time sync,
//!      so this probe drives every request explicitly instead of relying on
//!      the master's default automatic task sequence).
//!   2. Issue a Class 0 integrity poll (`ReadRequest::class0()`) and assert,
//!      via a custom `ReadHandler` capturing measurement values into a
//!      shared snapshot: the Binary Input, both Analog Inputs (int and
//!      float), AND the forced Binary Output reads back its FORCED value
//!      (`true`) rather than its live value (`false`) -- the falsifiable
//!      proof that a forced point's value reaches a real master's read, not
//!      just this codebase's own test doubles.
//!   3. DIRECT_OPERATE a CROB (g12v1, `OpType::LatchOn`) targeting the
//!      FORCED Binary Output and assert the master's `operate()` call
//!      itself fails with `CommandError::Response(CommandResponseError::
//!      BadStatus(CommandStatus::NotAuthorized))` -- the outstation's
//!      force-aware control-skip path (Task 4) rejecting a real master's
//!      command, not silently dropping or wrongly accepting it.
//!   4. DIRECT_OPERATE an analog-output-block (g41v1, 32-bit int) targeting
//!      the NOT-forced Analog Output and assert the master's `operate()`
//!      call succeeds.
//!   5. Re-issue the Class 0 poll and assert: the Analog Output now reads
//!      the new operated value (the change landed), AND the forced Binary
//!      Output still reads its forced value, unchanged (the rejected
//!      operate on step 3 never touched it).
//!   6. Issue a SELECT-then-OPERATE (`CommandMode::SelectBeforeOperate`,
//!      a real two-fragment SELECT + OPERATE pair from the master) analog-
//!      output-block on the Analog Output with a different value, and
//!      re-poll to confirm it landed -- this is the only step that
//!      exercises the outstation's SELECT handler and its byte-identical
//!      SELECT/OPERATE object-matching logic, another concern Task 4
//!      flagged for real-master verification (steps 3-5 above only ever
//!      use single-pass DIRECT_OPERATE).
//!
//! Prints `DNP3 PROBE PASS` and exits 0 on success; on any failure prints
//! `DNP3 PROBE FAIL: <reason>` and exits 1 -- never panics past the top
//! level.
use std::env;
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use dnp3::app::control::*;
use dnp3::app::measurement::*;
use dnp3::app::*;
use dnp3::decode::*;
use dnp3::link::*;
use dnp3::master::*;
use dnp3::tcp::*;

use tokio::time::timeout;

/// Fixed outstation/master link addresses, matching
/// `mobile/tool/dnp3_host_probe.dart`'s hardcoded `DnpProtocolConfig`.
const OUTSTATION_ADDRESS: u16 = 1024;
const MASTER_ADDRESS: u16 = 1;

/// Point indices within their respective DNP3 point types, matching the
/// Dart fixture's `DnpMap` entries.
const BI_INDEX: u16 = 0;
const AI_INT_INDEX: u16 = 0;
const AI_FLOAT_INDEX: u16 = 1;
const BO_INDEX: u16 = 0; // FORCED
const AO_INDEX: u16 = 0;

const EXPECTED_BI: bool = true;
const EXPECTED_AI_INT: f64 = 4222.0;
const EXPECTED_AI_FLOAT: f64 = 88.5;
/// `Motor`'s FORCED value (its live `value` is `false`) -- reading `true`
/// here can only mean the outstation's force-aware `readPath` resolver was
/// actually consulted by the Class 0 response builder.
const EXPECTED_BO_FORCED: bool = true;
const EXPECTED_AO_INITIAL: f64 = 1000.0;

/// Value this probe DIRECT_OPERATEs onto the (not-forced) Analog Output.
const AO_OPERATE_VALUE: i32 = 5000;

/// Value this probe SELECTs-then-OPERATEs onto the (not-forced) Analog
/// Output, in a second round exercising the SELECT/OPERATE two-pass path
/// (see Step 5 below).
const AO_SELECT_OPERATE_VALUE: i32 = 6000;

/// Per-call bound so a hung outstation can never make this probe (or the
/// CI job wrapping it) block forever.
const CALL_TIMEOUT: Duration = Duration::from_secs(10);

/// Measurement values captured off the wire by [CapturingHandler], keyed by
/// point index within each point type -- what every assertion below reads
/// back and checks.
#[derive(Default, Debug, Clone, Copy)]
struct Snapshot {
    bi: Option<bool>,
    ai_int: Option<f64>,
    ai_float: Option<f64>,
    bo: Option<bool>,
    ao: Option<f64>,
}

/// A [ReadHandler] that captures every measurement value this probe cares
/// about into a shared [Snapshot] rather than just printing them (as the
/// crate's own example `ReadHandler` does) -- this is what makes the Class
/// 0 poll's results assertable after `association.read()` returns.
struct CapturingHandler {
    snapshot: Arc<Mutex<Snapshot>>,
}

impl ReadHandler for CapturingHandler {
    fn handle_binary_input(
        &mut self,
        _info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (BinaryInput, u16)>,
    ) {
        let mut snap = self.snapshot.lock().unwrap();
        for (v, idx) in iter {
            if idx == BI_INDEX {
                snap.bi = Some(v.value);
            }
        }
    }

    fn handle_analog_input(
        &mut self,
        _info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (AnalogInput, u16)>,
    ) {
        let mut snap = self.snapshot.lock().unwrap();
        for (v, idx) in iter {
            if idx == AI_INT_INDEX {
                snap.ai_int = Some(v.value);
            } else if idx == AI_FLOAT_INDEX {
                snap.ai_float = Some(v.value);
            }
        }
    }

    fn handle_binary_output_status(
        &mut self,
        _info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (BinaryOutputStatus, u16)>,
    ) {
        let mut snap = self.snapshot.lock().unwrap();
        for (v, idx) in iter {
            if idx == BO_INDEX {
                snap.bo = Some(v.value);
            }
        }
    }

    fn handle_analog_output_status(
        &mut self,
        _info: HeaderInfo,
        iter: &mut dyn Iterator<Item = (AnalogOutputStatus, u16)>,
    ) {
        let mut snap = self.snapshot.lock().unwrap();
        for (v, idx) in iter {
            if idx == AO_INDEX {
                snap.ao = Some(v.value);
            }
        }
    }
}

/// Empty-impl association callbacks -- this probe doesn't need to react to
/// association lifecycle events, only to issue requests and inspect their
/// results. Mirrors the `dnp3` crate's own `master.rs` example.
#[derive(Copy, Clone)]
struct ProbeAssociationHandler;
impl AssociationHandler for ProbeAssociationHandler {}

#[derive(Copy, Clone)]
struct ProbeAssociationInformation;
impl AssociationInformation for ProbeAssociationInformation {}

/// Issues a bounded Class 0 integrity poll. The [CapturingHandler] attached
/// to `association` populates the shared [Snapshot] as a side effect before
/// this future resolves.
async fn class0_read(association: &mut AssociationHandle) -> Result<(), String> {
    timeout(
        CALL_TIMEOUT,
        association.read(ReadRequest::class_scan(Classes::class0())),
    )
    .await
        .map_err(|_| "Class 0 read timed out".to_string())?
        .map_err(|e| format!("Class 0 read failed: {e}"))
}

async fn run(host: &str, port: u16) -> Result<(), String> {
    let snapshot = Arc::new(Mutex::new(Snapshot::default()));
    let handler = CapturingHandler {
        snapshot: snapshot.clone(),
    };

    let master_address = EndpointAddress::try_new(MASTER_ADDRESS)
        .map_err(|e| format!("bad master address {MASTER_ADDRESS}: {e}"))?;
    let outstation_address = EndpointAddress::try_new(OUTSTATION_ADDRESS)
        .map_err(|e| format!("bad outstation address {OUTSTATION_ADDRESS}: {e}"))?;

    println!("[probe] spawning dnp3 master TCP channel targeting {host}:{port} (master addr {MASTER_ADDRESS}, outstation addr {OUTSTATION_ADDRESS})...");
    let mut config = MasterChannelConfig::new(master_address);
    // Full object-value decode logging -- if the real outstation's wire
    // format is wrong in some way this probe doesn't already assert on,
    // this is what surfaces it (per the task brief: "the master's error
    // logs will tell you what's wrong").
    config.decode_level = AppDecodeLevel::ObjectValues.into();

    let mut channel = spawn_master_tcp_client(
        LinkErrorMode::Close,
        config,
        EndpointList::new(format!("{host}:{port}"), &[]),
        ConnectStrategy::default(),
        NullListener::create(),
    );

    // `quiet()`: no automatic disable-unsolicited / startup-integrity-scan /
    // time-sync handshaking. This v1 outstation implements neither
    // unsolicited responses nor time synchronization (both explicitly
    // deferred -- see `docs/protocols/DNP3.md`), so this probe drives every
    // request it needs explicitly instead of relying on the master's
    // default automatic task sequence, which would otherwise issue requests
    // this outstation doesn't have dedicated support for.
    let assoc_config = AssociationConfig::quiet();

    let mut association = timeout(
        CALL_TIMEOUT,
        channel.add_association(
            outstation_address,
            assoc_config,
            Box::new(handler),
            Box::new(ProbeAssociationHandler),
            Box::new(ProbeAssociationInformation),
        ),
    )
    .await
    .map_err(|_| "add_association timed out".to_string())?
    .map_err(|e| format!("add_association failed: {e}"))?;

    timeout(CALL_TIMEOUT, channel.enable())
        .await
        .map_err(|_| "channel.enable() timed out".to_string())?
        .map_err(|e| format!("channel.enable() failed: {e}"))?;

    // --- Step 1: Class 0 integrity poll ------------------------------------
    println!("[probe] issuing Class 0 integrity poll...");
    class0_read(&mut association).await?;

    {
        let snap = *snapshot.lock().unwrap();
        println!("[probe] Class 0 snapshot: {snap:?}");
        if snap.bi != Some(EXPECTED_BI) {
            return Err(format!(
                "expected Binary Input[{BI_INDEX}] == {EXPECTED_BI}, got {:?}",
                snap.bi
            ));
        }
        if snap.ai_int != Some(EXPECTED_AI_INT) {
            return Err(format!(
                "expected Analog Input(int)[{AI_INT_INDEX}] == {EXPECTED_AI_INT}, got {:?}",
                snap.ai_int
            ));
        }
        if snap.ai_float != Some(EXPECTED_AI_FLOAT) {
            return Err(format!(
                "expected Analog Input(float)[{AI_FLOAT_INDEX}] == {EXPECTED_AI_FLOAT}, got {:?}",
                snap.ai_float
            ));
        }
        if snap.bo != Some(EXPECTED_BO_FORCED) {
            return Err(format!(
                "expected Binary Output[{BO_INDEX}] (FORCED) == {EXPECTED_BO_FORCED}, got {:?} -- the forced value did not reach the DNP3 read",
                snap.bo
            ));
        }
        if snap.ao != Some(EXPECTED_AO_INITIAL) {
            return Err(format!(
                "expected Analog Output[{AO_INDEX}] == {EXPECTED_AO_INITIAL}, got {:?}",
                snap.ao
            ));
        }
    }
    println!("[probe] Class 0 integrity poll OK: BI + AI(int) + AI(float) + forced BO + AO all match.");

    // --- Step 2: DIRECT_OPERATE a CROB on the FORCED Binary Output ---------
    //
    // `Motor` (Binary Output index 0) is forced -- Task 4's outstation
    // handler is documented to silently skip the write and report
    // NOT_AUTHORIZED for any control targeting a forced point. A real
    // master's `operate()` call surfacing that exact rejected status is the
    // falsifiable proof this reaches the wire correctly.
    println!("[probe] DIRECT_OPERATE CROB (LATCH_ON) on the FORCED Binary Output[{BO_INDEX}] -- expecting rejection...");
    let crob_result = timeout(
        CALL_TIMEOUT,
        association.operate(
            CommandMode::DirectOperate,
            CommandBuilder::single_header_u16(Group12Var1::from_op_type(OpType::LatchOn), BO_INDEX),
        ),
    )
    .await
    .map_err(|_| "DIRECT_OPERATE CROB on the forced Binary Output timed out".to_string())?;

    match crob_result {
        Err(CommandError::Response(CommandResponseError::BadStatus(CommandStatus::NotAuthorized))) => {
            println!("[probe] forced-tag CROB correctly REJECTED by the outstation: BadStatus(NotAuthorized).");
        }
        other => {
            return Err(format!(
                "expected DIRECT_OPERATE CROB on the FORCED Binary Output[{BO_INDEX}] to be rejected with BadStatus(NotAuthorized), got {other:?}"
            ));
        }
    }

    // --- Step 3: DIRECT_OPERATE an analog-output-block on the Analog Output
    //
    // `Setpoint` (Analog Output index 0) is NOT forced -- this operate is
    // expected to succeed.
    println!(
        "[probe] DIRECT_OPERATE analog-output-block (g41v1, value={AO_OPERATE_VALUE}) on Analog Output[{AO_INDEX}]..."
    );
    timeout(
        CALL_TIMEOUT,
        association.operate(
            CommandMode::DirectOperate,
            CommandBuilder::single_header_u16(Group41Var1::new(AO_OPERATE_VALUE), AO_INDEX),
        ),
    )
    .await
    .map_err(|_| "DIRECT_OPERATE analog-output-block timed out".to_string())?
    .map_err(|e| {
        format!("DIRECT_OPERATE analog-output-block on Analog Output[{AO_INDEX}] failed: {e}")
    })?;
    println!("[probe] analog-output-block DIRECT_OPERATE accepted.");

    // --- Step 4: re-poll and assert the changed value / the unchanged value
    println!("[probe] re-polling Class 0 to confirm the operate results...");
    class0_read(&mut association).await?;

    {
        let snap = *snapshot.lock().unwrap();
        println!("[probe] post-operate Class 0 snapshot: {snap:?}");
        if snap.ao != Some(AO_OPERATE_VALUE as f64) {
            return Err(format!(
                "expected Analog Output[{AO_INDEX}] == {AO_OPERATE_VALUE} after DIRECT_OPERATE, got {:?}",
                snap.ao
            ));
        }
        if snap.bo != Some(EXPECTED_BO_FORCED) {
            return Err(format!(
                "expected Binary Output[{BO_INDEX}] (FORCED) to remain {EXPECTED_BO_FORCED} after the rejected DIRECT_OPERATE, got {:?} -- the forced tag's value changed!",
                snap.bo
            ));
        }
    }
    println!(
        "[probe] re-poll OK: Analog Output changed to {AO_OPERATE_VALUE}; forced Binary Output unchanged at {EXPECTED_BO_FORCED}."
    );

    // --- Step 5: SELECT-then-OPERATE (two-pass) on the Analog Output -------
    //
    // Everything above used DIRECT_OPERATE (single-pass), which never
    // exercises the outstation's SELECT handler or its byte-identical
    // SELECT/OPERATE object-matching logic (`_objectsMatch` in
    // `dnp3_outstation.dart`) -- one of the concerns Task 4 flagged for
    // real-master verification. `CommandMode::SelectBeforeOperate` makes the
    // `dnp3` master issue a real SELECT fragment followed by a real OPERATE
    // fragment carrying the identical control object, so a success here is
    // the falsifiable proof that the outstation's SELECT/OPERATE pairing
    // works against a real master, not just this codebase's own tests.
    println!(
        "[probe] SELECT-then-OPERATE analog-output-block (g41v1, value={AO_SELECT_OPERATE_VALUE}) on Analog Output[{AO_INDEX}]..."
    );
    timeout(
        CALL_TIMEOUT,
        association.operate(
            CommandMode::SelectBeforeOperate,
            CommandBuilder::single_header_u16(Group41Var1::new(AO_SELECT_OPERATE_VALUE), AO_INDEX),
        ),
    )
    .await
    .map_err(|_| "SELECT-then-OPERATE analog-output-block timed out".to_string())?
    .map_err(|e| {
        format!("SELECT-then-OPERATE analog-output-block on Analog Output[{AO_INDEX}] failed: {e}")
    })?;
    println!("[probe] SELECT-then-OPERATE accepted.");

    println!("[probe] re-polling Class 0 to confirm the SELECT/OPERATE result...");
    class0_read(&mut association).await?;
    {
        let snap = *snapshot.lock().unwrap();
        println!("[probe] post-select-operate Class 0 snapshot: {snap:?}");
        if snap.ao != Some(AO_SELECT_OPERATE_VALUE as f64) {
            return Err(format!(
                "expected Analog Output[{AO_INDEX}] == {AO_SELECT_OPERATE_VALUE} after SELECT-then-OPERATE, got {:?}",
                snap.ao
            ));
        }
    }
    println!("[probe] SELECT/OPERATE re-poll OK: Analog Output changed to {AO_SELECT_OPERATE_VALUE}.");

    Ok(())
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let host = match args.get(1) {
        Some(h) => h.clone(),
        None => {
            eprintln!("usage: dnp3_probe <host> <port>");
            println!("DNP3 PROBE FAIL: missing host argument");
            return ExitCode::FAILURE;
        }
    };
    let port: u16 = match args.get(2).and_then(|p| p.parse().ok()) {
        Some(p) => p,
        None => {
            eprintln!("usage: dnp3_probe <host> <port>");
            println!("DNP3 PROBE FAIL: missing or invalid port argument");
            return ExitCode::FAILURE;
        }
    };

    match run(&host, port).await {
        Ok(()) => {
            println!("DNP3 PROBE PASS");
            ExitCode::SUCCESS
        }
        Err(reason) => {
            println!("DNP3 PROBE FAIL: {reason}");
            ExitCode::FAILURE
        }
    }
}
