# Custom (User-Defined) Function Blocks

A **function block (FB)** definition is a reusable, project-level type: a
typed interface (input/output/internal vars) plus a Structured Text body.
Instantiating one creates a struct-typed tag that holds the instance's
state — so **every instance has independent state**, the same way two
`TON` timers never share a preset/elapsed.

Implementation: `mobile/lib/models/project_model.dart` (`FbDefinition`,
`FbVar`, `FbVarDir`, `PlcProject.fbDefinitions`), `mobile/lib/models/
fb_instance.dart` (`createFbInstanceTag`, `uniqueFbInstanceName`),
`mobile/lib/models/fb_exec.dart` (`executeFbInstance`, the scoped-ST runner),
`mobile/lib/models/fbd_pins.dart` (`fbdInputPinsFor`/`fbdOutputPinsFor`), and
`mobile/lib/screens/fb_editor_screen.dart` (the define/edit UI).

## Define an FB

Open the "Function Blocks" section (alongside program/struct management) to
create or edit an FB: an **interface list** — add vars with a name, data
type, direction (`input` / `output` / `internal`), and optional initial
value — plus the existing ST editor embedded for the **body**. The body is
limited to the app's ST subset (`IF`/`ELSIF`/`ELSE` + assignments,
arithmetic/comparators) — the same subset ST programs use everywhere else.

## Use it as a block

**FBD:** the project's FB definitions appear in the palette as blocks.
Dropping one auto-creates a uniquely-named instance tag (`dataType` = the FB
name) and binds it; the FB's input vars become input pins, its output vars
become output pins, wired like any other block.

**LD:** FB blocks appear in the block picker's "Function Blocks" group,
rendered as a data-block box. Since ladder blocks don't have FBD-style
multiple named pins, an FB node instead carries an additive
`LdNode.pinBindings` map (FB var name → bound tag) — the block reads its
inputs from the bound tags, runs the body, and writes its outputs back, all
gated on rung power like any other LD data block.

## Per-instance state, in one scan

Each scan, evaluating an FB block runs `executeFbInstance`: copies the wired
inputs into the instance's struct fields, executes the ST body scoped to
that instance (a bare var name resolves to `<instance>.<var>`; anything else
falls through to a global tag), then reads the output vars back out. Because
`internal`-direction vars live in the instance's own tag, they **persist
across scans** exactly like a `TON`'s elapsed time — two instances of the
same FB never see each other's state.

A shipped example lives in the "Noisy Level Measurement" default project: a
`Hysteresis` FB (`PV`/`High`/`Low` in, internal `Q`, `Out` out) drives a
High-Level Alarm with a 40–60% deadband around the noisy, filtered tank
level. Its `IF PV > High THEN Q := TRUE; ELSIF PV < Low THEN Q := FALSE;
END_IF; Out := Q;` body only writes `Q` at the edges — the deadband holds
because `Q` is read back unchanged on every scan where `PV` is between the
two thresholds. See `test/hysteresis_fb_demo_test.dart`.

## What's deferred

This is **native authoring** — defining and placing FBs by hand in-app.
Mapping an *imported* PLCopen `functionBlock` POU onto this same
`FbDefinition`/instance model is a separate, near-term follow-up (today's
LD/FBD import translators stub unsupported custom blocks). Graphical-bodied
FBs, FB-calling-FB nesting, ST bodies beyond the app's subset, and IEC
*functions* (stateless POUs) all remain out of scope — tracked in
`docs/DEFERRED.md`'s "Custom (user-defined) function blocks" section.
