import 'dart:math' as math;

/// The three supported valve characteristics.
const String kValveLinear = 'linear';
const String kValveEqualPercentage = 'equalPercentage';
const String kValveQuickOpening = 'quickOpening';

/// Equal-percentage rangeability (fixed, standard).
const double kEqualPercentageR = 50.0;

/// Maps a raw valve fraction (`source / refValue`, typically 0..1) to an
/// effective gain through the selected valve characteristic.
///
/// - `linear` (or any unknown value): returns [fraction] unchanged, including
///   values > 1 or < 0 — numerically identical to the pre-feature behaviour.
/// - `equalPercentage`: fraction clamped to [0,1], then `(R^f - 1)/(R - 1)`
///   with R = 50 — convex; endpoints 0->0, 1->1.
/// - `quickOpening`: fraction clamped to [0,1], then `sqrt(f)` — concave;
///   endpoints 0->0, 1->1.
double valveCurveGain(String curve, double fraction) {
  switch (curve) {
    case kValveEqualPercentage:
      final f = fraction.clamp(0.0, 1.0);
      return (math.pow(kEqualPercentageR, f) - 1) / (kEqualPercentageR - 1);
    case kValveQuickOpening:
      final f = fraction.clamp(0.0, 1.0);
      return math.sqrt(f);
    default:
      return fraction;
  }
}
