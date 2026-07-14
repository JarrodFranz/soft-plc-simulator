import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('LiveTickScope.of exposes the notifier; a pulse rebuilds a listening leaf only', (tester) async {
    final tick = LiveTick();
    var leafBuilds = 0;
    var rootBuilds = 0;
    await tester.pumpWidget(LiveTickScope(
      notifier: tick,
      child: Builder(builder: (context) {
        rootBuilds++;
        return MaterialApp(
          home: Center(
            child: ListenableBuilder(
              listenable: LiveTickScope.of(context),
              builder: (context, _) {
                leafBuilds++;
                return const Text('v');
              },
            ),
          ),
        );
      }),
    ));
    final rootAfterFirst = rootBuilds;
    final leafAfterFirst = leafBuilds;
    tick.pulse();
    await tester.pump();
    expect(leafBuilds, leafAfterFirst + 1); // leaf repainted
    expect(rootBuilds, rootAfterFirst);     // root did NOT rebuild
    tick.dispose();
  });
}
