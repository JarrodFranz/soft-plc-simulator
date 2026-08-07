---
id: knowledge:industry/iec61131/ladder-diagram
title: Ladder Diagram
domain: industry/iec61131
version: "2026-08"
topics: [ladder-diagram, ld, iec-61131-3, rung, power-flow, timers, counters, seal-in]
summary: Documents IEC 61131-3 Ladder Diagram's rung/power-flow model alongside this engine's exact node-and-wire executor semantics - contact/coil modifiers, which blocks are power-flow vs data blocks, the seal-in idiom's same-scan ordering dependency, and the CTD first-scan preload that LD has and FBD lacks.
related:
  - knowledge:industry/iec61131/index
  - knowledge:industry/iec61131/function-block-diagram
  - knowledge:industry/iec61131/custom-function-blocks
  - knowledge:industry/plc-formats/rockwell-l5x
learnings: [CL-1, CL-18]
---

# Ladder Diagram

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from IEC 61131-3's LD language concept and the executor,
> `mobile/lib/models/ld_exec.dart` plus its topology helper `mobile/lib/models/ld_graph.dart`.
> **Read this before:** writing or reviewing a rung, debugging a seal-in that doesn't hold,
> comparing LD and FBD counter/timer behavior, or importing/translating RLL or PLCopen `<LD>` bodies.

---

## 1. The headline rule

**A rung is a node-and-wire graph evaluated in topological column order, not a flat instruction
list - and LD's `CTD` self-preloads `CV := PV` on its first scan, while FBD's `CTD` does not
(CL-1).**

`LdRung` holds `nodes: List<LdNode>` and `wires: List<LdWire>`. `executeRung` computes a column
per node via `colAssignment` (longest path from the left rail; the right rail is forced to
`maxCol`), then evaluates nodes in ascending column order - this is what makes series and parallel
wiring both fall out of one mechanism (see §2) rather than needing separate series/parallel code
paths.

---

## 2. Power-flow semantics

Every node carries `power: Map<String,bool>` (whether power is flowing into it this scan) and a
separate `elemTrue: Map<String,bool>` (the element's own conducting state, decoupled from power,
used for the online-glow indicator independent of whether the rung is actually energized).

- `inputPower(n)` = **OR** of `power[w.fromId]` over every wire whose `toId == n.id`. This single
  rule produces both topologies: a contact with one inbound wire effectively AND-chains through
  successive series contacts (each gates on `inputPower(this) && ownCondition`); a node with
  multiple inbound wires (a parallel branch merge) ORs them.
- The left rail is always `power = true`. The right rail's power is the rung's own `inputPower` -
  whether the rung as a whole is energized this scan.

### Contact modifiers

| Modifier | Conducting condition | IEC-standard equivalent |
|---|---|---|
| `normal` (default) | `val` | XIC |
| `negated` | `!val` | XIO |
| `rising` | `val && !prev` | one-scan rising-edge contact |
| `falling` | `!val && prev` | one-scan falling-edge contact |

Edge state is keyed `'$progName|${rung.rungIndex}|${n.id}'`. **First-scan behavior**: `prev`
defaults to the *current* value when no prior state exists (`rt.prevBool[key] ?? val`), so a
rising/falling contact never spuriously fires on the very first scan it's evaluated, regardless of
the tag's current state. Contrast with FBD's `R_TRIG`/`F_TRIG` - see
[function-block-diagram.md](./function-block-diagram.md) §3.

### Coil modifiers

| Modifier | Write behavior | IEC-standard equivalent |
|---|---|---|
| `normal` | `write(target, inP)` - tracks rung power exactly | OTE |
| `set` | `if (inP) write(target, true)` - never writes `false` | OTL |
| `reset` | `if (inP) write(target, false)` - never writes `true` | OTU |
| `negated` | `write(target, !inP)` | - |
| `rising` | `write(target, inP && !prevP)` - one-scan pulse on rung-power rising edge | - |
| `falling` | `write(target, !inP && prevP)` | - |

---

## 3. Power-flow blocks vs data blocks

Confirmed by `kLdBuiltinBlockTypes` and `executeRung`'s block dispatch:

- **Power-flow blocks** (their own done/output bit drives `power[n.id]` downstream, so a
  contact/coil after them chains off it): `TON`, `TOF`, `TP`, `CTU`, `CTD`, `CTUD`.
- **Compare blocks** (`GT`/`LT`/`GE`/`LE`/`EQ`/`NE`) are **also power-flow-affecting**, not
  transparent data blocks: `power[n.id] = inP && res` - the comparison result ANDs directly into
  the rung.
- **True data blocks** (`power[n.id] = inP` unconditionally, transparent to rung flow, execute
  only `if (inP)`): math (`ADD`/`SUB`/`MUL`/`DIV`), `MOVE`.
- **Custom FB call blocks**: `power[n.id] = inP` unconditionally - an FB instance call "never
  breaks the rung," regardless of what its outputs are.

> `docs/iec61131/LADDER_LOGIC.md`'s "Supported Instructions" list names only
> XIC/XIO/OTE/OTL/OTU/parallel-branches/TON/TOF. It omits compare blocks, math/MOVE blocks, `TP`,
> `CTU`, `CTD`, `CTUD`, and custom-FB blocks entirely, even though the executor fully implements
> all of them. This is a coverage gap in that doc, not a contradiction - nothing it says is wrong,
> it's simply far short of what `ld_exec.dart` actually runs. Flag this if extending that doc.

---

## 4. First-scan preload - CL-1, the LD side

`CTD` has an explicit, engine-level first-ever-evaluation preload:

```dart
final rawCv = readPath(p, '$base.CV');
int cv = rawCv == null ? pre : (rawCv as num).toInt();
final initKey = '$key|init';
if (rt.prevBool[initKey] != true) {
  cv = pre;                    // preload CV := PV unconditionally
  rt.prevBool[initKey] = true;
}
```

A separate `initKey` flag is required (rather than relying on `rawCv == null`) because a placed
`COUNTER` tag already initializes `.CV` to `0`, not `null` - so the null-fallback alone would never
fire. **Net effect: LD's `CTD` always starts at `CV = PV` on its first scan of a run session, so
`QD` is never spuriously true before any down-counting has happened.** `TON`/`TOF`/`TP`/`CTU`/`CTUD`
have no equivalent special-cased preload - they rely on the `TIMER`/`COUNTER` struct's declared
defaults (`ACC = 0`, `CV = 0`) being adequate starting points, which they are for those blocks.

**FBD's `CTD` has no such preload** - see [function-block-diagram.md](./function-block-diagram.md)
§3 for the exact contrast (CL-1's other half).

---

## 5. The seal-in idiom

`executeLdPrograms`'s own doc comment states writes are immediately visible to later rungs - "seal-in
works." Mechanism: rungs are iterated in project list order, and each rung's writes go straight to
the live project via `_forceAwareWrite`, so a later rung's contact reading a tag an earlier rung's
coil just wrote sees the new value **this same scan**.

**This makes the classic `Start | Stop -> Motor_Run` + `Motor_Run` seal-in contact idiom same-scan
only if the coil's rung precedes the seal-in contact's rung in list order.** A seal-in contact on
the *same* rung as its own coil, positioned before the coil in column order, reads the tag's
pre-this-scan value - the contact evaluates in column order before the coil writes, so it cannot
see its own coil's write from this pass.

```
Wrong assumption: "a seal-in contact always sees the latest value regardless of rung/column position"

Correct: seal-in across two rungs (coil rung listed first, contact rung listed after) is same-scan;
a seal-in contact wired on the SAME rung as its coil, upstream of the coil in column order, is
one scan behind.
```

---

## 6. Branch topology

No explicit "series-parallel only" runtime validation exists - `colAssignment`'s cycle guard only
protects against infinite recursion on a cyclic graph, it does not reject non-series-parallel
(crossing/bridge) topologies. **Authoring is constrained to series-parallel by the editor's own
branch-building operations** (a branch spans a single tap-to-merge span with one upstream source
and one downstream destination), not by a runtime check - a hand-edited or imported rung with a
more exotic topology still executes via the generic power-flow algorithm without crashing.

---

## 7. Counter presets are literals, not tag references - CL-18

`LdNode.presetMs` is a plain `int` field (JSON key `preset_ms`), read directly by `executeRung`
(`final pre = n.presetMs;`) and used unmodified as the block's `PV`. **There is no code path that
resolves a preset through `readPath`/a tag lookup** - it is structurally an editor-set literal
baked into the rung's JSON, never a live binding.

```
Wrong: a UI slider or HMI control bound to a "preset" tag, expecting it to retune a placed
LD counter's PV live.

Correct: an LD counter's preset is fixed at edit time. To make a preset runtime-adjustable,
use FBD instead - FBD's CTU/CTD/CTUD PV is a wired input pin and CAN be bound to any tag or
expression (see function-block-diagram.md §3). This is a genuine LD/FBD asymmetry, not a bug
in either.
```

---

## What this means practically

### "Why is `QD` already `true` before I've counted anything down?"
Not an LD symptom - LD's `CTD` self-preloads `CV := PV` on its first scan (§4). If you're seeing
this, check whether the block is actually FBD's `CTD`, which has no such preload (CL-1).

### "My seal-in contact drops out one scan after the Start pulse ends - why?"
Check rung order: the seal-in contact's rung must come *after* the coil's rung in the program's
rung list for same-scan latching (§5). If both are on one rung with the contact upstream of the
coil in column order, the seal-in is a scan behind by construction.

### "Can I make a counter's preset tag-adjustable from an HMI?"
Not with a native LD counter block - its preset is a literal (CL-18). Use FBD's `CTU`/`CTD`/`CTUD`,
whose `PV` pin accepts any wired tag or expression.

### "Why did my comparison block seem to gate the rung, when I only expected data flow?"
Compare blocks (`GT`/`LT`/…) are power-flow-affecting in this engine, not transparent - their
result ANDs into the rung's power (§3), unlike math/MOVE blocks which pass power straight through.

---

## Related

- [function-block-diagram.md](./function-block-diagram.md) - the FBD-side contrast for CL-1 (no CTD preload) and for tag-bindable presets.
- [custom-function-blocks.md](./custom-function-blocks.md) - `pinBindings` on an `LdKind.block` node and the `LdScope` rewrite rule for FB calls placed on a rung.
- [../plc-formats/rockwell-l5x.md](../plc-formats/rockwell-l5x.md) - Rockwell RLL neutral-text ladder maps onto this same executor after import.
- [index.md](./index.md) - domain hub.
