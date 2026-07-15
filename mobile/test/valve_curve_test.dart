import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/valve_curve.dart';

void main() {
  test('linear passes the fraction through unchanged (incl. out of range)', () {
    expect(valveCurveGain(kValveLinear, 0.0), 0.0);
    expect(valveCurveGain(kValveLinear, 0.37), 0.37);
    expect(valveCurveGain(kValveLinear, 1.5), 1.5);
    expect(valveCurveGain(kValveLinear, -0.2), -0.2);
    // Unknown curve also falls back to linear passthrough.
    expect(valveCurveGain('bogus', 0.42), 0.42);
  });

  test('equal-percentage: endpoints, convex, clamped', () {
    expect(valveCurveGain(kValveEqualPercentage, 0.0), closeTo(0.0, 1e-9));
    expect(valveCurveGain(kValveEqualPercentage, 1.0), closeTo(1.0, 1e-9));
    // Convex: at half travel the gain is well below 0.5.
    expect(valveCurveGain(kValveEqualPercentage, 0.5), lessThan(0.5));
    // Clamped to [0,1].
    expect(valveCurveGain(kValveEqualPercentage, 1.5),
        closeTo(valveCurveGain(kValveEqualPercentage, 1.0), 1e-9));
    expect(valveCurveGain(kValveEqualPercentage, -0.3),
        closeTo(valveCurveGain(kValveEqualPercentage, 0.0), 1e-9));
  });

  test('quick-opening: endpoints, concave, clamped', () {
    expect(valveCurveGain(kValveQuickOpening, 0.0), closeTo(0.0, 1e-9));
    expect(valveCurveGain(kValveQuickOpening, 1.0), closeTo(1.0, 1e-9));
    // Concave: at half travel the gain is above 0.5 (sqrt(0.5) ~= 0.707).
    expect(valveCurveGain(kValveQuickOpening, 0.5), greaterThan(0.5));
    expect(valveCurveGain(kValveQuickOpening, 1.7),
        closeTo(valveCurveGain(kValveQuickOpening, 1.0), 1e-9));
  });

  test('both curves are monotonic increasing on [0,1]', () {
    for (final c in [kValveEqualPercentage, kValveQuickOpening]) {
      double prev = -1;
      for (var i = 0; i <= 10; i++) {
        final g = valveCurveGain(c, i / 10);
        expect(g, greaterThanOrEqualTo(prev));
        prev = g;
      }
    }
  });
}
