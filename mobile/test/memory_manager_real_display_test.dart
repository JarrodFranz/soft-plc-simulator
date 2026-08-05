// QA sweep item A2 (#15): Tags & Structs Live Value column previously
// printed a REAL/FLOAT64 tag's raw double precision (`80.83999999999966`)
// and was inconsistent about `0` vs `0.0` between rows. This asserts the
// Live Value cell now goes through the shared `formatLiveValue` helper
// (lib/ui/value_format.dart) for FLOAT64 tags.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

PlcProject _project() {
  final p = PlcProject(
    id: 'p1',
    name: 'Test Project',
    controllerName: 'c',
    tags: [],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  p.tags.add(PlcTag(
    name: 'Level_PV',
    path: 'Level_PV',
    dataType: 'FLOAT64',
    value: 80.83999999999966,
    defaultValue: 0.0,
    ioType: 'Internal',
  ));
  // A FLOAT64 tag whose current value is a bare int zero (its
  // default/uninitialized JSON-round-tripped representation) — this is what
  // produced the inconsistent "0" (vs a sibling row's "0.0") the QA finding
  // called out.
  p.tags.add(PlcTag(
    name: 'Zeroed_PV',
    path: 'Zeroed_PV',
    dataType: 'FLOAT64',
    value: 0,
    defaultValue: 0.0,
    ioType: 'Internal',
  ));
  return p;
}

void main() {
  Widget app(PlcProject project) => LiveTickScope(
        notifier: LiveTick(),
        child: MaterialApp(
          home: MemoryManagerScreen(
            currentProject: project,
            onProjectUpdated: () {},
            historian: TagHistorian(),
          ),
        ),
      );

  testWidgets('a REAL tag with noisy double precision displays trimmed to 3 decimals',
      (tester) async {
    await tester.pumpWidget(app(_project()));
    await tester.pumpAndSettle();

    expect(find.text('80.84'), findsOneWidget);
    expect(find.textContaining('80.83999999999966'), findsNothing);
  });

  testWidgets('a REAL tag whose value is a bare int zero still displays "0.0"', (tester) async {
    await tester.pumpWidget(app(_project()));
    await tester.pumpAndSettle();

    expect(find.text('0.0'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
