//! Machine-proof that a REAL, independent, third-party Modbus TCP client
//! (the `tokio-modbus` crate's own client — not anything hand-rolled by the
//! Dart side) can read from and write to the in-app pure-Dart Modbus TCP
//! server (WS24 Tasks 1-3, `mobile/lib/models/modbus_map.dart` +
//! `mobile/lib/protocols/modbus/modbus_pdu.dart` +
//! `mobile/lib/services/modbus_host.dart`).
//!
//! Usage:
//!   cargo run --manifest-path gateway/Cargo.toml --example modbus_probe -- 127.0.0.1 <port>
//!
//! Talks to a server hosting a small fixture project with three mapped tags
//! (see `mobile/tool/modbus_host_probe.dart`, which this probe is designed
//! to run against via `tool/modbus_e2e.sh`):
//!   - `Start_PB`    : BOOL,  ReadWrite -> coil address 0
//!   - `Forced_Bool` : BOOL,  ReadWrite -> coil address 1, `isForced: true`,
//!     `forcedValue: true` (Task 4 forced-coil-reads-through proof; the
//!     tag's live `value` is `false`)
//!   - `Speed`       : INT16, ReadWrite -> holding register address 0
//!   - `Motor.Speed` : INT32 struct member -> holding registers 1-2 (Task 4
//!     struct-member-decodes-correctly proof)
//!   - `Temp`        : INT16, ReadOnly  -> input register address 0 (unused
//!     by this probe; present so the fixture map exercises all four Modbus
//!     data tables, per the docs' 4-table mapping)
//!
//! Steps:
//!   1. Connect a TCP context to `host:port` (no unit-id framing beyond the
//!      default `Slave::tcp_device()` — this is a direct Modbus TCP
//!      connection, not routed through a gateway).
//!   2. Poll `read_holding_registers(0, 1)` (bounded) until it reads back
//!      `4242` — the value the Dart fixture host's own timer mutates
//!      holding-register 0 to at T+3s after printing `READY`, entirely
//!      independently of this client. Observing that value can only mean
//!      this probe is reading the *live* register file, not a frozen
//!      snapshot taken at connect time.
//!   3. `write_single_register(0, 7777)` then read the same register back
//!      and assert it now reads `7777` — proof the write actually landed in
//!      the server's tag database (verified by an independent Read, not the
//!      write's own echo response).
//!   4. `write_single_coil(0, true)` then `read_coils(0, 1)` and assert
//!      `[true]` — same proof, for the bit-table side of the map.
//!   5. `read_coils(1, 1)` and assert `[true]` — the falsifiable proof that
//!      `Forced_Bool`'s `isForced`/`forcedValue` state reaches Modbus reads:
//!      the tag's live `value` is `false`, so this only reads `true` if the
//!      force-aware `readPath` resolver (shared with the scan engine and the
//!      OPC UA server) is actually being consulted by the Modbus register
//!      handler.
//!   6. `read_holding_registers(1, 2)` and decode as a big-endian,
//!      high-word-first INT32, asserting it equals the `Motor.Speed`
//!      struct-member field's value — proof a dotted struct-member map entry
//!      resolves its type/value through the full path, not just a top-level
//!      tag name.
//! Prints `MODBUS PROBE PASS` and exits 0 on success; on any failure prints
//! `MODBUS PROBE FAIL: <reason>` and exits 1 — never panics past the top
//! level.
use std::env;
use std::net::SocketAddr;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use tokio::time::{sleep, timeout};
use tokio_modbus::client::tcp::connect;
use tokio_modbus::client::Context;
use tokio_modbus::prelude::*;

/// Value the Dart fixture host (`mobile/tool/modbus_host_probe.dart`)
/// writes to holding-register 0 (the `Speed` tag) at T+3s after printing
/// `READY`, purely as a server-side mutation for this probe to observe (a
/// real "value changed on the device" push via polling, not a client
/// write).
const SERVER_MUTATED_HOLDING_VALUE: u16 = 4242;

/// Value this probe itself writes to holding-register 0 via FC06, then
/// reads back to verify the write landed.
const CLIENT_WRITTEN_HOLDING_VALUE: u16 = 7777;

/// How long to wait for the server-side mutation to become visible before
/// giving up. The Dart fixture host schedules it at a fixed T+3s, so this
/// generously covers connection + polling overhead.
const SERVER_MUTATION_WAIT: Duration = Duration::from_secs(10);

/// Per-call bound so a hung server can never make this probe (or the CI
/// job wrapping it) block forever.
const CALL_TIMEOUT: Duration = Duration::from_secs(5);

/// Coil address of `Forced_Bool` in the Dart fixture host's map (see
/// `mobile/tool/modbus_host_probe.dart`), a tag whose live `value` is
/// `false` but whose `isForced`/`forcedValue` mark it force-read as `true`
/// — reading `true` here is only possible if the force-aware resolver is
/// actually consulted by the Modbus register handler.
const FORCED_COIL_ADDR: u16 = 1;

/// Holding-register address of the `Motor.Speed` INT32 struct-member map
/// entry (occupies 2 registers: `STRUCT_MEMBER_HOLDING_ADDR` and
/// `STRUCT_MEMBER_HOLDING_ADDR + 1`, high-word-first).
const STRUCT_MEMBER_HOLDING_ADDR: u16 = 1;

/// Expected decoded value of `Motor.Speed`, matching the Dart fixture
/// host's `_structMemberSpeedValue`.
const STRUCT_MEMBER_EXPECTED_VALUE: i32 = 9001;

async fn read_holding(ctx: &mut Context, addr: u16, cnt: u16) -> Result<Vec<u16>, String> {
    timeout(CALL_TIMEOUT, ctx.read_holding_registers(addr, cnt))
        .await
        .map_err(|_| format!("read_holding_registers({addr},{cnt}) timed out"))?
        .map_err(|e| format!("read_holding_registers({addr},{cnt}) transport error: {e}"))?
        .map_err(|ex| format!("read_holding_registers({addr},{cnt}) exception: {ex}"))
}

async fn write_single_register(ctx: &mut Context, addr: u16, value: u16) -> Result<(), String> {
    timeout(CALL_TIMEOUT, ctx.write_single_register(addr, value))
        .await
        .map_err(|_| format!("write_single_register({addr},{value}) timed out"))?
        .map_err(|e| format!("write_single_register({addr},{value}) transport error: {e}"))?
        .map_err(|ex| format!("write_single_register({addr},{value}) exception: {ex}"))
}

async fn write_single_coil(ctx: &mut Context, addr: u16, value: bool) -> Result<(), String> {
    timeout(CALL_TIMEOUT, ctx.write_single_coil(addr, value))
        .await
        .map_err(|_| format!("write_single_coil({addr},{value}) timed out"))?
        .map_err(|e| format!("write_single_coil({addr},{value}) transport error: {e}"))?
        .map_err(|ex| format!("write_single_coil({addr},{value}) exception: {ex}"))
}

async fn read_coils(ctx: &mut Context, addr: u16, cnt: u16) -> Result<Vec<bool>, String> {
    timeout(CALL_TIMEOUT, ctx.read_coils(addr, cnt))
        .await
        .map_err(|_| format!("read_coils({addr},{cnt}) timed out"))?
        .map_err(|e| format!("read_coils({addr},{cnt}) transport error: {e}"))?
        .map_err(|ex| format!("read_coils({addr},{cnt}) exception: {ex}"))
}

async fn run(host: &str, port: u16) -> Result<(), String> {
    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .map_err(|e| format!("bad address {host}:{port}: {e}"))?;

    println!("[probe] connecting to {addr}...");
    let mut ctx = timeout(Duration::from_secs(10), connect(addr))
        .await
        .map_err(|_| "connect timed out".to_string())?
        .map_err(|e| format!("connect failed: {e}"))?;
    println!("[probe] connected.");

    // --- Step 1: poll for the server-side mutation of holding[0] ---------
    println!(
        "[probe] polling holding[0] (up to {:?}) for the server-side mutation to {SERVER_MUTATED_HOLDING_VALUE}...",
        SERVER_MUTATION_WAIT
    );
    let deadline = Instant::now() + SERVER_MUTATION_WAIT;
    let mut last_seen: Vec<u16>;
    let mut observed = false;
    loop {
        let regs = read_holding(&mut ctx, 0, 1).await?;
        last_seen = regs.clone();
        if regs.first().copied() == Some(SERVER_MUTATED_HOLDING_VALUE) {
            observed = true;
            break;
        }
        if Instant::now() >= deadline {
            break;
        }
        sleep(Duration::from_millis(200)).await;
    }
    if !observed {
        return Err(format!(
            "timed out after {SERVER_MUTATION_WAIT:?} waiting for holding[0] == {SERVER_MUTATED_HOLDING_VALUE}, last saw {last_seen:?}"
        ));
    }
    println!("[probe] observed server-side mutation: holding[0] = {SERVER_MUTATED_HOLDING_VALUE}");

    // --- Step 2: write_single_register(0, 7777) then read back -----------
    println!("[probe] write_single_register(0, {CLIENT_WRITTEN_HOLDING_VALUE})...");
    write_single_register(&mut ctx, 0, CLIENT_WRITTEN_HOLDING_VALUE).await?;
    println!("[probe] write OK; reading holding[0] back to verify...");
    let regs = read_holding(&mut ctx, 0, 1).await?;
    match regs.first().copied() {
        Some(v) if v == CLIENT_WRITTEN_HOLDING_VALUE => {
            println!("[probe] read-back OK: holding[0] = {v}");
        }
        other => {
            return Err(format!(
                "expected holding[0] == {CLIENT_WRITTEN_HOLDING_VALUE} after the write, got {other:?}"
            ))
        }
    }

    // --- Step 3: write_single_coil(0, true) then read_coils(0, 1) --------
    println!("[probe] write_single_coil(0, true)...");
    write_single_coil(&mut ctx, 0, true).await?;
    println!("[probe] write OK; reading coil[0] back to verify...");
    let coils = read_coils(&mut ctx, 0, 1).await?;
    match coils.first().copied() {
        Some(true) => println!("[probe] read-back OK: coil[0] = true"),
        other => {
            return Err(format!("expected coil[0] == Some(true) after the write, got {other:?}"))
        }
    }

    // --- Step 4: read the forced coil and assert it reads back forced -----
    //
    // `Forced_Bool`'s live tag `value` is `false` -- a read that returns
    // `true` here can only mean the Modbus register-file handler resolved
    // the read through the same force-aware `readPath` the scan engine and
    // OPC UA server use, not the tag's raw underlying value. This is the
    // falsifiable machine-proof (Task 4 of "Protocol Interop Fixes") that a
    // force set in the app is actually visible over Modbus.
    println!("[probe] read_coils({FORCED_COIL_ADDR}, 1) -- expect the forced value true...");
    let forced_coils = read_coils(&mut ctx, FORCED_COIL_ADDR, 1).await?;
    match forced_coils.first().copied() {
        Some(true) => println!(
            "[probe] forced-coil read OK: coil[{FORCED_COIL_ADDR}] = true (force reached Modbus)"
        ),
        other => {
            return Err(format!(
                "expected coil[{FORCED_COIL_ADDR}] == Some(true) (Forced_Bool's forced value read through to Modbus), got {other:?}"
            ))
        }
    }

    // --- Step 5: read the struct-member holding registers and decode -------
    //
    // `Motor.Speed` is a dotted struct-member map entry (an INT32 field of
    // the `Motor` tag's `MotorType` struct), occupying 2 holding registers.
    // Decoding the correct value at the correct width proves the register
    // handler resolves a struct-member path's type/value through the full
    // dotted path, not just by matching the map entry's `tag` string against
    // top-level tag names (which would silently fall back to a wrong width
    // or wrong value).
    println!(
        "[probe] read_holding_registers({STRUCT_MEMBER_HOLDING_ADDR}, 2) -- struct member Motor.Speed (INT32)..."
    );
    let motor_regs = read_holding(&mut ctx, STRUCT_MEMBER_HOLDING_ADDR, 2).await?;
    if motor_regs.len() != 2 {
        return Err(format!(
            "expected 2 registers reading Motor.Speed, got {} ({:?})",
            motor_regs.len(),
            motor_regs
        ));
    }
    // Big-endian, high-word-first per the docs' encoding rules.
    let motor_speed = ((motor_regs[0] as u32) << 16 | motor_regs[1] as u32) as i32;
    if motor_speed != STRUCT_MEMBER_EXPECTED_VALUE {
        return Err(format!(
            "expected Motor.Speed == {STRUCT_MEMBER_EXPECTED_VALUE}, decoded {motor_speed} from registers {motor_regs:?}"
        ));
    }
    println!("[probe] struct-member read OK: Motor.Speed = {motor_speed}");

    if let Err(e) = ctx.disconnect().await {
        // Non-fatal: every assertion above already passed, and a clean
        // disconnect failing doesn't mean the protocol behavior was wrong.
        println!("[probe] (non-fatal) disconnect error: {e}");
    }

    Ok(())
}

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let host = match args.get(1) {
        Some(h) => h.clone(),
        None => {
            eprintln!("usage: modbus_probe <host> <port>");
            println!("MODBUS PROBE FAIL: missing host argument");
            return ExitCode::FAILURE;
        }
    };
    let port: u16 = match args.get(2).and_then(|p| p.parse().ok()) {
        Some(p) => p,
        None => {
            eprintln!("usage: modbus_probe <host> <port>");
            println!("MODBUS PROBE FAIL: missing or invalid port argument");
            return ExitCode::FAILURE;
        }
    };

    match run(&host, port).await {
        Ok(()) => {
            println!("MODBUS PROBE PASS");
            ExitCode::SUCCESS
        }
        Err(reason) => {
            println!("MODBUS PROBE FAIL: {reason}");
            ExitCode::FAILURE
        }
    }
}
