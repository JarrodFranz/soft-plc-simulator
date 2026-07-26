import 'package:flutter_test/flutter_test.dart';
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
}
