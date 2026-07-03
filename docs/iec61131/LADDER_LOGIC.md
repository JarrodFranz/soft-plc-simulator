# IEC 61131-3 Language Specification: Ladder Diagram (LD)

## Rung Structure & Instructions

Ladder Diagram programs consist of rungs connecting a left power rail to a right power rail.

### Supported Instructions
- **Examine Open (XIC / `-[ ]-`)**: Normally open contact. Passes power if tag is true.
- **Examine Closed (XIO / `-[/]-`)**: Normally closed contact. Passes power if tag is false.
- **Output Coil (OTE / `-( )-`)**: Sets target tag to current rung power state.
- **Set Coil (OTL / `-(S)-`)**: Sets target tag to true if rung power is true (Latches).
- **Reset Coil (OTU / `-(R)-`)**: Resets target tag to false if rung power is true (Unlatches).
- **Parallel Branches**: OR logic execution stack.
- **TON / TOF Timers**: Function block rungs.
