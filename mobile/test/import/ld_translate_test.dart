import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ld_translate.dart';

void main() {
  group('parseIecDuration', () {
    test('parses seconds, ms, minutes, compound, and TIME# prefix', () {
      expect(parseIecDuration('T#5s'), 5000);
      expect(parseIecDuration('T#500ms'), 500);
      expect(parseIecDuration('T#2m'), 120000);
      expect(parseIecDuration('T#1m30s'), 90000);
      expect(parseIecDuration('T#1.5s'), 1500);
      expect(parseIecDuration('TIME#250ms'), 250);
      expect(parseIecDuration('t#3h'), 10800000);
    });
    test('returns null for non-durations', () {
      expect(parseIecDuration('hello'), isNull);
      expect(parseIecDuration('5'), isNull);
      expect(parseIecDuration(''), isNull);
    });
  });
}
