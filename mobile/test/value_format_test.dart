// QA sweep item A2 (#15): shared display formatting for REAL/FLOAT64 live
// values, used by both the Tags & Structs table/card views and the Tag
// Inspector dock so a float never prints full double precision
// (`80.83999999999966`) or an inconsistent bare `0` where a sibling row
// shows `0.0`.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/ui/value_format.dart';

void main() {
  test('trims noisy double precision to 3 decimals', () {
    expect(formatLiveValue(80.83999999999966), '80.84');
  });

  test('always keeps at least one decimal for whole numbers', () {
    expect(formatLiveValue(0.0), '0.0');
    expect(formatLiveValue(100.0), '100.0');
    expect(formatLiveValue(-12.0), '-12.0');
  });

  test('trims trailing zeros beyond the first decimal', () {
    expect(formatLiveValue(12.5), '12.5');
    expect(formatLiveValue(12.50), '12.5');
    expect(formatLiveValue(-12.500), '-12.5');
  });

  test('rounds to 3 decimal places, not truncates', () {
    expect(formatLiveValue(1.23456), '1.235');
  });

  test('passes through non-finite doubles unchanged', () {
    expect(formatLiveValue(double.nan), 'NaN');
    expect(formatLiveValue(double.infinity), 'Infinity');
    expect(formatLiveValue(double.negativeInfinity), '-Infinity');
  });
}
