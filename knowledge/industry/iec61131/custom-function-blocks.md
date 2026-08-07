---
id: knowledge:industry/iec61131/custom-function-blocks
title: Custom Function Blocks
domain: industry/iec61131
version: "2026-08"
topics: [function-blocks, fb, iec-61131-3, instance-scoping, nesting, ld-scope, aoi]
summary: Documents IEC 61131-3 custom function blocks alongside this engine's exact instance-execution model - the ST-bodied/ladder-bodied body discriminator, the shared LdScope/StScope root-segment rewrite rule, the max-call-depth guard (_kMaxFbCallDepth = 16), and the Rockwell EnableIn re-assertion mechanism.
related:
  - knowledge:industry/iec61131/index
  - knowledge:industry/iec61131/ladder-diagram
  - knowledge:industry/iec61131/function-block-diagram
  - knowledge:industry/iec61131/structured-text
  - knowledge:industry/plc-formats/rockwell-l5x
---

# Custom Function Blocks

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from IEC 61131-3's function-block concept and the executor,
> `mobile/lib/models/fb_exec.dart` (execution/scoping), with the scoping rule shared verbatim by
> `mobile/lib/models/ld_exec.dart`'s `LdScope` and `mobile/lib/models/st_exec.dart`'s `StScope`.
> **Read this before:** authoring a custom FB, debugging cross-instance state bleed, wiring a
> nested FB-in-FB call, or importing a Rockwell AOI.

---

## 1. The headline rule

**A custom FB body is ST-bodied or ladder-bodied (never FBD-bodied), each instance's state lives
in its own struct-typed tag, and calls nest up to a hard guard of 16 deep
(`_kMaxFbCallDepth = 16` in `mobile/lib/models/fb_exec.dart`) before silently no-opping.**

`FbDefinition` holds `name`, `vars: List<FbVar>` (each with `name`, `dataType`,
`direction ∈ {input, output, internal}`, optional `initialValue`), `stSource: String`, and
`ladderRungs: List<LdRung>`. The body discriminator is `ladderRungs.isNotEmpty` - non-empty means
ladder-bodied (`stSource` is ignored entirely); empty means ST-bodied (the default/legacy shape).
**There is no FBD-bodied custom FB in this engine** - FBD *calls* FBs (as a block on the canvas),
it does not host FB bodies.

---

## 2. Instance state model

Instantiating an FB creates a struct-typed tag (`dataType = fb.name`), resolved via the same
composite-lookup path as `TIMER`/`COUNTER`/`SYSTEM`, which synthesizes a struct definition on the
fly from the FB's var list when no matching project struct exists. Every field - including
`internal`-direction vars - persists per instance tag exactly like any other struct tag. Two
instances of the same FB never see each other's state; this holds for `internal` vars too, not
just `input`/`output`.

---

## 3. `executeFbInstance` - the per-call execution mechanism

Per call, in order:

1. **Guard**: an empty `instanceName` is refused outright (`return const {}`) rather than risk
   binding to unrelated globals.
2. **Nesting-depth guard**: a module-level counter increments before the call and decrements in a
   `finally` block, so depth unwinds correctly even though nothing throws. The exact constant:
   `const int _kMaxFbCallDepth = 16;` in `mobile/lib/models/fb_exec.dart`. Beyond depth 16, a
   nested call is a silent no-op - an empty output map, not an error.
3. Every `input`-direction var present in the caller's inputs map is written to
   `'<instanceName>.<varName>'`.
4. **Body dispatch** (the three-way precedence, ladder wins over ST since FBD-bodied FBs don't
   exist): `ladderRungs.isNotEmpty` -> `runScopedLdBody(...)`; else -> `runScopedStBody(...)`.
   **Ephemeral-runtime fallback**: if the caller omits a real `LdExecRuntime`, a brand-new
   throwaway one is constructed for that call - documented as unreachable from the real scan
   (both real engine call sites always thread the actual scan runtime through), but any hand-rolled
   caller that skips this argument silently gets non-persistent edge/pulse state for that call
   (never an error).
5. **Rockwell `EnableIn` re-assertion** (ladder-bodied FBs only): if the FB has an
   `internal`-direction `BOOL` var literally named `EnableIn`, it is force-written `true`
   immediately before the rungs run. This is data-driven off the var's name/direction/type, not a
   definition-level flag, so it applies uniformly to hand-authored and imported FBs alike - it
   exists so a body containing an unlatch of `EnableIn` (e.g. imported Rockwell AOI logic) doesn't
   permanently self-disable the instance on the next call. See
   [../plc-formats/rockwell-l5x.md](../plc-formats/rockwell-l5x.md).
6. Every `output`-direction var is read back out of the instance tag into the returned map.

---

## 4. Pin binding / scoping - the `LdScope`/`StScope` rewrite rule

Both scopes implement the **identical** algorithm, independently per language:

```
rewrite(path):
  root = path.split('.').first.split('[').first
  if root in localVars:
    return '<instancePath>.<path>'
  else:
    return path   # untouched - falls through to the global tag namespace
```

`localVars` is the FB's own declared var name set. Nested FB-in-FB calls compose naturally: an
outer instance's `rewrite()` is applied to a pin binding *before* the inner `executeFbInstance`
call, and the inner instance's own name is passed through the outer `rewrite()` too (e.g.
`'Inner'` -> `'A1.Inner'`), so a nested instance's state and any edge/pulse keys nest correctly
under the outer instance's path.

**LD pin binding**: `LdNode.pinBindings: Map<String,String>` - FB var name to bound
tag-path-or-literal string, since ladder nodes don't carry FBD-style multiple named pins.

**FBD pin binding**: positional, not named - see
[function-block-diagram.md](./function-block-diagram.md) §6.

**Edge/pulse state isolation**: a ladder-bodied FB's rungs run under a synthetic program key
`'fb:<instancePath>'`. Since sanitized identifiers can never contain `:`, this key is structurally
disjoint from every real program's own rung-state keys - two instances of the same ladder-bodied
FB never share rising/falling-contact or pulse-coil edge memory.

---

## 5. Name validation

Not enforced at the execution layer read here - FB var name / instance uniqueness validation lives
in the project model and FB editor UI, outside `fb_exec.dart`/`ld_exec.dart`/`st_exec.dart`. At the
execution layer itself, there is **no runtime collision guard beyond the root-segment
`localVars.contains()` test** in §4 - if an FB's own var name happened to equal a global tag's
name, every reference to that name inside the FB body resolves to the instance member (shadowing
the global), silently, with no warning.

---

## What this means practically

### "Can I define a custom FB with an FBD body?"
No - only ST-bodied and ladder-bodied FBs exist. FBD can *call* an FB (as a block), but cannot
*host* one (§1).

### "My deeply nested FB call chain stopped producing output partway through - why?"
Check nesting depth against the hard guard of 16 (`_kMaxFbCallDepth`). Beyond that, a call
silently returns an empty map rather than erroring (§1, §3).

### "Two instances of my ladder-bodied FB seem to share timer/edge state - is that expected?"
It should not happen - instance state and edge/pulse memory are both isolated per instance path
(§2, §4). If you're seeing bleed, check whether the instance name/path being passed to
`executeFbInstance` is actually distinct between the two call sites.

### "Why does my imported Rockwell AOI's `OTU(EnableIn)` not permanently disable the instance?"
`EnableIn` is re-asserted `true` immediately before every call's rungs run, specifically so an
unlatch inside the body doesn't self-disable the instance across calls (§3 step 5).

---

## Related

- [ladder-diagram.md](./ladder-diagram.md) - `pinBindings` on an `LdKind.block` node and the seal-in/power-flow semantics an FB call block participates in.
- [function-block-diagram.md](./function-block-diagram.md) - positional pin binding for FBD-side FB call blocks.
- [structured-text.md](./structured-text.md) - why FB calls cannot appear inside an ST body itself.
- [../plc-formats/rockwell-l5x.md](../plc-formats/rockwell-l5x.md) - AOI-to-FbDefinition mapping and the RLL-Logic AOI execution path that motivated the `EnableIn` re-assertion.
- [index.md](./index.md) - domain hub.
