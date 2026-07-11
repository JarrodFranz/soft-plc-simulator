# DNP3 Events + Unsolicited (Phase 8 v-next / WS-dnp3-events) Design

**Date:** 2026-07-11
**Status:** Approved by user (chat, 2026-07-11): FULL event engine — per-point Class 0/1/2/3 assignment, change-detected event buffers, event object variations, solicited Class 1/2/3 reads, AND unsolicited responses with the application CONFIRM handshake + retry.
**Builds on:** WS26 (the shipped in-app DNP3 outstation — `dnp3_link.dart`/`dnp3_transport.dart`/`dnp3_app.dart`/`dnp3_outstation.dart`/`dnp3_host.dart`, `DnpMap`/`DnpProtocolConfig`). v1 was Class 0 static polling + SELECT/OPERATE/DIRECT_OPERATE control; this adds the events layer that was explicitly deferred. Machine-verified against the Step Function I/O Rust `dnp3` master (which supports Class 1/2/3 polls + unsolicited).

## Goal

Turn the static-only outstation into a full event-reporting outstation: input changes assigned to Class 1/2/3 are captured into per-class event buffers and delivered to a master either by **solicited** Class 1/2/3 polls or **unsolicited** push (with the DNP3 application-layer CONFIRM handshake + retry). This is what a real utility/water SCADA master expects — most integrations rely on events, not repeated integrity polls.

## Scope

**In:**
- **Per-point event Class** on INPUT points: `DnpMapEntry.eventClass ∈ {0,1,2,3}` (default 0 = static only, no events). Only `binaryInput` and `analogInput` generate events (outputs report status via static reads; output-event objects are out of scope). Class 1/2/3 → the point's changes are captured as events.
- **Change detection + event buffers**: a pure engine compares each Class-1/2/3 input's current value (via `readPath`, force-aware) to its last-reported value each tick; on change it appends an event to that class's bounded ring buffer (default capacity **200 events/class**, oldest dropped with the EVENT_BUFFER_OVERFLOW IIN2 bit set when full). Each event carries the point index, the new value + DNP3 flags (ONLINE), and a wall-clock UTC timestamp.
- **Event object variations** (with absolute time): **Binary Input Event g2v2**; **Analog Input Event g32v3** (32-bit int, with time) for INT16/INT32 points and **g32v7** (single-precision float, with time) for FLOAT64 points. Encoded with qualifier `0x28` (2-byte count + 2-byte index prefix — events carry their own point index).
- **Solicited Class reads**: a master READ of Class objects **g60v2 (Class 1) / g60v3 (Class 2) / g60v4 (Class 3)** returns the buffered events for the requested classes (grouped by point type + variation), with the response's application-control **CON bit set**; the events are **flushed only after the master's CONFIRM** (application function code 0 with the matching sequence). A Class-0 (g60v1) read still returns static data (unchanged). A combined poll (g60v1..v4) returns events + static. IIN1 **Class 1/2/3 events available** bits (0x02/0x04/0x08) reflect non-empty buffers.
- **Unsolicited responses**: the outstation tracks a per-class **unsolicited-enabled** flag (DNP3 default: disabled; the master enables/disables at runtime via **ENABLE_UNSOLICITED fc 20 / DISABLE_UNSOLICITED fc 21**, each carrying g60v2/v3/v4 to name the classes). When a class is unsolicited-enabled and it has pending events, the host sends an **unsolicited response (fc 130)** with the UNS + CON bits and the events, then waits for the master's CONFIRM: on CONFIRM → flush those events + advance the unsolicited sequence; on timeout → **retry** (bounded, e.g. up to 3 retries at a configurable interval), then give up until the next change (and keep the events buffered). A "null" unsolicited response (no objects) is sent once on (re)start/first-enable per spec so the master learns the outstation restarted.
- **IIN**: DEVICE_RESTART cleared as today; add Class-available bits (IIN1.1/1.2/1.3), EVENT_BUFFER_OVERFLOW (IIN2.3) on buffer overflow.
- **Config UI**: a per-point **event Class dropdown (0/1/2/3)** on input rows in the DNP3 point map; a read-only indicator of unsolicited state (master-controlled). `autoGenerate` sets `eventClass = 0` (back-compat: static-only until the user assigns classes).
- **E2E**: extend `dnp3_probe.rs` — the Rust `dnp3` master runs Class 1/2/3 polls (asserts a binary + analog change is delivered as an event) and enables unsolicited (asserts an outstation-initiated event push + that the master's CONFIRM flushes it).

**Out (v-next):** output-point events (g11/g42); counter events (g22); event variations without time (g2v1/g32v1) — v1 always timestamps; per-class deadbands for analog events (any change generates an event in v1); dataset/octet-string events; select-timeout tuning; time synchronization (g50) beyond the existing NEED_TIME=off.

## Config model (additive)

- `DnpMapEntry`: add `int eventClass` (default 0). `fromJson` default 0; `toJson` includes it; `autoGenerate` sets 0. Only meaningful for `binaryInput`/`analogInput` (ignored for outputs).
- `DnpProtocolConfig`: add `int unsolConfirmTimeoutMs` (default 5000) and `int unsolMaxRetries` (default 3) for the unsolicited retry policy; `int eventBufferPerClass` (default 200). All additive with defaults; the per-class unsolicited-**enabled** state is RUNTIME (master-controlled via fc20/21), not persisted. WS6 lossless round-trip stays green.

## Architecture

| Unit | File | Responsibility |
|---|---|---|
| Event engine (NEW, pure) | `mobile/lib/protocols/dnp3/dnp3_events.dart` | Per-class bounded event ring buffers; `detectChanges(project, map, nowMs)` (force-aware via `readPath`) appends events for changed Class 1/2/3 inputs; `pull(classes)` returns + marks-pending; `flush(confirmedEvents)`; overflow tracking. Pure — no `dart:io`/Flutter. |
| App codec (MODIFIED, pure) | `mobile/lib/protocols/dnp3/dnp3_app.dart` | Encode event objects g2v2 / g32v3 / g32v7 (qualifier 0x28); parse ENABLE_UNSOLICITED (20) / DISABLE_UNSOLICITED (21) with g60v2/v3/v4; parse Class read (g60v2/v3/v4); build unsolicited response (fc 130, UNS+CON); parse CONFIRM (fc 0). New function-code + IIN constants. |
| Outstation handler (MODIFIED, pure) | `mobile/lib/protocols/dnp3/dnp3_outstation.dart` | Solicited Class read → events (+ static for combined) with CON, flush-on-CONFIRM; ENABLE/DISABLE_UNSOLICITED → per-class enabled flags + null-response; CONFIRM routing; IIN class-available/overflow bits; owns the event engine + unsolicited seq. |
| Socket host (MODIFIED, only dart:io) | `mobile/lib/services/dnp3_host.dart` | A periodic change-detection tick (like the OPC UA host's 50 ms clock) feeding `detectChanges`; when a class is unsolicited-enabled and non-empty, send the unsolicited response, run the CONFIRM-wait timer + bounded retry, flush on CONFIRM; a per-connection unsolicited state. Never crashes. |
| Config model (MODIFIED) | `mobile/lib/models/dnp3_map.dart` + `protocol_settings.dart` | `eventClass` on entries; `unsolConfirmTimeoutMs`/`unsolMaxRetries`/`eventBufferPerClass` on config. |
| UI (MODIFIED) | `mobile/lib/screens/gateway_screen.dart` | Per-input-point event-Class dropdown in the DNP3 point map; unsolicited-state indicator. |
| E2E (MODIFIED) | `gateway/examples/dnp3_probe.rs` (+ Dart fixture) | Rust `dnp3` master: Class 1/2/3 poll asserts an event; enable-unsolicited asserts an outstation push + CONFIRM flush. |

## Wire facts (verify against IEEE 1815 + the Rust `dnp3` crate)

- Function codes: READ=1 (already), plus ENABLE_UNSOLICITED=20, DISABLE_UNSOLICITED=21, CONFIRM=0; responses: RESPONSE=129 (already), **UNSOLICITED_RESPONSE=130**.
- Application control: the UNS bit (0x10) marks an unsolicited response; unsolicited uses its OWN sequence counter (0-15) separate from the solicited sequence. CON bit (0x20) requests a CONFIRM.
- Class objects: g60v1=Class0(static), g60v2=Class1, g60v3=Class2, g60v4=Class3 — variation 0 qualifier 0x06 (all) in READ / ENABLE_UNSOLICITED / DISABLE_UNSOLICITED.
- Event objects (little-endian, qualifier 0x28 = 2-byte count + per-object 2-byte index): **g2v2** binary event = flags(1) + 48-bit DNP time(6); **g32v3** analog int event = flags(1) + int32 LE(4) + 48-bit time(6); **g32v7** analog float event = flags(1) + float32 LE(4) + 48-bit time(6). DNP3 time is ms since 1970-01-01 UTC as a 48-bit LE integer (`setUint32`+`setUint16`, dart2js-safe; never `setInt64`).
- CONFIRM = app fragment with fc 0 and the sequence number being confirmed (solicited or unsolicited per the UNS bit).

## Testing (same bar as WS26)

1. **Event engine tests** (`dnp3_events_test.dart`): a Class-1 binary input change appends one g2-style event; a Class-2 analog change appends a g32 event with the right value/time; Class-0 points never generate events; buffer caps at capacity with overflow flagged; `pull` + `flush(confirmed)` semantics (flush only removes confirmed events; unconfirmed stay). Force-aware: a forced input's forced value is what's captured.
2. **App-codec tests** (`dnp3_app_test.dart`): g2v2/g32v3/g32v7 encode byte-exact (flags+value+48-bit time, qualifier 0x28); parse ENABLE/DISABLE_UNSOLICITED (fc 20/21 with g60v2/3/4); parse a Class 1/2/3 READ; build an unsolicited response (fc130, UNS+CON, own seq); parse CONFIRM.
3. **Outstation tests** (`dnp3_outstation_test.dart`): a solicited Class 1 read returns buffered events with CON set and does NOT flush until a CONFIRM arrives (then it does); a combined g60v1..v4 read returns static + events; ENABLE_UNSOLICITED sets the class flag + null response; IIN class-available bits track buffers; overflow sets IIN2.3.
4. **Host tests** (`dnp3_host_test.dart`): with unsolicited enabled and an input changed, the host sends an unsolicited fc130; on a raw CONFIRM the events flush; on no CONFIRM it retries up to the cap then stops; malformed inbound never crashes; static/solicited behavior from WS26 still works.
5. **Machine-proof E2E** (`tool/dnp3_e2e.sh`): Rust `dnp3` master (a) runs a Class 1/2/3 integrity+event poll and asserts a changed binary + analog point arrive as events; (b) enables unsolicited, the fixture changes a point, and the master receives the unsolicited event + its CONFIRM flushes it → `DNP3 EVENTS PROBE PASS`. Honest fallback (build+unit) if the environment can't run it.
6. **Regression:** full `flutter test`, `flutter analyze` ZERO, `flutter build web --release` compiles, WS6 round-trip green (additive), `cargo build --examples` green, and the WS26 static/control E2E still passes.

## Global constraints

- No vendor branding; DNP3/IEEE 1815 terms fine.
- Zero `flutter analyze` warnings; no overflow at 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/dnp3/**` stays PURE Dart (no Flutter/`dart:io`); only `dnp3_host.dart` uses `dart:io`. The outstation never crashes on malformed input.
- Little-endian wire; 48-bit DNP time via 32+16-bit accessors (no `getInt64`/`setInt64`).
- Events are force-aware (captured value = forced value when forced). Additive persistence; WS6 round-trip green; app byte-identical when hosting is stopped.
- Unsolicited is OFF until a master enables it (DNP3 default), so an existing static-only setup is unchanged.

## Phasing (one spec → plan tasks)

1. **Config + event Class** — `eventClass` on `DnpMapEntry` + unsol retry/buffer fields on `DnpProtocolConfig` (additive) + round-trip test.
2. **Event engine** — `dnp3_events.dart` (per-class buffers, change detection, pull/flush, overflow); engine tests.
3. **App codec** — event object encoders (g2v2/g32v3/g32v7) + ENABLE/DISABLE_UNSOLICITED + Class read parse + unsolicited response build + CONFIRM parse; app fixtures.
4. **Outstation handler** — solicited Class reads (events + CON + flush-on-confirm), unsol enable/disable, CONFIRM routing, IIN bits; handler tests.
5. **Host + UI** — change-detection tick + unsolicited push + CONFIRM-wait/retry; DNP3 card event-Class dropdown + unsol indicator; host tests.
6. **Rust `dnp3` E2E (Class polls + unsolicited) + validation + docs + final review** — machine-proof, all gates, `docs/protocols/DNP3.md` update, ROADMAP note, whole-branch review, merge.
