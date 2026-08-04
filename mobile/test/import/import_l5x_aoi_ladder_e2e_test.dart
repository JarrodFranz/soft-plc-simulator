// End-to-end: a handcrafted L5X whose AOI has an RLL `Logic` routine compiles
// to a ladder-bodied FbDefinition and EXECUTES — two instances stay
// independent. Pipeline: parseL5x -> mapImportedProject -> executeLdPrograms.
//
// Corpus note: every AOI in the available Rockwell corpus is ST-bodied, so
// this feature is provable only against handcrafted, spec-faithful fixtures.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kXml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Latch">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="BOOL" Usage="Input" Visible="true"/>
        <Parameter Name="Out" DataType="BOOL" Usage="Output" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[XIC(EnableIn)XIC(In)OTE(Out);]]></Text></Rung>
      </RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
  <Tags>
    <Tag Name="A1" DataType="Latch"/>
    <Tag Name="A2" DataType="Latch"/>
    <Tag Name="Src1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Src2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[Latch(A1,Src1,Dst1);]]></Text></Rung>
        <Rung Number="1"><Text><![CDATA[Latch(A2,Src2,Dst2);]]></Text></Rung>
      </RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';

void main() {
  test('an RLL-Logic AOI imports as a ladder-bodied FB and executes per instance', () {
    final ir = parseL5x(_kXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'aoi_ladder_e2e');
    final p = res.project;

    // The AOI became a LADDER-bodied FbDefinition (no ST source).
    final fb = p.fbDefinitions.singleWhere((f) => f.name == 'Latch');
    expect(fb.stSource, '');
    expect(fb.ladderRungs, hasLength(1));
    expect(fb.vars.map((v) => v.name), ['EnableIn', 'EnableOut', 'In', 'Out']);
    expect(fb.vars.firstWhere((v) => v.name == 'EnableIn').direction, FbVarDir.internal);

    // Both AOI-typed controller tags resolved to the FB's composite shape.
    expect(readPath(p, 'A1.EnableIn'), isTrue);
    expect(readPath(p, 'A2.EnableIn'), isTrue);

    // 1 AOI-body rung + 2 program rungs, all counted as RLL.
    expect(res.report.translatedRllRungCount, 3);

    final prog = p.programs.firstWhere((pr) => pr.name == 'Main_Logic');
    expect(prog.language, 'LadderLogic');
    expect(prog.rungs, hasLength(2));

    final rt = LdExecRuntime();

    // Nothing driven yet.
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'Dst1'), isFalse);
    expect(readPath(p, 'Dst2'), isFalse);

    // Drive instance 1 only.
    writePath(p, 'Src1', true);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'A1.Out'), isTrue);
    expect(readPath(p, 'Dst1'), isTrue);
    expect(readPath(p, 'A2.Out'), isFalse);
    expect(readPath(p, 'Dst2'), isFalse); // the second instance is independent

    // Swap: instance 2 only.
    writePath(p, 'Src1', false);
    writePath(p, 'Src2', true);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'Dst1'), isFalse);
    expect(readPath(p, 'Dst2'), isTrue);
  });

  test('an AOI whose RLL logic cannot compile degrades to a no-op + warning', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Bad">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="BOOL" Usage="Input" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[CPT(Dest,Expr);]]></Text></Rung>
      </RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
  <Tags><Tag Name="B1" DataType="Bad"/></Tags>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'aoi_ladder_bad');
    final fb = res.project.fbDefinitions.single;
    expect(fb.name, 'Bad');
    expect(fb.ladderRungs, isEmpty);   // no-op, exactly as before this feature
    expect(fb.stSource, '');
    expect(res.report.unsupportedRllInstructions, contains('CPT'));
    expect(res.report.warnings.any((w) => w.message.contains('Bad')), isTrue);
  });

  // F1: an AOI LocalTag whose DataType is an EARLIER-defined AOI must resolve
  // to that FB's composite shape, not fall back to the INT16 scalar default —
  // otherwise every nested read/write silently no-ops.
  test('an AOI LocalTag typed as an earlier AOI resolves and the nested body executes', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Inner">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="BOOL" Usage="Input" Visible="true"/>
        <Parameter Name="Out" DataType="BOOL" Usage="Output" Visible="true"/>
      </Parameters>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[XIC(EnableIn)XIC(In)OTE(Out);]]></Text></Rung>
      </RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
    <AddOnInstructionDefinition Name="Outer">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="BOOL" Usage="Input" Visible="true"/>
        <Parameter Name="Out" DataType="BOOL" Usage="Output" Visible="true"/>
      </Parameters>
      <LocalTags><LocalTag Name="Nest" DataType="Inner"/></LocalTags>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[Inner(Nest,In,Out);]]></Text></Rung>
      </RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
  <Tags>
    <Tag Name="O1" DataType="Outer"/>
    <Tag Name="Src" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Dst" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[Outer(O1,Src,Dst);]]></Text></Rung>
      </RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'aoi_in_aoi');
    final p = res.project;

    // The nested LocalTag kept its FB type (the bug normalized it to INT16).
    final outer = p.fbDefinitions.singleWhere((f) => f.name == 'Outer');
    expect(outer.vars.firstWhere((v) => v.name == 'Nest').dataType, 'Inner');
    expect(outer.vars.firstWhere((v) => v.name == 'Nest').direction, FbVarDir.internal);

    // The instance member is a real composite, seeded from Inner's defaults.
    expect(readPath(p, 'O1.Nest.EnableIn'), isTrue);
    expect(readPath(p, 'O1.Nest.Out'), isFalse);

    // Outer's rung routed to a real FB-call node (not a stub).
    expect(outer.ladderRungs, hasLength(1));
    expect(
        outer.ladderRungs.first.nodes
            .any((n) => n.kind == LdKind.block && n.blockType == 'Inner'),
        isTrue);

    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'O1.Nest.Out'), isFalse);
    expect(readPath(p, 'Dst'), isFalse);

    // Drive it: the value has to travel Src -> O1.In -> O1.Nest.In ->
    // O1.Nest.Out -> O1.Out -> Dst. Under the INT16 bug every nested hop
    // no-ops and these all stay 0/false.
    writePath(p, 'Src', true);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'O1.Nest.In'), isTrue);
    expect(readPath(p, 'O1.Nest.Out'), isTrue);
    expect(readPath(p, 'O1.Out'), isTrue);
    expect(readPath(p, 'Dst'), isTrue);

    writePath(p, 'Src', false);
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'O1.Nest.Out'), isFalse);
    expect(readPath(p, 'Dst'), isFalse);
  });

  // F2: a `TIMER` LocalTag has to normalize to the builtin TIMER composite, or
  // the compiled TON's `.ACC`/`.PRE`/`.DN` writes all land on a scalar and
  // silently vanish.
  test('an AOI TIMER LocalTag drives a real TON across scans', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Dly">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="Run" DataType="BOOL" Usage="Input" Visible="true"/>
        <Parameter Name="Done" DataType="BOOL" Usage="Output" Visible="true"/>
      </Parameters>
      <LocalTags><LocalTag Name="T" DataType="TIMER"/></LocalTags>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[XIC(Run)TON(T,1000,0)OTE(Done);]]></Text></Rung>
      </RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
  <Tags>
    <Tag Name="D1" DataType="Dly"/>
    <Tag Name="D2" DataType="Dly"/>
    <Tag Name="Go" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Fin" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main">
    <Tags/>
    <Routines>
      <Routine Name="Logic" Type="RLL"><RLLContent>
        <Rung Number="0"><Text><![CDATA[Dly(D1,Go,Fin);]]></Text></Rung>
      </RLLContent></Routine>
    </Routines>
  </Program></Programs>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'aoi_timer');
    final p = res.project;

    final fb = p.fbDefinitions.singleWhere((f) => f.name == 'Dly');
    expect(fb.vars.firstWhere((v) => v.name == 'T').dataType, 'TIMER');
    expect(readPath(p, 'D1.T.ACC'), 0);

    final rt = LdExecRuntime();
    writePath(p, 'Go', true);

    executeLdPrograms(p, 600, rt);
    expect(readPath(p, 'D1.T.PRE'), 1000);
    expect(readPath(p, 'D1.T.ACC'), 600); // accumulates inside the instance
    expect(readPath(p, 'D1.T.DN'), isFalse);
    expect(readPath(p, 'Fin'), isFalse);

    executeLdPrograms(p, 600, rt);
    expect(readPath(p, 'D1.T.ACC'), 1000); // clamped at the preset
    expect(readPath(p, 'D1.T.DN'), isTrue);
    expect(readPath(p, 'Fin'), isTrue);

    // The second, uncalled instance owns a SEPARATE timer struct — composite
    // var defaults must not be shared objects between instances.
    expect(readPath(p, 'D2.T.ACC'), 0);
    expect(readPath(p, 'D2.T.DN'), isFalse);
  });
}
