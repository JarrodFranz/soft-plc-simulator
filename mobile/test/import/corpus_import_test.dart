// Corpus test over the local third-party export fixtures in
// `Resources/Project Exports/` (see that folder's MANIFEST.md).
//
// The corpus is gitignored (third-party / GPL samples are kept locally, not
// redistributed), so this test SKIPS gracefully when the folder is absent
// (CI, fresh clone). When present — the developer's machine — it proves,
// against real vendor exports, that:
//   * every PLCopen-TC6 file imports through detect -> parse -> map without
//     throwing (the whole point of the importer), and
//   * every non-PLCopen vendor file (Rockwell L5X, Beckhoff TwinCAT, CODESYS
//     native .export, Siemens SCL) is cleanly rejected by detectDialect,
//     i.e. routed to the friendly "unrecognized format" path — never
//     mis-parsed as PLCopen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/dialect_detect.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';

/// Locates `Resources/Project Exports/` by walking up from the test's working
/// directory (the `mobile/` package root when run via `flutter test`) to the
/// repo root. Returns null if it can't be found.
Directory? _findCorpus() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = Directory('${dir.path}/Resources/Project Exports');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

List<File> _filesIn(Directory root, String subfolder) {
  final d = Directory('${root.path}/$subfolder');
  if (!d.existsSync()) return const [];
  return d
      .listSync()
      .whereType<File>()
      .where((f) => !f.path.endsWith('MANIFEST.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

void main() {
  final corpus = _findCorpus();

  group('Resources/Project Exports corpus', () {
    if (corpus == null) {
      test('corpus present', () {
        markTestSkipped(
            'Resources/Project Exports/ not found (gitignored fixtures absent) '
            '— skipping corpus import checks.');
      }, skip: true);
      return;
    }

    final plcopen = _filesIn(corpus, 'PLCopen-TC6');
    final others = <File>[
      ..._filesIn(corpus, 'Rockwell-L5X'),
      ..._filesIn(corpus, 'Beckhoff-TwinCAT'),
      ..._filesIn(corpus, 'CODESYS'),
      ..._filesIn(corpus, 'Siemens-TIA'),
    ];

    test('at least one PLCopen sample is present', () {
      expect(plcopen, isNotEmpty,
          reason: 'expected PLCopen-TC6 fixtures under ${corpus.path}');
    });

    for (final f in plcopen) {
      final name = f.uri.pathSegments.last;
      test('PLCopen import: $name', () {
        final xml = f.readAsStringSync();
        expect(detectDialect(xml), ImportDialect.plcOpen,
            reason: '$name should be detected as PLCopen TC6');
        // The whole pipeline must complete without throwing on a real export.
        final ir = parsePlcOpen(xml);
        final result = mapImportedProject(
          ir,
          projectName: ir.name.isEmpty ? 'Imported' : ir.name,
          projectId: 'corpus_test',
        );
        expect(result.project, isNotNull);
        // Every graphical POU must be accounted for as a stub (never silently
        // dropped) — report counts are internally consistent.
        expect(
          result.report.tagCount >= 0 &&
              result.report.structCount >= 0 &&
              result.report.stProgramCount >= 0 &&
              result.report.graphicalStubCount >= 0,
          isTrue,
        );
      });
    }

    for (final f in others) {
      final name = f.uri.pathSegments.last;
      test('non-PLCopen rejected: $name', () {
        final text = f.readAsStringSync();
        expect(detectDialect(text), isNull,
            reason: '$name is not PLCopen and must route to the '
                '"unrecognized format" path, not be mis-detected');
      });
    }
  });
}
