// End-to-end proof: a handcrafted PLCopen SFC POU imports as a real, executing
// SequentialFunctionChart program. Exercises a referenced-ST transition + a
// referenced-ST action, and verifies the scan advances the active step and runs
// the action. Pipeline: parsePlcOpen -> mapImportedProject -> executeSfcPrograms.
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="SfcE2E"/>
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
        <step localId="1" name="Idle" initialStep="true"><position x="0" y="0"/></step>
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
    <globalVars>
      <variable name="Start"><type><BOOL/></type><initialValue><simpleValue value="FALSE"/></initialValue></variable>
      <variable name="Motor"><type><BOOL/></type><initialValue><simpleValue value="FALSE"/></initialValue></variable>
    </globalVars>
  </resource></configuration></configurations></instances>
</project>
''';

void main() {
  test('SFC POU imports as an executing chart (referenced condition + action)', () {
    final ir = parsePlcOpen(_kXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'sfc_e2e');
    final p = res.project;

    final chart = p.programs.firstWhere((pr) => pr.name == 'Chart');
    expect(chart.language, 'SequentialFunctionChart');
    expect(chart.sfcSteps.map((s) => s.name), containsAll(['Idle', 'Run']));
    expect(res.report.translatedSfcCount, 1);

    final rt = SfcRuntime();
    // Scan 1: Start is false -> stays in Idle; Motor stays false.
    executeSfcPrograms(p, 100, rt);
    expect(rt.active['Chart'], contains(chart.sfcSteps.firstWhere((s) => s.name == 'Idle').id));

    // Set Start; next scan the transition fires -> Run becomes active.
    writePath(p, 'Start', true);
    executeSfcPrograms(p, 100, rt);
    final runId = chart.sfcSteps.firstWhere((s) => s.name == 'Run').id;
    expect(rt.active['Chart'], contains(runId));

    // One more scan: Run is active, its action runs -> Motor := TRUE.
    executeSfcPrograms(p, 100, rt);
    expect(readPath(p, 'Motor'), true);
  });
}
