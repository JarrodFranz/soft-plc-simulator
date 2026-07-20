# Omron FINS (device side) — Design Spec

**Date:** 2026-07-20
**Status:** Approved (design)
**Workstream:** Protocol expansion program, **workstream 4 of 6** (see
`2026-07-16-protocol-expansion-program-roadmap.md`).

## Goal

Host **Omron FINS over UDP on port 9600** in-process so a SCADA FINS driver can
read and write the app's tags by **memory area + word offset**. Seventh protocol
in the pure-Dart suite, after OPC UA, Modbus TCP, MQTT/Sparkplug B, DNP3,
EtherNet/IP and S7comm.

## Reference client — CONFIRMED BEFORE PLANNING

The roadmap requires confirming the reference client *before* the plan. Verified
on this machine, not assumed:

- `fins` 1.0.5 installs from PyPI. It is **pure Python** (no native library, so
  none of the Windows-load risk snap7 carried).
- `fins.udp.UDPFinsConnection` exposes exactly what v1 needs:
  - `connect(ip_address, port=9600, bind_port=9600)`
  - `memory_area_read(memory_area_code, beginning_address, number_of_items)`
  - `memory_area_write(memory_area_code, beginning_address, write_bytes, number_of_items)`
  - plus `read`/`write` convenience wrappers and `execute_fins_command_frame`.
- `fins.udp.FinsPLCMemoryAreas` provides all the area codes (DM, CIO, Work,
  Holding, EM banks, …).

This reuses the **Python probe lane** (`tool/py/`) established for EtherNet/IP
and S7comm — the third protocol to use it.

## The central reuse (why this is the lowest-risk of the six)

FINS addresses data by **memory area + word offset** — the same shape as S7
(area + byte offset). So almost the entire S7 stack pattern carries over: a
`FinsMap` binding named tags to area+word+bit, an area byte-image
(materialize/apply, gaps read zero, force-aware writes, `FLOAT64→REAL`
narrowing), and read/write memory-area services. FINS additionally has **no
session-setup handshake** like S7's Setup Communication — a client just sends a
Memory Area Read — so it is *less* code than S7, not more.

**The one genuinely new component is the UDP host.** Every shipped protocol is
TCP with a per-connection socket object; FINS is natively UDP, so this is the
suite's first `RawDatagramSocket` host.

## Decisions taken (user-approved)

1. **Transport: UDP only.** FINS/UDP on 9600 is the protocol's native and
   most-common transport (Ignition's Omron driver and most masters default to
   it), and the `fins` client's `UDPFinsConnection` drives it directly. TCP FINS
   (which adds a `FINS`-magic framing header and a node-assignment handshake) is
   out of scope for v1.
2. **Memory areas: DM, CIO, WR, HR** (the word areas a SCADA driver actually
   polls). DM (Data Memory) is the heaviest-polled and maps to the tag DB like
   S7's DB. Timers/counters, the EM banks, clock pulses and condition flags are
   deferred — legacy or no app equivalent.
3. **The real-client probe runs EARLY** — task 3 of 5, before any read/write
   logic — consistent with S7 and EtherNet/IP, where a framing error otherwise
   hid behind a green unit suite until the last task.

## Non-goals / YAGNI

- **No FINS/TCP.** (Decision 1.) Its extra framing/handshake layer is deferred.
- **No EM banks, timers/counters, clock pulses, condition flags.**
- **No STRING** — same struct-shaped deferral as S7 and CIP.
- **No FINS control services** — no run/program mode change, no clock set, no
  CPU-unit program transfer. This is a data-access target.
- **No RUN/STOP or status services** beyond what a read/write path needs. (A
  `cpu_unit_status_read` may be answered minimally if the probe requires it —
  decided at Task 3 against the real client, not now.)

## Global Constraints

- **ADR-010**: pure Dart, in-process, no companion process, no FFI.
- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/protocols/fins/` and
  `mobile/lib/models/`; `dart:io` confined to `mobile/lib/services/fins_host.dart`.
- Codecs must **never throw** on malformed or hostile input.
- Deterministic: no wall clock, no randomness in codec logic.
- **Additive/backward-compatible**: a project with no `fins` key loads disabled
  at port 9600; no existing serialized form or scan behaviour changes;
  default-projects round-trip and scan-equivalence stay green.
- **Force-aware writes**: reuse the shared `isExternallyWritable`
  (`models/tag_write_gate.dart`) hard backstop and the per-entry access check, so
  a write to a forced / read-only / reserved-`System` tag is refused, tag
  unchanged. FINS inherits the hardening just merged for free.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No competitor-tooling branding in code, UI, or docs: no "OpenPLC"/"Beremiz"/
  "CODESYS"/"RSLogix"/"CX-Programmer"/"Sysmac". No reverse-engineering wording —
  implemented from public FINS specification material. `FINS` is a protocol name
  and is used freely (as `Modbus`/`DNP3`/`OPC UA`/`S7comm` already are); naming a
  controller family (`CJ`, `CS`, `NJ`) is acceptable only where a technical
  distinction requires it, never as a compatibility claim.

> **ENDIANNESS + WORD ORDER — the FINS-specific trap.**
> FINS multi-byte fields are **big-endian**. The subtle part: a 32-bit value
> (`DINT`/`REAL`) spans **two consecutive words**, and Omron's word order for
> those (which word is high) is a documented gotcha. Tests must assert the
> 32-bit layout against a **hand-built buffer with a known value**, and the
> Task 5 `fins` E2E is the ultimate authority — a `read`/`write` round-trip of a
> 32-bit value through the real client settles it.

## Component 1 — FINS command/response frame (`protocols/fins/fins_frame.dart`)

Pure; `dart:typed_data` only.

- **10-byte FINS header**: `ICF` (info control field — bit 6 distinguishes
  command vs response, bit 0 the response-required flag), `RSV` (0x00), `GCT`
  (gateway count, 0x02), `DNA` (dest network), `DA1` (dest node), `DA2` (dest
  unit), `SNA` (src network), `SA1` (src node), `SA2` (src unit), `SID` (service
  id — echoed so the client correlates the reply).
- **Command frame**: header + `command code` u16 (big-endian) + text.
- **Response frame**: header + `command code` u16 + **end code** u16 (`0x0000` =
  normal completion) + data. The response ICF marks it a response, and DNA/DA1/DA2
  ↔ SNA/SA1/SA2 are **swapped** (the reply goes back to the requester) with the
  same `SID` echoed.
- **Node addressing accepted permissively**: DNA/DA1/DA2/SNA/SA1/SA2 are echoed
  back swapped without validation — this is a simulator; rejecting a node/unit
  mismatch is a confusing failure with no diagnostic value (the same call as S7's
  rack/slot).
- End codes: `0x0000` normal; `0x1101` area classification missing / no such area;
  `0x1103` address range exceeded; `0x2101` … (a small set for the error paths).

## Component 2 — Memory Area Read/Write (`protocols/fins/fins_memory.dart`)

Pure. All big-endian.

- **Memory Area Read** = command code **`0x0101`**; **Write** = **`0x0102`**.
- **Item spec**: `memory area code` u8, then a **3-byte address** = word address
  u16 + bit u8, then `number of items` u16 (count of words, or bits for a bit
  area).
- **Area codes (word areas, v1)**: `DM 0x82`, `CIO 0xB0`, `WR (Work) 0xB1`,
  `HR (Holding) 0xB2`. (Bit-area variants exist — `CIO bit 0x30` etc. — and are
  handled where a `BOOL` tag needs a single bit, decided at implementation
  against the `fins` client's own codes.)
- **Read response**: end code `0x0000` + the requested words (big-endian).
- **Write**: the text carries the item spec + the write words; the response is
  end code only (no data).
- A read/write beyond a mapped/defined range returns the appropriate **end code**
  (not a dropped datagram), so a driver sees a real error.

## Component 3 — UDP host skeleton + EARLY real-client probe

**Files:** `services/fins_host.dart`, `mobile/tool/fins_host_probe.dart`,
`tool/py/fins_probe.py`, `tool/fins_e2e.sh`.

- **The UDP host** (the new-shape component): `RawDatagramSocket.bind(anyIPv4,
  port)`, listen for `RawSocketEvent.read`, `receive()` one `Datagram`, decode
  **one** FINS command (a FINS request fits one datagram — no reassembly loop),
  dispatch, and `send()` the response datagram back to `datagram.address` /
  `datagram.port`. **No per-connection object**; requests correlate by source
  address + `SID`.
- **Robustness**: a datagram from any source at any time, or a malformed/short
  datagram, is dropped without crashing the bind. There is no "connection closed"
  signal, so status/counters are inferred from recent source addresses (last-seen
  peers), not live sockets — a deliberate difference from the TCP hosts.
- `dart:io` is allowed **only** in `fins_host.dart`.
- At this task the host serves the connect path and a Memory Area Read against a
  small fixture; the `fins` client's `connect` + `memory_area_read` is the gate.
  Read/Write against the real tag map is Task 4.
- **Fixture-host constraint** (as for every prior probe): `fins_host_probe.dart`
  must **not** import `services/fins_host.dart` (hosts extend `ChangeNotifier` →
  `dart:ui`, unavailable under plain `dart run`); it imports the pure codec and
  re-implements the small receive loop.
- E2E contract as established: pin `fins==1.0.5` in `tool/py/requirements.txt`,
  start the fixture host on a non-default port, wait for `READY`, run the probe,
  unconditional teardown (trap), propagate exit code.

## Component 4 — `FinsMap` + area image (`models/fins_map.dart`, `protocols/fins/fins_area_image.dart`)

Mirrors the S7 shapes closely.

- **`FinsMapEntry { tag, area, wordAddress, bitOffset, access }`** — `area` one
  of `'DM'|'CIO'|'WR'|'HR'`, `access` `'ReadOnly'|'ReadWrite'` defaulting to
  `'ReadWrite'`. `FinsMap.autoGenerate(project)` packs tags into `DM` with word
  alignment, routes through `defaultsExternallyWritable` (the shared helper) so
  `SimulatedOutput`/`System`/`ReadOnly` default read-only, and **skips `STRING`**.
- **`fins_area_image.dart`** (the S7-shaped pure unit): `readAreaImage(project,
  map, area, startWord, wordCount)` materializes the requested words, encoding
  each mapped tag; **unmapped words read `0x0000`**. `applyAreaWrite(...)` decodes
  a written word range onto covered tags; **writes to unmapped words are
  discarded**; a tag only **partially** covered is **not** written and is
  reported. **Force-aware** via `isExternallyWritable` — a write to a forced /
  read-only / reserved-`System` tag is refused, tag unchanged.
- **Type mapping**: `BOOL`→1 bit, `INT16`→INT 1 word, `INT32`→DINT 2 words,
  `INT64`→LINT 4 words, `FLOAT64`→**REAL 2 words — narrowing to IEEE-754 single,
  asserted with `closeTo` AND `isNot(equals(original))`**, `STRING`→skipped. The
  32-bit **word order** (see the endianness note) is pinned by a literal-byte
  test and settled by the E2E.

## Component 5 — Config, UI, full E2E, docs

- **`FinsProtocolConfig { enabled, port, map }`**, JSON key `fins`, default port
  **9600**, following `S7ProtocolConfig` (`protocol_settings.dart:476`) exactly.
- **Outbound Protocols card** mirroring the existing six (enable, port, counters,
  map editor). Shell lifecycle: the host is **stopped on every project switch**,
  as all seven others are.
- The `fins` probe is extended to the full read → write → independent read-back
  across DM + one of CIO/WR/HR, a `BOOL` bit, and a 32-bit value (to settle word
  order), reusing the Python lane.

> **Port 9600 is NOT privileged** (>1024), so unlike S7's port 102 there is no
> elevation caveat on desktop. UDP hosting has the same platform reality the
> roadmap flagged: works on Android/desktop/iOS-foreground; **web compiles but
> cannot host inbound UDP** (`RawDatagramSocket` is unavailable), same class of
> limit as the TCP hosts on web.

## Data flow

UDP datagram → `fins_host` receive → `fins_frame` parse → Memory Area Read/Write
(`fins_memory`) → `fins_area_image` materialize/apply against the tags via
`FinsMap` → response frame (header swapped, SID echoed, end code) → UDP datagram
back to the sender. No connection state; one datagram in, one datagram out.

## Error handling / edge cases

- Malformed / short / non-FINS datagram → dropped, bind stays up, no throw.
- Unknown command code → response with a non-zero end code (not a drop).
- Read/write of an unmapped or out-of-range address → the appropriate end code.
- A write refused for force / read-only / reserved tag → an access end code, tag
  unchanged (reusing the shared gate).
- A datagram larger than a sane bound → dropped (guard before allocation).

## Testing

- **Pure unit tests** per component, asserting **byte order explicitly** against
  hand-built big-endian buffers (not only round-trips), including the 32-bit
  word-order layout.
- Area image: unmapped words read zero; writes to gaps discarded; partial
  coverage not written; bit addressing; each type's width; the `FLOAT64→REAL`
  narrowing asserted so a non-narrowing impl fails; **force / read-only /
  reserved-`System` refusal, including a member path** (reusing the Task-2
  hardening tests' shape).
- Host: a real `RawDatagramSocket` round-trip (read + write); a malformed
  datagram does not crash the bind; two peers get independent replies correlated
  by SID.
- Persistence: a project JSON with no `fins` key loads disabled at port 9600.
- **Real client**: `fins==1.0.5` connect + memory-area read (Task 3), extended to
  read → write → independent read-back incl. a 32-bit value (Task 5).
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`,
  and re-run `tool/{s7,enip,modbus,opcua}_e2e.sh` to confirm no regression.

## Files

- **Create:** `mobile/lib/protocols/fins/fins_frame.dart`, `fins_memory.dart`,
  `fins_area_image.dart`; `mobile/lib/models/fins_map.dart`;
  `mobile/lib/services/fins_host.dart`; `mobile/tool/fins_host_probe.dart`;
  `tool/py/fins_probe.py`; `tool/fins_e2e.sh`; matching tests.
- **Modify:** `mobile/lib/models/protocol_settings.dart` (`FinsProtocolConfig`),
  the Outbound Protocols screen, the workspace shell (lifecycle),
  `tool/py/requirements.txt` (pin `fins==1.0.5`).
- **Docs:** `docs/protocols/fins.md`; `ROADMAP.md`; `README.md`.

## Risks

- **Fidelity, not framing, is the risk** — as with every protocol here. The early
  probe (decision 3) surfaces it while cheap.
- **The 32-bit word order** is the one FINS-specific unknown; the literal-byte
  test plus the real-client round-trip settle it.
- **The UDP host is the only new-shape component** — no reassembly, but also no
  connection lifecycle, so status/robustness are modelled differently. The
  "malformed datagram doesn't wedge the bind" and "correlate by SID" properties
  get explicit tests.
- Area-image subtleties (alignment, partial coverage, bit offsets, gap
  semantics) are the same as S7's and reuse its solved approach.

## Decomposition (plan-time)

**5 tasks**, probe-early: (1) FINS frame (header + command/response, permissive
node echo); (2) Memory Area Read/Write + area codes; (3) **UDP host skeleton +
`fins` connect/read E2E** — the early real-client gate; (4) `FinsMap` + area image
+ Read/Write services (force-aware via the shared gate); (5) `FinsProtocolConfig`
+ UI card + shell lifecycle + full read/write/read-back E2E + full gate + docs.
