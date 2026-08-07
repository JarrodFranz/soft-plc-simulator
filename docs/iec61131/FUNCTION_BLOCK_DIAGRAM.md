# IEC 61131-3 Specification: Function Block Diagram (FBD)

Function Block Diagram represents logic as interconnected graphical blocks with inputs on the left and outputs on the right (AND, OR, XOR, ADD, SUB, PID, TON, TOF).

## FBD import (PLCopen and Rockwell L5X → native FunctionBlockDiagram)

Imported FBD POUs translate per **network** (one native network per
weakly-connected component of the diagram, ordered top-to-bottom / left-to-right
by element position). A network translates fully or degrades to an empty network
with an explanatory comment plus a warning (faithful-or-stub).

| Source element | Native mapping |
| --- | --- |
| `<block>` (built-in `AND`/`OR`/`NOT`/`ADD`/…/`TON`/`CTU`/…) | `FbdBlock(type)`; extensible `inputCount` from wired `IN<n>` pins |
| `<block>` (custom FB, ST-bodied) | `FbdBlock(type = FB name, tagBinding = instance)` + struct-typed instance tag |
| `<inVariable>` (identifier) | `TAG_INPUT` bound to the tag |
| `<inVariable>` (literal `5`/`TRUE`) | `CONST` |
| `<outVariable>` (identifier) | `TAG_OUTPUT` bound to the tag |
| operand in `<expression>` | read the same as `<variable>` (identifier/literal only) |

Stubbed (whole network) — with the `stubReasons` key: `inOutVariable` /
`connector` / `continuation` / `label` / `jump` (`unsupported-element`);
negated pins (`negated-pin`); compound `<expression>` (`complex-expression`);
unknown block type (`unsupported-block`); a wire to an unknown pin
(`unresolved-pin`).

Proven end-to-end (parse → map → translate → execute), including a
cross-network tag hop and a custom-FB call routed to an instance, in
`mobile/test/import/import_fbd_e2e_test.dart`.

### L5X (Rockwell) FBD import

An L5X `<Routine Type="FBD">`'s `<FBDContent><Sheet>` elements parse into the
same neutral `GraphBody` the PLCopen path produces, then run through the same
`translateFbdBody` — per-network faithful-or-stub, unchanged. Getting there
needs a Rockwell-specific front end: element mapping, type/pin aliasing, and
multi-sheet merge.

**Element mapping**

| Source element | Native mapping |
| --- | --- |
| `IRef` | `inVariable` |
| `ORef` | `outVariable` |
| `Block` / `Function` | block (Rockwell type aliased to IEC where mapped — see below) |
| `AddOnInstruction` | block (custom-FB call; name is **never** aliased) |
| `Wire` / `FeedbackWire` | connection |
| `ICon` / `OCon` | resolved to the matching producer/consumer at parse time (name-based, routine-wide) |
| `TextBox` / `Attachment` | ignored (dropped; one info warning per routine counting how many) |
| anything else with an `ID` | kept as an opaque, unmapped node so its network stubs visibly instead of silently vanishing (covers `JSR`/`SBR`/`Ret` and other execution-control elements) |

**Type aliases** (Rockwell mnemonic → IEC block type): `EQU`→`EQ`, `NEQ`→`NE`,
`GEQ`→`GE`, `LEQ`→`LE`, `GRT`→`GT`, `LES`→`LT`, `BAND`→`AND`, `BOR`→`OR`,
`BNOT`→`NOT`. Best-effort (approximate, with a prominent verify warning):
`TONR`→`TON`, `TOFR`→`TOF` (retentive accumulation and the `Reset` pin are not
modeled), `OSRI`→`R_TRIG`, `OSFI`→`F_TRIG`.

**Pin aliases** (keyed by the Rockwell type, since Rockwell wires carry
Rockwell pin names that don't match the IEC registry): `SourceA`/`SourceB`/
`Dest` → `IN1`/`IN2`/`OUT` for math and compare blocks; `In<k>`/`Out` →
`IN<k>`/`OUT` for `BAND`/`BOR`; `In`/`Out` → `IN`/`OUT` for `BNOT`;
`TimerEnable`/`PRE`/`DN`/`ACC` → `IN`/`PT`/`Q`/`ET` for `TONR`/`TOFR`;
`SelectorIn`/`In1`/`In2`/`Out` → `G`/`IN0`/`IN1`/`OUT` for `SEL` (Logix's
`Out = SelectorIn ? In2 : In1` maps onto IEC `OUT = G ? IN1 : IN0`);
`CUEnable`/`CDEnable`/`Reset`/`Load`/`PRE`/`ACC`/`DN` → `CU`/`CD`/`R`/`LD`/
`PV`/`CV`/`QU` for `CTUD`; `InputBit`/`OutputBit` → `CLK`/`Q` for
`OSRI`/`OSFI`. An unmapped pin passes through verbatim and, since it won't
match the IEC registry, stubs that network.

**Multi-sheet merge**: all of a routine's `<Sheet>` elements merge into one
body, in ascending `<Sheet Number>` order. Every sheet after the first gets
its element ids offset (so ids never collide across sheets) and its Y
coordinate offset (so network numbering reads sheet-by-sheet, top to bottom,
in source order) rather than overlapping the previous sheet's layout.

**What stubs** (in addition to the PLCopen reasons above): an unmapped block
type (e.g. `SCL`, `PIDE`, `MOV`, `MOD`, `ESEL`); an unmapped pin; a *wired*
`EnableIn`/`EnableOut` pin on a block (built-in-aliased or an AOI call — the
block it maps to has no such pin); an unmatched `ICon`/`OCon` connector; a
malformed/non-numeric `ID`; more than one wire driving the same input pin;
and a dotted/member operand (`Timer1.DN`) on an `IRef`/`ORef`.

See `docs/import/L5X.md`'s "FBD routines translate" and "FBD-Logic AOIs
execute" sections, and `mobile/test/import/import_l5x_aoi_fbd_e2e_test.dart`
for the end-to-end proof.
