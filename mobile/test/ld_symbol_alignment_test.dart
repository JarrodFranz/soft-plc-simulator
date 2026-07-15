import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('contact symbol glyph is vertically centred on the cell', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final PlcProject proj = DefaultProjects.all().firstWhere((p) => p.name.contains('Motor'));
    final prog = proj.programs.firstWhere((p) => p.language == 'LadderLogic');

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: LdEditorScreen(
          currentProject: proj,
          program: prog,
          onProgramUpdated: () {},
          monitor: LdMonitor(),
          scanRunning: false,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The NO contact glyph '-| |-' should be centred within its element cell.
    // Find one contact symbol and its enclosing element Container centre.
    final symbol = find.text('-| |-').first;
    expect(symbol, findsWidgets);
    final symbolCenter = tester.getCenter(symbol);
    // The element cell height is _kContactH (54). The symbol centre must be
    // within a few px of the tap target centre. Reuse the GestureDetector that
    // wraps the node as the cell proxy.
    final cell = find.ancestor(of: symbol, matching: find.byType(GestureDetector)).first;
    final cellCenter = tester.getCenter(cell);
    expect((symbolCenter.dy - cellCenter.dy).abs(), lessThan(4.0));
  });
}
