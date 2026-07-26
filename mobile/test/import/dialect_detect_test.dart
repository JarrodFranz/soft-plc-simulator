import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/dialect_detect.dart';

void main() {
  test('detects L5X by RSLogix5000Content root', () {
    const l5x = '<?xml version="1.0"?>\n<RSLogix5000Content SchemaRevision="1.0" TargetType="Program"><Controller Name="C"/></RSLogix5000Content>';
    expect(detectDialect(l5x), ImportDialect.l5x);
  });
  test('still detects PLCopen', () {
    const p = '<?xml version="1.0"?><project xmlns="http://www.plcopen.org/xml/tc6_0201"/>';
    expect(detectDialect(p), ImportDialect.plcOpen);
  });
  test('unknown returns null', () {
    expect(detectDialect('<foo/>'), isNull);
  });
}
