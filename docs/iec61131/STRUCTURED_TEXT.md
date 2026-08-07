# IEC 61131-3 Language Specification: Structured Text (ST)

## Syntax & Features

Structured Text is a block-structured textual programming language.

```pascal
IF Start_PB AND NOT Stop_PB AND EStop_OK AND Overload_OK THEN
    Motor_Run := TRUE;
ELSIF Stop_PB OR NOT EStop_OK OR NOT Overload_OK THEN
    Motor_Run := FALSE;
END_IF;

// Read a timer's own output back into a tag - assignment only, no FB call
Timer_Done := TON_1.Q;
```

This engine's ST executor (`mobile/lib/models/st_exec.dart`) recognizes exactly
two statement shapes: `path := expr ;` and `IF ... THEN ... [ELSIF ... THEN
...] [ELSE ...] END_IF`. There is **no function-block-call statement syntax**
— a line like `TON_1(IN := Motor_Run, PT := T#5s, Q => Timer_Done);` is not
valid ST in this engine; it fails the assignment lookahead and is silently
skipped as an unrecognized statement. Instantiate and drive function blocks
(timers, counters, custom FBs) from **FBD** or **LD** instead, then read their
output members (`TON_1.Q`, `TON_1.ET`, …) from ST like any other struct-typed
tag. See [FUNCTION_BLOCKS.md](FUNCTION_BLOCKS.md) for where FB calls live.

### Supported Data Types
- `BOOL`, `INT16`, `INT32`, `FLOAT32`, `FLOAT64`, `STRING`, `TIME`
