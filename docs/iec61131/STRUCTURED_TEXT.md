# IEC 61131-3 Language Specification: Structured Text (ST)

## Syntax & Features

Structured Text is a block-structured textual programming language.

```pascal
IF Start_PB AND NOT Stop_PB AND EStop_OK AND Overload_OK THEN
    Motor_Run := TRUE;
ELSIF Stop_PB OR NOT EStop_OK OR NOT Overload_OK THEN
    Motor_Run := FALSE;
END_IF;

// Timer instantiation
TON_1(IN := Motor_Run, PT := T#5s, Q => Timer_Done);
```

### Supported Data Types
- `BOOL`, `INT16`, `INT32`, `FLOAT32`, `FLOAT64`, `STRING`, `TIME`
