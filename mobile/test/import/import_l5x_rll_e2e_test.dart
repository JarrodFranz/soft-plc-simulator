// End-to-end: a handcrafted L5X with an RLL routine compiles to a real
// LadderLogic program and executes. Pipeline: parseL5x -> mapImportedProject ->
// executeLdPrograms. Plus a smoke run over the real Rockwell corpus (skips if
// the gitignored fixtures are absent).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
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
