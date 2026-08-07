// End-to-end proof: a handcrafted L5X SFC routine imports as a real, executing
// SequentialFunctionChart program. Exercises an initial step with an N action,
// a linear transition, a SELECTION branch whose legs select on a tag, and a
// SIMULTANEOUS fork/join. Pipeline: parseL5x -> mapImportedProject ->
// executeSfcPrograms. A second document proves the stub path and §7's message
// counts.
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

String _t(int id, String name, String cond) =>
    '<Transition ID="$id" Operand="$name"><Condition><STContent>'
    '<Line Number="0"><![CDATA[$cond]]></Line></STContent></Condition></Transition>';

String _act(int id, String name, String st) =>
    '<Action ID="$id" Operand="$name" Qualifier="N"><Body><STContent>'
    '<Line Number="0"><![CDATA[$st]]></Line></STContent></Body></Action>';

/// Idle -T2(Start)-> Charge -selection(ModeA | ModeB)-> PathA | PathB
///   -> Prep -T14(Go, fork)-> {Mix1, Mix2} -> {MixADone, MixBDone}
///   -T28(Go, join)-> Done
final String _kChartXml = '''
<?xml version="1.0" encoding="utf-8"?>
<RSLogix5000Content TargetType="Controller"><Controller Name="SfcE2E">
  <Tags>
    <Tag Name="Start" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="ModeA" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="ModeB" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Go" DataType="BOOL"><Data Format="Decorated"><DataValue Value="1"/></Data></Tag>
    <Tag Name="Ready" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="Charging" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="A_On" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="B_On" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="M1" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
    <Tag Name="M2" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag>
  </Tags>
  <Programs><Program Name="Main"><Tags/><Routines>
    <Routine Name="Seq" Type="SFC"><SFCContent>
      <Step ID="1" X="0" Y="0" Operand="Idle" InitialStep="true" Preset="0">
        ${_act(101, 'SetReady', 'Ready := TRUE;')}
      </Step>
      ${_t(2, 'ToCharge', 'Start')}
      <Step ID="3" X="0" Y="80" Operand="Charge">
        ${_act(103, 'DoCharge', 'Charging := TRUE;')}
      </Step>
      <Branch ID="10" X="0" Y="120" BranchType="Selection"><Leg ID="11"/><Leg ID="12"/></Branch>
      ${_t(4, 'PickA', 'ModeA')}
      <Step ID="5" X="-60" Y="200" Operand="PathA">
        ${_act(105, 'DoA', 'A_On := TRUE;')}
      </Step>
      ${_t(6, 'LegADone', 'Go')}
      ${_t(7, 'PickB', 'ModeB')}
      <Step ID="8" X="60" Y="200" Operand="PathB">
        ${_act(108, 'DoB', 'B_On := TRUE;')}
      </Step>
      ${_t(9, 'LegBDone', 'Go')}
      <Step ID="13" X="0" Y="320" Operand="Prep"/>
      ${_t(14, 'Fork', 'Go')}
      <Branch ID="20" X="0" Y="380" BranchType="Simultaneous"><Leg ID="21"/><Leg ID="22"/></Branch>
      <Step ID="22001" X="-60" Y="440" Operand="Mix1">
        ${_act(1220, 'DoM1', 'M1 := TRUE;')}
      </Step>
      ${_t(24, 'M1Done', 'Go')}
      <Step ID="25" X="-60" Y="520" Operand="MixADone"/>
      <Step ID="23001" X="60" Y="440" Operand="Mix2">
        ${_act(1230, 'DoM2', 'M2 := TRUE;')}
      </Step>
      ${_t(26, 'M2Done', 'Go')}
      <Step ID="27" X="60" Y="520" Operand="MixBDone"/>
      ${_t(28, 'Join', 'Go')}
      <Step ID="29" X="0" Y="600" Operand="Done"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="3"/>
      <DirectedLink FromID="3" ToID="10"/>
      <DirectedLink FromID="11" ToID="4"/>
      <DirectedLink FromID="4" ToID="5"/>
      <DirectedLink FromID="5" ToID="6"/>
      <DirectedLink FromID="6" ToID="11"/>
      <DirectedLink FromID="12" ToID="7"/>
      <DirectedLink FromID="7" ToID="8"/>
      <DirectedLink FromID="8" ToID="9"/>
      <DirectedLink FromID="9" ToID="12"/>
      <DirectedLink FromID="10" ToID="13"/>
      <DirectedLink FromID="13" ToID="14"/>
      <DirectedLink FromID="14" ToID="20"/>
      <DirectedLink FromID="21" ToID="22001"/>
      <DirectedLink FromID="22" ToID="23001"/>
      <DirectedLink FromID="22001" ToID="24"/>
      <DirectedLink FromID="24" ToID="25"/>
      <DirectedLink FromID="23001" ToID="26"/>
      <DirectedLink FromID="26" ToID="27"/>
      <DirectedLink FromID="25" ToID="21"/>
      <DirectedLink FromID="27" ToID="22"/>
      <DirectedLink FromID="20" ToID="28"/>
      <DirectedLink FromID="28" ToID="29"/>
    </SFCContent></Routine>
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''';

/// The same shape, cut down, with one `<Stop>` — the whole POU must stub.
const String _kStopXml = '''
<?xml version="1.0" encoding="utf-8"?>
<RSLogix5000Content TargetType="Controller"><Controller Name="SfcStop">
  <Tags><Tag Name="Start" DataType="BOOL"><Data Format="Decorated"><DataValue Value="0"/></Data></Tag></Tags>
  <Programs><Program Name="Main"><Tags/><Routines>
    <Routine Name="Seq" Type="SFC"><SFCContent>
      <Step ID="1" Operand="Idle" InitialStep="true"/>
      <Transition ID="2"><Condition><STContent>
        <Line Number="0"><![CDATA[Start]]></Line></STContent></Condition></Transition>
      <Step ID="3" Operand="Run"/>
      <Stop ID="4" X="0" Y="200" Operand="Halt"/>
      <DirectedLink FromID="1" ToID="2"/>
      <DirectedLink FromID="2" ToID="3"/>
      <DirectedLink FromID="3" ToID="4"/>
    </SFCContent></Routine>
  </Routines></Program></Programs>
</Controller></RSLogix5000Content>''';

void main() {
  test('an L5X SFC routine imports as an executing chart (selection + fork/join)', () {
    final ir = parseL5x(_kChartXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_sfc_e2e');
    final p = res.project;

    final chart = p.programs.firstWhere((pr) => pr.name == 'Main_Seq');
    expect(chart.language, 'SequentialFunctionChart');
    expect(
        chart.sfcSteps.map((s) => s.name),
        containsAll(<String>[
          'Idle', 'Charge', 'PathA', 'PathB', 'Prep',
          'Mix1', 'Mix2', 'MixADone', 'MixBDone', 'Done',
        ]));
    expect(chart.sfcSteps.firstWhere((s) => s.name == 'Idle').isInitial, isTrue);
    expect(chart.sfcTransitions.where((t) => t.kind == 'parallelFork'), hasLength(1));
    expect(chart.sfcTransitions.where((t) => t.kind == 'parallelJoin'), hasLength(1));
    expect(res.report.translatedSfcCount, 1);
    expect(res.report.stubbedSfcCount, 0);
    expect(res.report.sfcStubReasons, isEmpty);
    expect(
        res.report.warnings.where((w) =>
            w.severity == WarningSeverity.warning &&
            w.message.contains('Main_Seq')),
        isEmpty);

    String idOf(String name) =>
        chart.sfcSteps.firstWhere((s) => s.name == name).id;
    final rt = SfcRuntime();
    void tick() => executeSfcPrograms(p, 100, rt);
    Set<String> active() => rt.active['Main_Seq'] ?? <String>{};

    // `Go` is the always-true guard on the leg-closing / fork / join
    // transitions. Written explicitly rather than leaned on the imported
    // literal, so this test proves the CHART, not BOOL literal coercion.
    writePath(p, 'Go', true);

    // Scan 1: Idle is active, its action runs; Start is false -> no move.
    tick();
    expect(active(), {idOf('Idle')});
    expect(readPath(p, 'Ready'), true);

    // Scan 2: Start fires the linear transition.
    writePath(p, 'Start', true);
    tick();
    expect(active(), {idOf('Charge')});

    // Scan 3: Charge acts; the selection picks the leg whose condition is
    // true (first-true-wins over ModeA then ModeB).
    writePath(p, 'ModeA', true);
    tick();
    expect(readPath(p, 'Charging'), true);
    expect(active(), {idOf('PathA')});

    // Scan 4: PathA acts, then its leg-closing transition merges to Prep.
    tick();
    expect(readPath(p, 'A_On'), true);
    expect(readPath(p, 'B_On') == true, isFalse,
        reason: 'the unselected leg never ran');
    expect(active(), {idOf('Prep')});

    // Scan 5: the fork activates BOTH parallel steps at once.
    tick();
    expect(active(), {idOf('Mix1'), idOf('Mix2')});

    // Scan 6: both parallel actions run, both legs advance.
    tick();
    expect(readPath(p, 'M1'), true);
    expect(readPath(p, 'M2'), true);
    expect(active(), {idOf('MixADone'), idOf('MixBDone')});

    // Scan 7: the join waits for BOTH, then fires.
    tick();
    expect(active(), {idOf('Done')});
  });

  test('an SFC routine containing a <Stop> stubs the whole POU, with two messages', () {
    final ir = parseL5x(_kStopXml);
    expect(
        ir.warnings.where((w) => w.severity == WarningSeverity.warning),
        isEmpty,
        reason: 'the parser no longer pre-judges an SFC routine');

    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_sfc_stop');
    expect(res.report.translatedSfcCount, 0);
    expect(res.report.stubbedSfcCount, 1);
    expect(res.report.sfcStubReasons['complex-topology'], 1);

    final loud = res.report.warnings
        .where((w) =>
            w.severity == WarningSeverity.warning &&
            w.message.contains('Main_Seq'))
        .toList();
    expect(loud, hasLength(2), reason: loud.map((w) => w.message).toString());
    expect(loud.any((w) => w.message.contains('not translated (')), isTrue);
    expect(loud.any((w) => w.message.contains('graphical body not yet translated')),
        isTrue);

    final prog = res.project.programs.firstWhere((pr) => pr.name == 'Main_Seq');
    expect(prog.language, 'SequentialFunctionChart');
    expect(prog.sfcSteps, isEmpty);
  });
}
