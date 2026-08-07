// L5X FBD parser units: <FBDContent><Sheet> XML -> the vendor-neutral
// GraphBody, using EXACTLY the attribute keys plcopen_parser.dart emits so
// translateFbdBody needs no changes.
//
// Corpus note: the local Rockwell corpus contains zero FBD content, so every
// fixture here is handcrafted schema-faithful L5X (the same precedent as the
// PLCopen FBD e2e).
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/fbd_translate.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

ImportedProject _parse(String fbdContent) => parseL5x('''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Programs><Program Name="Prog"><Tags/><Routines>
    <Routine Name="Main" Type="FBD"><FBDContent>$fbdContent</FBDContent></Routine>
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''');

GraphBody _graph(ImportedProject ir) =>
    ir.pous.firstWhere((p) => p.name == 'Prog_Main').body as GraphBody;

IrGraphNode _node(GraphBody g, int id) =>
    g.nodes.firstWhere((n) => n.localId == id);

PlcTag _tag(String n, dynamic v) =>
    PlcTag(name: n, path: n, dataType: 'INT32', value: v, ioType: 'Internal');

void main() {
  test('every element kind maps to the expected elementType + attributes', () {
    // Real-Logix element shapes: stateful instructions are <Block> with an
    // Operand (their backing tag); stateless bit functions are <Function>.
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand=" Speed " X="10" Y="20"/>
        <ORef ID="1" Operand="Alarm" X="30" Y="40"/>
        <Block ID="2" Type="TON" Operand="T1" X="50" Y="60"/>
        <Block ID="3" Type="ADD" Operand="Add_01" X="70" Y="80"/>
        <AddOnInstruction ID="4" Name="MyAoi" Operand="Inst1" X="90" Y="100"/>
        <Function ID="5" Type="BNOT" X="110" Y="120"/>
      </Sheet>'''));

    expect(g.nodes, hasLength(6));

    expect(_node(g, 0).elementType, 'inVariable');
    expect(_node(g, 0).attributes['variable'], 'Speed'); // trimmed
    expect(_node(g, 0).x, 10);
    expect(_node(g, 0).y, 20);

    expect(_node(g, 1).elementType, 'outVariable');
    expect(_node(g, 1).attributes['variable'], 'Alarm');

    expect(_node(g, 2).elementType, 'block');
    expect(_node(g, 2).attributes['typeName'], 'TON');
    expect(_node(g, 2).attributes['instanceName'], 'T1');

    expect(_node(g, 3).elementType, 'block');
    expect(_node(g, 3).attributes['typeName'], 'ADD');
    expect(_node(g, 3).attributes['instanceName'], 'Add_01');

    expect(_node(g, 4).elementType, 'block');
    expect(_node(g, 4).attributes['typeName'], 'MyAoi');
    expect(_node(g, 4).attributes['instanceName'], 'Inst1');

    // <Function> is stateless: no Operand, so no instanceName key at all.
    expect(_node(g, 5).elementType, 'block');
    expect(_node(g, 5).attributes.containsKey('instanceName'), isFalse);

    // hasNegatedPin/negated are NEVER emitted (Logix FBD has no pin inversion
    // or element negation; BNOT is an explicit element).
    expect(g.nodes.any((n) => n.attributes.containsKey('hasNegatedPin')), isFalse);
    expect(g.nodes.any((n) => n.attributes.containsKey('negated')), isFalse);
  });

  test('Wire maps to IrConnection; absent Params are null', () {
    // A real Logix wire out of an <IRef> carries no FromParam (the ref has a
    // single implicit output); a wire out of a block names its output pin.
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="A"/>
        <Function ID="1" Type="BNOT"/>
        <ORef ID="2" Operand="B"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
        <Wire FromID="1" FromParam="OUT" ToID="2"/>
      </Sheet>'''));

    expect(g.connections, hasLength(2));
    final w0 = g.connections[0];
    expect(w0.fromLocalId, 0);
    expect(w0.fromPin, isNull); // absent FromParam -> null
    expect(w0.toLocalId, 1);
    expect(w0.toPin, 'IN');
    final w1 = g.connections[1];
    expect(w1.fromPin, 'OUT');
    expect(w1.toPin, isNull); // absent ToParam -> null
  });

  test('FeedbackWire maps like Wire, translates, and EXECUTES without hanging', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <Block ID="1" Type="ADD" Operand="Add_01" X="100" Y="0"/>
        <ORef ID="2" Operand="Dst" X="200" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="IN1"/>
        <Wire FromID="1" FromParam="OUT" ToID="2" ToParam="IN"/>
        <FeedbackWire FromID="1" FromParam="OUT" ToID="1" ToParam="IN2"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.connections, hasLength(3));
    final fb = g.connections.last;
    expect(fb.fromLocalId, 1);
    expect(fb.fromPin, 'OUT');
    expect(fb.toLocalId, 1);
    expect(fb.toPin, 'IN2');

    // One weakly-connected component -> one real network.
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 1);
    expect(tr.stubbedNetworkCount, 0);

    // The "never hangs" claim is only worth anything if it is EXECUTED: the
    // engine's dataflow-cycle fallback evaluates each unresolved block once
    // and returns. (The ADD's own feedback input is unresolved on that pass,
    // so it yields null and the ORef writes nothing; the point is the call
    // returns at all.)
    final prog = PlcProgram(name: 'Prog_Main', language: 'FunctionBlockDiagram');
    prog.fbdBlocks.addAll(tr.blocks);
    prog.fbdWires.addAll(tr.wires);
    final p = PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: [_tag('Src', 5), _tag('Dst', 0)],
      structDefs: [], programs: [prog], tasks: [], hmis: [], fbDefinitions: [],
    );
    executeFbdPrograms(p, 100, FbdRuntime());
    expect(readPath(p, 'Dst'), 0);
  });

  test('an unrecognized element with an ID is KEPT and stubs its component', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src"/>
        <JSR ID="1" Routine="Sub"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(_node(g, 1).elementType, 'JSR'); // raw tag name, not dropped
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unsupported-element'], 1);
  });

  test('TextBox/Attachment are dropped with ONE info "ignored" warning', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src"/>
        <TextBox ID="7" Width="100"><Text>note</Text></TextBox>
        <TextBox ID="8" Width="100"><Text>note2</Text></TextBox>
        <Attachment FromID="7" ToID="0"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.nodes.map((n) => n.localId), [0]); // annotations are not nodes
    final ignored = ir.warnings
        .where((w) =>
            w.message.contains('ignored') &&
            w.message.contains('Routine "Prog_Main"'))
        .toList();
    expect(ignored, hasLength(1));
    expect(ignored.single.severity, WarningSeverity.info);
    expect(ignored.single.message, contains('3 element(s) ignored'));
    expect(ignored.single.message, contains('TextBox'));
    expect(ignored.single.message, contains('Attachment'));
  });

  test('malformed ids get DISTINCT negative ids; a dangling wire gets a placeholder', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef Operand="NoId"/>
        <IRef ID="abc" Operand="BadId"/>
        <IRef ID="-4" Operand="Negative"/>
        <IRef ID="0" Operand="Fine"/>
        <Wire FromID="abc" ToID="0" ToParam="IN"/>
      </Sheet>'''));

    // 3 malformed elements + 1 placeholder for the wire's unresolvable source.
    final negatives =
        g.nodes.where((n) => n.localId < 0).map((n) => n.localId).toList();
    expect(negatives, hasLength(4));
    expect(negatives.toSet(), hasLength(4)); // distinct, never a shared -1
    expect(g.nodes.where((n) => n.localId >= 0), hasLength(1));

    // The wire is KEPT (never silently dropped) and points at the placeholder.
    expect(g.connections, hasLength(1));
    final placeholder =
        g.nodes.firstWhere((n) => n.elementType == 'danglingWire');
    expect(g.connections.single.fromLocalId, placeholder.localId);
    expect(g.connections.single.toLocalId, 0);

    // So the CONSUMER's component stubs instead of translating as if its
    // input were merely unwired. 3 isolated malformed nodes + 1 component
    // {placeholder, Fine} = 4 stubbed components, 0 translated.
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unsupported-element'], 4);
  });

  test('an absent/empty FBDContent yields an empty GraphBody, no warning, no throw', () {
    final ir = parseL5x('''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Programs><Program Name="Prog"><Tags/><Routines>
    <Routine Name="Main" Type="FBD"/>
    <Routine Name="Empty" Type="FBD"><FBDContent/></Routine>
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''');
    for (final n in ['Prog_Main', 'Prog_Empty']) {
      final pou = ir.pous.firstWhere((p) => p.name == n);
      expect(pou.lang, PouLanguage.fbd);
      final g = pou.body as GraphBody;
      expect(g.nodes, isEmpty);
      expect(g.connections, isEmpty);
      // Distinguishes the NEW path from the old one: the pre-feature FBD arm
      // emitted an equally-empty GraphBody but ALWAYS warned. Nothing here has
      // failed, so nothing warns at all.
      expect(ir.warnings.any((w) => w.message.contains(n)), isFalse);
    }
  });

  test('the old "graphical body not yet translated" FBD warning is gone', () {
    final ir = _parse('''
      <Sheet Number="1"><IRef ID="0" Operand="Src"/></Sheet>''');
    expect(
        ir.warnings.any((w) =>
            w.message.contains('Prog_Main') &&
            w.message.contains('not yet translated')),
        isFalse);
    final pou = ir.pous.firstWhere((p) => p.name == 'Prog_Main');
    expect(pou.lang, PouLanguage.fbd);
    expect(pou.kind, PouKind.program);
  });

  test('two sheets with OVERLAPPING raw ids merge with disjoint localIds', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="A" X="0" Y="0"/>
        <ORef ID="1" Operand="B" X="100" Y="50"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
      </Sheet>
      <Sheet Number="2">
        <IRef ID="0" Operand="C" X="0" Y="0"/>
        <ORef ID="1" Operand="D" X="100" Y="10"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
      </Sheet>'''));

    expect(g.nodes.map((n) => n.localId).toSet(), hasLength(4));
    // Sheet 1 keeps raw ids; sheet 2 is offset past the max assigned so far.
    expect(_node(g, 0).attributes['variable'], 'A');
    expect(_node(g, 2).attributes['variable'], 'C');
    expect(_node(g, 3).attributes['variable'], 'D');
    // Wires are sheet-local, so they follow their sheet's offset.
    expect(g.connections.map((c) => '${c.fromLocalId}->${c.toLocalId}'),
        ['0->1', '2->3']);
    // Sheet 2 sits BELOW sheet 1 (maxY 50 + 200), so network numbering reads
    // sheet by sheet instead of interleaving.
    expect(_node(g, 2).y, 250);
    expect(_node(g, 3).y, 260);

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 2);
  });

  test('sheets are visited in ascending Number order, not document order', () {
    final g = _graph(_parse('''
      <Sheet Number="2">
        <IRef ID="0" Operand="Second" X="0" Y="0"/>
      </Sheet>
      <Sheet Number="1">
        <IRef ID="0" Operand="First" X="0" Y="0"/>
      </Sheet>'''));

    // The Number="1" sheet is processed first, so it keeps the raw id.
    expect(_node(g, 0).attributes['variable'], 'First');
    expect(_node(g, 1).attributes['variable'], 'Second');
  });

  test('an unnumbered sheet falls back to its document-order position', () {
    // Document order: Number="2", (none), Number="1". Keys: 2.0, 2.5, 1.0 ->
    // processed 1, 2, unnumbered (the unnumbered one sits just after the
    // neighbour it followed in the file).
    final g = _graph(_parse('''
      <Sheet Number="2">
        <IRef ID="0" Operand="Two" X="0" Y="0"/>
      </Sheet>
      <Sheet>
        <IRef ID="0" Operand="NoNumber" X="0" Y="0"/>
      </Sheet>
      <Sheet Number="1">
        <IRef ID="0" Operand="One" X="0" Y="0"/>
      </Sheet>'''));

    expect(_node(g, 0).attributes['variable'], 'One');
    expect(_node(g, 1).attributes['variable'], 'Two');
    expect(_node(g, 2).attributes['variable'], 'NoNumber');
  });

  test('the synthetic-id counter is ROUTINE-wide across sheets', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef Operand="BadOne"/>
        <IRef ID="0" Operand="Fine"/>
      </Sheet>
      <Sheet Number="2">
        <IRef ID="oops" Operand="BadTwo"/>
        <IRef ID="0" Operand="AlsoFine"/>
      </Sheet>'''));

    final negatives =
        g.nodes.where((n) => n.localId < 0).map((n) => n.localId).toList();
    expect(negatives, hasLength(2));
    expect(negatives.toSet(), hasLength(2)); // distinct, not both -1

    // Each malformed element stubs its OWN component.
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.stubReasons['unsupported-element'], 2);
  });

  test('a matched OCon/ICon pair becomes a direct wire and the nodes vanish', () {
    final g = _graph(_parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <Function ID="1" Type="NOT" X="50" Y="0"/>
        <OCon ID="2" Name="Loop1" X="100" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
        <Wire FromID="1" FromParam="OUT" ToID="2"/>
      </Sheet>
      <Sheet Number="2">
        <ICon ID="0" Name="Loop1" X="0" Y="0"/>
        <ORef ID="1" Operand="Dst" X="50" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
      </Sheet>'''));

    expect(g.nodes.any((n) => n.elementType == 'ICon'), isFalse);
    expect(g.nodes.any((n) => n.elementType == 'OCon'), isFalse);

    // Producer (NOT.OUT) is wired straight to the consumer (Dst.IN); both
    // connector wires are gone.
    final notId =
        g.nodes.firstWhere((n) => n.attributes['typeName'] == 'NOT').localId;
    final dstId =
        g.nodes.firstWhere((n) => n.attributes['variable'] == 'Dst').localId;
    final direct = g.connections
        .where((c) => c.fromLocalId == notId && c.toLocalId == dstId)
        .toList();
    expect(direct, hasLength(1));
    expect(direct.single.fromPin, 'OUT');
    expect(direct.single.toPin, 'IN');
    expect(g.connections, hasLength(2)); // Src->NOT plus the merged wire

    // Merged into ONE component -> one real network. (The IEC type name `NOT`
    // is deliberate: Task 6's alias table does not exist yet, so the fixture
    // must already name an IEC built-in to translate here.)
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 1);
    expect(tr.stubbedNetworkCount, 0);
  });

  test('UNNAMED connectors never match each other; both stub', () {
    // Two blank-Name connectors are NOT the same connector. Splicing them
    // would wire two unrelated networks together, so they must never enter the
    // match maps: the nodes stay and their components stub.
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <OCon ID="1" Name="" X="50" Y="0"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>
      <Sheet Number="2">
        <ICon ID="0" X="0" Y="0"/>
        <ORef ID="1" Operand="Dst" X="50" Y="0"/>
        <Wire FromID="0" ToID="1" ToParam="IN"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.nodes.any((n) => n.elementType == 'OCon'), isTrue);
    expect(g.nodes.any((n) => n.elementType == 'ICon'), isTrue);
    // No splice happened: Src is not wired to Dst.
    expect(g.connections.any((c) => c.fromLocalId == 0 && c.toLocalId == 3),
        isFalse);

    final w = ir.warnings
        .where((x) =>
            x.message.contains('unmatched connector') &&
            x.message.contains('(unnamed)'))
        .toList();
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.info);

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unsupported-element'], 2);
  });

  test('connector CHAINING (an ICon feeding an OCon) routes to the unmatched path',
      () {
    // There is no producer/consumer pair to splice here, so both names take
    // the unmatched path and their components stub.
    final ir = _parse('''
      <Sheet Number="1">
        <ICon ID="0" Name="A" X="0" Y="0"/>
        <OCon ID="1" Name="B" X="50" Y="0"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>
      <Sheet Number="2">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <OCon ID="1" Name="A" X="50" Y="0"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.nodes.where((n) => n.elementType == 'ICon'), hasLength(1));
    expect(g.nodes.where((n) => n.elementType == 'OCon'), hasLength(2));
    final names = ir.warnings
        .where((x) => x.message.contains('unmatched connector'))
        .map((x) => x.message)
        .toList();
    expect(names, hasLength(2)); // one for "A", one for "B"
    expect(names.any((m) => m.contains('"A"')), isTrue);
    expect(names.any((m) => m.contains('"B"')), isTrue);

    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
  });

  test('an unmatched connector is KEPT, warns, and stubs its component', () {
    final ir = _parse('''
      <Sheet Number="1">
        <IRef ID="0" Operand="Src" X="0" Y="0"/>
        <OCon ID="1" Name="Dangling" X="50" Y="0"/>
        <Wire FromID="0" ToID="1"/>
      </Sheet>''');
    final g = _graph(ir);

    expect(g.nodes.any((n) => n.elementType == 'OCon'), isTrue);
    final w = ir.warnings
        .where((x) => x.message.contains('unmatched connector'))
        .toList();
    expect(w, hasLength(1));
    expect(w.single.severity, WarningSeverity.info);
    expect(w.single.message, contains('Routine "Prog_Main"'));
    expect(w.single.message, contains('Dangling'));

    // R4: the ELEMENT-kind gate fires (not the pin gate).
    final tr = translateFbdBody(g, pouName: 'Prog_Main');
    expect(tr.translatedNetworkCount, 0);
    expect(tr.stubReasons['unsupported-element'], 1);
  });
}
