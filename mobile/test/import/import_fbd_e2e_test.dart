// End-to-end proof: a handcrafted-but-spec-faithful PLCopen TC6 FBD POU imports
// as a real, executing FunctionBlockDiagram program. Exercises: <expression>
// operands (Task 1 parser fallback), component-per-network segmentation with a
// tag hop across networks (Task 3), and a custom-FB call routed to an instance
// (Task 4). Pipeline: parsePlcOpen -> mapImportedProject -> executeFbdPrograms.
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="FbdE2E"/>
  <types>
    <dataTypes/>
    <pous>
      <pou name="Scaler" pouType="functionBlock">
        <interface>
          <inputVars>
            <variable name="In"><type><REAL/></type></variable>
            <variable name="Gain"><type><REAL/></type></variable>
          </inputVars>
          <outputVars>
            <variable name="Out"><type><REAL/></type></variable>
          </outputVars>
        </interface>
        <body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Out := In * Gain;</xhtml></ST></body>
      </pou>
      <pou name="Logic" pouType="program">
        <interface><localVars/></interface>
        <body><FBD>
          <!-- Network A: Mid := Scaler(In := PV, Gain := 2.0) -->
          <inVariable localId="1"><position x="0" y="0"/><expression>PV</expression>
            <connectionPointOut/></inVariable>
          <inVariable localId="2"><position x="0" y="40"/><expression>2.0</expression>
            <connectionPointOut/></inVariable>
          <block localId="3" typeName="Scaler" instanceName="S1"><position x="60" y="0"/>
            <inputVariables>
              <variable formalParameter="In">
                <connectionPointIn><connection refLocalId="1"/></connectionPointIn></variable>
              <variable formalParameter="Gain">
                <connectionPointIn><connection refLocalId="2"/></connectionPointIn></variable>
            </inputVariables>
            <outputVariables>
              <variable formalParameter="Out"><connectionPointOut/></variable>
            </outputVariables>
          </block>
          <outVariable localId="4"><position x="150" y="0"/><expression>Mid</expression>
            <connectionPointIn><connection refLocalId="3" formalParameter="Out"/></connectionPointIn>
          </outVariable>
          <!-- Network B (below): CV := Mid (reads what network A wrote, same scan) -->
          <inVariable localId="5"><position x="0" y="200"/><expression>Mid</expression>
            <connectionPointOut/></inVariable>
          <outVariable localId="6"><position x="150" y="200"/><expression>CV</expression>
            <connectionPointIn><connection refLocalId="5"/></connectionPointIn>
          </outVariable>
        </FBD></body>
      </pou>
    </pous>
  </types>
  <instances>
    <configurations>
      <configuration name="Config">
        <resource name="Res">
          <globalVars>
            <variable name="PV"><type><REAL/></type><initialValue><simpleValue value="0.0"/></initialValue></variable>
            <variable name="Mid"><type><REAL/></type><initialValue><simpleValue value="0.0"/></initialValue></variable>
            <variable name="CV"><type><REAL/></type><initialValue><simpleValue value="0.0"/></initialValue></variable>
          </globalVars>
        </resource>
      </configuration>
    </configurations>
  </instances>
</project>
''';

void main() {
  test('FBD POU imports as an executing multi-network program with a custom FB', () {
    final ir = parsePlcOpen(_kXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'fbd_e2e');
    final p = res.project;

    // Scaler imported as a native FB; Logic is a real FBD program (not a stub).
    expect(p.fbDefinitions.map((f) => f.name), contains('Scaler'));
    final logic = p.programs.firstWhere((pr) => pr.name == 'Logic');
    expect(logic.language, 'FunctionBlockDiagram');
    expect(logic.fbdBlocks, isNotEmpty);
    expect(res.report.translatedFbdNetworkCount, 2);

    // The FB call routed to an instance tag, struct-typed to the FB.
    final scalerBlock = logic.fbdBlocks.firstWhere((b) => b.type == 'Scaler');
    expect(p.tags.firstWhere((t) => t.name == scalerBlock.tagBinding).dataType, 'Scaler');

    // And it RUNS: PV=10 -> Mid = 10*2 = 20 (network A) -> CV = 20 (network B,
    // reads Mid written by A in the same scan via network ordering).
    writePath(p, 'PV', 10.0);
    final rt = FbdRuntime();
    executeFbdPrograms(p, 100, rt);
    expect(readPath(p, 'Mid'), 20.0);
    expect(readPath(p, 'CV'), 20.0);
  });
}
