import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/ld_layout.dart';

void main() {
  test('kLdGapHalf is half the inter-cell gap', () {
    // gap = kLdColW - kLdCellW = 116 - 66 = 50; half = 25.
    expect(kLdGapHalf, 25.0);
  });

  test('ldRiserXBefore centres in the gap left of the column', () {
    // col 1 left edge = 116; riser sits 25px before it.
    expect(ldRiserXBefore(1), 91.0);
    expect(ldRiserXBefore(2), 207.0);
  });

  test('ldRiserXAfter centres in the gap right of the column', () {
    // col 1: right edge = 116 + 66 = 182; +25 = 207.
    expect(ldRiserXAfter(1), 207.0);
    expect(ldRiserXAfter(0), 91.0);
  });
}
