// End-to-end: a handcrafted L5X whose program FBD routine (two sheets, an
// aliased compare, a connector pair) becomes a real FunctionBlockDiagram
// program, and whose AOI FBD `Logic` routine becomes an FBD-bodied
// FbDefinition that EXECUTES per instance — two instances stay independent.
// Pipeline: parseL5x -> mapImportedProject -> executeLdPrograms +
// executeFbdPrograms.
//
// Corpus note: the available Rockwell corpus contains zero FBD content, so
// this feature is provable only against handcrafted, schema-faithful fixtures
// (the same precedent as import_fbd_e2e_test.dart and the AOI-ladder e2e).
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Ramp">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="BOOL" Usage="Input" Visible="true"/>
        <Parameter Name="Out" DataType="BOOL" Usage="Output" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="FBD"><FBDContent>
        <Sheet Number="1">
          <IRef ID="0" Operand="EnableIn" X="0" Y="0"/>
          <IRef ID="1" Operand="In" X="0" Y="40"/>
          <Function ID="2" Type="BAND" X="100" Y="0"/>
          <IRef ID="3" Operand="1000" X="100" Y="80"/>
          <Block ID="4" Type="TONR" Operand="T1" X="200" Y="0"/>
          <ORef ID="5" Operand="Out" X="300" Y="0"/>
          <Wire FromID="0" ToID="2" ToParam="In1"/>
          <Wire FromID="1" ToID="2" ToParam="In2"/>
          <Wire FromID="2" FromParam="Out" ToID="4" ToParam="TimerEnable"/>
          <Wire FromID="3" ToID="4" ToParam="PRE"/>
          <Wire FromID="4" FromParam="DN" ToID="5" ToParam="IN"/>
        </Sheet>
      </FBDContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
  <Tags>
    <Tag Name="R1" DataType="Ramp"/>
    <Tag Name="R2" DataType="Ramp"/>
    <Tag Name="Src1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Src2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Level" DataType="DINT"><Data Format="Decorated"><DataValue Value="10"/></Data></Tag>
    <Tag Name="HiAlarm" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Fbd" Type="FBD"><FBDContent>
        <Sheet Number="1">
          <IRef ID="0" Operand="Level" X="0" Y="0"/>
          <IRef ID="1" Operand="50" X="0" Y="40"/>
          <Block ID="2" Type="GRT" Operand="Grt_01" X="100" Y="0"/>
          <OCon ID="3" Name="Hi" X="200" Y="0"/>
          <Wire FromID="0" ToID="2" ToParam="SourceA"/>
          <Wire FromID="1" ToID="2" ToParam="SourceB"/>
          <Wire FromID="2" FromParam="Dest" ToID="3"/>
        </Sheet>
        <Sheet Number="2">
          <ICon ID="0" Name="Hi" X="0" Y="0"/>
          <ORef ID="1" Operand="HiAlarm" X="100" Y="0"/>
          <Wire FromID="0" ToID="1" ToParam="IN"/>
        </Sheet>
      </FBDContent></Routine>
      <Routine Name="Ladder" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[Ramp(R1,Src1,Dst1);]]></Text></Rung>
        <Rung Number="1"><Text><![CDATA[Ramp(R2,Src2,Dst2);]]></Text></Rung>
      </RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';

void main() {
  test('L5X FBD routines translate and FBD-Logic AOIs execute per instance', () {
    final ir = parseL5x(_kXml);
    expect(ir.dialect, ImportDialect.l5x);

    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_fbd_e2e');
    final p = res.project;

    // ---- the AOI became an FBD-bodied FbDefinition ----
    final fb = p.fbDefinitions.singleWhere((f) => f.name == 'Ramp');
    expect(fb.stSource, '');
    expect(fb.ladderRungs, isEmpty);
    expect(fb.fbdBlocks, isNotEmpty);
    expect(fb.fbdNetworks, hasLength(1));
    expect(fb.vars.map((v) => v.name), ['EnableIn', 'EnableOut', 'In', 'Out']);
    expect(fb.vars.firstWhere((v) => v.name == 'EnableIn').direction,
        FbVarDir.internal);
    // BAND -> AND, TONR -> TON (with the prominent verify warning).
    expect(fb.fbdBlocks.map((b) => b.type), contains('AND'));
    expect(fb.fbdBlocks.map((b) => b.type), contains('TON'));
    expect(
        res.report.warnings.any((w) =>
            w.severity == WarningSeverity.warning &&
            w.message.contains('AOI "Ramp"') &&
            w.message.contains('verify')),
        isTrue);

    // ---- both AOI-typed controller tags resolved to the FB's shape ----
    expect(readPath(p, 'R1.EnableIn'), isTrue);
    expect(readPath(p, 'R2.EnableIn'), isTrue);

    // ---- the program FBD routine became a real FBD program ----
    final fbdProg = p.programs.firstWhere((pr) => pr.name == 'Main_Fbd');
    expect(fbdProg.language, 'FunctionBlockDiagram');
    // The two sheets merged into ONE network via the Hi connector pair.
    expect(fbdProg.fbdBlocks.map((b) => b.network).toSet(), {0});
    expect(fbdProg.fbdBlocks.map((b) => b.type), contains('GT')); // GRT -> GT
    expect(fbdProg.fbdBlocks.any((b) => b.type == 'TAG_OUTPUT' && b.tagBinding == 'HiAlarm'),
        isTrue);

    // 1 AOI-body network + 1 program network, both counted as FBD.
    expect(res.report.translatedFbdNetworkCount, 2);
    expect(res.report.stubbedFbdNetworkCount, 0);

    final ladder = p.programs.firstWhere((pr) => pr.name == 'Main_Ladder');
    expect(ladder.language, 'LadderLogic');
    expect(ladder.rungs, hasLength(2));

    // ---- scan ----
    final ldRt = LdExecRuntime();
    final fbdRt = FbdRuntime();
    void scan() {
      executeLdPrograms(p, 500, ldRt, fbdRt: fbdRt);
      executeFbdPrograms(p, 500, fbdRt, ldRt: ldRt);
    }

    // The FBD program computes: Level (10) is not > 50.
    scan();
    expect(readPath(p, 'HiAlarm'), isFalse);
    writePath(p, 'Level', 80);
    scan();
    expect(readPath(p, 'HiAlarm'), isTrue);

    // Instance 1 only: its EnableIn-gated TON accumulates independently.
    expect(readPath(p, 'Dst1'), isFalse);
    writePath(p, 'Src1', true);
    scan(); // ET 500 < PT 1000
    expect(readPath(p, 'Dst1'), isFalse);
    scan(); // ET 1000 >= PT
    expect(readPath(p, 'Dst1'), isTrue);
    expect(readPath(p, 'Dst2'), isFalse); // instance 2 untouched

    // Instance 2 starts its own timer from zero: state is per instance.
    writePath(p, 'Src2', true);
    scan();
    expect(readPath(p, 'Dst2'), isFalse);
    scan();
    expect(readPath(p, 'Dst2'), isTrue);
    expect(readPath(p, 'Dst1'), isTrue); // still latched on
  });

  test('an FBD routine where NOTHING translates keeps the whole-POU stub', () {
    // The faithful-or-stub floor, end to end: a routine made only of unmapped
    // Rockwell blocks must fall into `ir_to_project`'s EXISTING else arm (an
    // empty LadderLogic-style stub program + a warning + graphicalStubCount),
    // not into a half-built FBD program.
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <Tags>
    <Tag Name="Raw" DataType="REAL"><Data Format="Decorated"><DataValue Value="1.0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Fbd" Type="FBD"><FBDContent>
        <Sheet Number="1">
          <IRef ID="0" Operand="Raw" X="0" Y="0"/>
          <Block ID="1" Type="SCL" Operand="S1" X="100" Y="0"/>
          <Wire FromID="0" ToID="1" ToParam="In"/>
        </Sheet>
      </FBDContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';
    final res = mapImportedProject(parseL5x(xml),
        projectName: 'P', projectId: 'l5x_fbd_stub');
    final prog = res.project.programs.firstWhere((pr) => pr.name == 'Main_Fbd');

    expect(prog.fbdBlocks, isEmpty);
    expect(res.report.translatedFbdNetworkCount, 0);
    expect(res.report.stubbedFbdNetworkCount, 1);
    expect(res.report.unsupportedFbdBlockTypes, contains('SCL'));
    expect(
        res.report.warnings.any((w) =>
            w.message.contains('Main_Fbd') &&
            w.message.contains('not yet translated')),
        isTrue);
  });
}
