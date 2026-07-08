# Modbus TCP (In-App Server)

The app itself is the Modbus TCP server — no companion process, no second
machine. A hand-rolled, pure-Dart Modbus TCP server subset runs inside the
Flutter app (`mobile/lib/protocols/modbus/modbus_pdu.dart` +
`mobile/lib/services/modbus_host.dart`), reads the project's tag database
live at Read time, and applies writes through the same force-aware rule the
scan engine uses. Any Modbus TCP master (pymodbus, ModScan, QModMaster, a
SCADA historian, a custom `tokio-modbus` client) connects directly to the
phone/tablet/desktop running the app.

```
Modbus master (pymodbus, ModScan, SCADA, ...)  --Modbus TCP/502-->  the app itself
                                                                       - runs the scan
                                                                       - owns the tag DB
                                                                       - hosts the register file
                                                                       - force-aware writes
```

Full design rationale: `docs/superpowers/specs/2026-07-08-in-app-modbus-tcp-server-design.md`
(adjacent to `docs/protocols/opcua.md`'s ADR-010, which established the
"one app hosts everything" pattern this reuses for a second protocol).

## Using it

1. Open **Outbound Protocols** from the app's shell nav.
2. Enable the **Modbus TCP** switch on the Modbus TCP card — this reveals
   the hosting controls, port field, and register map editor.
3. Set the **port** (default `502`, the IANA-registered Modbus TCP port
   most masters default to). The field is editable only while stopped. See
   "Privileged ports" below if you want to actually bind `502`.
4. Tap **Start hosting**. The card shows live status (Stopped / Running /
   Error), the mapped-tag count, connected client count, and — once
   running — the endpoint (`modbus-tcp://<device-ip>:<port>`).
5. Point any Modbus TCP master at that endpoint, unit id `1` (the only
   unit id this server answers).
6. **Read** a coil/discrete-input/holding-register/input-register — the
   value comes live from the running soft PLC at the moment of the read
   (there is no mirror/cache to go stale). Any in-range address the map
   doesn't cover simply reads back `0`/`false` rather than erroring — see
   "Reads never fail" below.
7. **Write** a coil or holding register mapped `ReadWrite` — it applies
   through the same force-aware path as any other write. Writing an
   address mapped `ReadOnly`, or one not in the map at all, returns
   exception code `02` (Illegal Data Address). Writing a tag that is
   currently **forced** in the app is accepted at the wire level (a normal
   success response is returned) but silently discarded server-side — see
   "Force-aware, silently" below.
8. Tap **Stop hosting** to close the listener; the app is otherwise
   byte-identical to a build with Modbus TCP never enabled.

The register map (which tags are exposed, their table/address, and
`ReadOnly`/`ReadWrite` access) is fully **hand-editable** from the Modbus TCP
card's map editor — add, remove, or retarget a row's tag/table/address/access
directly — or auto-generated from the project's tags (**Regenerate** —
`Simulated Inputs`/`Internal` tags default to `ReadWrite`; `Simulated
Outputs` default to `ReadOnly`). It is stored per-project under the
additive `protocols` field (`protocols.modbus`), alongside the `port`
(additive, default `502`).

A map row's `tag` isn't limited to a top-level tag name: it may be a
**dotted struct-member path** (e.g. `Motor.Speed` for the `Speed` field of a
`Motor` tag typed as a struct), resolved through the same field-def walk the
Memory Manager and other editors use (`tag_resolver.dart`). This lets you
expose an individual struct field at its own Modbus address without mapping
the whole composite tag — composite tags themselves still can't be mapped as
a single unit (see "v1 scope" below). The register width/type at that path
is resolved from the full path, not by matching the map entry's `tag` string
against top-level tag names, so a struct member gets the correct register
width (e.g. 2 registers for an `INT32` field) and decodes to the correct
value. **Regenerate** only ever emits top-level scalar entries; dotted
struct-member entries are a manual-map-only feature today.

## The 4-table tag mapping

Modbus TCP has four independently-numbered data tables. Every mapped tag
lives in exactly one table, at an address the map assigns (either manually
or via **Regenerate**):

| Table | Function codes | Contents | Access |
|---|---|---|---|
| **Coils** | `01` Read, `05` Write Single, `0F` Write Multiple | `BOOL` tags | Read/Write |
| **Discrete Inputs** | `02` Read | `BOOL` tags | Read-only |
| **Holding Registers** | `03` Read, `06` Write Single, `10` Write Multiple | `INT16`/`INT32`/`FLOAT64` tags | Read/Write |
| **Input Registers** | `04` Read | `INT16`/`INT32`/`FLOAT64` tags | Read-only |

**Regenerate** (the auto-map) assigns `BOOL` tags to Coils (read/write
`ioType`s) or Discrete Inputs (`SimulatedOutput`, matching the OPC UA
auto-map convention), and numeric tags to Holding Registers or Input
Registers by the same read/write rule. Addresses are assigned sequentially
per table in tag order, advancing by 1 for bit tables or by the type's
register width for register tables (see below). `TIMER`/`COUNTER`/`STRING`
tags and composite (struct/array) tags are skipped entirely — v1 only maps
scalar `BOOL`/`INT16`/`INT32`/`FLOAT64` leaf tags (see "v1 scope" below).

**Register width per type** (holding/input tables only — coils/discrete
inputs always occupy exactly one bit):

| Tag type | Registers occupied |
|---|---|
| `INT16` | 1 |
| `INT32` | 2 |
| `FLOAT64` | 4 |

A multi-register tag can only be written atomically: `06` (Write Single
Register) refuses (exception `03`, Illegal Data Value) any address whose
tag occupies more than 1 register, and `10` (Write Multiple Registers)
requires the full span of every touched tag to lie within the requested
write range — no partial overwrite of an `INT32`/`FLOAT64` tag is possible.

## The full function-code set

All 8 classic Modbus function codes are implemented:

| FC | Name | Table |
|---|---|---|
| `01` | Read Coils | Coils |
| `02` | Read Discrete Inputs | Discrete Inputs |
| `03` | Read Holding Registers | Holding Registers |
| `04` | Read Input Registers | Input Registers |
| `05` | Write Single Coil | Coils |
| `06` | Write Single Register | Holding Registers |
| `0F` | Write Multiple Coils | Coils |
| `10` | Write Multiple Registers | Holding Registers |

Any other function code answers exception `01` (Illegal Function). Requests
with an out-of-range quantity (`0` or above the wire limits — 2000 bits,
125 registers — or a start+quantity that overflows the 16-bit address
space) answer exception `03` (Illegal Data Value).

## Data encoding: big-endian, high word first

Every multi-byte value on the wire is **big-endian**, matching the Modbus
Application Protocol spec:

- Each 16-bit register is transmitted big-endian (high byte first).
- `INT32` occupies 2 registers, **high word first** (register 0 = the
  value's high 16 bits, register 1 = the low 16 bits) — the "AB CD" word
  order, not the little-endian-word-swapped "CD AB" some Modbus devices use.
- `FLOAT64` occupies 4 registers, the IEEE-754 double's 8 bytes in
  big-endian order, 2 bytes per register, in the same natural order as the
  bytes.
- Coil/discrete-input bit packing within a byte is **LSB-first** (bit 0 of
  the first returned byte is the first requested coil), per spec.

There is no word-swap/byte-swap configuration option in v1 — if a
third-party master defaults to little-endian word order for 32-bit types,
configure that master's endianness setting to match (most masters,
including pymodbus and ModScan, support this).

## Force-aware, silently

A write to a tag that is currently **forced** in the app is accepted at the
protocol level — the server still returns the normal success response
(the FC05/06 echo, or the FC0F/10 start+quantity echo) — but the write
itself is silently discarded; the forced value is not overwritten. This
differs deliberately from the OPC UA server's behavior (which refuses a
forced write visibly with `Bad_UserAccessDenied`): the classic Modbus wire
protocol has no rich per-write status equivalent to an OPC UA
`StatusCode`, so a visible refusal isn't available without either lying
about a different exception code (misleading) or breaking wire
compatibility with masters that don't expect an exception on an
otherwise-valid write. Forcing always wins over an external master's write
either way — the difference is only in what the master's response tells it
happened.

Forcing is **scalar-only**: the Force toggle (Tag Inspector) is only ever
offered for scalar leaf tags, never for a struct/array-typed root tag. A
dotted-path map entry's force check walks to that path's **root** tag and
looks at its `isForced` flag — so forcing `Motor` (if it were somehow forced
as a whole, which the UI never allows) would gate writes to `Motor.Speed`
too, but forcing a scalar sibling has no effect on `Motor.Speed`. This is the
same scalar-only force model the OPC UA server and the scan engine share
(see `docs/protocols/opcua.md`).

## Reads never fail

Unlike writes, reads are unconditional: any in-range address inside a
`01`/`02`/`03`/`04` request's quantity that isn't covered by the map (a
gap between mapped tags, or a table with fewer mapped tags than the
requested range) reads back `0` (registers) or `false` (bits) rather than
raising an exception. Only a request whose quantity/address is itself
out-of-range per the wire limits (see "the full function-code set" above)
is refused.

## Privileged ports (502) and the "port already in use" case

Port `502` is the IANA-registered Modbus TCP port, but it's a **privileged
port** (< 1024) on most desktop OSes (Linux/macOS require elevated
capabilities to bind it; Windows does not restrict it, but some other
process may already own it — a leftover Modbus stack, a conflicting
service). If **Start hosting** moves to the **Error** status:

- On Linux/macOS, either grant the app the capability to bind privileged
  ports, or (simpler for a training/simulator use case) change the **Port**
  field to something unprivileged (e.g. `5020`, `1502`) before starting —
  most masters let you configure a non-default port to connect to.
- On any platform, if `502` is already bound by another process (a real
  PLC gateway, another instance of this app, etc.), the same "change the
  port" fix applies; the card's **Last error** line shows the OS's bind
  failure reason.
- Android/iOS apps never have elevated privileges to bind `<1024`
  regardless of settings — use a non-default port there.

## Connecting a master

Any Modbus TCP master works. Two commonly used ones:

**pymodbus** (Python):
```python
from pymodbus.client import ModbusTcpClient

client = ModbusTcpClient('<device-ip>', port=502)
client.connect()
client.read_holding_registers(0, count=1, slave=1)
client.write_register(0, 7777, slave=1)
client.write_coil(0, True, slave=1)
```

**ModScan / QModMaster** (GUI masters): point the connection at
`<device-ip>:<port>`, unit id `1`, and add the coil/register addresses
from the app's register map editor as poll items — the same way you'd
point either tool at a real PLC's Modbus TCP interface.

## v1 scope (and what's deferred)

**v1 delivers:** the full classic FC set (`01`/`02`/`03`/`04`/`05`/`06`/
`0F`/`10`) over Modbus **TCP** only, against the project's register map and
live tags, force-aware writes, and the auto-map/manual-map editor described
above.

**Deferred (v2+):**
- **Modbus RTU** (serial) — this is a TCP-only server; there is no
  serial/RS-485 transport.
- **Top-level composite tags** (structs/arrays) are not mappable as a
  whole — only scalar `BOOL`/`INT16`/`INT32`/`FLOAT64` leaf tags can be
  assigned a Modbus address. Composite members can still be exposed
  individually if you address the specific leaf tag/path in the map (same
  restriction the OPC UA server has today).
- **FC 07/08/11/12/17/20/21/22/23/24/43** (Read Exception Status,
  Diagnostics, Get Comm Event Counter/Log, Report Server ID, Read/Write
  File Record, Mask Write Register, Read/Write Multiple Registers,
  Read Device Identification, and other less-common codes) are not
  implemented — any of them answers exception `01` (Illegal Function).
- **No word-swap toggle** — see "Data encoding" above; 32-bit types are
  always high-word-first, matching the spec default.

## Platform notes

- **iOS**: the app can only accept inbound connections while it is in the
  **foreground** — an OS constraint on background sockets, not a
  limitation of this server. Backgrounding the app stops accepting new
  connections.
- **Android**: works the same as desktop while the app is running, but the
  master must be on the **same LAN** — there is no port-forwarding/NAT
  traversal, and mobile carriers/most Wi-Fi networks block unsolicited
  inbound connections from outside the local network anyway.
- The app remains byte-identical when Modbus TCP hosting is disabled or
  stopped — this is strictly an opt-in feature.
- **Web:** Modbus TCP hosting is a **native-platform feature only**
  (Android, iOS, desktop). The web build compiles fine, but a browser tab
  cannot host an inbound TCP server (no `ServerSocket` in the browser
  sandbox), so Modbus TCP serving is unavailable when the app runs as a
  web build — the map editor still works there for design purposes.

## What is machine-verified vs. manual

**Machine-verified (`flutter test` in `mobile/`):**
- `ModbusMap`/`ModbusMapEntry`/`ModbusProtocolConfig` model round-trips and
  `autoGenerate` behavior — `mobile/test/modbus_map_test.dart`.
- The MBAP/PDU codec byte-for-byte (transaction/protocol/unit/length
  framing, all 8 FC request/response encodings, exception responses,
  big-endian register packing, LSB-first bit packing) —
  `mobile/test/modbus_pdu_test.dart`.
- The register-file handler against a live project's tag DB: reads that
  never fail on unmapped gaps, force-aware silent-skip writes, atomic
  multi-register write rules, and every exception path (`01`/`02`/`03`
  on illegal function/address/value) — `mobile/test/modbus_registers_test.dart`.
- Dotted struct-member map entries (e.g. `Motor.Speed`): correct register
  width/type resolution through the full path (not a top-level-name-only
  match) and correct force-gating against the path's root tag —
  `mobile/test/modbus_dotted_path_test.dart`.
- The `dart:io` socket host (start/stop lifecycle, real-socket FC03
  request/response over an ephemeral loopback port, hostile-frame-size and
  malformed-frame connection isolation) — `mobile/test/modbus_host_test.dart`.
- Additive persistence: the new `protocols.modbus` key round-trips
  end-to-end alongside the unchanged `opcua`/`gatewayUrl` keys —
  `mobile/test/protocol_settings_test.dart`, `mobile/test/serialization_roundtrip_test.dart`.

**Machine-verified end-to-end, with a REAL third-party Modbus TCP client
(`tool/modbus_e2e.sh`):**

This is the strongest proof available short of a human running ModScan: a
genuine Rust `tokio-modbus` crate **client**
(`gateway/examples/modbus_probe.rs`) connects over the real Modbus TCP wire
protocol to the Dart server hosted by a small fixture runner
(`mobile/tool/modbus_host_probe.dart`), and exercises: poll
`read_holding_registers(0, 1)` until it observes a value the fixture host
mutates **server-side** on its own timer (T+3s after `READY`, entirely
independent of the probing client) — proof the client is reading the live
register file, not a value frozen at connect time — then
`write_single_register(0, 7777)` + independent read-back, then
`write_single_coil(0, true)` + independent read-back (`read_coils`), then
**`read_coils` on a second, pre-forced coil and assert it reads `1`** — the
fixture's `Forced_Bool` tag has a live `value` of `false` but
`isForced: true`/`forcedValue: true`, so reading `true` back is only
possible if the register handler is actually consulting the force-aware
resolver, not the tag's raw value — and finally **`read_holding_registers`
across the two registers a dotted struct-member entry (`Motor.Speed`, an
`INT32` field) occupies, decoded big-endian high-word-first and asserted
against the fixture's known value** — proof a struct-member map entry
resolves its type and value through the full path at the correct register
width.

Run it from the repo root (bash/Git Bash):

```bash
tool/modbus_e2e.sh
```

It starts the Dart fixture host on a non-default port, waits for it to
report `READY`, runs the Rust probe against it, and unconditionally kills
the Dart host on exit (propagating the probe's exit code). A successful run
ends with:

```
MODBUS PROBE PASS
```

**Requires a human with a real Modbus master (manual, documented here, not
automatable in CI):**
- Actually opening `<device-ip>:502` (or a configured non-default port)
  from ModScan/QModMaster/pymodbus running on a **different device** on
  the LAN, to confirm real network reachability (the E2E probe above runs
  over `127.0.0.1`, proving the protocol implementation but not physical
  network/firewall behavior).
- Confirming the iOS-foreground and Android-same-LAN behavior described
  above on physical devices.
- Confirming behavior against masters with non-default endianness/word-swap
  settings (see "Data encoding" above).

## Out of scope / positioning

This is a **simulator/training tool, not a safety-certified or
conformance-tested product**. The hand-rolled server targets master
*compatibility* (pymodbus, ModScan, QModMaster, and common SCADA stacks
talking classic Modbus TCP), not formal Modbus Organization conformance
testing. Do not use it to control real safety-critical equipment. Modbus
RTU (serial) is not implemented; scalar leaf tags only (struct/array
members are not individually addressable as a whole in v1).
