# L5X RLL Ladder Compiler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compile imported L5X RLL routines (Rockwell neutral-text ladder) into real executable native `LadderLogic` programs.

**Architecture:** The L5X parser captures each RLL rung's text into a new `NeutralLadderBody` IR; a new pure `compileRllRungs` (`lib/import/rll_compile.dart`) tokenizes each rung's neutral text into an instruction/branch AST, maps instructions to `LdNode`s, and assembles rungs via the existing `buildRung`/`BranchSpec`. The mapper (`ir_to_project.dart`) gets a `body is NeutralLadderBody` arm; AOI calls reuse the shipped LD FB-call path. Faithful-or-stub per rung.

**Tech Stack:** Dart (Flutter package `soft_plc_mobile`, in `mobile/`). Pure Dart, no new dependencies. Run all `flutter` commands from `mobile/`; `flutter` is at `/c/flutter/bin/flutter`.

## Global Constraints

- Pure Dart, in-app (ADR-010). Deterministic. **Never-throws** — a rung that can't compile degrades to a placeholder; the pipeline continues. The internal `_RllStub` (per-rung control flow) and the public `RllParseException` (tokenizer) are both always caught inside `compileRllRungs`.
- `rll_compile.dart` is Flutter-free pure Dart (imports `project_model.dart` / `ld_graph.dart` / `import_ir.dart` only). The `xml` package stays confined to `l5x_parser.dart`.
- Zero `flutter analyze` warnings (run from `mobile/`).
- **Additive / backward-compatible:** PLCopen import and the L5X foundation's tag/UDT/AOI/ST behavior are unchanged; only the RLL routine arm changes from stub to compile. Whole suite stays green.
- **Faithful-or-stub per rung**, with one flagged exception: a timer/counter whose preset can't be resolved compiles with a defaulted preset + a prominent warning (never silent).
- **Strict AOI binding:** an AOI call routes only when its arg count matches the AOI interface; else the rung stubs.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

- **Modify** `mobile/lib/import/import_ir.dart` — `RllRung` + `NeutralLadderBody`.
- **Modify** `mobile/lib/import/l5x_parser.dart` — `_l5xRoutines` RLL arm captures rung text.
- **Create** `mobile/lib/import/rll_compile.dart` — tokenizer (Task 2) + compiler (Tasks 3–4).
- **Modify** `mobile/lib/import/ir_to_project.dart` — `NeutralLadderBody` arm (stub in Task 1, compile in Task 5) + report fields.
- **Modify** `mobile/lib/screens/import_xml_preview.dart` — RLL counts.
- **Create/Modify tests** under `mobile/test/import/`.
- **Modify docs** `docs/import/L5X.md`, `docs/DEFERRED.md`.

---

### Task 1: `NeutralLadderBody` IR + parser capture + behavior-preserving mapper arm

**Files:**
- Modify: `mobile/lib/import/import_ir.dart`
- Modify: `mobile/lib/import/l5x_parser.dart` (`_l5xRoutines`, the `case 'RLL':` arm ~lines 267-277)
- Modify: `mobile/lib/import/ir_to_project.dart` (add a `body is NeutralLadderBody` stub arm)
- Test: `mobile/test/import/l5x_parser_test.dart`

**Interfaces:**
- Produces: `RllRung{int number; String text; String comment}` and `NeutralLadderBody extends PouBody {List<RllRung> rungs}` in `import_ir.dart`. After this task, an RLL routine parses into a `NeutralLadderBody` carrying each rung's neutral text + comment, and the mapper keeps emitting the same whole-POU LD stub (behavior-preserving).

- [ ] **Step 1: Add the IR types**

Append to `mobile/lib/import/import_ir.dart` (after `GraphBody`):

```dart
class RllRung {
  final int number;
  final String text;     // neutral-text ladder, e.g. 'XIC(Start)OTE(Motor)'
  final String comment;
  RllRung({required this.number, required this.text, this.comment = ''});
}

class NeutralLadderBody extends PouBody {
  final List<RllRung> rungs;
  NeutralLadderBody({required this.rungs});
}
```

- [ ] **Step 2: Write the failing parser test**

Add to `mobile/test/import/l5x_parser_test.dart`:

```dart
  test('RLL routine parses into a NeutralLadderBody with rung text + comments', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0" Type="N"><Comment><![CDATA[start it]]></Comment><Text><![CDATA[XIC(Start)OTE(Motor);]]></Text></Rung>
        <Rung Number="1" Type="N"><Text><![CDATA[NOP();]]></Text></Rung>
      </RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final pou = ir.pous.firstWhere((p) => p.name == 'Main_Logic');
    expect(pou.lang, PouLanguage.ld);
    final body = pou.body as NeutralLadderBody;
    expect(body.rungs, hasLength(2));
    expect(body.rungs[0].text, 'XIC(Start)OTE(Motor);');
    expect(body.rungs[0].comment, 'start it');
    expect(body.rungs[1].text, 'NOP();');
  });
```

- [ ] **Step 3: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart`
Expected: FAIL — `pou.body` is a `GraphBody`, not `NeutralLadderBody`.

- [ ] **Step 4: Capture RLL rung text in the parser**

In `mobile/lib/import/l5x_parser.dart`, replace the `case 'RLL':` arm of `_l5xRoutines`:

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

(The FBD/SFC arms are unchanged.) Update the function's doc comment above it to say RLL is now captured as a `NeutralLadderBody`.

- [ ] **Step 5: Add a behavior-preserving `NeutralLadderBody` stub arm in the mapper**

RLL POUs no longer match `body is GraphBody && pou.lang == ld`, so without a new arm they vanish. In `mobile/lib/import/ir_to_project.dart`, add — immediately AFTER the FBD arm (`} else if (body is GraphBody && pou.lang == PouLanguage.fbd) { … }`, ~line 329) and BEFORE the `body is SfcBody` arm:

```dart
    } else if (body is NeutralLadderBody) {
      // RLL whole-POU stub (compiler wired in a later task). Unchanged
      // behaviour: an RLL routine imports as a stub LadderLogic program.
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'POU "${pou.name}" (Ladder): ${body.rungs.length} rungs not yet '
              'compiled — neutral-text ladder import ships in a later update.'));
      programs.add(PlcProgram(name: pou.name, language: 'LadderLogic',
          description: 'Neutral-text ladder not yet compiled (${body.rungs.length} rungs captured).'));
      stubCount++;
    } else if (body is SfcBody) {
```

- [ ] **Step 6: Run to verify passing + import suite**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/l5x_parser_test.dart && /c/flutter/bin/flutter test test/import/ && /c/flutter/bin/flutter analyze`
Expected: PASS; no analyzer issues. RLL POUs still import as LD stub programs (graphicalStubCount unchanged); no existing test regresses.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/import/import_ir.dart mobile/lib/import/l5x_parser.dart mobile/lib/import/ir_to_project.dart mobile/test/import/l5x_parser_test.dart
git commit -m "feat(import): NeutralLadderBody IR + L5X RLL text capture

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: RLL tokenizer / parser

**Files:**
- Create: `mobile/lib/import/rll_compile.dart`
- Test: `mobile/test/import/rll_parse_test.dart` (create)

**Interfaces:**
- Produces: the AST — `sealed class RllElement`, `RllInstruction{String mnemonic; List<String> operands}`, `RllBranch{List<List<RllElement>> legs}` — and `List<RllElement> parseRllText(String text)` which tokenizes a rung's neutral text (trailing `;` and whitespace tolerated), throwing `RllParseException{String message}` on malformed input. Consumed by the compiler (Task 3).

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/import/rll_parse_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/rll_compile.dart';

void main() {
  test('parses a simple series with a branch', () {
    final els = parseRllText('XIC(A)[XIC(B),XIC(C)]OTE(D);');
    expect(els, hasLength(3));
    expect((els[0] as RllInstruction).mnemonic, 'XIC');
    expect((els[0] as RllInstruction).operands, ['A']);
    final br = els[1] as RllBranch;
    expect(br.legs, hasLength(2));
    expect((br.legs[0].single as RllInstruction).operands, ['B']);
    expect((br.legs[1].single as RllInstruction).operands, ['C']);
    expect((els[2] as RllInstruction).mnemonic, 'OTE');
  });

  test('branch legs are multi-instruction; commas inside args and [] subscripts are respected', () {
    final els = parseRllText(
        '[N_ETHMACtoStr(inst,Sys.List[0].PhysicalAddress,0,Str) MOVE(Str,Str) , '
        'N_ETHMACtoStr(inst,Sys.List[0].PhysicalAddress,1,S1) MOVE(S1,S1)]');
    final br = els.single as RllBranch;
    expect(br.legs, hasLength(2));
    final leg0 = br.legs[0];
    expect(leg0, hasLength(2)); // AOI call + MOVE
    final aoi = leg0[0] as RllInstruction;
    expect(aoi.mnemonic, 'N_ETHMACtoStr');
    // 4 operands: instance, dotted/array path, literal 0, dest
    expect(aoi.operands, ['inst', 'Sys.List[0].PhysicalAddress', '0', 'Str']);
    expect((leg0[1] as RllInstruction).mnemonic, 'MOVE');
  });

  test('no-arg instruction', () {
    final els = parseRllText('NOP();');
    expect((els.single as RllInstruction).mnemonic, 'NOP');
    expect((els.single as RllInstruction).operands, isEmpty);
  });

  test('unbalanced bracket throws RllParseException', () {
    expect(() => parseRllText('XIC(A'), throwsA(isA<RllParseException>()));
    expect(() => parseRllText('[XIC(A)'), throwsA(isA<RllParseException>()));
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/rll_parse_test.dart`
Expected: FAIL — `rll_compile.dart` / `parseRllText` do not exist (compile error).

- [ ] **Step 3: Implement the tokenizer**

Create `mobile/lib/import/rll_compile.dart`:

```dart
import '../models/project_model.dart';
import '../models/ld_graph.dart';
import 'import_ir.dart';

/// One element of a parsed RLL rung: an instruction or a parallel branch group.
sealed class RllElement {}

class RllInstruction extends RllElement {
  final String mnemonic;
  final List<String> operands;
  RllInstruction(this.mnemonic, this.operands);
}

class RllBranch extends RllElement {
  final List<List<RllElement>> legs;
  RllBranch(this.legs);
}

/// Thrown by [parseRllText] on malformed neutral text. Always caught inside
/// [compileRllRungs] (a parse error degrades that rung to a placeholder).
class RllParseException implements Exception {
  final String message;
  RllParseException(this.message);
  @override
  String toString() => 'RllParseException: $message';
}

class _Cursor {
  final String s;
  int i = 0;
  _Cursor(this.s);
}

bool _isIdent(String ch) =>
    RegExp(r'[A-Za-z0-9_]').hasMatch(ch);

void _skipWs(_Cursor c) {
  while (c.i < c.s.length && (c.s[c.i] == ' ' || c.s[c.i] == '\t' ||
      c.s[c.i] == '\n' || c.s[c.i] == '\r')) {
    c.i++;
  }
}

/// Tokenizes a rung's neutral text into a top-level element sequence. A trailing
/// `;` and inter-instruction whitespace are tolerated. Throws
/// [RllParseException] on unbalanced brackets or a missing/empty instruction.
List<RllElement> parseRllText(String text) {
  var t = text.trim();
  if (t.endsWith(';')) t = t.substring(0, t.length - 1);
  final c = _Cursor(t);
  final els = _parseSeq(c);
  _skipWs(c);
  if (c.i != c.s.length) {
    throw RllParseException('unexpected "${c.s[c.i]}" at ${c.i}');
  }
  return els;
}

/// Parses a sequence of elements, stopping at a top-level ',' or ']'.
List<RllElement> _parseSeq(_Cursor c) {
  final out = <RllElement>[];
  while (c.i < c.s.length) {
    _skipWs(c);
    if (c.i >= c.s.length) break;
    final ch = c.s[c.i];
    if (ch == ',' || ch == ']') break;
    if (ch == '[') {
      out.add(_parseBranch(c));
    } else {
      out.add(_parseInstr(c));
    }
  }
  return out;
}

RllBranch _parseBranch(_Cursor c) {
  c.i++; // consume '['
  final legs = <List<RllElement>>[_parseSeq(c)];
  while (c.i < c.s.length && c.s[c.i] == ',') {
    c.i++; // consume ','
    legs.add(_parseSeq(c));
  }
  if (c.i >= c.s.length || c.s[c.i] != ']') {
    throw RllParseException('unclosed branch "["');
  }
  c.i++; // consume ']'
  return RllBranch(legs);
}

RllInstruction _parseInstr(_Cursor c) {
  final start = c.i;
  while (c.i < c.s.length && _isIdent(c.s[c.i])) {
    c.i++;
  }
  final mnemonic = c.s.substring(start, c.i);
  if (mnemonic.isEmpty) {
    throw RllParseException('expected an instruction at ${c.i}');
  }
  _skipWs(c);
  if (c.i >= c.s.length || c.s[c.i] != '(') {
    throw RllParseException('expected "(" after "$mnemonic"');
  }
  c.i++; // consume '('
  final operands = _parseArgs(c);
  return RllInstruction(mnemonic, operands);
}

/// Reads to the matching ')', splitting on top-level ',' (respecting nested
/// () and []). '(' must have been consumed by the caller.
List<String> _parseArgs(_Cursor c) {
  final args = <String>[];
  final buf = StringBuffer();
  var paren = 0, brack = 0;
  var closed = false;
  while (c.i < c.s.length) {
    final ch = c.s[c.i];
    if (ch == ')' && paren == 0 && brack == 0) {
      c.i++;
      closed = true;
      break;
    }
    if (ch == ',' && paren == 0 && brack == 0) {
      args.add(buf.toString().trim());
      buf.clear();
      c.i++;
      continue;
    }
    if (ch == '(') paren++;
    if (ch == ')') paren--;
    if (ch == '[') brack++;
    if (ch == ']') brack--;
    buf.write(ch);
    c.i++;
  }
  if (!closed) throw RllParseException('unclosed "("');
  final last = buf.toString().trim();
  if (last.isNotEmpty || args.isNotEmpty) args.add(last);
  return args;
}
```

- [ ] **Step 4: Run to verify passing**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/rll_parse_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues. (`project_model.dart`/`ld_graph.dart` are imported now but only used by the compiler added in Task 3; if analyze flags them as unused imports here, keep them and add the compiler in Task 3 in the same file — OR add `// ignore: unused_import` and remove it in Task 3. Prefer keeping them; the compiler lands next.)

```bash
git add mobile/lib/import/rll_compile.dart mobile/test/import/rll_parse_test.dart
git commit -m "feat(import): RLL neutral-text tokenizer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: RLL compiler core (instructions + rung assembly, no AOI)

**Files:**
- Modify: `mobile/lib/import/rll_compile.dart`
- Test: `mobile/test/import/rll_compile_test.dart` (create)

**Interfaces:**
- Consumes: `parseRllText`/AST (Task 2); `LdNode`/`LdKind`/`LdRung`/`LdWire`/`FbDefinition` (`project_model.dart`); `buildRung`/`BranchSpec`/`kLeftRailId`/`kRightRailId` (`ld_graph.dart`); `ImportWarning`/`WarningSeverity`/`NeutralLadderBody`/`RllRung` (`import_ir.dart`).
- Produces:
  ```dart
  class RllTranslation {
    final List<LdRung> rungs;
    final int translatedRungCount;
    final int stubbedRungCount;
    final Set<String> unsupportedInstructions;
    final Map<String, int> stubReasons;
    final List<ImportWarning> warnings;
    RllTranslation({ ...all required... });
  }
  RllTranslation compileRllRungs(NeutralLadderBody body, {
    required String pouName,
    Map<String, FbDefinition> fbRegistry = const {},
    Map<String, String> fbRenameMap = const {},
  });
  ```
  Task 3 handles contacts/coils/compare/math/MOV/timers/counters + single-level branches; an AOI call (or any unknown mnemonic) stubs its rung (Task 4 adds AOI routing).

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/import/rll_compile_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/rll_compile.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

NeutralLadderBody _body(List<String> texts) => NeutralLadderBody(
    rungs: [for (var i = 0; i < texts.length; i++) RllRung(number: i, text: texts[i])]);

void main() {
  test('contacts + coil compile to a series rung', () {
    final tr = compileRllRungs(_body(['XIC(A)XIO(B)OTE(C);']), pouName: 'P');
    expect(tr.translatedRungCount, 1);
    final nodes = tr.rungs.single.nodes;
    final a = nodes.firstWhere((n) => n.variable == 'A');
    expect(a.kind, LdKind.contact);
    expect(a.modifier, 'normal');
    expect(nodes.firstWhere((n) => n.variable == 'B').modifier, 'negated');
    final c = nodes.firstWhere((n) => n.variable == 'C');
    expect(c.kind, LdKind.coil);
    expect(c.modifier, 'normal');
  });

  test('OTL/OTU -> set/reset coils', () {
    final tr = compileRllRungs(_body(['OTL(A);', 'OTU(B);']), pouName: 'P');
    expect(tr.rungs[0].nodes.firstWhere((n) => n.variable == 'A').modifier, 'set');
    expect(tr.rungs[1].nodes.firstWhere((n) => n.variable == 'B').modifier, 'reset');
  });

  test('branch -> parallel lanes', () {
    final tr = compileRllRungs(_body(['XIC(A)[XIC(B),XIC(C)]OTE(D);']), pouName: 'P');
    expect(tr.translatedRungCount, 1);
    final rows = tr.rungs.single.nodes.map((n) => n.row).toSet();
    expect(rows.contains(1), isTrue); // a parallel lane exists
  });

  test('compare / math / MOV blocks', () {
    final tr = compileRllRungs(
        _body(['EQU(x,y)OTE(f);', 'ADD(a,b,d);', 'MOV(s,t);']), pouName: 'P');
    final eq = tr.rungs[0].nodes.firstWhere((n) => n.blockType == 'EQ');
    expect(eq.operandA, 'x');
    expect(eq.operandB, 'y');
    final add = tr.rungs[1].nodes.firstWhere((n) => n.blockType == 'ADD');
    expect(add.operandA, 'a');
    expect(add.operandB, 'b');
    expect(add.variable, 'd');
    final mov = tr.rungs[2].nodes.firstWhere((n) => n.blockType == 'MOVE');
    expect(mov.operandA, 's');
    expect(mov.variable, 't');
  });

  test('timer with literal preset is exact; with ? preset defaults + warns', () {
    final tr = compileRllRungs(_body(['TON(T1,5000,0);', 'TON(T2,?,?);']), pouName: 'P');
    expect(tr.translatedRungCount, 2); // both translate (best-effort)
    expect(tr.rungs[0].nodes.firstWhere((n) => n.blockType == 'TON').presetMs, 5000);
    expect(tr.warnings.any((w) => w.message.contains('T2') && w.message.contains('preset')), isTrue);
  });

  test('NOP -> empty valid rung', () {
    final tr = compileRllRungs(_body(['NOP();']), pouName: 'P');
    expect(tr.translatedRungCount, 1);
  });

  test('RTO + unknown mnemonic + nested branch stub their rung', () {
    final tr = compileRllRungs(
        _body(['RTO(T,?,?);', 'FOO(A);', 'XIC(A)[[XIC(B)],XIC(C)]OTE(D);']), pouName: 'P');
    expect(tr.translatedRungCount, 0);
    expect(tr.stubbedRungCount, 3);
    expect(tr.stubReasons['unsupported-instruction'], 2); // RTO + FOO
    expect(tr.stubReasons['complex-topology'], 1);        // nested branch
    expect(tr.unsupportedInstructions, containsAll(['RTO', 'FOO']));
    // placeholder rungs preserve numbering
    expect(tr.rungs, hasLength(3));
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/rll_compile_test.dart`
Expected: FAIL — `compileRllRungs` / `RllTranslation` do not exist.

- [ ] **Step 3: Implement the compiler core**

Append to `mobile/lib/import/rll_compile.dart`:

```dart
class RllTranslation {
  final List<LdRung> rungs;
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedInstructions;
  final Map<String, int> stubReasons;
  final List<ImportWarning> warnings;
  RllTranslation({
    required this.rungs,
    required this.translatedRungCount,
    required this.stubbedRungCount,
    required this.unsupportedInstructions,
    required this.stubReasons,
    required this.warnings,
  });
}

/// Per-rung bail-out; always caught in [compileRllRungs].
class _RllStub implements Exception {
  final String reason;
  final String detail;
  _RllStub(this.reason, this.detail);
}

/// Compiles a [NeutralLadderBody] into native `LdRung`s. Each rung compiles
/// fully or degrades to a commented placeholder rung (rung index preserved).
/// The one non-stub degrade is a timer/counter with an unresolvable preset
/// (defaulted + warning). Pure, deterministic, never-throws.
RllTranslation compileRllRungs(
  NeutralLadderBody body, {
  required String pouName,
  Map<String, FbDefinition> fbRegistry = const {},
  Map<String, String> fbRenameMap = const {},
}) {
  final rungs = <LdRung>[];
  final warnings = <ImportWarning>[];
  final unsupported = <String>{};
  final reasons = <String, int>{};
  var translated = 0;
  var stubbed = 0;

  for (var i = 0; i < body.rungs.length; i++) {
    final rr = body.rungs[i];
    try {
      final els = parseRllText(rr.text);
      rungs.add(_assembleRung(els, i, rr.comment, unsupported, fbRegistry,
          fbRenameMap, warnings));
      translated++;
    } on RllParseException catch (e) {
      _stub(reasons, 'parse-error', e.message, rr, i, rungs, warnings, pouName);
      stubbed++;
    } on _RllStub catch (e) {
      _stub(reasons, e.reason, e.detail, rr, i, rungs, warnings, pouName);
      stubbed++;
    }
  }

  return RllTranslation(
    rungs: rungs,
    translatedRungCount: translated,
    stubbedRungCount: stubbed,
    unsupportedInstructions: unsupported,
    stubReasons: reasons,
    warnings: warnings,
  );
}

void _stub(Map<String, int> reasons, String reason, String detail, RllRung rr,
    int i, List<LdRung> rungs, List<ImportWarning> warnings, String pouName) {
  reasons[reason] = (reasons[reason] ?? 0) + 1;
  warnings.add(ImportWarning(
      severity: WarningSeverity.warning,
      message: 'POU "$pouName" rung ${i + 1}: not compiled ($reason: $detail).'));
  rungs.add(LdRung(
    rungIndex: i,
    comment: 'Rung not compiled on import ($reason): $detail. Source: ${rr.text}',
    nodes: [
      LdNode(id: kLeftRailId, kind: LdKind.leftRail),
      LdNode(id: kRightRailId, kind: LdKind.rightRail),
    ],
    wires: [LdWire(fromId: kLeftRailId, toId: kRightRailId)],
  ));
}

/// Lowers one rung's element sequence to a main line + parallel branches and
/// builds it. A branch's first leg extends the main line; other legs become
/// `BranchSpec`s spanning that leg's index range. Nested/empty legs stub.
LdRung _assembleRung(
  List<RllElement> els,
  int index,
  String comment,
  Set<String> unsupported,
  Map<String, FbDefinition> fbRegistry,
  Map<String, String> fbRenameMap,
  List<ImportWarning> warnings,
) {
  final main = <LdNode>[];
  final branches = <BranchSpec>[];

  LdNode toNode(RllElement e) {
    if (e is! RllInstruction) {
      throw _RllStub('complex-topology', 'nested branch');
    }
    return _instrToNode(e, unsupported, fbRegistry, fbRenameMap, warnings);
  }

  for (final el in els) {
    if (el is RllInstruction) {
      main.add(_instrToNode(el, unsupported, fbRegistry, fbRenameMap, warnings));
    } else if (el is RllBranch) {
      for (final leg in el.legs) {
        if (leg.isEmpty) {
          throw _RllStub('complex-topology', 'empty (bypass) branch leg');
        }
        if (leg.any((e) => e is RllBranch)) {
          throw _RllStub('complex-topology', 'nested branch');
        }
      }
      final startIdx = main.length;
      for (final e in el.legs.first) {
        main.add(toNode(e));
      }
      final endIdx = main.length - 1;
      for (var li = 1; li < el.legs.length; li++) {
        branches.add(BranchSpec(
          startIndex: startIdx,
          endIndex: endIdx,
          nodes: [for (final e in el.legs[li]) toNode(e)],
        ));
      }
    }
  }

  return buildRung(index: index, comment: comment, main: main, branches: branches);
}

/// Maps one instruction to an `LdNode`, or throws `_RllStub`. Task 4 inserts the
/// AOI-call branch at the top (before the switch).
LdNode _instrToNode(
  RllInstruction instr,
  Set<String> unsupported,
  Map<String, FbDefinition> fbRegistry,
  Map<String, String> fbRenameMap,
  List<ImportWarning> warnings,
) {
  // (Task 4 inserts the custom-AOI-call branch here, BEFORE the switch.)
  final m = instr.mnemonic.toUpperCase();
  final ops = instr.operands;
  switch (m) {
    case 'XIC':
      return _contact(ops, 'normal');
    case 'XIO':
      return _contact(ops, 'negated');
    case 'ONS':
      return _contact(ops, 'rising');
    case 'OTE':
      return _coil(ops, 'normal');
    case 'OTL':
      return _coil(ops, 'set');
    case 'OTU':
      return _coil(ops, 'reset');
    case 'TON':
    case 'TOF':
    case 'CTU':
    case 'CTD':
    case 'CTUD':
      return _timerCounter(m, ops, warnings);
    case 'EQU':
      return _compare('EQ', ops);
    case 'NEQ':
      return _compare('NE', ops);
    case 'LEQ':
      return _compare('LE', ops);
    case 'GEQ':
      return _compare('GE', ops);
    case 'LES':
      return _compare('LT', ops);
    case 'GRT':
      return _compare('GT', ops);
    case 'ADD':
    case 'SUB':
    case 'MUL':
    case 'DIV':
      return _math(m, ops);
    case 'MOV':
      return _move(ops);
    default:
      unsupported.add(instr.mnemonic);
      throw _RllStub('unsupported-instruction', 'unsupported instruction "$m"');
  }
}

LdNode _contact(List<String> ops, String mod) {
  if (ops.length != 1) throw _RllStub('unresolved-operand', 'contact needs 1 operand');
  return LdNode(id: '', kind: LdKind.contact, variable: ops[0], modifier: mod);
}

LdNode _coil(List<String> ops, String mod) {
  if (ops.length != 1) throw _RllStub('unresolved-operand', 'coil needs 1 operand');
  return LdNode(id: '', kind: LdKind.coil, variable: ops[0], modifier: mod);
}

LdNode _compare(String op, List<String> ops) {
  if (ops.length != 2) throw _RllStub('unresolved-operand', 'compare needs 2 operands');
  return LdNode(id: '', kind: LdKind.block, blockType: op, operandA: ops[0], operandB: ops[1]);
}

LdNode _math(String op, List<String> ops) {
  if (ops.length != 3) throw _RllStub('unresolved-operand', '$op needs 3 operands');
  return LdNode(id: '', kind: LdKind.block, blockType: op,
      operandA: ops[0], operandB: ops[1], variable: ops[2]);
}

LdNode _move(List<String> ops) {
  if (ops.length != 2) throw _RllStub('unresolved-operand', 'MOV needs 2 operands');
  return LdNode(id: '', kind: LdKind.block, blockType: 'MOVE', operandA: ops[0], variable: ops[1]);
}

/// Timer/counter: variable = instance operand; preset best-effort from a literal
/// second operand, else defaulted + a prominent warning (never silent).
LdNode _timerCounter(String type, List<String> ops, List<ImportWarning> warnings) {
  if (ops.isEmpty) throw _RllStub('unresolved-operand', '$type needs an instance operand');
  final node = LdNode(id: '', kind: LdKind.block, blockType: type, variable: ops[0]);
  final preset = ops.length > 1 ? int.tryParse(ops[1].trim()) : null;
  if (preset != null) {
    node.presetMs = preset;
  } else {
    warnings.add(ImportWarning(
        severity: WarningSeverity.warning,
        message: 'Timer/counter "${ops[0]}" preset could not be resolved from the '
            'neutral text — defaulted, verify.'));
  }
  return node;
}
```

(`RTO` is not in the switch → hits `default` → `unsupported-instruction`, as the test expects. If `project_model.dart`/`ld_graph.dart` were flagged unused in Task 2, they are now used — remove any `// ignore` added there.)

- [ ] **Step 4: Run to verify passing**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/rll_compile_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/rll_compile.dart mobile/test/import/rll_compile_test.dart
git commit -m "feat(import): RLL compiler core (contacts/coils/data/timers/branches)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: AOI call routing (strict)

**Files:**
- Modify: `mobile/lib/import/rll_compile.dart` (`_instrToNode`)
- Test: `mobile/test/import/rll_compile_test.dart` (add tests)

**Interfaces:**
- Consumes: `FbDefinition`/`FbVar`/`FbVarDir` (`project_model.dart`); the `fbRegistry`/`fbRenameMap`/`unsupported` already threaded into `_instrToNode`.
- Produces: an RLL instruction whose (renamed) mnemonic is a key in `fbRegistry` becomes an FB-call `LdNode(kind: block, blockType: <final AOI name>, variable: <instance>, pinBindings: …)` — first operand is the instance, remaining operands bind positionally to the AOI's `vars`. Strict: an arg-count mismatch (or unknown AOI) stubs the rung.

- [ ] **Step 1: Write the failing tests**

Add to `mobile/test/import/rll_compile_test.dart` (add imports for `FbDefinition`/`FbVar`/`FbVarDir` from `project_model.dart` if not present):

```dart
  FbDefinition _scaler() => FbDefinition(name: 'Scaler', vars: [
        FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      ], stSource: 'Out := In * Gain;');

  test('AOI call with matching arity -> FB-call node with positional pinBindings', () {
    final tr = compileRllRungs(_body(['Scaler(Inst1,PV,2.0,CV);']),
        pouName: 'P', fbRegistry: {'Scaler': _scaler()});
    expect(tr.translatedRungCount, 1);
    final fb = tr.rungs.single.nodes.firstWhere((n) => n.blockType == 'Scaler');
    expect(fb.variable, 'Inst1');
    expect(fb.pinBindings['In'], 'PV');
    expect(fb.pinBindings['Gain'], '2.0');
    expect(fb.pinBindings['Out'], 'CV');
  });

  test('renamed AOI routes via fbRenameMap', () {
    final tr = compileRllRungs(_body(['AND(I1,X);']), pouName: 'P',
        fbRegistry: {
          'AND_1': FbDefinition(name: 'AND_1', vars: [
            FbVar(name: 'X', dataType: 'BOOL', direction: FbVarDir.input),
          ], stSource: '')
        },
        fbRenameMap: {'AND': 'AND_1'});
    expect(tr.translatedRungCount, 1);
    expect(tr.rungs.single.nodes.any((n) => n.blockType == 'AND_1'), isTrue);
  });

  test('AOI arity mismatch stubs the rung', () {
    final tr = compileRllRungs(_body(['Scaler(Inst1,PV);']),
        pouName: 'P', fbRegistry: {'Scaler': _scaler()});
    expect(tr.translatedRungCount, 0);
    expect(tr.stubReasons['aoi-mismatch'], 1);
    expect(tr.unsupportedInstructions, contains('Scaler'));
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/rll_compile_test.dart`
Expected: the three new tests FAIL (`Scaler` currently hits `default` → `unsupported-instruction` stub).

- [ ] **Step 3: Implement the AOI branch**

In `mobile/lib/import/rll_compile.dart`, replace the marker comment in `_instrToNode` (`// (Task 4 inserts the custom-AOI-call branch here, BEFORE the switch.)`) with:

```dart
  // Custom-AOI call: a mnemonic that (after fbRenameMap) names an imported AOI
  // routes to an FB-call node. Strict: the arg count must match the interface.
  final effective = fbRenameMap[instr.mnemonic] ?? instr.mnemonic;
  final fb = fbRegistry[effective];
  if (fb != null) {
    final ops = instr.operands;
    if (ops.isEmpty || ops.length - 1 != fb.vars.length) {
      unsupported.add(instr.mnemonic);
      throw _RllStub('aoi-mismatch',
          'AOI "$effective" arg count ${ops.isEmpty ? 0 : ops.length - 1} != ${fb.vars.length}');
    }
    final pin = <String, String>{};
    for (var k = 0; k < fb.vars.length; k++) {
      pin[fb.vars[k].name] = ops[k + 1];
    }
    return LdNode(id: '', kind: LdKind.block, blockType: effective,
        variable: ops[0], pinBindings: pin);
  }
```

- [ ] **Step 4: Run to verify passing**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/rll_compile_test.dart`
Expected: PASS (all tests).

- [ ] **Step 5: Analyze + commit**

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/import/rll_compile.dart mobile/test/import/rll_compile_test.dart
git commit -m "feat(import): RLL AOI-call routing (strict positional binding)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Mapper integration + report fields + preview

**Files:**
- Modify: `mobile/lib/import/ir_to_project.dart`
- Modify: `mobile/lib/screens/import_xml_preview.dart`
- Test: `mobile/test/import/ir_to_project_test.dart`

**Interfaces:**
- Consumes: `compileRllRungs`/`RllTranslation` (Tasks 3/4); the existing `fbRes.registry`/`fbRes.renameMap`.
- Produces: `ImportReport` gains `translatedRllRungCount` (int, 0), `stubbedRllRungCount` (int, 0), `unsupportedRllInstructions` (`Set<String>`, `{}`), `rllStubReasons` (`Map<String,int>`, `{}`). RLL POUs with ≥1 compiled rung become real `LadderLogic` programs.

- [ ] **Step 1: Write the failing test**

Add to `mobile/test/import/ir_to_project_test.dart` (build the IR directly):

```dart
  test('RLL POU compiles to a real LadderLogic program', () {
    final ir = ImportedProject(
      name: 'RllProj', types: const [], warnings: const [],
      globalVars: [
        ImportedVar(name: 'A', baseType: 'BOOL', scope: VarScope.global),
        ImportedVar(name: 'B', baseType: 'BOOL', scope: VarScope.global),
      ],
      pous: [
        ImportedPou(name: 'Main_Logic', kind: PouKind.program, lang: PouLanguage.ld,
            localVars: const [],
            body: NeutralLadderBody(rungs: [
              RllRung(number: 0, text: 'XIC(A)OTE(B);'),
              RllRung(number: 1, text: 'FOO(A);'), // unsupported -> placeholder
            ])),
      ],
    );
    final res = mapImportedProject(ir, projectName: 'RllProj', projectId: 'x');
    final prog = res.project.programs.firstWhere((p) => p.name == 'Main_Logic');
    expect(prog.language, 'LadderLogic');
    expect(prog.rungs, hasLength(2)); // compiled + placeholder (numbering preserved)
    expect(res.report.translatedRllRungCount, 1);
    expect(res.report.stubbedRllRungCount, 1);
    expect(res.report.unsupportedRllInstructions, contains('FOO'));
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/ir_to_project_test.dart`
Expected: FAIL — `translatedRllRungCount` not a member; the RLL POU still stubs (no `rungs`).

- [ ] **Step 3: Add the report fields**

In `mobile/lib/import/ir_to_project.dart`, extend `ImportReport` — add fields (near the SFC reporting fields):

```dart
  // RLL (L5X ladder) reporting (default-safe).
  final int translatedRllRungCount;
  final int stubbedRllRungCount;
  final Set<String> unsupportedRllInstructions;
  final Map<String, int> rllStubReasons;
```

and constructor params (after the SFC ones):

```dart
    this.translatedRllRungCount = 0,
    this.stubbedRllRungCount = 0,
    this.unsupportedRllInstructions = const {},
    this.rllStubReasons = const {},
```

- [ ] **Step 4: Add the import + accumulators + upgrade the arm**

Add the import near the top of `ir_to_project.dart`:

```dart
import 'rll_compile.dart';
```

Add accumulators near the FBD/SFC ones in `mapImportedProject`:

```dart
  var translatedRllRungCount = 0;
  var stubbedRllRungCount = 0;
  final unsupportedRllInstructions = <String>{};
  final rllStubReasons = <String, int>{};
```

Replace the Task-1 `body is NeutralLadderBody` stub arm with the compiler call:

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
        warnings.add(ImportWarning(severity: WarningSeverity.warning,
            message: 'POU "${pou.name}" (Ladder): ${body.rungs.length} rungs not compiled '
                '— neutral-text ladder not yet supported for these instructions.'));
        programs.add(PlcProgram(name: pou.name, language: 'LadderLogic',
            description: 'Neutral-text ladder not compiled (${body.rungs.length} rungs captured).'));
        stubCount++;
      }
    } else if (body is SfcBody) {
```

(RLL rungs reference existing tags by name — no instance-tag merge, unlike the PLCopen LD arm.)

- [ ] **Step 5: Thread the fields into the returned `ImportReport`**

In the `return ImportResult(... report: ImportReport(...))`, add:

```dart
        translatedRllRungCount: translatedRllRungCount,
        stubbedRllRungCount: stubbedRllRungCount,
        unsupportedRllInstructions: unsupportedRllInstructions,
        rllStubReasons: rllStubReasons,
```

- [ ] **Step 6: Run the mapper test + full import suite**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/`
Expected: PASS. (An L5X corpus file whose RLL routine now compiles instead of stubbing is expected — `corpus_import_test` asserts only no-throw + a valid project, so it stays green; if any assertion checked the RLL-stub specifically, update it to the correct new behavior.)

- [ ] **Step 7: Surface RLL counts in the preview**

In `mobile/lib/screens/import_xml_preview.dart`, after the SFC count block, add:

```dart
              if (report.translatedRllRungCount > 0 ||
                  report.stubbedRllRungCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'RLL ladder: ${report.translatedRllRungCount} rung(s) compiled'
                  '${report.stubbedRllRungCount > 0 ? ', ${report.stubbedRllRungCount} stubbed' : ''}'
                  '${report.unsupportedRllInstructions.isNotEmpty ? ' — unsupported: ${report.unsupportedRllInstructions.join(', ')}' : ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
```

- [ ] **Step 8: Flow test + analyze**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/import_xml_flow_test.dart && /c/flutter/bin/flutter analyze`
Expected: PASS; no analyzer issues.

- [ ] **Step 9: Commit**

```bash
git add mobile/lib/import/ir_to_project.dart mobile/lib/screens/import_xml_preview.dart mobile/test/import/ir_to_project_test.dart
git commit -m "feat(import): wire RLL compiler into mapper + report + preview

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end + corpus + docs + full validation

**Files:**
- Create: `mobile/test/import/import_l5x_rll_e2e_test.dart`
- Modify: `docs/import/L5X.md`, `docs/DEFERRED.md`

**Interfaces:**
- Consumes: the full pipeline — `parseL5x` → `mapImportedProject` → `executeLdPrograms` (`ld_exec.dart`, `LdExecRuntime`), `readPath`/`writePath` (`tag_resolver.dart`).
- Produces: an executable end-to-end proof, a real-corpus check, and docs.

- [ ] **Step 1: Write the failing end-to-end test**

Create `mobile/test/import/import_l5x_rll_e2e_test.dart`:

```dart
// End-to-end: a handcrafted L5X with an RLL routine compiles to a real
// LadderLogic program and executes. Pipeline: parseL5x -> mapImportedProject ->
// executeLdPrograms. Plus a smoke run over the real Rockwell corpus (skips if
// the gitignored fixtures are absent).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Tags>
    <Tag Name="Start" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Motor" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[XIC(Start)OTE(Motor);]]></Text></Rung>
      </RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';

File? _sample(String name) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/Resources/Project Exports/Rockwell-L5X/$name');
    if (f.existsSync()) return f;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  test('handcrafted RLL routine compiles + executes (XIC/OTE)', () {
    final ir = parseL5x(_kXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'rll_e2e');
    final p = res.project;
    final prog = p.programs.firstWhere((pr) => pr.name == 'Main_Logic');
    expect(prog.language, 'LadderLogic');
    expect(prog.rungs, isNotEmpty);
    expect(res.report.translatedRllRungCount, 1);

    // Start false -> Motor false; Start true -> Motor true.
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'Motor'), false);
    writePath(p, 'Start', true);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'Motor'), true);
  });

  test('real Numeric_Program.L5X RLL routine compiles without throwing', () {
    final f = _sample('logixlibraries_Numeric_Program.L5X');
    if (f == null) {
      markTestSkipped('Rockwell-L5X corpus absent — skipping.');
      return;
    }
    final ir = parseL5x(f.readAsStringSync());
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'rll_corpus');
    expect(res.project, isNotNull);
    // Its rungs are AOI calls + MOVE branches — at least some compile to FB nodes.
    expect(res.report.translatedRllRungCount, greaterThan(0));
  });
}
```

- [ ] **Step 2: Run the e2e test**

Run: `cd mobile && /c/flutter/bin/flutter test test/import/import_l5x_rll_e2e_test.dart`
Expected: PASS (the corpus test skips if fixtures absent). If the handcrafted test fails, diagnose against the failing assertion and fix the underlying `rll_compile.dart`/mapper (not the test). If the real corpus test fails, inspect the actual rung text and adjust the compiler/parser to handle it (real exports are the point) — but keep faithful-or-stub.

- [ ] **Step 3: Update docs**

In `docs/import/L5X.md`, add an RLL section:

```markdown
## RLL (ladder) compile

Imported RLL routines compile to native ladder, per rung. Supported: contacts
`XIC`/`XIO`/`ONS`; coils `OTE`/`OTL`/`OTU`; compares `EQU`/`NEQ`/`LEQ`/`GEQ`/`LES`/
`GRT`; math `ADD`/`SUB`/`MUL`/`DIV`; `MOV`; timers `TON`/`TOF` + counters
`CTU`/`CTD`/`CTUD` (preset best-effort — exact when a literal, else defaulted +
warning); AOI calls (positional binding to the AOI interface, strict); single-
level `[…]` branches. A rung with an unsupported instruction, an AOI arity
mismatch, a nested branch, or malformed text degrades to a commented placeholder
rung + an unsupported-instruction inventory. Deferred: nested branches, `RTO`
retentive timers, exact timer/counter preset fidelity, and unmapped instructions
(`CPT`/`JSR`/`PID`/`SQO`/file-array/…).
```

- [ ] **Step 4: Update `docs/DEFERRED.md`**

Strike the "RLL ladder compiler" row under the L5X sub-program (delivered; note the e2e path `mobile/test/import/import_l5x_rll_e2e_test.dart`). Add residual RLL deferred rows: nested `[…]` branches; empty (bypass) branch legs; `RTO`/retentive timers; exact timer/counter preset fidelity (needs Rockwell predefined `TIMER`/`COUNTER` type mapping); unmapped instructions (`CPT`/`JSR`/`PID`/`SQO`/`COP`/`MSG`/…). Note L5X sub-projects 3 (non-ST AOI logic), 4 (FBD), 5 (SFC) remain.

- [ ] **Step 5: Full validation — whole suite + analyze**

Run: `cd mobile && /c/flutter/bin/flutter test`
Expected: entire suite PASS (baseline was 2698 passing; this adds tests and must not regress — PLCopen import and the L5X foundation are unchanged).

Run: `cd mobile && /c/flutter/bin/flutter analyze`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add mobile/test/import/import_l5x_rll_e2e_test.dart docs/import/L5X.md docs/DEFERRED.md
git commit -m "test(import): L5X RLL e2e + corpus; docs; RLL compiler complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- §1 `NeutralLadderBody`/`RllRung` IR → Task 1. ✅
- §2 parser captures rung text → Task 1. ✅
- §3 compiler (`RllTranslation`/`compileRllRungs`) → Tasks 2 (tokenizer) + 3 (mapping/assembly). ✅
- §3.1 recursive-descent tokenizer → Task 2. ✅
- §3.2 instruction→LdNode → Task 3. ✅
- §3.2.1 timer/counter best-effort preset + RTO stub → Task 3 (`_timerCounter`, RTO→default case). ✅
- §3.3 strict AOI routing → Task 4. ✅
- §3.4 single-level branch assembly + placeholder rung → Task 3 (`_assembleRung`, `_stub`). ✅
- §4 mapper arm + report fields → Task 1 (stub) + Task 5 (compile + counts). ✅
- §5 preview → Task 5 Step 7. ✅
- §6 error handling (all stubReasons keys) → Tasks 2/3/4. ✅
- §7 testing → Tasks 2,3,4,6. ✅
- §8 docs → Task 6. ✅
- §9 deferred → Task 6 Step 4. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output. The Task 3 note about a possible Task-2 unused-import is a conditional cleanup with an exact resolution, not an open placeholder.

**3. Type consistency:**
- `parseRllText(String) -> List<RllElement>`; `RllElement` (sealed) / `RllInstruction{mnemonic, operands}` / `RllBranch{legs}`; `RllParseException{message}` — identical across Task 2 def and Task 3/4 use. ✅
- `compileRllRungs(NeutralLadderBody, {required String pouName, Map<String,FbDefinition> fbRegistry, Map<String,String> fbRenameMap}) -> RllTranslation{rungs, translatedRungCount, stubbedRungCount, unsupportedInstructions, stubReasons, warnings}` — identical Task 3 def, Task 5 consumer. ✅
- `_instrToNode(RllInstruction, Set<String>, Map<String,FbDefinition>, Map<String,String>, List<ImportWarning>)` — same signature Task 3 def + Task 4 edit. ✅
- `NeutralLadderBody{rungs}` / `RllRung{number, text, comment}` — identical Task 1 def, Tasks 2/3/5 use. ✅
- `LdNode(id, kind, variable, modifier, blockType, presetMs, operandA, operandB, pinBindings)`, `LdRung(rungIndex, comment, nodes, wires)`, `buildRung(index, comment, main, branches)`, `BranchSpec(startIndex, endIndex, nodes)`, `kLeftRailId`/`kRightRailId`, `LdKind.contact/coil/block/leftRail/rightRail` — match `project_model.dart`/`ld_graph.dart`. ✅
- Report fields `translatedRllRungCount`/`stubbedRllRungCount`/`unsupportedRllInstructions`/`rllStubReasons` — identical Task 5 model, mapper, preview, Task 5 test. ✅
- stubReason keys (`parse-error`/`unsupported-instruction`/`unresolved-operand`/`complex-topology`/`aoi-mismatch`) — consistent between compiler code and tests. ✅

All consistent. Plan ready.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-07-27-l5x-rll-ladder-compiler.md`. Six tasks: Task 1 keeps the suite green (RLL routes to a behavior-preserving `NeutralLadderBody` stub while capturing rung text); Tasks 2–4 build the tokenizer → compiler → AOI routing as pure units; Task 5 wires it into the mapper; Task 6 proves it end-to-end and against the real Rockwell corpus.
