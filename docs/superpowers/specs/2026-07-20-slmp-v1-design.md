# Mitsubishi SLMP / MC Protocol (device side) — Design Spec

**Date:** 2026-07-20
**Status:** Approved (design)
**Workstream:** Protocol expansion program, **workstream 5 of 6** (see
`2026-07-16-protocol-expansion-program-roadmap.md`).

## Goal

Host **SLMP (MELSEC Communication protocol), 3E binary frame over TCP**, in-process
so a SCADA MC-protocol driver can read and write the app's tags by **device code +
address** (`D0`, `M100`). Eighth protocol in the pure-Dart suite, after OPC UA,
Modbus TCP, MQTT/Sparkplug B, DNP3, EtherNet/IP, S7comm and FINS.

## Reference client — CONFIRMED BEFORE PLANNING

The roadmap requires confirming the reference client *before* the plan. Verified
on this machine, not assumed:

- `pymcprotocol` 0.3.0 installs from PyPI. It is **pure Python** (socket-based,
  no `ctypes`, no native library — none of the Windows-load risk snap7 carried).
- `pymcprotocol.Type3E` defaults to **binary** encoding, **Q**-series, and drives
  exactly what v1 needs:
  - `connect(ip, port)` / `close()`
  - `batchread_wordunits(headdevice, readsize)` / `batchwrite_wordunits(headdevice, values)`
  - `batchread_bitunits` / `batchwrite_bitunits`
  - `read_cputype`, `echo_test`, `randomread`/`randomwrite`.
- `mcprotocolconst` provides `COMMTYPE_BINARY`/`COMMTYPE_ASCII` and the device
  constants.

This reuses the **Python probe lane** (`tool/py/`) established for EtherNet/IP,
S7comm and FINS — the fourth protocol to use it.

## The central reuse (the S7/FINS family, again)

SLMP addresses data by **device code + address** — the same family as S7 (area +
byte offset) and FINS (area + word offset). So the tag-map, device-image
(materialize/apply), and read/write services reuse those proven shapes, and SLMP
**inherits the merged write-gate hardening** (`isExternallyWritable`) for free.

**Two deliberate contrasts from FINS:**

1. **Back to TCP.** FINS was the suite's first (and only) UDP host; SLMP returns
   to a length-prefixed TCP host, reusing the S7/EtherNet-IP reassembly shape (the
   3E frame's request-data-length field delimits the frame).
2. **LITTLE-ENDIAN.** Every area-based protocol so far — S7, FINS — has been
   big-endian. MELSEC/SLMP binary is **little-endian throughout**: the subheader,
   the length fields, the device number, and all word data. This is the single
   most likely source of a self-consistent-but-wrong codec, and it is the exact
   inverse of the protocol built immediately before it.

## Decisions taken (user-approved)

1. **3E binary frame only.** The dominant MC-protocol format (Q/L/iQ-R), what
   `pymcprotocol.Type3E` defaults to and most masters use. The 4E frame (3E plus
   a request/response serial number) and the ASCII encoding are deferred — 4E is
   a small superset addition later; ASCII doubles the codec for legacy links.
2. **Devices: D, M, W, R.** Data register (D, word — the heaviest-polled, the
   DM/DB equivalent), Internal relay (M, bit), Link register (W, word), File
   register (R, word). X/Y I/O relays (hex/octal numbering quirks) and the exotic
   devices are deferred.
3. **The real-client probe runs EARLY** — task 3 of 5, before any read/write
   logic — consistent with FINS/S7/EtherNet-IP, where a framing or endianness
   error otherwise hid behind a green unit suite until the last task.

## Non-goals / YAGNI

- **No 4E frame, no ASCII encoding.** (Decision 1.)
- **No X/Y I/O relays, no exotic devices.** (Decision 2.)
- **No STRING** — same struct-shaped deferral as S7/FINS/CIP.
- **No MC control services** — no remote RUN/STOP/RESET/lock, no CPU program
  transfer. This is a data-access target. (`read_cputype`/`echo_test` may be
  answered minimally if the probe requires them — decided at Task 3 against the
  real client, not now.)
- **No random-access read/write** (`randomread`/`randomwrite`, non-contiguous
  device lists) in v1 — batch read/write of a contiguous device range is the
  common poll path; random access is a v2 addition.

## Global Constraints

- **ADR-010**: pure Dart, in-process, no companion process, no FFI.
- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/protocols/slmp/` and
  `mobile/lib/models/`; `dart:io` confined to `mobile/lib/services/slmp_host.dart`.
- Codecs must **never throw** on malformed or hostile input.
- Deterministic: no wall clock, no randomness in codec logic.
- **Additive/backward-compatible**: a project with no `slmp` key loads disabled
  at the default port; no existing serialized form or scan behaviour changes;
  default-projects round-trip and scan-equivalence stay green.
- **Force-aware writes**: reuse the shared `isExternallyWritable`
  (`models/tag_write_gate.dart`) so a write to a forced / read-only / reserved-
  `System` tag is refused, tag unchanged. SLMP inherits the hardening for free.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No competitor-tooling branding in code, UI, or docs: no "OpenPLC"/"Beremiz"/
  "CODESYS"/"RSLogix"/"GX Works"/"MELSOFT". No reverse-engineering wording —
  implemented from public SLMP specification material. `SLMP`/`MELSEC` are
  protocol names and are used freely (as `Modbus`/`DNP3`/`S7comm`/`FINS` already
  are); naming a controller family (`Q`/`L`/`iQ-R`) only where a technical
  distinction requires it, never as a compatibility claim.

> **LITTLE-ENDIAN + 32-BIT WORD ORDER — the SLMP-specific trap.**
> SLMP binary is **little-endian** — the exact inverse of S7/FINS, built just
> before it. Do not pattern-match byte order from a neighbouring area protocol.
> And a 32-bit value (`DINT`/`REAL`) spans **two consecutive words**; which word
> holds the high half is the same class of documented gotcha FINS had — and FINS
> resolved it *against* the provisional guess. Tests must assert the device
> number, the word data, AND the 32-bit two-word layout against **hand-built
> little-endian buffers with known values** (a build→parse round-trip cancels a
> byte-order OR word-order error). The Task 5 `pymcprotocol` E2E round-trip of a
> 32-bit value is the ultimate authority — pick a provisional word order, isolate
> it to two encode/decode helpers, and let the client settle it.

## Component 1 — 3E binary frame (`protocols/slmp/slmp_frame.dart`)

Pure; `dart:typed_data` only. **All fields LITTLE-ENDIAN.**

- **Request**: `subheader` u16 (`0x5000`), `network no` u8, `PC no` u8 (`0xFF` =
  host station), `dest module IO` u16 (`0x03FF`), `dest module station` u8,
  `request data length` u16 (bytes that follow this field), `CPU monitoring
  timer` u16, then `command` u16 + `subcommand` u16 + command data.
- **Response**: `subheader` u16 (`0xD000`), the echoed routing bytes (network/PC/
  module), `response data length` u16, `end code` u16 (`0x0000` = success), then
  response data.
- **Routing bytes accepted permissively** — network/PC/module are echoed back
  unvalidated (the same call as S7's rack/slot and FINS's node fields; validating
  them in a simulator is a confusing failure with no diagnostic value).
- The `request data length` field delimits the frame — the TCP host uses it for
  reassembly exactly as the OPC UA/S7 length-prefixed hosts do.
- **End codes**: `0x0000` normal; `0xC059` command/subcommand error; `0xC056`
  address/range exceeded; `0xC051` read/write point-count over limit (a small set
  for the error paths — confirmed against the real client at Task 3).

## Component 2 — Batch Read/Write + device codes (`protocols/slmp/slmp_commands.dart`)

Pure. Little-endian.

- **Batch Read (word)** = command `0x0401`, subcommand `0x0000`; **Batch Write
  (word)** = command `0x1401`, subcommand `0x0000`. **Bit units** use subcommand
  `0x0001`.
- **Device spec (binary 3E)**: a **3-byte device number (little-endian)** + a
  **1-byte device code**, then `number of device points` u16.
- **Device codes (v1)**: `D 0xA8`, `M 0x90`, `W 0xB4`, `R 0xAF`.
- **Read response**: end code `0x0000` + the requested words (little-endian).
  **Write**: the command data is the device spec + point count + the write words;
  the response carries the **end code only** (no data).
- A read/write beyond a mapped/defined range returns the appropriate **end code**
  (not a dropped frame), so a driver sees a real error.
- Parse functions return `null` on a short/malformed command (never throw).

## Component 3 — TCP host skeleton + EARLY real-client probe

**Files:** `services/slmp_host.dart`, `mobile/tool/slmp_host_probe.dart`,
`tool/py/slmp_probe.py`, `tool/slmp_e2e.sh`.

- **The TCP host** reuses the S7/EtherNet-IP length-prefixed reassembly: a
  `_Connection` per socket with a `_buffer`; accumulate bytes; once the `request
  data length` field is readable, wait for the full frame; slice; dispatch; write
  the response. A single **pure shared dispatch** (as FINS's `fins_dispatch.dart`
  and S7's `dispatchS7VarJob`) that BOTH the host and the fixture probe import, so
  the fixture cannot drift from the shipped host.
- Replicate from `s7_host.dart`/`fins_host.dart`: `ChangeNotifier`, `start`/
  `stop`/`dispose`, nullable `AppLogger? logger` with `logger?.logLazy` on the hot
  path (add `kLogSourceSlmp`), `status`/`lastError`/`endpointUrl`, `projectProvider`
  called fresh per request, and the drop-log gating.
- **Default port**: MC protocol has **no universal default port** (site-configured,
  unlike FINS 9600 or S7 102). Pick a sensible configurable default at Task 3 and
  verify the `pymcprotocol` probe connects to it; the port field is user-editable.
- `dart:io` is allowed **only** in `slmp_host.dart`.
- At this task the host serves a Batch Read (word) against a small fixture; the
  `pymcprotocol` client's `connect` + `batchread_wordunits` is the gate.
- **Fixture-host constraint**: `slmp_host_probe.dart` must **not** import
  `services/slmp_host.dart` (hosts extend `ChangeNotifier` → `dart:ui`, unavailable
  under plain `dart run`); it imports the pure codec + shared dispatch and
  re-implements the small reassembly loop.
- E2E contract as established: pin `pymcprotocol==0.3.0` in
  `tool/py/requirements.txt`, start the fixture host on a non-default port, wait
  for `READY`, run the probe, unconditional teardown (trap), propagate exit code.

## Component 4 — `SlmpMap` + device image (`models/slmp_map.dart`, `protocols/slmp/slmp_device_image.dart`)

Mirrors the FINS/S7 shapes.

- **`SlmpMapEntry { tag, device, address, access }`** — `device` one of
  `'D'|'M'|'W'|'R'`, `access` `'ReadOnly'|'ReadWrite'` defaulting to `'ReadWrite'`.
  `SlmpMap.autoGenerate(project)` packs tags into `D` with word alignment, routes
  through `defaultsExternallyWritable` (the shared helper) so `SimulatedOutput`/
  `System`/`ReadOnly` default read-only, and **skips `STRING`**.
- **`slmp_device_image.dart`** (the FINS/S7-shaped pure unit): `readDeviceImage(
  project, map, device, startAddress, count)` materializes the requested words,
  encoding each mapped tag; **unmapped words read `0x0000`** (little-endian).
  `applyDeviceWrite(...)` decodes a written word range onto covered tags; **writes
  to unmapped words discarded**; a tag only **partially** covered is **not**
  written and is reported. **Force-aware** via `isExternallyWritable` — a write to
  a forced / read-only / reserved-`System` tag is refused, tag unchanged.
- **Type mapping**: `BOOL`→1 bit, `INT16`→1 word, `INT32`→2 words, `INT64`→4
  words, `FLOAT64`→**REAL 2 words — narrowing to IEEE-754 single, asserted with
  `closeTo` AND `isNot(equals(original))`**, `STRING`→skipped. All little-endian.
  The **32-bit two-word order** is provisional, pinned by a literal-byte test, and
  settled by the Task 5 E2E (as FINS did).

## Component 5 — Config, UI, full E2E, docs

- **`SlmpProtocolConfig { enabled, port, map }`**, JSON key `slmp`, default port
  chosen at Task 3, following `FinsProtocolConfig` (`protocol_settings.dart:522`)
  exactly.
- **Outbound Protocols card** mirroring the existing seven (enable, port, counters,
  map editor). Shell lifecycle: the host is **stopped on every project switch**,
  as all others are.
- The `pymcprotocol` probe is extended to full read → write → independent
  read-back across D + one of M/W/R, a `BOOL` bit, and a 32-bit value (to settle
  word order), reusing the Python lane.

## Data flow

TCP bytes → `slmp_host` length-prefixed reassembly → `slmp_frame` parse → Batch
Read/Write (`slmp_commands`) → `slmp_device_image` materialize/apply against the
tags via `SlmpMap` → response frame (subheader `0xD000`, routing echoed, end code)
→ TCP. Length-prefixed, one request one response.

## Error handling / edge cases

- Malformed / short / non-SLMP frame → dropped or an end-code response; the bind
  stays up, no throw.
- Unknown command/subcommand → end code `0xC059` (not a drop).
- Read/write of an unmapped or out-of-range device → the appropriate end code.
- A write refused for force / read-only / reserved tag → an access end code, tag
  unchanged (reusing the shared gate).
- A frame claiming a length beyond a sane bound → dropped (guard before
  allocation), as the S7/ENIP hosts do.

## Testing

- **Pure unit tests** per component, asserting **byte order explicitly** against
  hand-built LITTLE-endian buffers (not only round-trips), including the device
  number, word data, and the 32-bit two-word layout.
- Device image: unmapped words read zero; writes to gaps discarded; partial
  coverage not written; bit addressing; each type's width; the `FLOAT64→REAL`
  narrowing asserted so a non-narrowing impl fails; **force / read-only /
  reserved-`System` refusal, including a member path** (reusing the hardening
  tests' shape).
- Host: a real TCP round-trip (read + write); a malformed frame does not crash the
  bind; a fragmented and a coalesced frame both handled (assert an exact reply
  count).
- Persistence: a project JSON with no `slmp` key loads disabled at the default
  port.
- **Real client**: `pymcprotocol==0.3.0` connect + batch word read (Task 3),
  extended to read → write → independent read-back incl. a 32-bit value (Task 5).
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`, and
  re-run `tool/{fins,s7,enip,modbus,opcua}_e2e.sh` to confirm no regression.

## Files

- **Create:** `mobile/lib/protocols/slmp/slmp_frame.dart`, `slmp_commands.dart`,
  `slmp_device_image.dart`, `slmp_dispatch.dart`; `mobile/lib/models/slmp_map.dart`;
  `mobile/lib/services/slmp_host.dart`; `mobile/tool/slmp_host_probe.dart`;
  `tool/py/slmp_probe.py`; `tool/slmp_e2e.sh`; matching tests.
- **Modify:** `mobile/lib/models/protocol_settings.dart` (`SlmpProtocolConfig`),
  the Outbound Protocols screen, the workspace shell (lifecycle),
  `mobile/lib/models/app_log.dart` (`kLogSourceSlmp`), `tool/py/requirements.txt`
  (pin `pymcprotocol==0.3.0`).
- **Docs:** `docs/protocols/slmp.md`; `ROADMAP.md`; `README.md`.

## Risks

- **Fidelity, not framing, is the risk** — as with every protocol here. The early
  probe (decision 3) surfaces it while cheap.
- **LITTLE-endianness is the headline risk** — the exact inverse of the two
  protocols built before it. Explicit literal-byte assertions and the early
  real-client read are the mitigation.
- **The 32-bit word order** is the one genuine unknown (as it was for FINS, which
  was overturned); the literal test plus the E2E round-trip settle it, and it is
  isolated to two helpers for a cheap flip.
- Device-image subtleties (alignment, partial coverage, bit offsets, gap
  semantics) are the same as S7/FINS and reuse their solved approach.

## Decomposition (plan-time)

**5 tasks**, probe-early: (1) 3E binary frame (little-endian, permissive routing
echo); (2) Batch Read/Write + device codes; (3) **TCP host skeleton +
`pymcprotocol` connect/read E2E** — the early real-client gate (also settles the
default port); (4) `SlmpMap` + device image + Read/Write services (force-aware via
the shared gate); (5) `SlmpProtocolConfig` + UI card + shell lifecycle + full
read/write/read-back E2E + full gate + docs.
