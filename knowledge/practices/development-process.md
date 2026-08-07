---
id: knowledge:practices/development-process
title: Development Process
domain: practices
version: "2026-08"
topics: [spec, plan, code-review, two-tier-review, deferred-work, refactor-safety, snapshot-testing, whole-branch-review]
summary: The spec -> plan -> per-task implement/review -> whole-branch review -> fix wave -> browser verify -> PR pipeline used for every workstream on this project, why the two review tiers catch different classes of defect, the docs/DEFERRED.md convention for recording conscious scope cuts, and the byte-identical snapshot technique for proving a refactor moved data without changing it.
related:
  - knowledge:practices/index
  - knowledge:practices/verification
learnings: []
---

# Development Process

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** `docs/DEFERRED.md` (whole-branch-review follow-up entries across many
> workstreams), `mobile/test/defaults/all_water_test.dart`, `docs/default-projects.md`,
> `docs/superpowers/specs/` and `docs/superpowers/plans/` (process artifacts for every
> shipped workstream on this repo).
> **Read this before:** starting a new spec/plan workstream, deciding whether something is
> in scope for the current change, or proving a refactor didn't change behavior.

---

## 1. The headline rule

**Every non-trivial workstream on this project follows the same pipeline: spec -> plan ->
per-task implement + review -> whole-branch review -> fix wave -> browser verify -> PR - and
skipping either review tier lets a different class of defect through.**

The pipeline exists because the two review tiers are not redundant with each other. A
per-task review, done immediately after that task's implementation, has the task's own
spec section fresh in view and catches drift from what was specified - a task quietly
under- or over-implementing its own contract. A whole-branch review, done only after every
task in the plan is implemented, has something a task review structurally cannot have: the
full diff across all tasks simultaneously. It catches the seams between tasks - duplicated
logic that should have been shared, an invariant one task assumed that a later task quietly
broke, a helper written twice with silently diverging behavior.

---

## 2. The pipeline

1. **Spec** (`docs/superpowers/specs/<date>-<slug>-design.md`) - the design: what's being
   built, why, and its shape. Process artifact, not behavioral authority - once the code
   ships, the code is the source of truth and the spec is cited only as design rationale.
2. **Plan** (`docs/superpowers/plans/<date>-<slug>.md`) - the spec broken into ordered,
   independently reviewable tasks.
3. **Per-task implement + review** - each task is implemented, then reviewed against its own
   section of the spec/plan before the next task starts. This catches verbatim drift: did
   the task actually implement what its own section says, not more, not less, not
   subtly different.
4. **Whole-branch review** - after every task lands, the entire branch's diff is reviewed as
   one unit, independent of the per-task boundaries. This is where cross-task seams surface -
   see §2.1.
5. **Fix wave** - whole-branch review findings get triaged: blocking issues are fixed in the
   same branch before it ships; non-blocking findings are recorded (either fixed anyway as
   quick wins, or filed to `docs/DEFERRED.md` - see §3).
6. **Browser verify** - for anything UI-facing, the headless Playwright loop (see
   [verification.md](./verification.md) §2) runs and must pass clean before the branch is
   considered done. For anything protocol-facing, the relevant `tool/*_e2e.sh` lane (see
   [verification.md](./verification.md) §5) must pass.
7. **PR** - opened only once steps 1-6 are complete for the workstream.

### 2.1 What each tier actually catches, from real findings

These are drawn from `docs/DEFERRED.md`'s "review" follow-up rows, which cite which tier
found them - the pattern is consistent across many different workstreams on this repo:

**Task reviews catch spec/contract drift within one task's boundary.** Example: a
function-block import task was reviewed against its own spec section and found to only
implement FB-call translation for a bare FB block wired directly off a rail - a call preceded
by a series contact on the same rung was unproven, a narrower contract than the task
believed it had delivered. That's a task review finding: it compares one task's output
against that task's own spec paragraph.

**Whole-branch reviews catch cross-task seams that no single task's spec section could
reveal**, because the seam only exists once multiple tasks' code coexists:
- A whole-branch review on an FBD-import workstream found that the editor's
  `_resolvedWireFromPin` had been hand-written to mirror the execution engine's private
  `_resolvedFromPin` helper - two independently-maintained copies of the same resolution
  logic, each written by a different task, silently able to drift apart. The fix isn't
  visible from either task's own spec section; it only shows up when both tasks' code is
  read side by side.
- A different whole-branch review, on the same import program, found that the LD translator
  folded an FB's boolean output into a coil only when it fed an `<outVariable>` element - a
  case one task's logic didn't handle that a later task's test corpus happened not to
  exercise, leaving a real double-write hazard (rung power AND a `pinBindings` write racing
  for the same coil) that no single task's own review would have had cause to look for.
- A whole-branch review on the FBD editor overhaul flagged that the desktop palette dock and
  the phone add-block FAB both add new blocks into network 0 unconditionally, with no "active
  lane" cue - a UX inconsistency that only becomes visible once the palette-dock task and the
  per-lane-network task are both in the diff together.

The shared shape: task reviews answer "did this task do what it said it would do";
whole-branch reviews answer "now that every task's code exists together, does the *system*
still hold together" - two different questions, and a defect that only the second question
can surface is invisible to any number of task reviews, however careful.

---

## 3. The deferred-work registry (`docs/DEFERRED.md`)

**`docs/DEFERRED.md` is the single canonical list of work that was consciously scoped out -
deferred on purpose, not forgotten and not a latent bug - and every spec/plan that defers
something records it there instead of only in prose.**

Mechanics, per the file's own header:
- Every deferral gets a row: item, priority (`near-term` = the intended next expansion,
  `later` = someday/maybe), and a note with enough context to act on it later (which file,
  which behavior, why it was safe to skip).
- A spec or plan's own "Deferred / out of scope" section links back to this file
  ("Deferred items are tracked in `docs/DEFERRED.md`") rather than re-listing items in prose,
  so there is exactly one place a reader checks for "is X known and intentional, or is X a
  bug nobody noticed."
- When a deferred item later gets picked up and shipped, its row is **struck through** in
  place (keeping it for history) with a note on what shipped it - items are never silently
  deleted, so the file also reads as a changelog of what used to be a gap. Example, verbatim
  pattern used throughout the file: `~~Custom / user function blocks in FBD~~ | ~~later~~ |
  **Shipped** (2026-07-23, custom-function-blocks feature): ...`.
- Both whole-branch-review non-blocking findings and consciously-scoped-out spec items land
  in the same file - it is the registry for "known and intentional gap," regardless of
  whether the gap was decided up front (spec) or discovered afterward (review).

This is the same convention this knowledge base's own governance uses for corrections
(mark superseded, never silently delete) - `docs/DEFERRED.md` is that pattern applied to
scope decisions specifically.

---

## 4. The byte-identical snapshot technique

**When a change claims to be a pure refactor - moving data or code without altering its
behavior - prove it by asserting the serialized output is byte-identical to a snapshot taken
before the change, not by re-deriving new expected values.**

A refactor that only moves code (e.g. splitting one large file of default project
definitions into one file per project) makes an implicit claim: nothing about the data
itself changed, only its location and its surrounding documentation. That claim is
falsifiable in a much stronger way than "the existing tests still pass" - existing tests
typically exercise *behavior* built from the data, not the data's exact shape, and could
stay green even if an unrelated field silently changed.

The technique, from `mobile/test/defaults/all_water_test.dart` (a project moved to its own
file and given a doc comment as part of the 2026-08 default-projects redo):

```dart
test('proj_all_water toJson() equals the pre-split snapshot', () {
  final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
  final actual = const JsonEncoder.withIndent('  ').convert(p.toJson());
  final expected =
      File('test/defaults/all_water_snapshot.json').readAsStringSync();
  expect(actual, expected,
      reason: 'the water plant must be moved verbatim - no data changes');
});
```

The snapshot (`all_water_snapshot.json`) is captured from the object's `toJson()` **before**
the refactor lands, checked in as a fixture, and the post-refactor object's `toJson()` is
diffed against it verbatim. Any change to the underlying data - a renamed tag, a shifted
gain, a reordered list that changes iteration-dependent behavior - fails the test
immediately and specifically, rather than surfacing later as a subtle behavioral regression
in some unrelated feature that happens to read that data. `docs/default-projects.md`
describes this project's own guard in exactly those terms: "a byte-identical snapshot
guard: this project's data is unchanged from before the redo."

Use this technique whenever a change's entire justification is "this is a move/rename/split,
not a behavior change" - it converts that claim from an assertion into a specific, automated
proof, and it is cheap: capture the snapshot once, assert equality forever after.

---

## What this means practically

### "Why does this project review the same branch twice?"
Because a per-task review and a whole-branch review structurally cannot see the same things.
A per-task review has one task's spec section in view and catches that task drifting from
its own contract. A whole-branch review has every task's code simultaneously and catches the
seams between tasks - shared logic that got duplicated instead of reused, an invariant one
task relied on that another task's change quietly invalidated. See §2.1 for real examples of
each.

### "I found something wrong but it's out of scope for this change - what do I do?"
Add a row to `docs/DEFERRED.md` in the relevant section: the item, a priority (`near-term` or
`later`), and enough context (file, behavior, why it's safe to skip) that a future reader can
act on it without re-deriving the finding. Link back to it from the spec/plan's own deferred
section instead of re-explaining it in prose (§3).

### "I refactored/moved some data and want to prove I didn't also change it."
Capture the pre-refactor serialized form (`toJson()` or equivalent) as a checked-in snapshot
fixture, then assert the post-refactor form equals it byte-for-byte (§4). This is a stronger
and cheaper claim than "the existing tests still pass."

### "A deferred item just got fixed - do I delete its row?"
No - strike it through in place and note what shipped it (commit/PR/feature name and date).
`docs/DEFERRED.md` is meant to be readable as history, not just as a current backlog.

---

## Related

- [index.md](./index.md) - domain hub.
- [verification.md](./verification.md) - the browser-verify and E2E-lane gates this pipeline
  runs before a PR is considered ready.
