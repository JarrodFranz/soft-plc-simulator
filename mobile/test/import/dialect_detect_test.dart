import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/dialect_detect.dart';

void main() {
  test('recognizes a PLCopen TC6 project root', () {
    const xml = '<?xml version="1.0"?>\n'
        '<project xmlns="http://www.plcopen.org/xml/tc6_0201"><contentHeader/></project>';
    expect(detectDialect(xml), ImportDialect.plcOpen);
  });
  test('null for a non-PLCopen XML document', () {
    expect(detectDialect('<RSLogix5000Content/>'), isNull);
  });
  test('null for junk / malformed, never throws', () {
    expect(() => detectDialect('not xml at all'), returnsNormally);
    expect(detectDialect('not xml at all'), isNull);
    expect(detectDialect(''), isNull);
  });
}
