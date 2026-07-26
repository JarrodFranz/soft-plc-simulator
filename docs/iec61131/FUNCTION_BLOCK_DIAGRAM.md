# IEC 61131-3 Specification: Function Block Diagram (FBD)

Function Block Diagram represents logic as interconnected graphical blocks with inputs on the left and outputs on the right (AND, OR, XOR, ADD, SUB, PID, TON, TOF).

## FBD import (PLCopen → native FunctionBlockDiagram)

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
