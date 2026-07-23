# Custom (User-Defined) Function Blocks — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-23

## Goal

Add **user-defined function blocks** to the soft PLC: a reusable FB with a typed
interface + a Structured Text body, instantiated with per-instance state and
usable as a block in **FBD and LD** programs. This is the capability the
graphical import translators need to map custom blocks instead of stubbing —
delivered here as a native feature; the import mapping that consumes it is
**sub-project 2** (deferred).

## North-star decisions (from brainstorming)

1. **ST-bodied FBs first.** An FB's body is Structured Text (the app's existing
   ST subset). Graphical-bodied FBs (LD/FBD body) are deferred — they need
   nested-engine execution + instance-scoped nested state.
2. **Native capability first; import mapping is sub-project 2.**
3. **Usable in both FBD and LD.** FBD is the natural multi-pin host; LD gets an
   additive pin-binding map so an arbitrary FB interface fits.

## Why this shape (grounded in the codebase)

- An FB **instance maps onto an existing precedent** — a struct-typed tag. A
  `TON` instance today *is* a `TIMER`-typed `PlcTag` whose `Map` value holds its
  state (`tag_resolver.dart` builtin composites; `readPath`/`writePath`/
  `defaultValueFor`). A custom FB instance reuses this wholesale → per-instance
  state, default construction, path I/O, tag-tree expansion, force-awareness for
  free.
- The genuinely new mechanism is **executing an FB body against an
  instance-scoped namespace** (ST today resolves every identifier against global
  tags only; there is no local-var scope).
- The block vocabularies are **closed switches** (LD `ld_exec.dart` if-chain +
  `_kSupportedBlocks`; FBD `fbd_pins.dart` + `_evalBlock`); an FB type needs a
  **registry fallback** so it is representable, wireable, and executable.

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic execution. Zero `flutter analyze`
  warnings. Run flutter from `mobile/`.
- **Additive / backward-compatible:** new `fbDefinitions` on the project, an
  additive `pinBindings` on `LdNode`; instances are ordinary tags. Existing
  projects have no FBs; every built-in block and all LD/FBD/ST/SFC behavior is
  unchanged (the registry fallback fires only for FB-name types).
- Force-aware writes; responsive (no overflow 320/360/1400); dark theme.

## §1 — FB definition & instance model

- **`FbDefinition`** on `PlcProject` (`fbDefinitions: List<FbDefinition>`):
  `{ String name; List<FbVar> vars; String stSource; }` where
  `FbVar { String name; String dataType; FbVarDir direction; dynamic initialValue; }`
  and `enum FbVarDir { input, output, internal }`. The body is ST; the typed
  interface (with direction) lives in `vars` — a plain struct can't record
  input/output/internal, which drives pins. Serialized key `fb_definitions`.
- **FB instance = a struct-typed `PlcTag`.** For each `FbDefinition` a composite
  type (name = FB name, fields = its vars) is resolvable by `lookupComposite`
  (alongside the `TIMER`/`COUNTER` builtins), so an instance is a `PlcTag` whose
  `dataType` is the FB name and whose `Map` value carries every var. Two
  instances = two struct tags = independent state, automatically.
- **A block that calls an FB** references its instance by name (FBD: `tagBinding`;
  LD: the block node's instance field). Additive serialization; existing files
  have none.

## §2 — Executing an FB body (the one new engine piece)

A shared, pure entry point
`Map<String,dynamic> executeFbInstance(PlcProject p, FbDefinition fb, String instanceName, Map<String,dynamic> inputs)`,
called by both engines when they evaluate an FB-typed block:

1. **Write inputs in:** copy the block's wired input values into the instance
   struct's input fields (`writePath` `Inst.<inputVar>`).
2. **Run the body, scoped:** execute the FB's ST source through the existing ST
   engine with a **scope context** = (the instance path + the set of the FB's var
   names). A bare identifier `x` resolves to `Inst.x` when `x` is an FB var, else
   falls through to a global tag; reads and writes both scoped. This optional
   scope on the ST executor is the only new mechanism (closes the no-local-scope
   obstacle).
3. **Read outputs out:** return the instance's output-var values → the block's
   output pins.

Properties: internal vars persist across scans (they live in the instance
struct — no runtime state map, no per-instance keying problem); deterministic
(the body is deterministic ST; the FB runs once per scan when its block is
evaluated — FBD topological, LD power-flow); reuses the ST tokenizer/parser/
evaluator + `readPath`/`writePath` + force-aware writes. The body is limited to
the app's ST subset; an FB whose ST exceeds it is handled exactly as ST programs
are today. **No nesting** (the ST subset has no FB-call syntax → an FB body can't
call another FB).

## §3 — Using an FB as a block

**FBD (natural fit):** `fbdInputPins`/`fbdOutputPins`/`_evalBlock` gain a
**fallback**: when a block's `type` is an FB name, its input pins = the FB's
input vars and output pins = its output vars; `_evalBlock` calls
`executeFbInstance` with the wired inputs and returns the outputs. The palette
lists the project's FB definitions as blocks; dropping one auto-creates a
uniquely-named instance tag and binds `tagBinding` to it.

**LD (additive pin-binding map):** `LdNode` gains an additive
`Map<String,String> pinBindings` (FB var name → source/target tag) used only by
FB-call block nodes (`blockType` = FB name, `variable` = instance name). An FB in
LD reads its inputs from the bound tags, runs `executeFbInstance`, writes outputs
to the bound tags — rendered as a data-block box. The LD block picker gains a
"Function Blocks" group; placing one creates the FB-call node + auto-instance.
Existing LD/FBD block types are untouched (the fallback only fires for FB names).

## §4 — Editing & using an FB (editor)

- **Define/edit an FB** (a project-level *type*, like a DUT): a dedicated FB
  editor — an **interface list** (add/edit vars: name, type, direction, initial)
  + the **existing ST editor** embedded for the body. Reached from a "Function
  Blocks" section near program/struct management. Creating/renaming an FB keeps
  its resolvable composite type in sync.
- **Use an FB:** it appears in the **FBD palette** (dynamic entries from the
  project's FB definitions) and the **LD block picker** ("Function Blocks" group).
  Placing one auto-creates a uniquely-named instance tag and binds the block.
  Instances are ordinary tags — visible/renamable/force-able per field in the tag
  tree.

## §5 — Backward-compat, testing, deferred

**Additive / backward-compatible:** new `fb_definitions` on the project, additive
`pinBindings` on `LdNode`, instances are ordinary tags. Existing projects have no
FBs; the FBD/LD registry fallback fires only for FB-name types, so all built-in
blocks and existing behavior are unchanged. Deterministic; force-aware; zero
analyze warnings.

**Testing:**
- *Execution (pure):* `executeFbInstance` runs the scoped ST body — inputs→
  outputs; an internal-state accumulator persists across scans; a global-tag
  reference in the body falls through correctly; a forced instance field is
  respected.
- *FBD:* an FB block's pins come from the interface; wiring + execution produce
  correct outputs in topological order; two instances stay independent.
- *LD:* an FB-call node reads/writes its pin-bound tags and executes.
- *Editor:* define an FB (interface + ST body) → it appears in the FBD palette +
  LD picker → placing creates a uniquely-named instance.
- *Serialization:* round-trip a project with FB definitions + instances; old
  files load unaffected; full existing suite stays green.

**Deferred — tracked in `docs/DEFERRED.md`:**
- **Import mapping (sub-project 2)** — PLCopen `functionBlock` POUs → FB
  definitions + instances; route custom-FB calls in the LD/FBD translators to
  instances instead of stubs. *This is the import payoff that follows this
  native capability.*
- Graphical-bodied FBs (LD/FBD body — nested execution + instance-scoped nested
  state).
- An FB body calling another FB (nesting/recursion).
- FB bodies whose ST exceeds the app's ST subset.
- IEC *functions* (stateless POUs) as a distinct POU kind.
