//! Machine-proof that a REAL, independent, third-party Modbus **RTU**
//! client (the `tokio-modbus` crate's own RTU client, via
//! `tokio_modbus::client::rtu::attach_slave` — not anything hand-rolled by
//! the Dart side) can read from and write to the in-app pure-Dart Modbus
//! server when it is configured to serve **RTU framing over a plain TCP byte
//! stream** (`ModbusProtocolConfig.framing == 'rtuOverTcp'`,
//! `mobile/lib/protocols/modbus/modbus_rtu.dart` +
//! `mobile/lib/services/modbus_host.dart`'s `_onDataRtu`), rather than
//! classic MBAP-header Modbus TCP (which `gateway/examples/modbus_probe.rs`
//! already proves).
//!
//! RTU-over-TCP carries no MBAP header at all: a frame is simply
//! `unitId + PDU + CRC-16` (CRC low byte first on the wire), and the
//! transport must derive the expected request length purely from the
//! function code since RTU has no length field anywhere in the frame. This
//! probe drives that framing end to end through `tokio-modbus`'s own RTU
//! client stack — `attach_slave` wraps an arbitrary `AsyncRead + AsyncWrite`
//! transport (here, a plain `TcpStream`) and speaks RTU framing/CRC over it
//! directly, with no MBAP layer involved anywhere in the client.
//!
//! Usage:
//!   cargo run --manifest-path gateway/Cargo.toml --example modbus_rtu_probe -- 127.0.0.1 <port>
//!
//! Talks to a server hosting the same small fixture project as
//! `modbus_probe.rs` (see `mobile/tool/modbus_host_probe.dart`, run with the
//! `rtuOverTcp` framing argument via `tool/modbus_rtu_e2e.sh`):
//!   - `Start_PB` : BOOL,  ReadWrite -> coil address 0
//!   - `Speed`    : INT16, ReadWrite -> holding register address 0
//!
//! Steps (all bounded by `tokio::time::timeout` so a hung/misbehaving server
//! can never make this probe or the CI job wrapping it block forever):
//!   1. Connect a plain `TcpStream` to `host:port` and attach a
//!      `tokio-modbus` RTU client context to it via `rtu::attach_slave`.
//!   2. `read_holding_registers(0, 1)` -- the fixture's initial `Speed` value
//!      (100) -- proof a real RTU-framed request/response round-trips
//!      through the CRC-16-checked wire format.
//!   3. `write_single_register(0, <value>)` then an INDEPENDENT
//!      `read_holding_registers(0, 1)` asserting the exact written value --
//!      proof the write actually landed in the server's tag database (not
//!      merely echoed by the write response), all over RTU framing.
//!   4. `write_single_coil(0, true)` then `read_coils(0, 1)` asserting
//!      `[true]` -- same proof, for the bit-table side of the map.
//! Prints `MODBUS RTU PROBE PASS` and exits 0 on success; on any failure
//! prints `MODBUS RTU PROBE FAIL: <reason>` and exits 1 -- never panics past
//! the top level.
use std::env;
use std::net::SocketAddr;
use std::process::ExitCode;
use std::time::Duration;

use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_modbus::client::rtu::attach_slave;
use tokio_modbus::client::Context;
use tokio_modbus::prelude::*;

/// Value this probe writes to holding-register 0 (the `Speed` tag) via
/// FC06, then reads back to verify the write landed -- distinct from
/// `modbus_probe.rs`'s `CLIENT_WRITTEN_HOLDING_VALUE` so the two probes'
/// writes are never confused if ever run against a shared fixture by
/// mistake.
const CLIENT_WRITTEN_HOLDING_VALUE: u16 = 5150;

/// Unit id this probe addresses. The Dart fixture host's `ModbusProtocolConfig
/// .unitId` defaults to `255` ("any"), so the server answers regardless of
/// the exact value here; `1` is used simply as the conventional non-zero
/// RTU slave address.
const UNIT_ID: u8 = 1;

/// Per-call bound so a hung server can never make this probe (or the CI job
/// wrapping it) block forever.
const CALL_TIMEOUT: Duration = Duration::from_secs(5);

/// Connection bound.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

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

    println!("[rtu-probe] connecting TCP transport to {addr}...");
    let stream = timeout(CONNECT_TIMEOUT, TcpStream::connect(addr))
        .await
        .map_err(|_| "connect timed out".to_string())?
        .map_err(|e| format!("connect failed: {e}"))?;
    println!("[rtu-probe] connected; attaching tokio-modbus RTU client (unit {UNIT_ID})...");
    let mut ctx = attach_slave(stream, Slave(UNIT_ID));

    // --- Step 1: read the fixture's initial Speed value (holding[0]) ------
    println!("[rtu-probe] read_holding_registers(0, 1) over RTU framing...");
    let initial = read_holding(&mut ctx, 0, 1).await?;
    println!("[rtu-probe] read OK: holding[0] = {:?}", initial.first());

    // --- Step 2: write_single_register(0, ...) then independent read-back -
    println!("[rtu-probe] write_single_register(0, {CLIENT_WRITTEN_HOLDING_VALUE})...");
    write_single_register(&mut ctx, 0, CLIENT_WRITTEN_HOLDING_VALUE).await?;
    println!("[rtu-probe] write OK; issuing an INDEPENDENT read to verify...");
    let regs = read_holding(&mut ctx, 0, 1).await?;
    match regs.first().copied() {
        Some(v) if v == CLIENT_WRITTEN_HOLDING_VALUE => {
            println!("[rtu-probe] read-back OK: holding[0] = {v}");
        }
        other => {
            return Err(format!(
                "expected holding[0] == {CLIENT_WRITTEN_HOLDING_VALUE} after the write, got {other:?}"
            ))
        }
    }

    // --- Step 3: write_single_coil(0, true) then read_coils(0, 1) ---------
    println!("[rtu-probe] write_single_coil(0, true)...");
    write_single_coil(&mut ctx, 0, true).await?;
    println!("[rtu-probe] write OK; reading coil[0] back to verify...");
    let coils = read_coils(&mut ctx, 0, 1).await?;
    match coils.first().copied() {
        Some(true) => println!("[rtu-probe] read-back OK: coil[0] = true"),
        other => {
            return Err(format!("expected coil[0] == Some(true) after the write, got {other:?}"))
        }
    }

    if let Err(e) = ctx.disconnect().await {
        // Non-fatal: every assertion above already passed, and a clean
        // disconnect failing doesn't mean the protocol behavior was wrong.
        println!("[rtu-probe] (non-fatal) disconnect error: {e}");
    }

    Ok(())
}

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let host = match args.get(1) {
        Some(h) => h.clone(),
        None => {
            eprintln!("usage: modbus_rtu_probe <host> <port>");
            println!("MODBUS RTU PROBE FAIL: missing host argument");
            return ExitCode::FAILURE;
        }
    };
    let port: u16 = match args.get(2).and_then(|p| p.parse().ok()) {
        Some(p) => p,
        None => {
            eprintln!("usage: modbus_rtu_probe <host> <port>");
            println!("MODBUS RTU PROBE FAIL: missing or invalid port argument");
            return ExitCode::FAILURE;
        }
    };

    match run(&host, port).await {
        Ok(()) => {
            println!("MODBUS RTU PROBE PASS");
            ExitCode::SUCCESS
        }
        Err(reason) => {
            println!("MODBUS RTU PROBE FAIL: {reason}");
            ExitCode::FAILURE
        }
    }
}
