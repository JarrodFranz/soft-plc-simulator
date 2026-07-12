# DNP3 Output Events Design

**Date:** 2026-07-11
**Status:** Approved by user (chat, 2026-07-11): add DNP3 output-status change events (g11 binary output, g42 analog output) so `binaryOutput`/`analogOutput` points can be assigned an event Class like inputs; **any change** to the output value triggers an event (master-commanded or logic/sim-driven); full parity with input events (same Class-poll + unsolicited mechanism).
**Builds on:** the DNP3 outstation + events workstreams (`mobile/lib/protocols/dnp3/{dnp3_events,dnp3_app,dnp3_outstation}.dart`, `dnp3_host.dart`, `DnpMap`). Input events (g2v2 binary-input, g32v3/g32v7 analog-input) shipped; **output events (g11/g42) were explicitly deferred to v-next** in the events design — this closes that gap so all four DNP3 point types report change events.

## Goal

Let an operator assign an event Class (1/2/3) to `binaryOutput` and `analogOutput` map entries, and have the outstation report their status changes as DNP3 **output events** — Binary Output Event (`g11v2`) and Analog Output Event (`g42v3`/`g42v7`) — delivered by the *existing* solicited Class 1/2/3 polls and unsolicited push. Today the Event-class dropdown only appears on input rows (outputs show `—`) because the change-detection engine and event codec only handle inputs; this extends both so all four point types have parity.

## Scope

**In:**
- **Change detection on outputs:** `dnp3_events.dart`'s `detectChanges` also watches `binaryOutput`/`analogOutput` entries whose `eventClass ∈ {1,2,3}`. On **any** change to the point's value (via `readPath`, force-aware — same as inputs; a master OPERATE and a logic/sim write are indistinguishable and both count), an event is appended to that class's ring buffer. First-seen establishes the baseline with no event (same as inputs).
- **Output event objects (with absolute time):** `g11v2` (Binary Output Event) for `binaryOutput`; `g42v3` (Analog Output Event, 32-bit int) for INT16/INT32 `analogOutput` points and `g42v7` (Analog Output Event, single float) for FLOAT64 `analogOutput` points. Byte layout is identical to the corresponding input-event objects — only the group number differs.
- **Solicited Class reads & unsolicited:** unchanged mechanism. A Class 1/2/3 poll (`g60v2/v3/v4`) returns the buffered output events alongside input events (grouped by point-type + variation); the same CON + flush-on-CONFIRM and unsolicited push/retry paths carry them. IIN Class-available/overflow bits already reflect any non-empty class buffer regardless of point type.
- **Config UI:** the DNP3-card Event-class dropdown (Static/Class 1/Class 2/Class 3) appears on `binaryOutput`/`analogOutput` rows too (the current input-only gate is widened to all four point types). `—` becomes a dropdown.
- **E2E:** extend `gateway/examples/dnp3_probe.rs` + the Dart fixture — map an output point with an event Class, change it, and assert the real Step Function I/O `dnp3` master receives it as an event on a Class poll (mirroring the input-event E2E leg).

**Out (v-next, unchanged from the input-events deferrals):** counter events (`g22`) — no counter point type is mapped over DNP3; no-time event variants (`g11v1`/`g42v1`) — v1 always timestamps; per-class analog deadbands (any change generates an event).

## Config model

**No change.** `DnpMapEntry.eventClass` (int, default 0) already exists for every point type — the engine and UI simply ignored it for outputs. This workstream is purely behavioral + a UI gate widening; it is additive and byte-identical when no output classes are assigned. The WS6 lossless round-trip already covers `eventClass`.

## Architecture (changes to existing units — no new files, no new infrastructure)

| Unit | File | Change |
|---|---|---|
| Event engine (pure) | `mobile/lib/protocols/dnp3/dnp3_events.dart` | `detectChanges` processes `binaryOutput`/`analogOutput` in addition to inputs; `DnpEvent` already carries `pointType`/`isBinary`/`isFloat` (no new fields). Output change → event on any value change, force-aware, first-seen baseline. |
| App codec (pure) | `mobile/lib/protocols/dnp3/dnp3_app.dart` | Add `encodeG11V2({value, flags, timeMs})` (7 bytes, same as `encodeG2V2`), `encodeG42V3({value, flags, timeMs})` (11 bytes, same as `encodeG32V3`), `encodeG42V7({value, flags, timeMs})` (11 bytes, same as `encodeG32V7`) — factored to share the flags+value+48-bit-time layout. |
| Outstation handler (pure) | `mobile/lib/protocols/dnp3/dnp3_outstation.dart` | `_encodeEventObjects` groups pulled events into **6** buckets (was 3): `binaryInput→g2v2`, `binaryOutput→g11v2`, `analogInput int→g32v3`, `analogInput float→g32v7`, `analogOutput int→g42v3`, `analogOutput float→g42v7`. Each still emitted as one index-prefixed (qualifier `0x28`) object header. |
| UI | `mobile/lib/screens/gateway_screen.dart` | Widen the DNP3-card Event-class dropdown gate from input-only to all four point types (the `_dnpRow` `isInputPoint` check → include `binaryOutput`/`analogOutput`). |
| E2E | `gateway/examples/dnp3_probe.rs` (+ Dart fixture) | Map an output point with an event Class; assert the real `dnp3` master polls it as an output event. |

## Wire facts (verify against IEEE 1815 + the vendored Rust `dnp3` crate)

- **g11v2** (Binary Output Event w/ time): flags(1) + 48-bit DNP time(6) = 7 bytes. Flags byte bit 7 = point state, bits 0-6 = quality (ONLINE) — identical to `g2v2`/`g10v2`.
- **g42v3** (Analog Output Event, 32-bit w/ time): flags(1) + int32 LE(4) + 48-bit time(6) = 11 bytes — identical to `g32v3`.
- **g42v7** (Analog Output Event, single float w/ time): flags(1) + float32 LE(4) + 48-bit time(6) = 11 bytes — identical to `g32v7`.
- Encoded with qualifier `0x28` (2-byte count + per-object 2-byte index prefix), exactly like the input-event objects. 48-bit DNP time via the existing dart2js-safe 32+16-bit split (no `getInt64`/`setInt64`).
- Class objects (`g60v2/v3/v4`), CON/CONFIRM, unsolicited (fc 130), and the IIN class-available (0x02/0x04/0x08) + overflow (IIN2.3) bits are unchanged — output events ride the same paths.

## Testing (same bar as the input-events work)

1. **Engine tests** (`dnp3_events_test.dart`): a Class-1 `binaryOutput` change appends one binary output event (`isBinary`, correct `pointType`); a Class-2 `analogOutput` change appends an analog output event with the right value/time; a Class-0 output never generates events; force-aware (a forced output's forced value is captured); a master-write and a logic write both trigger an event (any-change).
2. **Codec tests** (`dnp3_app_test.dart`): `encodeG11V2`/`encodeG42V3`/`encodeG42V7` encode byte-exact (flags+value+48-bit time, matching the g2/g32 layouts with the g11/g42 group numbers).
3. **Outstation tests** (`dnp3_outstation_test.dart`): a solicited Class read with buffered input **and** output events returns them grouped into the correct 6 object types (g2/g11/g32/g42) with the right indices; flush-on-CONFIRM still works across point types; combined static + events unaffected.
4. **UI test** (`gateway_screen_test.dart`, DNP3 tab): the Event-class dropdown renders and edits `eventClass` on a `binaryOutput`/`analogOutput` row (previously `—`).
5. **Machine-proof E2E** (`tool/dnp3_e2e.sh`): the real `dnp3` master runs a Class 1/2/3 poll and asserts a changed **output** point arrives as an event (g11/g42), in addition to the existing input-event assertions → `DNP3 EVENTS PROBE PASS`. Honest build+unit fallback.
6. **Regression:** full `flutter test`; `flutter analyze` ZERO; `flutter build web --release` compiles; WS6 round-trip green; the input-event + static/control paths byte-identical when no output classes are assigned.

## Global constraints

- No vendor branding; DNP3/IEEE 1815 terms fine. Dark theme; zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/dnp3/**` stays PURE Dart (no `dart:io`/Flutter); only `dnp3_host.dart` uses `dart:io`. The outstation never crashes on malformed input.
- Little-endian wire; 48-bit DNP time via 32+16-bit accessors (no `getInt64`/`setInt64`).
- Output events are force-aware (captured value = forced value when forced). Additive persistence (no model change); WS6 round-trip green; app byte-identical on the wire when no output event classes are assigned (existing input-events + static/control behavior preserved exactly).

## Phasing (one spec → plan tasks)

1. **Engine + codec** — un-gate `binaryOutput`/`analogOutput` in `dnp3_events.dart` `detectChanges`; add `encodeG11V2`/`encodeG42V3`/`encodeG42V7` to `dnp3_app.dart`; engine + codec tests.
2. **Outstation grouping + UI** — extend `_encodeEventObjects` to the 6 point-type/variation buckets; widen the DNP3-card dropdown to output rows; outstation + UI tests.
3. **Rust `dnp3` E2E (output-event poll) + docs + final review** — machine-proof, all gates, `docs/protocols/DNP3.md` update, ROADMAP note, whole-branch review, merge.
