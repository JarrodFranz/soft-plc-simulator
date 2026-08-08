# Learning Registry

> Last updated: 2026-08-07 (foundation seed: 18 confirmed learnings CL-1..CL-18, covering
> IEC 61131 execution semantics, protocol wire-format quirks, app engine internals, browser/test
> verification technique, PLC exchange-format dialect detection, and default-project catalog
> rules; finalizer pass: corrected CL-13/CL-18 "Knowledge base updated" citations that named
> app/default-projects.md without the file actually citing either id - see
> [../knowledge/app/tag-model.md](../knowledge/app/tag-model.md) and
> [../knowledge/industry/iec61131/ladder-diagram.md](../knowledge/industry/iec61131/ladder-diagram.md)
> for where those two learnings actually live; 2026-08-07 L5X FBD import pass: added CL-19..CL-22,
> covering a graphical-import merge identity-collision pitfall, an in-place-mutation retarget-steal
> pitfall, mutation-proving forwarding parameters, and Rockwell FBD interop specifics).

This is the append-only log of learnings surfaced across sessions. See
[HOW-TO-USE.md](./HOW-TO-USE.md) for how to read and write it, and
[../knowledge/governance.md](../knowledge/governance.md) section 6 for the full learning-loop
rule. CL = confirmed (proven by test/E2E/2+ observations or matches an authoritative source).
TL = tentative (single observation, apply with caution).

---

## Sessions Index

| Session ID | Date | Task | Key Learnings | Status |
|---|---|---|---|---|
| 2026-07-05-fbd-ladder-execution | 2026-07-05 | Implement and cross-verify FBD and LD execution engines (network ordering, timer/counter preload) | CL-1, CL-2 | closed |
| 2026-07-06-sfc-execution-and-scan-timing | 2026-07-06 | Implement SFC execution and reconcile STEP_T against task-period scan timing | CL-4 | closed |
| 2026-07-13-task-scheduler-and-system-tags | 2026-07-13 | Build the IEC task-type priority scheduler, per-task watchdog, free-run mode, reserved System UDT | CL-3 | closed |
| 2026-07-15-tag-historian-trends | 2026-07-15 | Build the memory-only tick-driven tag historian and multi-pen trend charts; verify write-gate predicates while wiring live tag reads | CL-13, CL-14 | closed |
| 2026-07-18-protocol-hardening-slmp-modbus | 2026-07-18 | Harden SLMP and Modbus codecs against malformed frames; cross-check byte order against real client libraries | CL-5, CL-6, CL-7 | closed |
| 2026-07-20-opcua-hardening-and-certs | 2026-07-20 | Validate OPC UA secure-channel crypto (Basic256Sha256) and certificate handling against a strict Rust client | CL-15 | closed |
| 2026-07-22-simulated-test-tags-and-noise | 2026-07-22 | Build bulk signal-generator tags and reconcile sim-rule noise determinism for repeatable tests | CL-8 | closed |
| 2026-07-24-widget-test-and-port-probe-hardening | 2026-07-24 | Fix widget tests hanging on real socket I/O under fake-async; classify privileged-port bind failures across POSIX/Windows | CL-10, CL-11 | closed |
| 2026-07-25-browser-verification-canvas-app | 2026-07-25 | Establish the headless-Playwright verification method for the Flutter-web CanvasKit app; diagnose why the in-app preview pane times out | CL-9, CL-16 | closed |
| 2026-07-26-l5x-import-foundation | 2026-07-26 | Ship the Rockwell L5X import foundation; add PLCopen-vs-L5X dialect autodetection | CL-17 | closed |
| 2026-08-06-default-projects-redo | 2026-08-06 | Rebuild the default-project catalog (7-project redo); fix a Continuous-task-starvation bug found via the Flagship default; pin the backfill ledger's never-overwrite rule; audit HMI layout and LD counter presets across all defaults | CL-3, CL-12, CL-13, CL-18 | closed |
| 2026-08-07-l5x-fbd-import | 2026-08-07 | Ship L5X FBD routine + FBD-Logic AOI import (PR #20); whole-branch review found and fixed an identity-collision merge bug, a retarget-steal bug, and mutation-uncovered forwarding gaps; alias Rockwell FBD mnemonics/pins to IEC | CL-19, CL-20, CL-21, CL-22 | closed |
| 2026-08-08-l5x-sfc-import | 2026-08-08 | Ship L5X SFC routine import (PR #21); plan review found an identity-gate scope gap covering a dereferenceable-but-unguarded element kind, confirmed the branch/leg/link classifier's dominance and self-referential safety argument, hardened concurrency/priority tests to be contested rather than uncontested, and pinned the poison-node validator-coupling risk with a dialect-neutral guard test | CL-23, CL-24, CL-25, CL-26 | closed |

---

## Tentative Learnings

### TL-1 - Ignition's Omron FINS driver requires Bind Address 0.0.0.0 when the client runs in Docker

**Observed in:** one live Ignition-in-Docker interop session during the FINS workstream (2026-07).
**Applies to:** connecting any UDP-based host (FINS, BACnet/IP) to a client inside Docker.
**Rule:** the FINS driver's Bind Address must be `0.0.0.0`, not `localhost` - a UDP socket bound
to loopback cannot send to `host.docker.internal`, and the device sits at "BOUND" with zero
datagrams arriving. Single observation, not reproduced since; apply with caution.
**Knowledge base updated:**
- [../knowledge/industry/protocols/fins.md](../knowledge/industry/protocols/fins.md)

## Confirmed Learnings

### CL-1 - FBD CTD needs an explicit load pulse; LD timer/counter blocks preload PRE on first scan

**Confirmed in:** 2026-07-05-fbd-ladder-execution
**Applies to:** LD and FBD counter/timer execution (`fbd_exec.dart`, `ld_exec.dart`)
**Rule:** LD timer/counter blocks preload their `PRE` value on the first scan. The FBD `CTD`
block does not - its `CV` seeds at 0, and `LD`/`CD` are mutually exclusive per scan. An FBD
`CTD` therefore needs an explicit load pulse (e.g. an `R_TRIG` feeding `LD`) before it starts
counting down from a nonzero value.

**Wrong:**
```
// assuming FBD CTD.CV starts at PRE like LD's countdown timer
CTD1(CD := doorClosed, PV := 5);   // CV reads 0 on scan 1, not 5
```

**Correct:**
```
// explicit load pulse before counting
CTD1(LD := R_TRIG1.Q, CD := doorClosed, PV := 5);
```
**Knowledge base updated:**
- [../knowledge/industry/iec61131/function-block-diagram.md](../knowledge/industry/iec61131/function-block-diagram.md)
- [../knowledge/industry/iec61131/ladder-diagram.md](../knowledge/industry/iec61131/ladder-diagram.md)

---

### CL-2 - FBD networks execute in ascending index order; same-scan chaining is real

**Confirmed in:** 2026-07-05-fbd-ladder-execution
**Applies to:** FBD execution engine (`fbd_exec.dart`)
**Rule:** FBD networks within one program execute in ascending index order within a single
scan. `TAG_OUTPUT` writes immediately when its network runs, and `TAG_INPUT` reads the live
current value, so a later network in the same scan can consume a value an earlier network wrote
moments before - same-scan chaining across networks is real and deterministic by network order,
not incidental.

**Knowledge base updated:**
- [../knowledge/industry/iec61131/function-block-diagram.md](../knowledge/industry/iec61131/function-block-diagram.md)

---

### CL-3 - A Periodic task with a period close to the scan period starves Continuous tasks

**Confirmed in:** 2026-07-13-task-scheduler-and-system-tags, 2026-08-06-default-projects-redo
**Applies to:** IEC task scheduler (`task_scheduler.dart`)
**Rule:** A Continuous task runs only when no higher-priority task is currently due
(`!anyHigherDue`). A Periodic task whose period is close to the scan period is due on nearly
every scan, which starves any Continuous-task program of scan time. Keep Periodic task periods
at least 10x the scan period. Confirmed a second time as the root cause of a Flagship default
project bug where a Continuous program appeared to stall.

**Knowledge base updated:**
- [../knowledge/industry/iec61131/task-scheduling.md](../knowledge/industry/iec61131/task-scheduling.md)
- [../knowledge/app/scan-engine.md](../knowledge/app/scan-engine.md)

---

### CL-4 - SFC STEP_T advances by scan dtMs, not by the owning task's period

**Confirmed in:** 2026-07-06-sfc-execution-and-scan-timing
**Applies to:** SFC execution engine (`scan_tick.dart`, `sfc_exec.dart`)
**Rule:** `STEP_T` accumulates by the scan's `dtMs` (the base scan period), not by the period of
the task that owns the SFC program. A program running in a 1000 ms task on a 100 ms base scan
dwells 10x longer in wall-clock time than `STEP_T`'s value suggests, because the program only
actually executes once per 1000 ms even though the counter ticks by the 100 ms scan unit.

**Knowledge base updated:**
- [../knowledge/industry/iec61131/sequential-function-chart.md](../knowledge/industry/iec61131/sequential-function-chart.md)
- [../knowledge/app/scan-engine.md](../knowledge/app/scan-engine.md)

---

### CL-5 - SLMP 3E binary is little-endian except the subheader, which is big-endian

**Confirmed in:** 2026-07-18-protocol-hardening-slmp-modbus
**Applies to:** SLMP codec (`slmp_frame.dart`), E2E-proven against `pymcprotocol`
**Rule:** SLMP's 3E binary frame is little-endian throughout the body, except its 2-byte
subheader, which is big-endian - a documented mixed-endianness convention, not a codec bug.

**Knowledge base updated:**
- [../knowledge/industry/protocols/slmp.md](../knowledge/industry/protocols/slmp.md)
- [../knowledge/industry/protocols/endianness-and-framing.md](../knowledge/industry/protocols/endianness-and-framing.md)

---

### CL-6 - Modbus RTU CRC-16 is little-endian on the wire; TCP MBAP fields are big-endian

**Confirmed in:** 2026-07-18-protocol-hardening-slmp-modbus
**Applies to:** Modbus RTU and TCP codecs (`modbus_rtu.dart`, `modbus_pdu.dart`), E2E-proven
against `tokio-modbus`
**Rule:** Modbus RTU's CRC-16 is transmitted little-endian, while Modbus TCP's MBAP header
fields are big-endian. RTU has no MBAP header at all - the two transports are not just "TCP with
a header stripped," they have genuinely different byte-order conventions for their respective
framing.

**Knowledge base updated:**
- [../knowledge/industry/protocols/modbus.md](../knowledge/industry/protocols/modbus.md)
- [../knowledge/industry/protocols/endianness-and-framing.md](../knowledge/industry/protocols/endianness-and-framing.md)

---

### CL-7 - Byte order is not consistent across protocols; never pattern-match a new codec off an old one

**Confirmed in:** 2026-07-18-protocol-hardening-slmp-modbus
**Applies to:** all protocol codecs (`tpkt_cotp.dart`, `fins_frame.dart`, `enip_encap.dart`, and
others)
**Rule:** S7comm (TPKT/COTP) and FINS are big-endian throughout. EtherNet/IP (CIP encapsulation)
is little-endian. There is no cross-protocol default to assume - each new protocol codec's byte
order must be verified against its own spec or a real client library, never copied by
pattern-matching an existing codec's convention.

**Knowledge base updated:**
- [../knowledge/industry/protocols/endianness-and-framing.md](../knowledge/industry/protocols/endianness-and-framing.md)
- [../knowledge/industry/protocols/s7comm.md](../knowledge/industry/protocols/s7comm.md)
- [../knowledge/industry/protocols/fins.md](../knowledge/industry/protocols/fins.md)
- [../knowledge/industry/protocols/ethernet-ip-cip.md](../knowledge/industry/protocols/ethernet-ip-cip.md)

---

### CL-8 - Sim-rule noise PRNG is seeded from the rule id, not its position

**Confirmed in:** 2026-07-22-simulated-test-tags-and-noise
**Applies to:** simulation engine and noise model (`sim_engine.dart`, `noise_model.dart`)
**Rule:** The pseudo-random noise sequence for a `SimRule` is seeded from that rule's id string,
not from its index/position in the rule list. Renaming a rule's id changes its noise sequence
even if its position and other parameters are untouched. Tests asserting deterministic noise
output must pin rule ids explicitly, never rely on list position as an implicit identity.

**Knowledge base updated:**
- [../knowledge/app/simulation.md](../knowledge/app/simulation.md)

---

### CL-9 - Flutter-web CanvasKit apps expose no DOM; drive them with screenshots + coordinate clicks

**Confirmed in:** 2026-07-25-browser-verification-canvas-app
**Applies to:** all browser verification of the Flutter-web build (Playwright)
**Rule:** The app renders to a `<canvas>`, so there is no DOM to click by default. Playwright
screenshots and viewport resize work fine despite the app's continuous scan-loop repaint -
capture without waiting for network idle. Flutter's semantics-tree clicks
(`flt-semantics-placeholder`) are unreliable for this app; when DOM-level interaction is needed,
fall back to `page.mouse.click(x, y)` using coordinates read off a screenshot.

**Knowledge base updated:**
- [../knowledge/practices/verification.md](../knowledge/practices/verification.md)

---

### CL-10 - dart:io futures never complete inside a widget-test's fake-async zone

**Confirmed in:** 2026-07-24-widget-test-and-port-probe-hardening
**Applies to:** any widget test that exercises real socket I/O (protocol host tests)
**Rule:** `dart:io` futures (real sockets, real ports) never complete inside a Flutter
widget-test's fake-async zone. Real socket work must be wrapped in `tester.runAsync`, and the
test must assert the `runAsync` result `isNotNull` - a thrown callback inside `runAsync` yields
`null` silently, which would otherwise let a broken test pass by accident.

**Wrong:**
```dart
testWidgets('host accepts a connection', (tester) async {
  await realHost.start(); // hangs / never completes under fake-async
});
```

**Correct:**
```dart
testWidgets('host accepts a connection', (tester) async {
  final result = await tester.runAsync(() => realHost.start());
  expect(result, isNotNull); // guards against a silently-swallowed throw
});
```
**Knowledge base updated:**
- [../knowledge/practices/verification.md](../knowledge/practices/verification.md)

---

### CL-11 - Binding a privileged port fails differently on POSIX vs Windows; classify separately

**Confirmed in:** 2026-07-24-widget-test-and-port-probe-hardening
**Applies to:** port-probe tests for any protocol host that can bind port < 1024 (e.g. Modbus
TCP's default 502)
**Rule:** Binding port 502 requires elevated privilege on POSIX (`EACCES`, errno 13) and on
Windows (`WSAEACCES`, 10013). Port-probe tests must classify a permission-denied bind failure
separately from an address-already-in-use failure, or they false-fail in CI environments that
run unprivileged. See [gaps.md](../knowledge/gaps.md) (G-8): the Windows `WSAEACCES` path is
recorded here as a risk, not yet confirmed by a dedicated Windows CI run.

**Knowledge base updated:**
- [../knowledge/practices/verification.md](../knowledge/practices/verification.md)

---

### CL-12 - The default-project backfill ledger never overwrites an existing project id

**Confirmed in:** 2026-08-06-default-projects-redo
**Applies to:** default-project seeding (`project_repository.dart`, `data/default_projects.dart`)
**Rule:** `backfillNewDefaults` can only add a default project whose id has never been seeded
before on that install; it will never overwrite or remove an id that already exists. Reusing a
retired project's id therefore silently suppresses delivery of new content to every existing
install that already has that id - new default projects always need a fresh id. Pinned by the
default-project integrity test.

**Knowledge base updated:**
- [../knowledge/app/default-projects.md](../knowledge/app/default-projects.md)

---

### CL-13 - HmiComponent has no x/y; HMI layout is grid-flow, so overlap is structurally impossible

**Confirmed in:** 2026-07-15-tag-historian-trends, 2026-08-06-default-projects-redo
**Applies to:** HMI layout model (`HmiComponent`, workspace HMI screens)
**Rule:** `HmiComponent` carries no `x`/`y` coordinates - HMI layout is pure grid-flow, positioned
only by `gridSpanWidth`. Because there is no absolute positioning, two components cannot overlap;
"fix an overlapping HMI layout" is not a class of bug this engine can have. Any apparent overlap
report is actually a `gridSpanWidth` miscalculation, not a positioning collision.

**Knowledge base updated:**
- [../knowledge/app/tag-model.md](../knowledge/app/tag-model.md)

---

### CL-14 - The write path has two distinct predicates: map-exposure vs the hard per-write backstop

**Confirmed in:** 2026-07-15-tag-historian-trends
**Applies to:** tag write gate (`tag_write_gate.dart`), all protocol write handlers
**Rule:** `defaultsExternallyWritable` governs what the map auto-generation step exposes as
writable to a protocol client. `isExternallyWritable` is the separate, hard per-write backstop
that every protocol handler must also consult at write time. A System tag refuses writes even if
a map were mutated to mark it writable - the two predicates are independent, and both must be
checked; one is a generation-time convenience, the other is the enforcement point.

**Knowledge base updated:**
- [../knowledge/app/tag-model.md](../knowledge/app/tag-model.md)

---

### CL-15 - OPC UA cert thumbprint is SHA-1 over DER; Basic256Sha256 OPN pad/sign order must be byte-exact

**Confirmed in:** 2026-07-20-opcua-hardening-and-certs
**Applies to:** OPC UA certificate handling and secure channel (`opcua_certificate.dart`,
`opcua_secure_channel.dart`), validated against a strict Rust `opcua` crate client
**Rule:** The OPC UA certificate thumbprint used for identification is SHA-1 computed over the
DER-encoded certificate. For the `Basic256Sha256` security policy, the OpenSecureChannel (OPN)
message's padding and sign-then-encrypt ordering must be byte-exact - a strict client (the Rust
`opcua` crate) rejects any deviation rather than tolerating it.

**Knowledge base updated:**
- [../knowledge/industry/protocols/opc-ua.md](../knowledge/industry/protocols/opc-ua.md)

---

### CL-16 - An in-app screenshot pane can time out on a continuously-repainting canvas app; use Playwright instead

**Confirmed in:** 2026-07-25-browser-verification-canvas-app
**Applies to:** any screenshot-based verification of the Flutter-web build
**Rule:** An embedded in-app preview/screenshot pane can time out against this app because of its
continuous scan-loop repaint, while headless Playwright captures the same page fine. Verify
canvas apps like this one with Playwright, not an embedded preview screenshotter that waits on a
render-idle signal this app never sends.

**Knowledge base updated:**
- [../knowledge/practices/verification.md](../knowledge/practices/verification.md)

---

### CL-17 - PLCopen TC6 vs L5X dialect detection is reliable from the document root; never route on filename

**Confirmed in:** 2026-07-26-l5x-import-foundation
**Applies to:** import dialect detection (`dialect_detect.dart`)
**Rule:** PLCopen TC6 documents are identified by a `<project>` root element in the TC6
namespace; L5X documents are identified by an `<RSLogix5000Content>` root element. Dialect
detection must route on the document root, never on the filename or file extension - a `.xml` or
mislabeled file still parses correctly this way.

**Knowledge base updated:**
- [../knowledge/industry/plc-formats/plcopen-tc6-xml.md](../knowledge/industry/plc-formats/plcopen-tc6-xml.md)
- [../knowledge/industry/plc-formats/rockwell-l5x.md](../knowledge/industry/plc-formats/rockwell-l5x.md)

---

### CL-18 - Ladder CTU/CTD presets are integer literals, not tag references

**Confirmed in:** 2026-08-06-default-projects-redo
**Applies to:** LD counter blocks (`builders.dart`), any UI or HMI that displays a counter preset
**Rule:** In this engine, a ladder `CTU`/`CTD` block's preset (`PV`) is compiled as an integer
literal, not a reference to a tag. A UI slider or HMI control bound to what looks like a "preset
tag" will desynchronize from the counter's real, compiled-in preset - descriptions and HMI
screens must not imply the preset is live-adjustable via a tag unless the block is explicitly
rebuilt to take a tag-bound preset. Surfaced while auditing the conveyor-line default project.

**Knowledge base updated:**
- [../knowledge/industry/iec61131/ladder-diagram.md](../knowledge/industry/iec61131/ladder-diagram.md)

---

### CL-19 - Graphical-import merges must treat identity collisions as stub-worthy, not last-write-wins

**Confirmed in:** 2026-08-07-l5x-fbd-import
**Applies to:** any graphical-import merge algorithm that indexes nodes by id (`l5x_parser.dart`'s
`weaklyConnectedComponents` byId map, and the shared component-scan machinery in
`graph_segment.dart`)
**Rule:** Building a byId map from a node list as `{for (n in nodes) n.localId: n}` silently keeps
only the last node with each id - an earlier duplicate is deleted outright, its wires re-point onto
the survivor, and the merged component then translates cleanly as the wrong logic (no error, no
stub, just wrong). Surfaced in L5X's multi-sheet FBD merge, where two elements on one sheet could
legitimately share a raw `ID`. The fix: demote the duplicate to a synthetic negative id before
indexing (never re-registering the raw id), so it trips the translator's `localId < 0` stub gate and
its component visibly stubs with a "duplicate ID" warning, instead of silently overwriting the real
element.

**Wrong:**
```dart
final byId = {for (final n in nodes) n.localId: n}; // later duplicate wins, earlier one vanishes
```

**Correct:**
```dart
// demote the duplicate before indexing so the STUB gate fires instead of an overwrite
final localId = duplicate ? (malformedId--) : parsed + idOffset;
```
**Knowledge base updated:**
- [../knowledge/industry/plc-formats/rockwell-l5x.md](../knowledge/industry/plc-formats/rockwell-l5x.md)

---

### CL-20 - In-place retarget loops that rescan mutated state can steal a value from an earlier iteration

**Confirmed in:** 2026-08-07-l5x-fbd-import
**Applies to:** any in-place mutation loop that renames/retargets by string-matching against values
the SAME loop is mutating (`fb_import.dart`'s AOI FBD-instance retarget, `ir_to_project.dart`'s
mirrored program-FBD loop)
**Rule:** A loop that retargets blocks by rescanning for "the current tag's original name" after
earlier iterations already mutated bindings is order-dependent: if a later instance's original name
happens to equal the name an earlier iteration just renamed to, the later iteration's match also
captures the earlier, already-renamed block - both end up sharing one var (of the wrong type for one
of them), sharing nested FB state. The fix is to build the match index over the BORN (pre-loop)
values once, before the loop starts, and retarget from that frozen index - never re-scan live/
mutated state mid-loop. Both retarget sites in this codebase had the same latent bug (`fb_import.
dart`'s AOI arm and `ir_to_project.dart`'s mirror); a red-first test reproduced the steal at both
sites before the fix.

**Wrong:**
```dart
// rescans CURRENT (partially-mutated) bindings on every iteration
for (final block in blocks) {
  final match = blocks.where((b) => b.tagBinding == block.originalName); // may hit an already-renamed block
  retarget(match, block.newName);
}
```

**Correct:**
```dart
// index ORIGINAL bindings once, before any mutation happens
final byOriginalBinding = {for (final b in blocks) b.originalName: b};
for (final block in blocks) {
  retarget(byOriginalBinding[block.originalName], block.newName);
}
```
**Knowledge base updated:**
- [../knowledge/practices/development-process.md](../knowledge/practices/development-process.md)

---

### CL-21 - Mutation-prove forwarding/threading parameters, including at the production call site

**Confirmed in:** 2026-08-07-l5x-fbd-import
**Applies to:** any optional-with-default parameter that threads runtime/context state through a
call chain (`fbdRt`, `ldRt` forwarding in `fb_exec.dart`, `runScanTick`, `runScopedFbdBody`)
**Rule:** An optional parameter with a default makes a dropped forward compile silently and pass an
entire test suite that never actually exercises the forwarded value - a unit test constructing its
own runtime object supplies its own default, masking the bug just as effectively as the production
caller's own accidental omission would. The only reliable guard is a test proven to fail (mutation-
verified) under each dropped hop individually, INCLUDING the production call site - a scan-level
test, not only a narrower unit-level path. Review mutation-testing on this workstream found three
uncovered forwarding hops this way: `runScanTick`'s `fbdRt: rt.fbd` (zero coverage before the fix),
`executeFbInstance`'s `ldRt: ldRt` mirror into `runScopedFbdBody`, and the FBD self-reference
depth-cap guard - all three closed with tests confirmed to fail when the forward was manually
dropped.

**Knowledge base updated:**
- [../knowledge/practices/verification.md](../knowledge/practices/verification.md)

---

### CL-22 - Rockwell FBD interop specifics: Operand vs Function elements, SEL/CTUD name collisions, connector name reuse, OSRI/OSFI mapping

**Confirmed in:** 2026-08-07-l5x-fbd-import
**Applies to:** L5X FBD import (`l5x_parser.dart`'s `_kL5xFbdTypeAliases`/`_kL5xFbdPinAliases`,
`_resolveL5xFbdConnectors`)
**Rule:** Four Rockwell-specific FBD quirks worth keeping as settled facts, not re-derived each time:
- Logix emits `<Block Operand="...">` for ordinary instructions and a distinct `<Function>` element
  for bit functions - both feed the same alias/translate pipeline but are structurally different
  elements, not the same tag with different attributes.
- `SEL` and `CTUD` are Rockwell mnemonics that COLLIDE with IEC built-in block names, so they pass
  the built-in allowlist without any alias needed and then die at pin assertion unless their pins
  are also aliased (`SelectorIn` -> `G`, etc.) - the type name matching an IEC built-in is not
  evidence the pins line up.
- Connector (`ICon`/`OCon`) names are unique within one Logix routine by construction, and this
  app's resolver matches them the same way (name-based, routine-wide). A malformed export that
  reuses one connector name for two independent producer/consumer pairs is out of spec for Logix
  but not rejected on import: every producer of that name splices onto every consumer (a
  cross-product), and the fused component then stubs deterministically at the translator's
  `unresolved-pin` gate rather than silently wiring the wrong signal. Full 1:1 pairing (by sheet
  proximity or declaration order) is deferred - see `docs/DEFERRED.md`.
- `OSRI`/`OSFI` map onto the IEC `R_TRIG`/`F_TRIG` blocks, with `InputBit` -> `CLK` and `OutputBit`
  -> `Q` pin aliases - both are best-effort (Logix's separate storage/output bits have no 1:1 IEC
  equivalent), flagged with a warning-severity breadcrumb rather than a silent lossy translation.

**Knowledge base updated:**
- [../knowledge/industry/plc-formats/rockwell-l5x.md](../knowledge/industry/plc-formats/rockwell-l5x.md)

---

### CL-23 - An identity gate must cover every dereferenceable element kind, not just the ones it was written for

**Confirmed in:** 2026-08-08-l5x-sfc-import (plan review C1 and Task 1's fix to `l5x_parser.dart`;
proven with both-document-orders tests)
**Applies to:** any id-indexed import/merge step that gates malformed identity before later
resolution dereferences it (`l5x_parser.dart`'s SFC element-id gate, and by extension every
id-indexed merge step in the codebase - see CL-19)
**Rule:** When one element kind both BYPASSES an identity gate (because the gate was scoped only
to the kinds the author expected to collide, e.g. steps/transitions/branches) and IS still
dereferenced by a later resolution pass (because a link or reference can legitimately target it),
a duplicate id on that bypassed kind silently deletes the earlier registration during resolution -
no error, no stub, just a dropped or misrouted reference. The safe scope rule is not "gate the
kinds I expect duplicates on" but "gate anything that CAN be referenced; skip only what can never
be an endpoint" - decided by asking whether resolution ever dereferences that kind, not by how
likely a real export is to produce a collision on it.

**Wrong:**
```dart
// gates only the kinds the author expected duplicates on
if (element is Step || element is Transition || element is Branch) {
  checkDuplicateId(element);
}
```

**Correct:**
```dart
// gates every kind that resolution can dereference, including annotation-adjacent ones
if (isDereferenceable(element)) {  // anything a link/reference can target
  checkDuplicateId(element);
}
```
**Knowledge base updated:**
- [../knowledge/practices/development-process.md](../knowledge/practices/development-process.md)

---

### CL-24 - A flat vendor encoding maps onto a paired-connector IR via a LOCAL-evidence classifier that dominates direction-only rules

**Confirmed in:** 2026-08-08-l5x-sfc-import (`l5x_parser.dart` branch synthesis, spec §3,
equivalence tests over both encodings)
**Applies to:** any vendor exchange-format import that flattens a paired-node IR concept
(divergence/convergence, producer/consumer) into a single element (L5X `<Branch>`/`<Leg>`/
`<DirectedLink>`)
**Rule:** A flat vendor encoding can be mapped onto a paired-connector IR without a mode switch by
classifying each link endpoint from LOCAL evidence only - leg ids classified by direction (out of
a leg feeds the divergence, into a leg drains the convergence), and links naming the container id
classified by the OTHER endpoint's node kind (selection diverges into transitions and converges
from a step; simultaneous is the mirror). This one classifier strictly dominates a direction-only
rule, which agrees on every trunk link but silently misreads a leg-head link expressed through the
branch id as a convergence outlet - a wrong chart that still passes every shape check. The caveat:
the classifier's safety argument ("kind determines role") is self-referential with the routine's
own shape validation - it is sound only because that validator independently rejects the chart
shapes where the kind-inference would be ambiguous. Any relaxation of the shape validator (for
example, to accept a genuinely third encoding) needs its own correctness check of the classifier,
not an assumption that "kind determines role" still holds once the validator's guarantees change.

**Knowledge base updated:**
- [../knowledge/industry/plc-formats/rockwell-l5x.md](../knowledge/industry/plc-formats/rockwell-l5x.md) §5

---

### CL-25 - Concurrency/priority tests must contest the semantics under test, not just exercise it uncontested

**Confirmed in:** 2026-08-08-l5x-sfc-import (Task 4 review and fix; mutation-verified: a
`consumed`-neutered mutation and an `every`->`any` mutation were both caught only after the tests
were contested)
**Applies to:** any test of first-true-wins selection or AND-join concurrency semantics
(`sfc_exec.dart`'s selection-divergence priority and simultaneous-branch join)
**Rule:** A test of concurrency or priority semantics proves nothing about the ordering/priority
rule itself unless the scenario actually CONTESTS it. A first-true-wins selection test where only
one condition is ever true passes identically whether "first true wins" is really implemented or
has regressed to "any true wins" - nothing in the assertion distinguishes the two. A parallel-join
test whose legs always arrive on the same scan passes identically whether the join requires ALL
legs (AND) or just ANY leg (OR). Staggering condition truth across scans and contesting priorities
(multiple simultaneously-true conditions, legs arriving on different scans) is what gives the test
the power to fail under a regressed implementation - confirm this with mutation testing, not by
reading the assertions.

**Knowledge base updated:**
- [../knowledge/practices/verification.md](../knowledge/practices/verification.md) §7 (extends the
  CL-21 mutation-testing theme)

---

### CL-26 - A poison node can route unrepresentable input through an existing validator's cheapest rejection path; guard the coupling with a dialect-neutral test in the validator's own file

**Confirmed in:** 2026-08-08-l5x-sfc-import (spec §4; Task 3's `sfc_translate_test.dart` guard)
**Applies to:** any import/translate step that needs to make an unrepresentable input visibly fail
without modifying the downstream validator (`l5x_parser.dart`'s SFC poison node - a step carrying
a self-edge - routed through `translateSfcBody`'s unconditional step-to-step edge scan)
**Rule:** Rather than adding a new rejection path to a validator for every new way upstream input
can be malformed, a "poison node" can synthesize a value that trips an EXISTING, cheap rejection
path already in that validator - here, a step with a self-edge trips the same step-to-step scan
that would catch a real malformed chart, giving a whole-unit visible stub with zero validator
changes. The trade-off: this couples the poison-node producer to the validator's internal
statement order (the scan must run, and must run before any other check that might short-circuit
first) - a coupling invisible from either side's own code. Guard it with a dialect-neutral
invariant test living IN THE VALIDATOR'S OWN test file (not the producer's), asserting the
property the poison node depends on directly, plus a one-line comment at the coupled site in the
producer naming the dependency. Without both, a later refactor of the validator's statement order
can silently break the poison-node trick with no test anywhere near the change catching it.

**Knowledge base updated:**
- [../knowledge/practices/verification.md](../knowledge/practices/verification.md) §8

---

## Related

- [HOW-TO-USE.md](./HOW-TO-USE.md) - how to read this file and how to add a new entry.
- [../knowledge/governance.md](../knowledge/governance.md) - section 6, the full learning-loop
  rule this registry implements.
- [../knowledge/gaps.md](../knowledge/gaps.md) - open coverage gaps, several of which trace back
  to a CL entry above (CL-11 -> G-8, CL-12 -> G-9).
- [sessions/](./sessions/) - per-session artifacts referenced by the Sessions Index above.
