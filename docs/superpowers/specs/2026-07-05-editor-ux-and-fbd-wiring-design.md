# Editor UX Fixes + Pin-Based FBD Wiring (WS7) — Design Spec

**Date:** 2026-07-05
**Status:** Approved by delegation (user: verify the reference FBD model, write
it up, then action it). FBD depth: pin-based with named ports; blocks may have
0, 1, or many outputs (user clarification).
**Author:** Claude (pairing with Jarrod)

Five user-reported issues, grouped into quick UX fixes and one real editor +
engine overhaul (pin-based FBD wiring).

## Part A — Quick editor UX fixes

### A1. LD toolbar horizontal overflow (the pasted RenderFlex error)
`ld_editor_screen.dart:214-225` renders a fixed `Row` toolbar (`height:44`,
mode buttons + `Spacer` + Add Rung) when `context.isExpanded` is true. But
`context.isExpanded` keys on the **window** width (`MediaQuery.sizeOf`), while
the editor can be laid out in a **narrower pane** (e.g. a ~257 px center when
both docks are open at a ~840 px window). Window says "expanded", pane is
narrow → the `Row` overflows (matches the reported `w≤257, h≤44` constraints).
**Fix:** the toolbar (and any embedded-editor responsive decision) must key on
the **local** available width via `LayoutBuilder`, not the window. Below a local
threshold use the wrapping toolbar; above it the `Row`. Audit the other editors
for the same window-vs-pane mistake.

### A2. LD elements unreachable on a phone
The rung canvas scrolls horizontally per-rung, but it's easy to miss and
parallel-branch elements can sit outside a rung box. **Fix:** on compact, wrap
the whole ladder in an `InteractiveViewer` (pan + light zoom), consistent with
the FBD/HMI treatment, so every element is reachable by swiping. Keep the
desktop layout unchanged.

### A3. Project CRUD buttons take too much space
`workspace_shell.dart:1062-1074` is a `Wrap` of 7 icon buttons that stacks
vertically in the narrow dock. **Fix:** collapse into a single `⋮`
`PopupMenuButton` beside the SELECT PROJECT dropdown (New, Duplicate, Rename,
Delete, Reset, Export, Import). The dropdown + `⋮` sit in one `Row`.

### A4. Type-ahead tag fields (replace dropdowns)
Six tag pickers are `DropdownButtonFormField` over the project tags
(`fbd_editor` ×2, `ld_editor` node dialog, `hmi_dashboard_builder`,
`simulated_io` ×3). **Fix:** a reusable `TagAutocompleteField` — a text field
with an autocomplete overlay (Flutter `Autocomplete`/`RawAutocomplete`) that
filters tag names/paths as you type ("JamTimer" → `JamTimer`, `JamTimer.DN`, …)
and still allows free-text (so you can type a path not yet in the list). Swap it
into all six sites. Source options from `currentProject.tags` (and
`leafAndNodePaths` where a path picker is wanted).

## Part B — Pin-based FBD wiring (the overhaul)

Today FBD blocks are boxes, `FbdWire` is block-to-block (`fromBlockId`,
`toBlockId`), there is **no UI to create wires**, and the executor gives each
block a single value with input order = wire-insertion order. We move to a
**pin model** faithful to the PLCopen/IEC reference (verified in the reference
editor): named, ordered input and output pins per block type; pin-addressed
wires; multi-output blocks; extensible-input operators.

### B1. Pin registry (`mobile/lib/models/fbd_pins.dart` — new, pure)
A pure function maps a block `type` (+ an input count for extensible ops) to its
ordered **input** and **output** pin names, using IEC-standard names:

| type | inputs | outputs |
|---|---|---|
| `TAG_INPUT`, `CONST` | — | `OUT` |
| `TAG_OUTPUT` | `IN` | — |
| `NOT` | `IN` | `OUT` |
| `AND`, `OR` | `IN1`,`IN2`,… (extensible, default 2) | `OUT` |
| `ADD`, `MUL` | `IN1`,`IN2`,… (extensible, default 2) | `OUT` |
| `SUB`, `DIV` | `IN1`,`IN2` | `OUT` |
| `GT`,`LT`,`GE`,`LE`,`EQ`,`NE` | `IN1`,`IN2` | `OUT` |
| `LIMIT` | `MN`,`IN`,`MX` | `OUT` |
| `SEL` | `G`,`IN0`,`IN1` | `OUT` |
| `TON`, `TOF` | `IN`,`PT` | `Q`,`ET` |

`Q` is BOOL, `ET` is elapsed-time (ms, num) — the canonical **multi-output**
case. EN/ENO execution-control pins are **out of scope** (deferred). Extensible
blocks read their input count from the block (below).

### B2. Model changes (`project_model.dart`)
- `FbdBlock` gains `int inputCount` (default per type; used by extensible
  AND/OR/ADD/MUL; ignored otherwise). Existing fields unchanged.
- `FbdWire` becomes **pin-addressed**: `fromBlockId`, `fromPin` (source output
  pin name), `toBlockId`, `toPin` (target input pin name). Serialization
  (WS6) extended for the new fields; a legacy block-to-block wire (no pin names)
  is read as connecting the source's first output to the target's first free
  input (back-compat for any old JSON), but the shipped defaults are migrated to
  explicit pins.
- One output pin may fan out to many input pins; each input pin takes at most
  one wire (a second wire to the same input replaces the first).

### B3. Executor (`fbd_exec.dart`)
- Each block evaluates to a **`Map<String,dynamic>` of output-pin → value**
  (not a single value). Single-output blocks yield `{'OUT': v}`; a timer yields
  `{'Q': bool, 'ET': num}`.
- An input pin's value = the wire targeting `(block, toPin)` resolved to the
  source block's `cache[fromBlockId][fromPin]`. Arithmetic/comparator operand
  order is the **pin order** from the registry (`IN1`,`IN2`,… / `MN`,`IN`,`MX`)
  — deterministic and explicit (replaces wire-insertion order).
- Topological evaluation as today (a block is ready when every block feeding any
  of its inputs is done); cycles terminate; never throws.
- **`TON`/`TOF` become executable, stateful, multi-output**: per-block state in
  `FbdRuntime` keyed by block id, advanced by `dtMs` (mirroring `ld_exec`'s
  timer semantics). `Q` and `ET` are produced as two outputs — proving the
  multi-output model end-to-end. Force-aware writes unchanged for `TAG_OUTPUT`.
- Parity: the migrated default diagrams (all single-output combinational) must
  scan-equivalent to today. New: a small test FBD using a `TON` (IN,PT→Q,ET)
  wired to two `TAG_OUTPUT`s proves multi-output execution.

### B4. Editor (`fbd_editor_screen.dart`)
- **Pins as dots:** render each block's input pins as labeled dots down the left
  edge and output pins down the right edge (names from the registry). A block
  with two outputs shows two right-edge dots (`Q`, `ET`).
- **Wiring:** tap an output dot → tap an input dot to create the wire (on
  desktop, drag from one to the other). Wires render as lines/curves between the
  connected dots. Tap a wire to select → delete. Connecting to an occupied input
  replaces its wire. Light type hint (bool vs numeric) shown as a colour/tooltip,
  not a hard block.
- **Extensible inputs:** for AND/OR/ADD/MUL a small +/- adjusts `inputCount`
  (2…8); pins and any now-orphaned wires update.
- **Config:** block tag binding uses the new `TagAutocompleteField` (A4); `CONST`
  value via text; delete block (removes its wires).
- **Canvas:** the block `Stack` sits in an `InteractiveViewer` (already added in
  WS5) for pan/zoom; wiring works within it. Desktop free-drag of blocks
  preserved.

### B5. Migration
Convert every default FBD diagram's block-to-block wires into pin-addressed
wires (map each old wire to the correct `fromPin`/`toPin` given the source's
single output and the target's pin order / next free input). Set `inputCount`
where a block currently relies on >2 wires into one operator. Prove
**scan-equivalence** (WS6 harness) so execution is byte-identical.

## Testing

- **A1/A2/A3:** widget tests at phone/desktop surface sizes — the LD toolbar no
  longer overflows when the *pane* is narrow (simulate a narrow LayoutBuilder
  constraint), the ladder is inside an `InteractiveViewer` on compact, the
  project `⋮` menu exposes all 7 actions and the CRUD `Wrap` is gone. No
  RenderFlex overflow at 360/320.
- **A4:** `TagAutocompleteField` filters options by typed text, allows free
  text, and writes the selection back; each of the 6 sites still binds its
  field (widget tests / no-overflow).
- **B (pins/exec):** pure tests — the pin registry returns correct in/out pins
  (incl. TON `Q`,`ET` and AND extensible counts); the executor reads inputs by
  pin, produces output-pin maps, TON/TOF `Q`/`ET` behave over scan ticks,
  fan-out works, cycles terminate. **Serialization round-trip + 20-scan
  scan-equivalence for every default project (unchanged behaviour) plus the new
  TON test diagram.**
- **B (editor):** widget tests — pins render (a two-output block shows two output
  dots), tap-out-then-tap-in creates a wire, tapping a wire deletes it,
  extensible +/- changes pin count, no overflow at phone widths.
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints (unchanged)

No third-party/reference-editor branding in any user-facing string/label/comment
/identifier (IEC-standard pin names `IN1`/`OUT`/`Q`/`ET`/`MN`/`MX` are fine).
Dark theme · width-based responsive (WS5), decisions inside embedded editors use
LOCAL width (`LayoutBuilder`), not window width · `flutter analyze` zero · no
RenderFlex overflow at 360/320/1400 · engines stay pure Dart in
`mobile/lib/models` · lossless persistence preserved (WS6 round-trip is the
guard for the FBD model change).

## Out of scope (deferred)

- EN/ENO execution-control pins; counters (CTU/CTD) execution (pin model can
  represent them, execution deferred like other stateful FBs beyond TON/TOF).
- Wire auto-routing/orthogonal paths (straight/curved lines are fine).
- Compile-to-ST/C (we interpret directly per ADR-009).
- LD/SFC pin editors (this workstream is FBD wiring + the four UX fixes).
