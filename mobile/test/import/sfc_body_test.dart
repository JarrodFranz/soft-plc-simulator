import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';

const _kSfcXml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="SfcProj"/>
  <types><dataTypes/><pous>
    <pou name="Chart" pouType="program">
      <interface><localVars/></interface>
      <actions>
        <action name="RunAct"><body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Motor := TRUE;</xhtml></ST></body></action>
      </actions>
      <transitions>
        <transition name="ToRun"><body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Start</xhtml></ST></body></transition>
      </transitions>
      <body><SFC>
        <step localId="1" name="Idle" initialStep="true"><position x="0" y="0"/>
          <connectionPointIn><connection refLocalId="3"/></connectionPointIn></step>
        <transition localId="2"><position x="0" y="40"/>
          <connectionPointIn><connection refLocalId="1"/></connectionPointIn>
          <condition><reference name="ToRun"/></condition></transition>
        <step localId="3" name="Run"><position x="0" y="80"/>
          <connectionPointIn><connection refLocalId="2"/></connectionPointIn></step>
        <actionBlock localId="9"><position x="60" y="80"/>
          <connectionPointIn><connection refLocalId="3"/></connectionPointIn>
          <action qualifier="N"><reference name="RunAct"/></action></actionBlock>
      </SFC></body>
    </pou>
  </pous></types>
  <instances><configurations><configuration name="C"><resource name="R">
    <globalVars/></resource></configuration></configurations></instances>
</project>''';

void main() {
  test('SFC POU parses into a populated SfcBody', () {
    final ir = parsePlcOpen(_kSfcXml);
    final pou = ir.pous.single;
    expect(pou.lang, PouLanguage.sfc);
    final body = pou.body as SfcBody;

    final steps = body.nodes.where((n) => n.kind == SfcNodeKind.step).toList();
    expect(steps.map((s) => s.name), containsAll(['Idle', 'Run']));
    expect(steps.firstWhere((s) => s.name == 'Idle').initial, isTrue);

    final trans = body.nodes.firstWhere((n) => n.kind == SfcNodeKind.transition);
    expect(trans.condition, isA<SfcCondRef>());
    expect((trans.condition as SfcCondRef).name, 'ToRun');

    // edges: 3->1, 1->2, 2->3 (from each node's connectionPointIn)
    bool hasEdge(int f, int t) => body.edges.any((e) => e.fromLocalId == f && e.toLocalId == t);
    expect(hasEdge(1, 2), isTrue);
    expect(hasEdge(2, 3), isTrue);

    // action association: step 3 (Run) has an N action referencing RunAct
    final act = body.actions.singleWhere((a) => a.stepLocalId == 3);
    expect(act.qualifier, 'N');
    expect(act.source, isA<SfcActRef>());
    expect((act.source as SfcActRef).name, 'RunAct');

    // referenced ST bodies captured
    expect(body.refBodies['RunAct'], 'Motor := TRUE;');
    expect(body.refBodies['ToRun'], 'Start');
    expect(body.graphicalRefs, isEmpty);
  });
}
