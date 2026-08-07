import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';

/// §4.5 guard: `proj_all_water` is MOVED to its own file and documented — its
/// data must stay byte-identical. Behaviour remains covered by the four
/// existing engine tests that already drive this project
/// (ld/fbd/st/sfc `_exec_integration_test.dart`).
void main() {
  test('proj_all_water toJson() equals the pre-split snapshot', () {
    final p = DefaultProjects.all().firstWhere((x) => x.id == 'proj_all_water');
    final actual = const JsonEncoder.withIndent('  ').convert(p.toJson());
    final expected =
        File('test/defaults/all_water_snapshot.json').readAsStringSync();
    expect(actual, expected,
        reason: 'the water plant must be moved verbatim — no data changes');
  });
}
