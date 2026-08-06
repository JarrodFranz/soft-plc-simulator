import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/fbd_pins.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

/// The spec's §7 invariants. A default project that violates one of these does
/// not throw at runtime — the engine silently reads null/0/false — so these are
/// the only thing standing between a typo and a dead demo.
void main() {
  final projects = DefaultProjects.all();

  /// True if [ref] is a real tag path in [p], a numeric/boolean literal, or a
  /// reserved System member.
  bool resolves(PlcProject p, String ref) {
    if (ref.isEmpty) return true;
    if (ref == 'true' || ref == 'false' || ref == 'TRUE' || ref == 'FALSE') {
      return true;
    }
    if (num.tryParse(ref) != null) return true;
    if (ref.startsWith('System.')) return true;
    final root = ref.split('.').first.split('[').first;
    return p.tags.any((t) => t.name == root);
  }

  test('project ids and names are unique across the catalog', () {
    final ids = projects.map((p) => p.id).toList();
    final names = projects.map((p) => p.name).toList();
    expect(ids.toSet().length, ids.length, reason: 'duplicate project id');
    expect(names.toSet().length, names.length,
        reason: 'duplicate project NAME — the dropdown switches by name');
  });

  test('the catalog order the shell and the repository depend on holds', () {
    expect(projects.length, 7);
    expect(projects.first.id, 'proj_ld_conveyor_line');
    expect(projects.first.programs.first.language, 'LadderLogic');
    expect(projects.first.tags.first.name, 'Start_PB');
    expect(projects.last.id, 'proj_process_lab');
  });

  for (final p in projects) {
    group(p.id, () {
      test('ids are unique within the project', () {
        final tagNames = p.tags.map((t) => t.name).toList();
        expect(tagNames.toSet().length, tagNames.length,
            reason: 'duplicate tag name');
        final simIds = p.simRules.map((r) => r.id).toList();
        expect(simIds.toSet().length, simIds.length,
            reason: 'duplicate SimRule id');
        final taskNames = p.tasks.map((t) => t.name).toList();
        expect(taskNames.toSet().length, taskNames.length,
            reason: 'duplicate task name');
        final progNames = p.programs.map((x) => x.name).toList();
        expect(progNames.toSet().length, progNames.length,
            reason: 'duplicate program name');
        for (final prog in p.programs) {
          final blockIds = prog.fbdBlocks.map((b) => b.id).toList();
          expect(blockIds.toSet().length, blockIds.length,
              reason: 'duplicate FbdBlock id in ${prog.name}');
          final stepIds = prog.sfcSteps.map((s) => s.id).toList();
          expect(stepIds.toSet().length, stepIds.length,
              reason: 'duplicate SfcStep id in ${prog.name}');
          final transIds = prog.sfcTransitions.map((t) => t.id).toList();
          expect(transIds.toSet().length, transIds.length,
              reason: 'duplicate SfcTransition id in ${prog.name}');
        }
        final componentIds = [
          for (final h in p.hmis)
            for (final c in h.components) '${h.id}/${c.id}',
        ];
        expect(componentIds.toSet().length, componentIds.length,
            reason: 'duplicate HmiComponent id within a screen');
        final screenIds = p.hmis.map((h) => h.id).toList();
        expect(screenIds.toSet().length, screenIds.length,
            reason: 'duplicate HMI screen id');
      });

      test('every program is referenced by at least one enabled task', () {
        final referenced = <String>{
          for (final t in p.tasks)
            if (t.enabled) ...t.programNames,
        };
        for (final prog in p.programs) {
          expect(referenced, contains(prog.name),
              reason: '${prog.name} has no task');
        }
        for (final t in p.tasks) {
          for (final name in t.programNames) {
            expect(p.programs.any((x) => x.name == name), isTrue,
                reason: 'task ${t.name} names a missing program $name');
          }
        }
      });

      test('no FbDefinition name shadows a built-in block type', () {
        final reserved = {...kFbdBuiltinBlockTypes, ...kLdBuiltinBlockTypes};
        for (final fb in p.fbDefinitions) {
          expect(reserved, isNot(contains(fb.name)),
              reason:
                  'FB ${fb.name} would shadow the built-in block of the same name');
        }
      });

      test('every binding resolves to a real tag', () {
        for (final r in p.simRules) {
          expect(resolves(p, r.targetPath), isTrue,
              reason: 'sim ${r.id} target ${r.targetPath}');
          expect(resolves(p, r.sourcePath), isTrue,
              reason: 'sim ${r.id} source ${r.sourcePath}');
          for (final c in r.condition) {
            expect(resolves(p, c.leftPath), isTrue,
                reason: 'sim ${r.id} clause ${c.leftPath}');
          }
        }
        for (final prog in p.programs) {
          for (final rung in prog.rungs) {
            for (final n in rung.nodes) {
              expect(resolves(p, n.variable), isTrue,
                  reason:
                      '${prog.name} rung ${rung.rungIndex} node ${n.id} -> ${n.variable}');
              expect(resolves(p, n.operandA), isTrue,
                  reason: '${prog.name} operandA ${n.operandA}');
              expect(resolves(p, n.operandB), isTrue,
                  reason: '${prog.name} operandB ${n.operandB}');
              n.pinBindings.forEach((pin, ref) {
                expect(resolves(p, ref), isTrue,
                    reason: '${prog.name} pin $pin -> $ref');
              });
            }
          }
          for (final b in prog.fbdBlocks) {
            if (b.type == 'TAG_INPUT' || b.type == 'TAG_OUTPUT') {
              expect(resolves(p, b.tagBinding), isTrue,
                  reason: '${prog.name} block ${b.id} -> ${b.tagBinding}');
            }
            if (fbDefinitionFor(p, b.type) != null) {
              expect(b.tagBinding, isNotEmpty,
                  reason: '${prog.name} FB block ${b.id} has no instance tag');
              expect(resolves(p, b.tagBinding), isTrue,
                  reason:
                      '${prog.name} FB instance ${b.tagBinding} is missing');
            }
          }
          for (final w in prog.fbdWires) {
            expect(prog.fbdBlocks.any((b) => b.id == w.fromBlockId), isTrue,
                reason:
                    '${prog.name} wire from missing block ${w.fromBlockId}');
            expect(prog.fbdBlocks.any((b) => b.id == w.toBlockId), isTrue,
                reason: '${prog.name} wire to missing block ${w.toBlockId}');
          }
          for (final t in prog.sfcTransitions) {
            for (final id in [
              if (t.fromStepId.isNotEmpty) t.fromStepId,
              if (t.toStepId.isNotEmpty) t.toStepId,
              ...t.fromStepIds,
              ...t.toStepIds,
            ]) {
              expect(prog.sfcSteps.any((s) => s.id == id), isTrue,
                  reason:
                      '${prog.name} transition ${t.id} names missing step $id');
            }
          }
        }
      });

      test('every HMI binding and every trend pen reference resolves', () {
        final penPaths = p.trends.map((t) => t.tagPath).toSet();
        for (final pen in p.trends) {
          expect(resolves(p, pen.tagPath), isTrue,
              reason: 'pen ${pen.tagPath}');
        }
        for (final h in p.hmis) {
          for (final c in h.components) {
            if (c.type == kTrendChartDisplay) {
              expect(c.trendPens, isNotEmpty,
                  reason: '${c.id} is an empty trend chart');
              for (final ref in c.trendPens) {
                expect(penPaths, contains(ref.penTagPath),
                    reason:
                        '${c.id} references pen ${ref.penTagPath} with no project pen');
              }
              continue;
            }
            expect(c.tagBinding, isNotEmpty, reason: '${c.id} has no binding');
            expect(resolves(p, c.tagBinding), isTrue,
                reason: '${h.id}/${c.id} -> ${c.tagBinding}');
          }
        }
      });
    });
  }
}
