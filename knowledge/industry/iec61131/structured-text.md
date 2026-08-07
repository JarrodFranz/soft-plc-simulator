---
id: knowledge:industry/iec61131/structured-text
title: Structured Text
domain: industry/iec61131
version: "2026-08"
topics: [structured-text, st, iec-61131-3, expression-grammar, statements, scan-order]
summary: Documents IEC 61131-3 Structured Text as a portable language plus this engine's exact executable subset (assignment and IF/ELSIF/ELSE only, no loops, no FB-call syntax, strict expression grammar with silent-null error propagation), verified directly against the ST/expression parsers.
related:
  - knowledge:industry/iec61131/index
  - knowledge:industry/iec61131/function-block-diagram
  - knowledge:industry/iec61131/ladder-diagram
  - knowledge:industry/iec61131/custom-function-blocks
---

# Structured Text

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from IEC 61131-3's ST language concept and the engine's ST/expression
> parsers, `mobile/lib/models/st_exec.dart` and `mobile/lib/models/st_expr.dart`.
> **Read this before:** writing or reviewing any ST program body, importing a `<ST>`/`<IL>` POU,
> writing an SFC transition/action condition (shares the same expression engine), or debugging a
> "my assignment didn't happen" report.

---

## 1. The headline rule

**This engine's ST subset is assignment and `IF/ELSIF/ELSE/END_IF` only - no `CASE`, `FOR`,
`WHILE`, `REPEAT`, `EXIT`, `RETURN`, and no function-block call syntax.**

The standard's ST is a full imperative language: iteration constructs, `CASE` selection, early
exit, and direct FB invocation (`TON_1(IN := x, PT := t, Q => y)`) are all legal IEC 61131-3 ST.
This app's `st_exec.dart` tokenizer recognizes exactly two statement shapes - `path := expr ;`
and `IF ... THEN ... [ELSIF ... THEN ...] [ELSE ...] END_IF` - via `_stKeywords =
{'IF','THEN','ELSIF','ELSE','END_IF'}`. Anything else (a `FOR` loop, a bare FB call) is not a
keyword the parser knows, fails the assignment lookahead (`toks[pos+1].kind == 'assign'`), and
falls into the unrecognized-statement branch, which **silently skips** it rather than raising an
error.

```st
(* Wrong - this looks like valid IEC ST, and IS valid IEC ST, but this engine drops it *)
FOR i := 1 TO 10 DO
  Total := Total + i;
END_FOR;

(* Correct - the app's ST subset: assignment + IF/ELSIF/ELSE only *)
IF Enable THEN
  Total := Total + Step;
END_IF;
```

Forward progress on an unrecognized statement is guaranteed structurally, not by a caught
exception: `_parseStatement` unconditionally advances at least one token and calls
`_skipToStatementEnd()` before continuing, which is also *how* "never throws" is enforced for
malformed ST across the whole engine.

---

## 2. Expression grammar (shared with SFC transitions/actions)

`st_expr.dart` implements one recursive-descent expression grammar, consumed both by ST programs
and by every SFC transition condition / step action (see
[sequential-function-chart.md](./sequential-function-chart.md)). Precedence, low to high:

| Level | Operators | Notes |
|---|---|---|
| 1 | `OR` | |
| 2 | `XOR` | |
| 3 | `AND` | |
| 4 | `NOT` | unary, binds tighter than AND/OR/XOR, looser than comparison |
| 5 | `=`, `<>`, `<`, `>`, `<=`, `>=` | **single-level, non-chaining** - `a < b < c` does not parse the way it reads |
| 6 | `+`, `-` | binary, left-associative |
| 7 | `*`, `/` | |
| 8 | unary `-` | |
| 9 | primary | numeric literal, `TRUE`/`FALSE`, identifier/tag-path, `(expr)` |

Not implemented at all: exponentiation (`**`), string concatenation, `MOD`. The standard's `TIME`
literal syntax (`T#5s`) also has **no lexer support** in either `st_exec.dart` or `st_expr.dart` -
a `#` character is an unrecognized token and the lex fails at that point. `T#`-literal parsing
exists only in the import path (`parseIecDuration` in `mobile/lib/import/ld_translate.dart`),
never in the live ST/expression engine.

```st
(* Wrong - reads like a chained inequality, but _cmp is single-level: this fails to parse *)
IF Low < Level < High THEN ...

(* Correct - the app's subset requires an explicit AND *)
IF Low < Level AND Level < High THEN ...
```

---

## 3. Data types and array/struct paths

Type-driven behavior in the engine is thin: `tag_resolver.dart`'s `_intTypes = ['INT16', 'INT32',
'INT64']` is the only branch that changes runtime behavior (integer truncation on write); `BOOL`,
`FLOAT32`/`FLOAT64`, and `STRING` are otherwise opaque `dynamic` values with no special-cased
coercion. Dotted (`Struct.Field`) and bracketed (`Array[0]`) path segments are lexed as a single
identifier run by both `st_exec.dart` and `st_expr.dart`'s tokenizers, and resolved by
`tag_resolver.dart`'s `readPath`/`writePath` - not by the ST parser itself.

**Integer truncation is a root-tag-only check.** `writePath`'s decision to truncate is keyed off
the *top-level* tag name (`_rootTagOf`), not the actual declared type of the member being written
- documented in `ld_exec.dart`'s MOVE-block comment as applying project-wide, ST included, via the
shared `_forceAwareWrite`/`writePath` path.

---

## 4. EN/ENO - not implemented

Neither `st_exec.dart` nor `st_expr.dart` has any concept of `EN`/`ENO` pins or a
conditional-execution gate beyond plain `IF`. This is consistent with FB calls having no home in
ST at all (§5) - there is no call-site syntax to attach `EN`/`ENO` to in the first place.

---

## 5. FB-call syntax does not exist in ST - doc/code contradiction found

**A block with `<functionblock>(IN := x, ...)` call syntax is not parseable ST in this engine, in
any form.** `_parseStatement` recognizes only `path := expr ;` and `IF...`; a line shaped like
`TON_1(IN := Motor_Run, PT := T#5s, Q => Timer_Done)` fails the assignment lookahead (the token
right after the leading identifier is `(`, not `:=`) and is silently dropped as an unrecognized
statement (§1).

Custom and built-in function blocks are called from **FBD** (a block dropped on the canvas,
auto-bound to an instance tag) or from **LD** (`pinBindings` on a block node) - never from an ST
program body. See [custom-function-blocks.md](./custom-function-blocks.md) and
[function-block-diagram.md](./function-block-diagram.md).

> **Documentation contradiction found (report this if you own `docs/iec61131/STRUCTURED_TEXT.md`):**
> that file's own code sample shows `TON_1(IN := Motor_Run, PT := T#5s, Q => Timer_Done);` as if it
> were valid ST executed by this engine. It is not - the ST parser has no call-statement grammar,
> and the doc's own sibling file `FUNCTION_BLOCKS.md` states the opposite directly: *"ST has no
> FB-call syntax in the app's subset, so the call lives in FBD."* The code (`st_exec.dart`) sides
> with `FUNCTION_BLOCKS.md`. The ST doc's sample is not executable as written and should be
> corrected or removed at the source.

---

## 6. Error and edge-case handling - silent-null propagation, never throws

| Situation | Behavior | Evidence |
|---|---|---|
| Division by zero | `_mul()` returns `null` for the whole expression rather than raising | `st_expr.dart`: `left = right == 0 ? null : left / right;` |
| Assignment whose RHS evaluated to `null` | Skipped - target tag's previous value is left unchanged | `st_exec.dart` `_execBlock`: `if (v != null) { ...write... }` |
| Comparison of non-`num`/non-`bool` operands (e.g. two `STRING`s) | Evaluates `false`, not an error | `evalStCondition` only handles `bool`/`num`, everything else `return false` |
| Arithmetic on a non-`num` operand | Whole expression collapses to `null` | `_add`/`_mul` require both operands `num` |
| Unresolvable tag path | Reads as `null` | flows into the same null-propagation chain above |
| Unterminated `(* ... *)` block comment | Silently drops the remainder of the source | shared `stripStComments` in `st_expr.dart` |

There is **no implicit bool-to-num or string-to-num coercion anywhere** in the expression engine -
a type mismatch degrades to `null`/`false`, never a runtime error, never a best-effort coercion.

```st
(* Wrong assumption - "comparing a STRING tag to a number coerces or errors" *)
IF StatusText > 0 THEN ...   (* evaluates to false: string is not num, _cmp returns null -> false *)

(* Correct - compare like types *)
IF StatusCode > 0 THEN ...
```

---

## 7. Scan-cycle evaluation order

Within one due task, `scan_tick.dart`'s `runScanTick` executes the four language engines in a
**fixed cross-language order**, independent of program declaration order in the project:

```
executeLdPrograms  ->  executeFbdPrograms  ->  executeSfcPrograms  ->  executeStPrograms
```

Practical consequence: an LD program's writes this scan are visible to an ST program's reads in
the *same* scan (LD runs first). An ST program's writes are **not** visible to that task's
LD/FBD/SFC programs until the *next* scan tick (ST runs last). Within `executeStPrograms` itself,
programs run in project list order and, within one program, statements execute top-to-bottom with
first-true-branch-wins `IF`/`ELSIF` semantics (exactly one branch, or `ELSE`, executes).

---

## What this means practically

### "Why did my `TON_1(...)` line in an ST program do nothing?"
It parsed as an unrecognized statement and was silently skipped - this engine's ST has no
call-statement grammar. Move the timer instantiation into FBD or LD (§5).

### "Why does my tag keep its old value after a division?"
The RHS evaluated to `null` (division by zero, or a non-numeric operand upstream), and a `null`
RHS skips the assignment rather than writing zero or raising an error (§6).

### "Why doesn't my ST write show up in the LD rung I expect it to feed, this same scan?"
ST runs last in the per-task engine order (§7). An ST-authored write is visible to LD/FBD/SFC only
starting the *next* scan tick.

### "Why did `FOR`/`CASE`/`WHILE` in my imported ST program silently vanish?"
They aren't statement shapes the parser recognizes at all; per-statement, the parser guarantees
forward progress by skipping anything it can't parse rather than failing the whole program (§1).

---

## Related

- [function-block-diagram.md](./function-block-diagram.md) - where FB calls actually live, and the shared network dataflow model.
- [ladder-diagram.md](./ladder-diagram.md) - the other place FB calls live (`pinBindings`), and the LD power-flow model.
- [sequential-function-chart.md](./sequential-function-chart.md) - consumes this same expression grammar for transition conditions and step actions.
- [custom-function-blocks.md](./custom-function-blocks.md) - ST-bodied FB definitions and their scoping.
- [index.md](./index.md) - domain hub.
