---
id: knowledge:industry/iec61131/function-block-diagram
title: Function Block Diagram
domain: industry/iec61131
version: "2026-08"
topics: [function-block-diagram, fbd, iec-61131-3, networks, dataflow, pid, timers, counters]
summary: Documents IEC 61131-3 FBD's network/dataflow model alongside this engine's exact executor semantics - ascending-index same-scan network chaining, per-block pin resolution, the CTD-has-no-preload gotcha that contrasts with ladder, the PID anti-windup algorithm, and undocumented cycle-handling behavior.
related:
  - knowledge:industry/iec61131/index
  - knowledge:industry/iec61131/ladder-diagram
  - knowledge:industry/iec61131/custom-function-blocks
  - knowledge:industry/plc-formats/plcopen-tc6-xml
learnings: [CL-1, CL-2]
---

# Function Block Diagram

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from IEC 61131-3's FBD language concept and the executor,
> `mobile/lib/models/fbd_exec.dart` plus the pin registry `mobile/lib/models/fbd_pins.dart`.
> **Read this before:** writing or reviewing an FBD network, wiring a counter/timer/PID block,
> debugging same-scan chaining between networks, or importing/translating a PLCopen `<FBD>` body.

---

## 1. The headline rule

**FBD networks execute in strict ascending network-index order within one scan, and writes from an
earlier network are visible to reads in a later network in that same pass (CL-2) - but a `CTD`
block starts its count value at zero with no preload, unlike ladder's `CTD` (CL-1).**

`executeFbdPrograms` partitions `prog.fbdBlocks` by `network` (default `0`), sorts the distinct
indices ascending, and evaluates each network's topological worklist before moving to the next.
`TAG_OUTPUT` writes call `_forceAwareWrite` immediately, inside the same `executeFbdPrograms` call
that later evaluates a subsequent network's `TAG_INPUT` via `readPath` - so a two-network handoff
(network 0 computes a value and writes it to a tag, network 1 reads that tag) resolves with zero
scan lag, not a one-scan delay.

---

## 2. Pin model

`TAG_INPUT`, `TAG_OUTPUT`, and `CONST` are minimal pseudo-blocks: `TAG_INPUT` has only an `OUT`
pin (no inputs), `CONST` likewise only `OUT` (its `tagBinding` holds the literal text, not a
path), `TAG_OUTPUT` has only an `IN` pin (no outputs). A custom FB block's pins resolve to its own
declared var names first (falling back to the built-in registry keyed by block type); a wire with
an empty `fromPin`/`toPin` (legacy pre-pin-addressing JSON) falls back to the block's first
output/input pin.

**Custom FBs can silently shadow built-in block type names.** `_evalBlock` checks
`fbDefinitionFor(p, b.type)` *before* the built-in `switch` - a project-defined FB named, say,
`AND` would shadow the built-in `AND` block project-wide, with no error. This is documented
directly in `fbd_pins.dart`'s own comment on `kFbdBuiltinBlockTypes`.

---

## 3. Timer/counter/edge blocks - exact state-preload behavior

Every stateful FBD block keys its state off `b.id` into `FbdRuntime`'s maps, all of which start
**empty** and default via `?? initialValue` on first read - there is no equivalent of ladder's
special-cased first-scan preload branch anywhere in FBD. This is the **program** case; an
FBD-bodied custom FB's body keys the same maps off `'fb:<instancePath>|<blockId>'` instead (see
[custom-function-blocks.md](./custom-function-blocks.md) §4), so two instances of the same
FBD-bodied FB never share timer/counter/edge state even though they share one set of body block
ids.

| Block | Start state | Preload? |
|---|---|---|
| `CTU` | `cv = 0` | Not needed - up-counting from 0 is correct by construction |
| `CTD` | `cv = 0` (**not** `pv`) | **None** - `Q` (`cv <= 0`) is `true` from scan 1 until an explicit `LD` pin pulse runs `cv = pv` |
| `CTUD` | `cv = 0`, clamped `>= 0` | None - down path before any `LD` just clamps at 0, `PV` is never preloaded |
| `TON`/`TOF` | `et = 0` | Not needed |
| `TP` | `et = 0`, `running = false` | Not needed |
| `R_TRIG` | `prev = false` (default) | N/A - see edge gotcha below |
| `F_TRIG` | `prev = false` (default) | N/A |

**CL-1, the FBD side, confirmed exactly**: FBD's `CTD` needs an explicit `LD` (load) pulse wired
to its `LD` input pin to establish a nonzero starting `CV`; without one, `Q` is spuriously `true`
immediately on scan 1. Ladder's `CTD` self-preloads with no such requirement (see
[ladder-diagram.md](./ladder-diagram.md) §4).

```
Wrong: porting an LD program that relies on CTD's self-preload into FBD and expecting the same
Q behavior with no LD pulse wired.

Correct: an FBD CTD needs an explicit load pulse (e.g. from an R_TRIG on a start condition)
before its Q output can be trusted at 0.
```

**Edge-detection first-scan gotcha (worth its own Wrong/Correct):** `R_TRIG`/`F_TRIG` default
their previous-clock state to `false` unconditionally - the *opposite* convention from LD's edge
contacts, which default their previous state to the *current* tag value specifically to suppress
a first-scan edge.

```
Wrong assumption: "edge detection behaves the same in LD and FBD on the very first scan."

Correct: an LD rising-edge contact bound to a tag that's already true at run-start does NOT
fire on scan 1 (prev seeded from the current value). An FBD R_TRIG fed a CLK that's already
true at run-start DOES fire on scan 1 (prev seeded false unconditionally).
```

---

## 4. PID block

Pin order: `SP, PV, KP, KI, KD` -> output `CV` only. `e = SP - PV`; derivative uses
`dt = dtMs / 1000.0` (derivative forced to `0` if `dt <= 0`, guarding a div-by-zero). Anti-windup
is **conditional, not clamped-integral**: a candidate integral term is computed
(`integral + e*dt`), a candidate output `raw = kp*e + ki*candidateInteg + kd*deriv` is computed; if
`raw` falls within `[0, 100]`, the candidate integral is committed; otherwise the integral is
**frozen** at its previous value and `raw` is recomputed without the candidate term. The final
`CV` is clamped to `[0, 100]`. **The 0-100 output range is hardcoded** - there is no `MIN`/`MAX`
input pin to reconfigure it. State persists per `b.id` across scans (per `'fb:<instancePath>|<blockId>'` instead, for a PID inside an FBD-bodied custom FB - see §3).

---

## 5. SEL and LIMIT

- `LIMIT` - pins `MN, IN, MX`; requires all three to be numeric, else outputs `null`; clamps `IN`
  between `MN` and `MX`.
- `SEL` - pins `G, IN0, IN1`; returns `IN1` when `G` is truthy, `IN0` otherwise (standard IEC
  `SEL` semantics: 0-input selected when `G = FALSE`, 1-input when `G = TRUE`).

---

## 6. Custom-FB call blocks

Input pins bind **positionally**: `inputs[i]` pairs with the FB's `i`-th declared `input`-direction
var, in declaration order (contrast with ladder's named `pinBindings` map - see
[custom-function-blocks.md](./custom-function-blocks.md)). An unwired input pin (`null`) is
**skipped**, not zero-written - the instance keeps its prior or initial value rather than being
clobbered.

---

## 7. Cycle handling - now documented in `docs/fbd-networks.md`

If a network's dataflow graph has a cycle, the topological worklist stabilizes with some blocks
never marked `done`; those remaining blocks are then evaluated **exactly once anyway**, reading
whatever upstream values happen to be cached (an unresolved cyclic peer's output reads as `null`
via `resolveInput`, since it hasn't been evaluated yet this pass). This guarantees the scan
terminates but produces **one stale/undefined pass through the cycle per scan tick**, not an error
and not a "solved" cyclic network. **Corrected 2026-08-07:** this is now documented in
`docs/fbd-networks.md`'s "Dataflow cycles: one stale pass per scan" subsection.

---

## What this means practically

### "Why is my FBD `CTD`'s `Q` output already true before I've counted anything?"
It has no self-preload (CL-1) - wire an `LD` (load) pulse to establish `CV := PV` before relying
on `Q`. See §3.

### "Why did my `R_TRIG` fire on the very first scan when I didn't expect an edge yet?"
`R_TRIG`/`F_TRIG` seed their previous-clock state to `false`, not to the current input - a CLK
that's already `true` at run-start reads as a rising edge on scan 1. See §3.

### "Can I make a counter's preset (`PV`) adjustable from a tag at runtime?"
Yes, in FBD - `PV` is a wired input pin, unlike ladder's literal-only preset (CL-18, see
[ladder-diagram.md](./ladder-diagram.md) §7).

### "My two-network FBD program isn't chaining the way I expect - is there a scan delay?"
No - same-scan chaining is guaranteed as long as the producing network's index is lower than the
consuming network's (CL-2, §1). Check network index assignment if a handoff seems delayed.

### "I renamed a custom FB to match a built-in block type name by accident, and it started behaving strangely."
Custom FBs silently shadow built-in blocks with the same type name - no error is raised (§2).
Rename the FB.

---

## Related

- [ladder-diagram.md](./ladder-diagram.md) - the CL-1 contrast (CTD preload) and the literal-vs-tag-bindable preset asymmetry.
- [custom-function-blocks.md](./custom-function-blocks.md) - positional pin binding for custom-FB call blocks and per-instance state isolation.
- [structured-text.md](./structured-text.md) - why FB calls live here (and in LD) rather than in ST.
- [../plc-formats/plcopen-tc6-xml.md](../plc-formats/plcopen-tc6-xml.md) - PLCopen `<FBD>` bodies translate into this exact block/wire/network model.
- [index.md](./index.md) - domain hub.
