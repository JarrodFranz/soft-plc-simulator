# FBD Import Translator — Design Spec

**Status:** Approved (brainstorm) — ready for implementation plan.
**Date:** 2026-07-26

## Goal

Convert imported PLCopen **FBD** POUs — today captured in the IR but emitted as
a whole-POU stub — into real, executable native `FunctionBlockDiagram` program
bodies. Because the translator handles `<block>` elements anyway, it also routes
**custom-FB calls** in FBD to native FB instances (the piece the import-FB
mapping spec, `2026-07-25-import-fb-mapping-design.md`, explicitly deferred until
this translator existed).

This is sub-project 2 of 3 in the graphical-translators program (LD shipped in
`2026-07-22-ld-translator-design.md`; SFC remains). It reuses the LD
translator's proven shape: a pure IR→native unit, faithful-or-stub degradation,
registry-passing for custom FBs, and instance-tag merge with rename propagation.

## North-star decisions (from brainstorming)

1. **Networks = connected components, layout-ordered.** Each weakly-connected
   component of the FBD graph becomes one native `FbdNetwork`, ordered by layout
   (min-y, then min-x, then min-localId). This mirrors LD rung segmentation,
   yields a clean multi-lane diagram matching the network-centric FBD editor,
   and gives tag-mediated cross-network flow a deterministic order. Wires are
   intra-network by construction (a wire only exists inside a component).
2. **Minimal `<expression>` operand support is in scope.** Real FBD
   `inVariable`/`outVariable` elements carry their tag/literal inside
   `<expression>`, but the shared parser reads only `<variable>` today (the
   deferred "`<expression>`-dialect operands" item). Without it every real FBD
   network stubs on unresolvable operands. This sub-project adds a minimal
   `<expression>` fallback to the parser (a bare identifier or literal only);
   compound expressions still stub.
3. **Faithful-or-stub, per network.** A component translates fully or its
   network becomes an empty network with an explanatory comment plus a warning —
   the direct analog of LD's placeholder rung. The POU is a real
   `FunctionBlockDiagram` program as long as ≥1 network translated; if nothing
   translates it keeps today's whole-POU stub.

## Why this shape (grounded in the codebase)

- The importer is a pure IR→project mapper (`lib/import/ir_to_project.dart`).
  Its `GraphBody && pou.lang == fbd` branch currently whole-POU stubs; this spec
  replaces that branch with a `translateFbdBody` call, exactly as the LD branch
  calls `translateLdBody`.
- The native FBD model already provides the complete target:
  `FbdBlock{id, type, title, tagBinding, x, y, inputCount, network}`,
  `FbdWire{fromBlockId, fromPin, toBlockId, toPin}`, and `FbdNetwork{comment}`
  (`models/project_model.dart`); the network-ordered dependency executor
  (`models/fbd_exec.dart`) runs networks in ascending index order with
  intra-network topological evaluation and immediate force-aware `TAG_OUTPUT`
  writes (so a later network reads an earlier network's tag write in the same
  scan — this is how cross-network flow works); the pin registry
  (`models/fbd_pins.dart`) resolves a block's ordered input/output pin names,
  resolving `fbDefinitionFor` (custom FB) before the `kFbdBuiltinBlockTypes`
  built-ins.
- The IR carries everything needed. The PLCopen parser (`plcopen_parser.dart`,
  `_graphBody`) emits an `IrGraphNode{localId, elementType, x, y, attributes}`
  per `<block>`/`<inVariable>`/`<outVariable>`/… with the raw XML attributes
  (so `typeName`, `instanceName` are present) plus the `<variable>` text folded
  into `attributes['variable']`, and an `IrConnection{toLocalId, toPin,
  fromLocalId, fromPin}` per wire whose `toPin`/`fromPin` are the PLCopen
  `formalParameter` names — which ARE the app's pin names.
- The custom-FB import machinery already exists: `mapImportedFbs`
  (`lib/import/fb_import.dart`) builds the `FbDefinition` registry + original→
  final rename map that `ir_to_project.dart` already threads into the LD
  translator. FBD reuses the same `fbRes.registry`/`fbRes.renameMap` values.

## Global constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never throws** — every
  untranslatable component degrades to a stubbed (empty commented) network + a
  warning, and the pipeline continues.
- Zero `flutter analyze` warnings. Run flutter from `mobile/`.
- **Additive / backward-compatible:** a project with no FBD POUs imports
  byte-identically to today. The FBD branch fires only on `pou.lang == fbd`;
  the parser's `<expression>` fallback only fires when no `<variable>` child
  exists, so existing `<variable>`-dialect LD/FBD bodies are unchanged. Existing
  import tests stay green.
- Follows the importer's name discipline: sanitize identifiers, dedup against
  the growing tag set, avoid `kSystemTagName`, warn on every rename — and
  propagate an instance-tag rename onto the referencing block(s).
- Protocol/logging rule N/A (no new protocol). No new dependency.

## §1 — New unit: `lib/import/fbd_translate.dart`

Pure, deterministic, never-throws. Mirrors `ld_translate.dart`.

```dart
class FbdTranslation {
  final List<FbdBlock> blocks;
  final List<FbdWire> wires;
  final List<FbdNetwork> networks;
  final List<PlcTag> instanceTags;        // custom-FB struct instance tags
  final int translatedNetworkCount;
  final int stubbedNetworkCount;
  final Set<String> unsupportedBlockTypes;
  final Map<String, int> stubReasons;
  final List<ImportWarning> warnings;
  FbdTranslation({ ...all required... });
}

FbdTranslation translateFbdBody(
  GraphBody body, {
  required String pouName,
  Map<String, FbDefinition> fbRegistry = const {},
  Map<String, String> fbRenameMap = const {},
});
```

### §1.1 — Component segmentation (shared with LD)

Factor the connected-components core out of `ld_translate.dart`'s
`segmentRungs` into a shared helper so both languages use one implementation:

```dart
// New shared helper (home: a new lib/import/graph_segment.dart, or exported
// from ld_translate.dart — plan decides). Weakly-connected components over an
// arbitrary node/edge set, deterministic order.
```

For FBD there are **no power rails**, so segmentation is simply: build undirected
adjacency over every node from `body.connections`, take connected components,
and order them by layout — `minY`, then `minX`, then `minLocalId` (the exact
tie-break `segmentRungs` uses). LD keeps its rail-stripping + rail-attachment
recording on top of the shared components core; FBD uses the core directly.

Each component, in order, produces one `FbdNetwork` at index = its position, and
every `FbdBlock` it emits carries `network = thatIndex`.

### §1.2 — Element → block mapping (per component)

Generate a deterministic block id per node (e.g. `'${pouName}_n${localId}'`,
guaranteed unique because localIds are unique within the POU). Build an
`localId → FbdBlock` map so wiring (§1.3) can translate endpoints.

- **`block`, `typeName` a custom FB** (after `fbRenameMap`, in `fbRegistry`):
  `FbdBlock(type: fbName, title: fbName, tagBinding: <instance name>)`. The
  instance name comes from the `instanceName` attribute when it is a valid
  identifier, else `'${pouName}_fb${localId}'`, deduped within the translation.
  Append a struct-typed instance `PlcTag(name: instance, path: instance,
  dataType: fbName, value: defaultValueFor(<fb-aware scratch>, fbName, 0),
  ioType: 'Internal')` to `instanceTags` — identical to `_buildFbCallNode` in
  `ld_translate.dart`. (Checked BEFORE the built-in allowlist so a user FB never
  shadows / is shadowed by a built-in name mismatch.)
- **`block`, `typeName` ∈ `kFbdBuiltinBlockTypes`:**
  `FbdBlock(type: typeName, title: typeName)`. For the extensible operators
  (`AND`/`OR`/`ADD`/`MUL`) set `inputCount` = the number of distinct wired input
  pins feeding this block (min 1); other types ignore `inputCount`.
- **`block`, `typeName` neither:** add `typeName` (or `'?'`) to
  `unsupportedBlockTypes`; **stub the component** (`stubReasons['unsupported-block']`).
- **`inVariable`:** an operand source. Resolve its text from
  `attributes['variable']` (populated from `<variable>` or, per §3, an
  `<expression>` fallback). If the text is a literal (`int`/`double` parses, or
  case-insensitive `TRUE`/`FALSE`) → `FbdBlock(type: 'CONST', tagBinding: text)`.
  Otherwise if it is a bare identifier → `FbdBlock(type: 'TAG_INPUT',
  tagBinding: <sanitized identifier>)`. Otherwise (empty, or compound) → **stub
  the component** (`stubReasons['complex-expression']` for a non-empty compound,
  `stubReasons['unresolved-operand']` for empty).
- **`outVariable`:** a sink. Resolve text as above; a bare identifier →
  `FbdBlock(type: 'TAG_OUTPUT', tagBinding: <sanitized identifier>)`. A literal
  or compound outVariable target → **stub the component**
  (`stubReasons['complex-expression']`).
- **Any other `elementType`** (`inOutVariable`, `connector`, `continuation`,
  `label`, `jump`, `comment`, …): **stub the component**
  (`stubReasons['unsupported-element']`).

**Binding names.** `TAG_INPUT`/`TAG_OUTPUT` bindings reference **existing global
tags** already imported from `<globalVars>`, so they are NOT added to
`instanceTags` and need no dedup — they bind by name to a tag that already
exists (or, if absent, bind to a name the running engine treats as unresolved,
exactly as a hand-built diagram referencing a missing tag would).
`translateFbdBody` emits the raw (parser-provided) identifier as `tagBinding`.
This exactly **mirrors LD's contact/coil behavior** (`_toLdNode` in
`ld_translate.dart` emits `attributes['variable']` raw): a graphical reference
to a global var whose name the mapper sanitized/renamed on import is NOT
retargeted. In practice PLCopen identifiers are already valid app identifiers
(so raw == sanitized) and this edge does not fire; the limitation is
pre-existing, shared with LD, and tracked in `docs/DEFERRED.md` (§8/§9). Only
custom-FB **instance** tags are newly created and dedup-managed (§4).

### §1.3 — Wires

For each `IrConnection` in the component whose both endpoints mapped to blocks:
`FbdWire(fromBlockId: id[fromLocalId], fromPin: fromPin ?? '', toBlockId:
id[toLocalId], toPin: toPin ?? '')`. Pass `fromPin`/`toPin` straight through —
they are already the app's pin names.

**Pin faithfulness gate.** Before committing a component, verify every wire's
`toPin` is on the resolved input-pin list of its target block and every
`fromPin` is on the resolved output-pin list of its source block (resolve via
the same rules `fbd_pins.dart` uses: custom FB → its var-direction names; built-
in → `fbdInputPins`/`fbdOutputPins`). An empty pin name is allowed only when the
block has exactly one pin on that side (the executor's first-pin fallback);
otherwise → **stub the component** (`stubReasons['unresolved-pin']`). This keeps
FBD faithful-or-stub like LD's `_assertFaithfulWiring`, catching a wire that
would silently mis-target a pin.

### §1.4 — Faithful-or-stub assembly

Translate components in order. A component that raises the internal stub signal
becomes an **empty** `FbdNetwork(comment: 'Network ${i+1} not translated on
import: <detail>.')` — no blocks, no wires — and increments
`stubbedNetworkCount` + the `stubReasons` key, plus a `WarningSeverity.warning`
naming the POU, the network ordinal, and the reason. A translated component
contributes its blocks/wires/instanceTags and increments
`translatedNetworkCount`. Network indices stay contiguous and match ordinal
order regardless of stubs (an empty network still occupies its index), so
`FbdBlock.network` values always point at a real header.

Per-component staging (mirrors `_translateComponent`): a component's instance
tags and dedup-name reservations accumulate in local buffers and commit to the
shared lists only after its pin-faithfulness gate passes, so a stubbed component
leaks no orphan instance tag and frees its dedup name. `unsupportedBlockTypes`
is mutated eagerly (a persistent inventory).

## §2 — Mapper integration (`ir_to_project.dart`)

Replace the `else if (body is GraphBody)` FBD arm (the `PouLanguage.fbd` half of
today's combined FBD/SFC stub) with:

```dart
} else if (body is GraphBody && pou.lang == PouLanguage.fbd) {
  final tr = translateFbdBody(body, pouName: pou.name,
      fbRegistry: fbRes.registry, fbRenameMap: fbRes.renameMap);
  translatedFbdNetworkCount += tr.translatedNetworkCount;
  stubbedFbdNetworkCount += tr.stubbedNetworkCount;
  unsupportedFbdBlockTypes.addAll(tr.unsupportedBlockTypes);
  tr.stubReasons.forEach((k, v) => fbdStubReasons[k] = (fbdStubReasons[k] ?? 0) + v);
  warnings.addAll(tr.warnings);
  if (tr.translatedNetworkCount > 0) {
    // Merge custom-FB instance tags with the SAME sanitize + dedup + node-
    // retarget loop the LD arm uses, retargeting FbdBlock.tagBinding (not
    // LdNode.variable). Only blocks whose type is a registered FB may be
    // retargeted (a TAG_INPUT/CONST whose binding coincidentally matches must
    // NOT be), exactly paralleling the LD `isInstanceBackedLdBlock` guard.
    for (final it in tr.instanceTags) { ...sanitize/dedup as global vars...
      if (renamed) for (final b in tr.blocks)
        if (fbRes.registry.containsKey(b.type) && b.tagBinding == original)
          b.tagBinding = name;
      ...used.add/tags.add... }
    programs.add(PlcProgram(name: pou.name, language: 'FunctionBlockDiagram',
        fbdBlocks: tr.blocks, fbdWires: tr.wires, fbdNetworks: tr.networks));
  } else {
    // Nothing translated -> today's whole-POU FBD stub (unchanged).
    ...existing FunctionBlockDiagram stub + warning + stubCount++...
  }
} else if (body is GraphBody) {
  // SFC (and any other graphical): unchanged whole-POU stub.
  ...
}
```

The SFC (and fallback) whole-POU stub arm is preserved unchanged.

`ImportReport` gains `translatedFbdNetworkCount` (int, default 0),
`stubbedFbdNetworkCount` (int, default 0), `unsupportedFbdBlockTypes`
(`Set<String>`, default `{}`), and `fbdStubReasons` (`Map<String,int>`, default
`{}`) — all default-safe so existing call sites compile.

## §3 — Parser `<expression>` fallback (`plcopen_parser.dart`)

In `_graphBody`, after the existing `<variable>` lookup:

```dart
final varEl = _findElement(el, 'variable');
if (varEl != null) {
  attrs['variable'] = varEl.innerText.trim();
} else {
  final exprEl = _findElement(el, 'expression');
  if (exprEl != null) attrs['variable'] = exprEl.innerText.trim();
}
```

Minimal and additive: `<variable>` still wins when both are present; a node with
neither is unchanged. Downstream (§1.2) only accepts a bare identifier or
literal from that slot — a compound `<expression>` (e.g. `A + B`) lands in the
slot but fails the identifier/literal test and stubs its component, so no
partial/incorrect expression is ever executed. LD benefits identically (an LD
`<inVariable>` using `<expression>` now resolves).

## §4 — Data flow / orchestration

`mapImportedProject` order is unchanged through structs → global vars → FB defs
(`fbRes`) → POU loop. The FBD arm (§2) runs inside the POU loop alongside the LD
arm, sharing `fbRes`, the `used`/`tags` accumulators, and the sanitize/dedup
helper. Preview surfacing (§5) reads the new report fields.

## §5 — Preview / UI (`import` screen)

The import preview surfaces the FBD counts beside the existing LD ones:
`translatedFbdNetworkCount` translated / `stubbedFbdNetworkCount` stubbed
networks, and the `unsupportedFbdBlockTypes` inventory (same treatment as
`unsupportedLdBlockTypes`). Follow the existing preview widget's presentation of
the LD numbers — no new UI pattern.

## §6 — Error handling (pure, never-throws)

| Situation | Handling |
|---|---|
| Component with an unsupported element (`inOutVariable`/`connector`/`continuation`/`label`/`jump`/…) | Stub network; `stubReasons['unsupported-element']` |
| Compound `<expression>` operand (operators/parens/spaces) | Stub network; `stubReasons['complex-expression']` |
| Empty/unresolvable operand | Stub network; `stubReasons['unresolved-operand']` |
| Negated block pin | Stub network; `stubReasons['negated-pin']` (NOT-insertion deferred) |
| Unknown block type not in registry | Stub network; add to `unsupportedBlockTypes`; `stubReasons['unsupported-block']` |
| Wire pin not on resolved pin list (and not the single-pin fallback) | Stub network; `stubReasons['unresolved-pin']` |
| Nothing in the POU translated | Keep today's whole-POU FBD stub (unchanged) |
| Custom-FB name collided/renamed on import | Resolved via `fbRenameMap` (block `type` = final name), as LD |

**Negated pins.** PLCopen block pins may carry `negated="true"` on their
`<inputVariables>`/`<outputVariables>` `<variable>` wrapper. The app FBD model
has no negated-pin concept (negation is an explicit `NOT` block), so a negated
pin executed as if un-negated would be silently-wrong logic — forbidden by the
faithful-or-stub guarantee. Therefore the parser MUST capture per-pin negation
sufficient to detect it (the plan adds this: input-pin negation on the same
`<variable>` wrapper the parser already reads `formalParameter`/`toPin` from;
output-pin negation by scanning the block's own `<outputVariables>` for
`negated="true"` into a node attribute). Any negated pin **stubs its component**
(`stubReasons['negated-pin']`). NOT-block insertion to translate them faithfully
is deferred.

## §7 — Testing

- **Parser unit** (`plcopen_parser` tests): an `inVariable`/`outVariable` using
  `<expression>` populates `attributes['variable']`; `<variable>` still wins
  when both present; a node with neither is unchanged; existing LD fixtures stay
  green.
- **Translate unit (pure)** (`fbd_translate_test.dart`): a two-component body →
  two layout-ordered networks (min-y/min-x tie-break); `inVariable` literal →
  CONST, identifier → TAG_INPUT; `outVariable` → TAG_OUTPUT; extensible `AND`
  `inputCount` = wired-pin count; a network containing `inOutVariable` /
  compound-expression / negated pin → empty commented network + warning + the
  right `stubReasons` key + preserved network index; an unknown block adds to
  `unsupportedBlockTypes`; a wire to a non-existent pin stubs.
- **Custom-FB routing (pure):** an FBD `block` whose `typeName` is a registered
  FB → `FbdBlock(type: fbName, tagBinding: instance)` + a struct-typed instance
  tag; a renamed FB (via `fbRenameMap`) routes to the final name; the instance
  tag is dedup-renamed if it collides and the block's `tagBinding` follows.
- **End-to-end fixture** (`import_fbd_e2e_test.dart`): a handcrafted PLCopen FBD
  POU — component A (`TAG_INPUT(A)`+`inVariable literal` → `GT` →
  `TAG_OUTPUT(Result1)`), component B reading a tag A wrote via a tag hop — →
  `mapImportedProject` → `executeFbdPrograms` scan yields the expected outputs,
  and B (a later network) reads A's written tag in the same scan (validates
  layout-ordered network execution). A custom-FB variant (`Scaler: Out :=
  In*Gain`) round-trips runnably (`readPath(Result) == In*Gain`), mirroring the
  LD e2e.
- **Backward-compat:** the existing PLCopen corpus/round-trip tests stay green;
  a no-FBD project imports identically; an all-`<variable>` body is byte-
  identical after the parser change.

## §8 — Docs

- `docs/iec61131/` — add an FBD import-support matrix (supported elements/blocks,
  stub reasons), paralleling the LD import notes.
- Import doc — note FBD POUs now translate (with the faithful-or-stub caveat and
  the `<expression>` operand support).
- `docs/DEFERRED.md` — strike "`<expression>`-dialect operands" and "FBD
  custom-FB call routing" / "FBD import translator" rows (delivered here); add
  rows for the remaining FBD gaps: negated FBD pins (NOT-insertion),
  `inOutVariable`, `connector`/`continuation` cross-references, `label`/`jump`,
  compound-expression operands. Leave SFC import as the remaining sub-project.

## §9 — Deferred (tracked in `docs/DEFERRED.md`)

- **Negated FBD pins** → NOT-block insertion (stubs for now).
- **`inOutVariable`** (by-reference in/out) — no native equivalent.
- **`connector` / `continuation`** off-page cross-references — no native model.
- **`label` / `jump`** execution-control — FBD is dataflow-only in the app.
- **Compound-expression operands** — needs a small expression→block compiler.
- **SFC import translator** — sub-project 3 of 3 (needs graphical→ST
  serialization); unchanged by this work.
