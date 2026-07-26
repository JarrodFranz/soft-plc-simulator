import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';

void main() {
  test('rejects a non-L5X root', () {
    expect(() => parseL5x('<project/>'), throwsFormatException);
  });
  test('rejects malformed XML', () {
    expect(() => parseL5x('<RSLogix5000Content>'), throwsFormatException);
  });
  test('reads the controller name into the project', () {
    const xml = '<RSLogix5000Content TargetType="Controller"><Controller Name="DEVPAC"/></RSLogix5000Content>';
    final ir = parseL5x(xml);
    expect(ir.name, 'DEVPAC');
    expect(ir.types, isEmpty);
    expect(ir.pous, isEmpty);
    expect(ir.globalVars, isEmpty);
  });

  test('user DataType -> ImportedType with array + BIT-overlay members', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <DataTypes>
    <DataType Name="MyUdt" Class="User">
      <Members>
        <Member Name="Count" DataType="DINT" Dimension="0" Radix="Decimal"/>
        <Member Name="Buf" DataType="INT" Dimension="4" Radix="Decimal"/>
        <Member Name="Flags" DataType="DINT" Dimension="0" Radix="Hex">
          <DefaultData Format="Decorated"><DataValue Value="255"/></DefaultData>
        </Member>
        <Member Name="Bit0" DataType="BIT" Dimension="0" Target="Flags" BitNumber="0"/>
      </Members>
    </DataType>
    <DataType Name="Builtin" Class="ProductDefined"><Members/></DataType>
  </DataTypes>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    expect(ir.types.map((t) => t.name), ['MyUdt']); // ProductDefined skipped
    final udt = ir.types.single;
    final byName = {for (final f in udt.fields) f.name: f};
    expect(byName['Count']!.baseType, 'DINT');
    expect(byName['Buf']!.arrayLength, 4);
    expect(byName['Flags']!.initialValue, 255);
    expect(byName['Bit0']!.baseType, 'BOOL'); // BIT overlay -> BOOL
    expect(ir.warnings.any((w) => w.message.contains('bit overlay')), isTrue);
  });

  test('_l5xScalar parses radices', () {
    // Exercised indirectly here via a hex member default.
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <DataTypes><DataType Name="U" Class="User"><Members>
    <Member Name="M" DataType="DINT" Dimension="0" Radix="Hex">
      <DefaultData Format="Decorated"><DataValue Value="16#0000_ffff" Radix="Hex"/></DefaultData>
    </Member>
  </Members></DataType></DataTypes>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    expect(ir.types.single.fields.single.initialValue, 0xffff);
  });

  test('_l5xScalar never throws on an out-of-range radix-prefix base', () {
    // Malformed/hand-edited L5X: base 99 is outside int.parse's 2..36 range.
    // Dart's int.tryParse(..., radix:) THROWS RangeError for out-of-range
    // bases instead of returning null — parseL5x must not propagate that.
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <DataTypes><DataType Name="U" Class="User"><Members>
    <Member Name="Bad" DataType="DINT" Dimension="0" Radix="Decimal">
      <DefaultData Format="Decorated"><DataValue Value="99#5"/></DefaultData>
    </Member>
    <Member Name="Good" DataType="DINT" Dimension="0" Radix="Hex">
      <DefaultData Format="Decorated"><DataValue Value="16#0000_ffff" Radix="Hex"/></DefaultData>
    </Member>
  </Members></DataType></DataTypes>
</Controller></RSLogix5000Content>''';
    late final dynamic ir;
    expect(() => ir = parseL5x(xml), returnsNormally);
    final byName = {for (final f in ir.types.single.fields) f.name: f};
    expect(byName['Bad']!.initialValue, isNull);
    expect(byName['Good']!.initialValue, 0xffff); // regression check
  });

  test('AOI -> functionBlock POU with params, skipped EnableIn/Out, ST body', () {
    const xml = '''
<RSLogix5000Content TargetType="Controller"><Controller Name="C">
  <AddOnInstructionDefinitions>
    <AddOnInstructionDefinition Name="Scaler">
      <Parameters>
        <Parameter Name="EnableIn" DataType="BOOL" Usage="Input" Visible="false"/>
        <Parameter Name="EnableOut" DataType="BOOL" Usage="Output" Visible="false"/>
        <Parameter Name="In" DataType="REAL" Usage="Input" Visible="true"/>
        <Parameter Name="Gain" DataType="REAL" Usage="Input" Visible="true">
          <DefaultData Format="Decorated"><DataValue Value="2.0" Radix="Float"/></DefaultData>
        </Parameter>
        <Parameter Name="Out" DataType="REAL" Usage="Output" Visible="true"/>
      </Parameters>
      <LocalTags><LocalTag Name="Tmp" DataType="REAL"/></LocalTags>
      <Routines>
        <Routine Name="Logic" Type="ST"><STContent>
          <Line Number="0"><![CDATA[Out := In * Gain;]]></Line>
        </STContent></Routine>
      </Routines>
    </AddOnInstructionDefinition>
    <AddOnInstructionDefinition Name="LadderAoi">
      <Parameters><Parameter Name="X" DataType="BOOL" Usage="Input" Visible="true"/></Parameters>
      <Routines><Routine Name="Logic" Type="RLL"><RLLContent><Rung Number="0"><Text><![CDATA[NOP();]]></Text></Rung></RLLContent></Routine></Routines>
    </AddOnInstructionDefinition>
  </AddOnInstructionDefinitions>
</Controller></RSLogix5000Content>''';
    final ir = parseL5x(xml);
    final scaler = ir.pous.firstWhere((p) => p.name == 'Scaler');
    expect(scaler.kind, PouKind.functionBlock);
    expect(scaler.lang, PouLanguage.st);
    expect(scaler.localVars.map((v) => v.name), ['In', 'Gain', 'Out', 'Tmp']); // EnableIn/Out skipped
    expect(scaler.localVars.firstWhere((v) => v.name == 'In').scope, VarScope.input);
    expect(scaler.localVars.firstWhere((v) => v.name == 'Out').scope, VarScope.output);
    expect(scaler.localVars.firstWhere((v) => v.name == 'Tmp').scope, VarScope.local);
    expect(scaler.localVars.firstWhere((v) => v.name == 'Gain').initialValue, 2.0);
    expect((scaler.body as TextBody).source, 'Out := In * Gain;');

    // RLL-bodied AOI: interface imported, empty body + warning.
    final ladder = ir.pous.firstWhere((p) => p.name == 'LadderAoi');
    expect((ladder.body as TextBody).source, '');
    expect(ir.warnings.any((w) => w.message.contains('LadderAoi') && w.message.contains('logic')), isTrue);
  });
}
