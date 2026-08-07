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
    // Normalize line endings before comparing: a Windows checkout can
    // rewrite the fixture's LF to CRLF (see .gitattributes in this
    // directory, which now pins it to eol=lf as belt-and-suspenders). The
    // byte-identity guarantee this test protects is about JSON *content*,
    // not platform line endings, so strip \r from both sides — a genuine
    // content difference still fails this comparison.
    final actualNormalized = actual.replaceAll('\r\n', '\n');
    final expectedNormalized = expected.replaceAll('\r\n', '\n');
    expect(actualNormalized, expectedNormalized,
        reason: 'the water plant must be moved verbatim — no data changes');
  });
}
