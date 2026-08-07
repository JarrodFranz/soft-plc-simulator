# IEC 61131-3 Language Specification: Ladder Diagram (LD)

## Rung Structure & Instructions

Ladder Diagram programs consist of rungs connecting a left power rail to a right power rail.

### Supported Instructions
- **Examine Open (XIC / `-[ ]-`)**: Normally open contact. Passes power if tag is true.
- **Examine Closed (XIO / `-[/]-`)**: Normally closed contact. Passes power if tag is false.
- **Rising/Falling Edge Contacts**: One-scan pulse contacts, conducting only on a
  false→true (rising) or true→false (falling) transition of the tag.
- **Output Coil (OTE / `-( )-`)**: Sets target tag to current rung power state.
- **Set Coil (OTL / `-(S)-`)**: Sets target tag to true if rung power is true (Latches).
- **Reset Coil (OTU / `-(R)-`)**: Resets target tag to false if rung power is true (Unlatches).
- **Negated / Rising / Falling Coils**: Write the inverse of rung power, or a
  one-scan pulse on rung-power's rising/falling edge, respectively.
- **Parallel Branches**: OR logic execution stack.
- **Timers — `TON` / `TOF` / `TP`**: Power-flow blocks; their done/output bit
  drives power downstream to any contact/coil chained after them.
- **Counters — `CTU` / `CTD` / `CTUD`**: Power-flow blocks (up, down, and
  up/down counters).
- **Compare Blocks — `GT` / `LT` / `GE` / `LE` / `EQ` / `NE`**: Power-flow-affecting,
  not transparent data blocks — the comparison result ANDs directly into the
  rung's power.
- **Math Blocks — `ADD` / `SUB` / `MUL` / `DIV`**: True data blocks, transparent
  to rung power flow; execute only while the rung is energized.
- **MOVE**: Copies a source value to a target tag; transparent data block, same
  as the math blocks above.
- **Custom Function Block Calls**: A placed instance of a project-defined FB,
  wired via `pinBindings`; transparent to rung power flow (never breaks the
  rung, regardless of its own outputs). See
  [FUNCTION_BLOCKS.md](FUNCTION_BLOCKS.md).
