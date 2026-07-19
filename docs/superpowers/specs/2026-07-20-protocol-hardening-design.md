# Protocol Hardening — Design Spec

**Date:** 2026-07-20
**Status:** Approved (design)

## Goal

Fix two classes of defect that two audits found in **already-shipped** protocol
hosts. These are not new features; they are correctness fixes in code the
codebase describes as machine-verified.

## Why now

Both classes share one root cause: **a rule computed once — at config time or at
handshake time — is never re-checked at the moment it is used.** Auto-generation
computes tag writability once and the write path trusts it forever; the
handshake negotiates a maximum response size and the send path ignores it.

The user chose to do this **before** the remaining protocol workstreams (FINS,
SLMP, BACnet), because three shipped protocols have real silent failures now,
and because the remaining protocols should have a correct budgeting pattern to
copy rather than three more chances to repeat the bug.

## Two themes

### Theme A — external-write gating (all six protocols)

Every write path derives "is this tag writable?" from the mutable per-protocol
**map entry** alone (`access` / `writable` / `pointType`), and never re-checks
the underlying `PlcTag` at write time. Auto-generation is the *only* place the
tag's own `ioType == 'SimulatedOutput'`, `access == 'ReadOnly'`, or the reserved
`System` name is ever consulted — and its output is then freely hand-editable
through the map editor (every "Add entry" defaults to writable; every access
dropdown is unconditional; the tag picker offers `System.*` and
`SimulatedOutput` tags unfiltered).

**Severity, reasoned rather than assumed:** a `System` write is transient —
`updateSystemStatus` overwrites those fields every scan, so it is a ~100 ms
glitch, not corruption. But a `SimulatedOutput` tag with **no sim rule driving
it** is never touched again by the engine, so an external write **persists
indefinitely**, silently substituting an injected value for a simulation-computed
output. That is the real integrity problem.

**One inconsistency the audit found:** only CIP checks the `System` tag *by
name* in auto-generation (`cip_map.dart`); the other five rely on
`ensureSystemTag` happening to set `access: 'ReadOnly'` — one migration or field
mutation from silently exposing it.

### Theme B — response-size overruns (three of four audited)

Three shipped protocols emit responses larger than the size they negotiated with
the client, on exactly the large-block-read pattern they exist to serve. A
strict client drops the over-long frame, so the operation **silently fails**.
All three had **zero** test coverage of the bound — the E2E probes all use tiny
datasets (the DNP3 probe uses 9 points, ~3% of the limit), so none ever
approached it. Modbus was audited and is **correct by construction** (per-FC
quantity caps enforced at admission; no multi-item function code); it needs no
change.

## Decisions taken (user-approved)

1. **`SimulatedOutput` stays user-configurable.** Hard-block only the reserved
   `System` tag at write time. `SimulatedOutput` keeps its `ReadOnly` default
   from auto-generation but a deliberate per-entry `ReadWrite` choice still
   works — preserving the legitimate case of driving a simulated field device
   from a SCADA test harness. The bug to fix is the *accidental* path, not the
   deliberate one.
2. **Modbus forced-tag writes refuse visibly.** Return a Modbus exception
   instead of the current success echo, matching the other five protocols and
   the project's own force-aware rule. (A spawned task already exists for this;
   it is folded into this workstream.)
3. **DNP3 gets real multi-fragment**, not fail-visibly. A bounded fragment plus
   genuine application-layer multi-fragment with a CONFIRM-gated resume cursor.
   A large-database Class 0 read is DNP3's *designed* normal operation; failing
   it would break routine polling. Multi-fragment is the protocol's own answer.
4. **OPC UA fails loudly now, chunks later.** Store the negotiated send-buffer
   size on the session and return `Bad_ResponseTooLarge` rather than emitting an
   oversized frame. Real `F`/`C` chunking is deferred to its own scoped piece.
5. **One workstream**, ~6 tasks, subagent-driven, with a whole-branch review.

## Non-goals / YAGNI

- **No OPC UA send-path chunking.** Deferred (decision 4). Fail-visibly is the
  v1 backstop.
- **No fix to the OPC UA inbound-memory exposure.** The host bounds inbound
  frames at 16 MB against a growable buffer with unbounded connections — an OOM
  vector on mobile, flagged by the audit — but that is a *memory* concern, not a
  *framing* one, and wants its own treatment. Out of scope here.
- **No Modbus response-budget change.** Audited correct.
- **No new protocols.** FINS/SLMP/BACnet remain their own workstreams.

## Global Constraints

- **ADR-010**: pure Dart, in-process, no companion process, no FFI.
- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/protocols/` and
  `mobile/lib/models/`; `dart:io` confined to `services/*_host.dart`.
- Codecs must **never throw** on malformed/hostile input.
- Deterministic: no wall clock, no randomness in codec logic.
- **Additive/backward-compatible.** No existing serialized form changes;
  default-projects round-trip and scan-equivalence stay green.
- **No protocol behaviour may change except where a decision above explicitly
  requires it** (Modbus force-refuse is a deliberate wire change; the size
  bounds change *over-limit* behaviour only — under-limit responses stay
  byte-identical).
- **Every fix ships with a test at its tipping point.** The audit's core finding
  is that all four bounds had zero coverage; a fix without a boundary test
  repeats the original mistake.
- **The four third-party E2Es must still pass** (`python-snap7`, `pycomm3`,
  `tokio-modbus`, a real Ignition OPC UA session) — the authority on wire
  behaviour for the protocols they exercise.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No competitor-tooling branding; no reverse-engineering wording.

## Component 1 — Shared write gate (`mobile/lib/models/tag_write_gate.dart`)

New pure file. One predicate, one rule, six auto-generation call sites and seven
write-time call sites collapse onto it:

```dart
/// Whether an EXTERNAL protocol client may write [leafPath] in [project].
/// The reserved System tag is never externally writable; otherwise the tag's
/// own access governs. Note SimulatedOutput is deliberately NOT hard-blocked
/// here — auto-generation defaults it to ReadOnly, but a user may still choose
/// ReadWrite per map entry (e.g. a SCADA test harness driving a simulated
/// field device).
bool isExternallyWritable(PlcProject project, String leafPath);
```

Rule: resolve the root via `rootTagOf`; `null` → false; `root.name ==
kSystemTagName` → false; else `root.access != 'ReadOnly'`. (`SimulatedOutput` is
intentionally not consulted here — that keeps decision 1's override alive.)

- **Auto-generation** (`cip_map.dart`, `opcua_map.dart`, `modbus_map.dart`,
  `dnp3_map.dart`, `mqtt_map.dart`, `s7_map.dart`): the read-only *default* still
  marks `SimulatedOutput` / `System` / `access==ReadOnly` as read-only — that is
  the sensible default and must not change. The System-by-name inconsistency
  (only CIP has it today) is fixed by routing all six through a shared helper.
- **Write-time gates** (`cip_tags.dart`, `s7_area_image.dart`,
  `opcua_services.dart`, `modbus_pdu.dart` write FCs, `mqtt_publisher.dart`, and
  DNP3's `_evaluateCrob`/`_evaluateAnalogOut` even though it has no `access`
  field): each additionally refuses when `!isExternallyWritable(project,
  entry.tag)`, **independent of** the map entry — so a hand-edited entry can no
  longer re-open a reserved `System` tag. The existing per-entry `access`/forced
  checks stay; this is an added backstop, not a replacement.

The single hard rule is: **`System` is never externally writable, whatever the
map says.** Everything else remains as the map configures it.

## Component 2 — Modbus visible force-refusal

`modbus_pdu.dart` currently *skips* a write to a forced tag but still returns a
SUCCESS echo, so the master believes it took. Change the write path to return a
Modbus exception, and surface the refusal as a **structured outcome** the host
can log (the logging workstream could not log it precisely because it was
invisible in the PDU). The pure file stays pure — the host inspects the return
value. This is a deliberate wire-behaviour change; document it in
`docs/protocols/modbus.md` and re-run the real `tokio-modbus` E2E.

## Component 3 — DNP3 fragment bound + multi-fragment

- A `const int kDnpMaxAppFragment = 2048` (the `dnp3` reference crate's minimum
  *and* default `rx_buffer_size`, which a master cannot raise).
- Charge each object's header **at admission**, and reserve room for the
  mandatory headers of remaining objects — the S7-fix shape.
- **Genuine application-layer multi-fragment**: when a response exceeds the
  fragment, emit it across fragments with correct FIR/FIN bits and a **resume
  cursor gated on the master's CONFIRM**. The transport/link segmentation layer
  is already correct (`dnp3_host.dart`'s `_buildResponseFrames`); this is the
  *application* layer above it, which currently hard-codes `fir: true, fin:
  true` at all 11 call sites.
- Regression test: a Class 0 read of **≥408 analog points** produces fragments
  each ≤ 2048, reassembling to the full dataset.

## Component 4 — OPC UA: store the negotiated size, fail loudly

- Persist the negotiated **send** buffer size on the session (today
  `negotiate(...)` results are function-local in `opcua_session.dart` and
  discarded).
- Before emitting a response, if the built message exceeds that size, return
  **`Bad_ResponseTooLarge`** instead. A large Browse then fails *visibly and
  diagnosably* (and, post-logging, is logged) rather than silently.
- Regression test: a Browse against **~1,400 root tags** returns
  `Bad_ResponseTooLarge`, not an oversized frame. A normal Browse under the
  limit is unchanged.

## Component 5 — EtherNet/IP: parse and honour the connection size

- Parse the Forward Open **connection parameters** the connection manager
  currently skips, and store the connection size on `CipConnection`.
- Thread it into the **Multiple Service Packet** as a response budget: charge
  each embedded response's header at admission, reserve `remainingItems × 4` for
  the mandatory error items — the S7-fix shape.
- Tighten the existing u16 guard from `cursor > 0xFFFF` to `cursor > 0xFFFF - 6`
  (the emitted CIP response is `cursor + 6` bytes; the current guard lets a
  self-inconsistent inner frame through, which the earlier `buildEnipFrame`
  truncation fix does *not* cover).
- Regression test: a client negotiating a 500-byte connection and filling it
  with Read Tag requests receives a reply **≤ 500 bytes**, not the ~792 the
  audit measured.

## Data flow (unchanged except at the limits)

Under every limit, responses are byte-identical to today. The fixes change only
what happens *at or over* the limit: a refused write returns a visible status;
an over-large response is bounded, fragmented (DNP3), or refused (OPC UA); an
over-budget MSP item is refused per-item (EtherNet/IP).

## Testing

- Each component ships a **boundary test at the audit's measured tipping point**
  (408 analog points; ~1,400 nodes; a 500-byte connection filled with reads;
  a forced-tag write; a hand-edited map entry re-opening `System`).
- The write-gate needs the **non-over-broad** counter-test too: a deliberately
  `ReadWrite` `SimulatedOutput` entry still succeeds (decision 1), and a
  non-forced composite member write still succeeds.
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`,
  and all four `tool/*_e2e.sh`.

## Risks

- **The write-gate touches six shipped protocols and their tests.** ~27 test
  files reference `SimulatedOutput`/`kSystemTagName`/`autoPopulate`; some
  deliberately construct a `ReadWrite` entry against a `SimulatedOutput`/`System`
  tag to prove auto-generation's default. Those must be re-examined once the
  write path stops trusting the entry alone.
- **DNP3 multi-fragment is the largest single piece** — a resume cursor and
  CONFIRM gating is real protocol state, not a bound check. It is the one
  component whose scope could grow; if it does, it can be split from the rest.
- **Behaviour-change surface.** Modbus force-refuse and the three size bounds
  are deliberate wire changes at the limits. The E2Es are the arbiter; a
  boundary test that a real client rejects is a finding, not a nuisance.

## Decomposition (plan-time)

**~6 tasks:** (1) shared `tag_write_gate` + the six auto-generation call sites;
(2) the seven write-time gates + the write-gate boundary/counter tests;
(3) Modbus visible force-refusal + structured outcome + E2E; (4) DNP3 fragment
bound + multi-fragment + resume cursor + boundary test; (5) OPC UA negotiated-size
storage + `Bad_ResponseTooLarge` + boundary test; (6) EtherNet/IP connection-size
parse + MSP budget + u16 tighten + boundary test, then the full gate + docs +
whole-branch review. (Tasks 4-6 are independent per protocol and may reorder.)
