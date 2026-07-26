# L5X RLL Ladder Compiler (sub-project 2) — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-27

## Goal

Compile imported L5X **RLL routines** — Rockwell ladder in neutral-text form,
stubbed by the L5X foundation (PR #14) — into real, executable native
`LadderLogic` programs. This is sub-project 2 of the L5X program (the biggest
Rockwell-logic payoff, since Rockwell projects are ladder-dominated).

Scope (from brainstorming): cover the instruction set the app's LD engine
executes plus AOI calls, faithful-or-stub **per rung**; AOI-call operand binding
is **strict** (a mismatch stubs the rung, never binds partially). Timers/counters
are **best-effort**: the compiler resolves an exact preset when it is a literal
in the neutral text (or resolvable from the instance tag), and otherwise defaults
it with a **prominent warning** — flagged, never silent, mirroring how the app
already imports the ST subset (runs partially + warns). (Exact preset fidelity
via Rockwell's predefined `TIMER`/`COUNTER` types is a follow-up.)

## North-star decisions

1. **Compile the native-executable instruction set + AOI calls.** Contacts
   (`XIC`/`XIO`/`ONS`), coils (`OTE`/`OTL`/`OTU`), timers (`TON`/`TOF`), counters
   (`CTU`/`CTD`/`CTUD`), compares (`EQU`/`NEQ`/`LEQ`/`GEQ`/`LES`/`GRT`), math
   (`ADD`/`SUB`/`MUL`/`DIV`), `MOV`, AOI calls, and single-level `[…]` branches.
   Everything else stubs the rung with an unsupported-mnemonic inventory.
2. **Faithful-or-stub per rung** (one flagged exception). A rung compiles fully
   or degrades to a commented placeholder rung (2 rails + one wire), carrying the
   reason and the original neutral text; rung numbering is preserved. Mirrors the
   PLCopen LD translator. The single exception is a timer/counter with an
   unresolvable preset (§3.2.1): it compiles with a defaulted preset + a
   prominent warning rather than stubbing — a flagged best-effort, never silent.
3. **Strict AOI binding.** An AOI call routes only when the arg count matches the
   AOI's interface and the AOI is known; otherwise the rung stubs. A mis-bound
   AOI arg is silently-wrong logic — forbidden.
4. **Reuse the native assembler + LD FB-call path.** `buildRung`/`BranchSpec`
   (`models/ld_graph.dart`) assemble the `LdRung`; `ld_exec.dart`'s FB-call
   execution runs AOI instances — no new engine code.

## Why this shape (grounded in the codebase + real samples)

- The L5X foundation already emits RLL routines as an empty-`GraphBody` stub
  (`l5x_parser.dart` `_l5xRoutines`, the `case 'RLL'` arm) and imports the tag
  database + AOIs. So an AOI/timer/counter **instance is an existing tag** — the
  compiler references it by name and synthesizes nothing (unlike the PLCopen LD
  translator, which had to create instance tags).
- The native LD model is the exact compile target:
  `LdNode{kind (contact/coil/block), variable, modifier
  (normal/negated/rising/set/reset), blockType, presetMs, operandA, operandB,
  pinBindings}` (`project_model.dart`); `buildRung(index, comment, main,
  branches)` + `BranchSpec(startIndex, endIndex, nodes)` (`ld_graph.dart`) wire
  rails/series/parallel; `ld_exec.dart` executes contacts, coils, timer/counter/
  compare/math/MOVE blocks, and custom-FB calls via `pinBindings`.
- Real RLL text (from `Resources/Project Exports/Rockwell-L5X/
  logixlibraries_Numeric_Program.L5X`) confirms the grammar: `NOP();`,
  `N_DINT(DINT);` (AOI call), and
  `[N_ETHMACtoStr(inst,Sys.List[0].PhysicalAddress,0,Str) MOVE(Str,Str) , …]`
  (a `[…]` branch, each leg a space-separated series of an AOI call + a MOVE,
  operands include dotted/array tag paths and literals).
- The mapper (`ir_to_project.dart`) already has the whole-POU-stub-vs-real-program
  decision for the LD arm; the RLL arm mirrors it. `ImportReport` already carries
  LD-style counters (`translatedRungCount`/`stubbedRungCount`/
  `unsupportedLdBlockTypes`/`ldStubReasons`); RLL adds parallel fields.

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never-throws** — a rung that
  can't compile degrades to a placeholder; the pipeline continues. (An internal
  `_RllStub` exception is used for per-rung control flow and is always caught.)
- The `xml` package stays confined to `l5x_parser.dart`; `rll_compile.dart` is
  Flutter-free pure Dart (imports `project_model.dart`/`ld_graph.dart`/
  `import_ir.dart` only).
- Zero `flutter analyze` warnings (run flutter from `mobile/`).
- **Additive / backward-compatible:** the PLCopen import path and the L5X
  foundation's tag/UDT/AOI/ST behavior are unchanged; only the RLL routine arm
  changes from stub to compile. Whole suite stays green.

## §1 — IR: `NeutralLadderBody` (`import_ir.dart`)

```dart
class RllRung {
  final int number;
  final String text;     // neutral-text, e.g. 'XIC(Start)OTE(Motor)'
  final String comment;  // rung comment (may be '')
  RllRung({required this.number, required this.text, this.comment = ''});
}

class NeutralLadderBody extends PouBody {
  final List<RllRung> rungs;
  NeutralLadderBody({required this.rungs});
}
```

Rockwell-flavored but IR-resident (as `SfcBody` is PLCopen-flavored) — the clean
parser→compiler seam.

## §2 — Parser change (`l5x_parser.dart` `_l5xRoutines`)

The `case 'RLL':` arm currently emits `GraphBody(nodes: const [], connections:
const [])` + a rung-count warning. Change it to capture the rungs:

```dart
case 'RLL':
  final rungs = <RllRung>[];
  for (final content in _children(r, 'RLLContent')) {
    for (final rung in _children(content, 'Rung')) {
      final num = int.tryParse(rung.getAttribute('Number') ?? '') ?? rungs.length;
      final text = (_firstChild(rung, 'Text')?.innerText ?? '').trim();
      final comment = _firstChild(rung, 'Comment')?.innerText.trim() ?? '';
      rungs.add(RllRung(number: num, text: text, comment: comment));
    }
  }
  out.add(ImportedPou(name: name, kind: PouKind.program,
      lang: PouLanguage.ld, localVars: const [],
      body: NeutralLadderBody(rungs: rungs)));
  break;
```

(No warning here — the compiler reports per-rung outcomes. `<Text>`/`<Comment>`
are direct children of `<Rung>`; `innerText` unwraps the CDATA.) FBD/SFC arms are
unchanged (still empty-`GraphBody`/`SfcBody` stubs).

## §3 — Compiler: `lib/import/rll_compile.dart`

Pure, deterministic, never-throws.

```dart
class RllTranslation {
  final List<LdRung> rungs;              // includes placeholder rungs (numbering preserved)
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedInstructions;
  final Map<String, int> stubReasons;
  final List<ImportWarning> warnings;
  RllTranslation({ ...all required... });
}

RllTranslation compileRllRungs(
  NeutralLadderBody body, {
  required String pouName,
  Map<String, FbDefinition> fbRegistry = const {},
  Map<String, String> fbRenameMap = const {},
});
```

Internal `_RllStub(reason, detail)` for per-rung bail-out, caught in the per-rung
loop.

### §3.1 — Tokenizer / parser (recursive descent)

Grammar (whitespace between instructions ignored; trailing `;` stripped):
```
rung    := element*
element := instruction | branch
instr   := IDENT '(' arglist? ')'
branch  := '[' element* (',' element*)* ']'   -- commas at bracket-depth 1 split legs
arglist := arg (',' arg)*                       -- commas at paren-depth 1 split args
arg     := chars, with balanced () and []       -- 'List[0]' is one arg; a ',' inside [] is not a separator
```
Produces `List<RllElement>` where `RllElement` is
`RllInstruction{String mnemonic, List<String> operands}` or
`RllBranch{List<List<RllElement>> legs}`. Depth-tracking (paren depth for arg
splits, bracket depth for leg splits) keeps a `[0]` subscript or a nested paren
comma from being mistaken for a separator. Unbalanced `(`/`[`, an empty mnemonic,
or a stray token → `_RllStub('parse-error', …)`.

### §3.2 — Instruction → `LdNode`

| Mnemonic | `LdNode` |
| --- | --- |
| `XIC(t)` / `XIO(t)` / `ONS(t)` | contact, modifier normal / negated / rising, variable=t |
| `OTE(t)` / `OTL(t)` / `OTU(t)` | coil, modifier normal / set / reset, variable=t |
| `TON(inst,pre,acc)` / `TOF(inst,pre,acc)` | block `TON`/`TOF`, variable=inst, presetMs = best-effort (§3.2.1) |
| `CTU(inst,pre,acc)` / `CTD` / `CTUD` | block `CTU`/`CTD`/`CTUD`, variable=inst, presetMs = best-effort (§3.2.1) |
| `EQU/NEQ/LEQ/GEQ/LES/GRT(a,b)` | block `EQ`/`NE`/`LE`/`GE`/`LT`/`GT`, operandA=a, operandB=b |
| `ADD/SUB/MUL/DIV(a,b,dest)` | block `ADD`/`SUB`/`MUL`/`DIV`, operandA=a, operandB=b, variable=dest |
| `MOV(src,dest)` | block `MOVE`, operandA=src, variable=dest |
| AOI call (§3.3) | FB-call block |
| anything else | `_RllStub('unsupported-instruction', …)`, mnemonic → `unsupportedInstructions` |

Operand-count mismatch for a mapped instruction (e.g. `TON` with 0 args, `MOV`
with ≠2, a compare with ≠2, a math op with ≠3) → `_RllStub('unresolved-operand',
…)`. `NOP()` (a no-op rung) is treated as an empty rung → an empty-but-valid
`LdRung` (rails + one wire), counted as translated.

### §3.2.1 — Timer/counter preset (best-effort, flagged)

For `TON`/`TOF`/`CTU`/`CTD`/`CTUD`, `variable` = the instance operand (`op0`, an
existing imported tag). The preset (`presetMs`) is resolved best-effort:
1. If a following operand (`op1`) is a **numeric literal**, use it (`int` for the
   count/ms). Exact.
2. Else (the operand is `?`, a `.PRE` member reference, or absent) leave the node
   at its default preset **and** emit
   `ImportWarning(warning, 'Timer/counter "<inst>" preset could not be resolved
   from the neutral text — defaulted, verify.')`.
The rung still **counts as translated** (a flagged best-effort, like the ST-
subset import), never a stub. `RTO` (retentive timer) is NOT mapped — its
retentive accumulate-through-false semantics differ from the native `TON`, so it
stubs (`unsupported-instruction`); mapping it to `TON` would be silently-wrong
behavior a preset warning wouldn't cover.

### §3.3 — AOI call routing (strict)

An `IDENT(op0, op1, …)` whose (renamed via `fbRenameMap`) `IDENT` is a key in
`fbRegistry` is an AOI call:
- `op0` = the **instance** tag → `LdNode.variable`.
- `op1…` bind **positionally** to `fbDef.vars` in declaration order:
  `pinBindings[fbDef.vars[i].name] = op(i+1)`.
- **Strict gate:** route only when `operands.length - 1 == fbDef.vars.length`.
  Otherwise (or if the AOI is absent from the registry) →
  `_RllStub('aoi-mismatch', …)` and the AOI name is added to
  `unsupportedInstructions`.
- Emits `LdNode(kind: block, blockType: <effective AOI name>, variable: op0,
  pinBindings: …)`. No instance tag is synthesized (the instance is an existing
  imported tag). Execution reuses `ld_exec.dart`'s FB-call path.

### §3.4 — Rung assembly (single-level branches)

A rung's `List<RllElement>` lowers to a main line + `BranchSpec`s:
- Top-level `RllInstruction`s map to main-line `LdNode`s in order.
- A top-level `RllBranch`: its **first leg**'s instructions extend the main line;
  each **other leg** becomes a `BranchSpec(startIndex, endIndex, nodes)` spanning
  the first leg's main-line index range (`buildRung` wires them as parallel
  lanes). A branch leg that itself contains an `RllBranch` (nested) →
  `_RllStub('complex-topology', …)`.
- The rung is built via `buildRung(index: rungIndex, comment: <RllRung.comment>,
  main: mainNodes, branches: specs)`.
- A rung with no output-producing element is still valid (a data/AOI-only rung,
  like the sample's `N_DINT(DINT)`), exactly as the PLCopen LD translator allows
  coil-less block rungs.

A stubbed rung → a placeholder `LdRung(rungIndex, comment: 'Rung not compiled on
import: <detail>. Source: <neutral text>', nodes: [leftRail, rightRail], wires:
[L→R])`, preserving the rung index.

## §4 — Mapper integration (`ir_to_project.dart`)

A new arm, before the generic graphical fallback (SFC/other):

```dart
} else if (body is NeutralLadderBody) {
  final tr = compileRllRungs(body, pouName: pou.name,
      fbRegistry: fbRes.registry, fbRenameMap: fbRes.renameMap);
  warnings.addAll(tr.warnings);
  translatedRllRungCount += tr.translatedRungCount;
  stubbedRllRungCount += tr.stubbedRungCount;
  unsupportedRllInstructions.addAll(tr.unsupportedInstructions);
  tr.stubReasons.forEach((k, v) => rllStubReasons[k] = (rllStubReasons[k] ?? 0) + v);
  if (tr.translatedRungCount > 0) {
    programs.add(PlcProgram(name: pou.name, language: 'LadderLogic', rungs: tr.rungs));
  } else {
    // whole-POU LD stub (unchanged wording), stubCount++
  }
}
```

RLL rungs reference existing tags by name (no instance-tag merge needed, unlike
the PLCopen LD arm). `ImportReport` gains `translatedRllRungCount` (int, default
0), `stubbedRllRungCount` (int, default 0), `unsupportedRllInstructions`
(`Set<String>`, default `{}`), `rllStubReasons` (`Map<String,int>`, default `{}`).

## §5 — Preview (`import_xml_preview.dart`)

Surface RLL counts beside the LD/FBD/SFC ones: `translatedRllRungCount` compiled
/ `stubbedRllRungCount` stubbed rungs, plus the `unsupportedRllInstructions`
inventory — same treatment as the LD `unsupportedLdBlockTypes` line.

## §6 — Error handling (pure, never-throws)

| Situation | `stubReasons` key |
| --- | --- |
| Unknown/unsupported mnemonic | `unsupported-instruction` (mnemonic inventoried) |
| AOI call: unknown AOI / arity mismatch | `aoi-mismatch` (name inventoried) |
| Nested `[…[…]…]` branch | `complex-topology` |
| Malformed text (unbalanced brackets, empty mnemonic) | `parse-error` |
| Mapped instruction with wrong arity / missing dest | `unresolved-operand` |
| `RTO` (retentive timer) | `unsupported-instruction` (retentiveness unrepresentable) |
| No rung in the POU compiled | whole-POU LD stub (unchanged) |

A timer/counter preset that can't be resolved is **not** a stub — the rung
compiles with a defaulted preset + a prominent warning (§3.2.1).

Only `_RllStub` is thrown, always caught per rung; nothing escapes
`compileRllRungs`.

## §7 — Testing

- **Parser unit** (`rll_parse_test.dart`): the depth-aware tokenizer splits
  `[N_ETHMACtoStr(inst,Sys.List[0].PhysicalAddress,0,Str) MOVE(Str,Str) ,
  N_ETHMACtoStr(inst,Sys.List[0].PhysicalAddress,1,Str1) MOVE(Str1,Str1)]` into
  two legs, each an AOI-call + MOVE with correctly-split operands (the `[0]` and
  the arg commas not confused with leg commas); a trailing `;` and whitespace are
  handled; unbalanced brackets → parse-error.
- **Compile unit (pure)** (`rll_compile_test.dart`): `XIC(A)OTE(B)` → contact
  (normal) + coil (normal); `XIO(A)` → negated; `OTL/OTU` → set/reset;
  `XIC(A)[XIC(B),XIC(C)]OTE(D)` → two parallel branch legs;
  `TON(T,5000,0)`→timer block with `presetMs=5000` (literal preset);
  `TON(T,?,?)`→timer block with a defaulted preset + a "preset could not be
  resolved" warning, still counted as translated; `RTO(T,?,?)`→stub
  (`unsupported-instruction`); `EQU(a,b)`/`ADD(a,b,d)`/`MOV(s,d)` → the right
  blocks with operands; an AOI call with matching arity → FB-call node with positional
  `pinBindings` + variable=instance; an AOI arity mismatch / unknown mnemonic /
  nested branch → placeholder rung + the right `stubReason`, unsupported
  inventory populated; `NOP()` → an empty valid rung.
- **End-to-end** (`import_l5x_rll_e2e_test.dart`): a handcrafted L5X program with
  an RLL routine (`XIC(Start)TON(T1,5000,0)` and an AOI call wired to real tags)
  → `parseL5x` → `mapImportedProject` → `executeLdPrograms` scans drive the timer
  and the AOI instance correctly. Plus a run against the real corpus
  `logixlibraries_Numeric_Program.L5X`: its RLL routine compiles (AOI-call rungs →
  FB nodes; unsupported → placeholders) with no throw, `translatedRllRungCount >
  0`. (Corpus test skips when the gitignored fixtures are absent.)
- **Backward-compat:** the PLCopen LD/import suite and the L5X foundation tests
  stay green; FBD/SFC L5X routines still stub; a project with no RLL imports as
  before.

## §8 — Docs

- `docs/import/L5X.md` — add the RLL support matrix (mapped instructions; AOI
  calls; single-level branches; stubbed: nested branches, unmapped instructions).
- `docs/DEFERRED.md` — strike the "RLL ladder compiler" row (delivered); record
  residual RLL gaps (nested branches; unmapped instructions CPT/JSR/PID/SQO/file-
  array ops; retentive-timer RTO fidelity; instruction modifiers outside the
  native set). Note L5X sub-projects 3–5 (non-ST AOI logic, FBD, SFC) remain.

## §9 — Deferred (tracked in `docs/DEFERRED.md`)

- **Nested `[…]` branches** — single-level only (matches the PLCopen LD limit).
- **Unmapped instructions** — `CPT`, `JSR`/`SBR`/`RET`, `PID`, `SQO`/`SQI`, file/
  array (`COP`/`FLL`/`FAL`), messaging (`MSG`), etc.
- **`RTO`/retentive timers** — the native timer isn't retentive; mapped to
  `TON` would be silently-wrong, so `RTO` stubs for now.
- **Exact timer/counter preset fidelity** — a preset that isn't a literal in the
  neutral text is defaulted + warned (§3.2.1). Resolving it exactly requires
  mapping Rockwell's predefined `TIMER`/`COUNTER` types (`.PRE`/`.ACC` →
  native `.pre`/`.et`), a follow-up that would also let the imported instance
  tag carry the real preset/accum.
- **Instruction modifiers** outside the native contact/coil/block set.
- L5X sub-projects 3 (non-ST AOI logic), 4 (FBD), 5 (SFC) — separate cycles.
