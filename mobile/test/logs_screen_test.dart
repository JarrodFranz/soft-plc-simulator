// Task 5 of the in-app log feature: the real Logs screen that replaces the
// Task-4 placeholder (`Center(child: Text('Logs (coming soon)'))`) wired up
// in `workspace_shell.dart`'s `_buildCenterWorkspace()`.
//
// These tests exercise `LogsScreen` standalone (not through the full
// `WorkspaceShell`), providing its own `AppLogger` and `LiveTick` via
// `LiveTickScope` exactly the way the shell does in production
// (`workspace_shell.dart` owns one `LiveTick` and provides it once above the
// whole center workspace) — see `mobile/lib/widgets/live_tick.dart`'s doc
// comment for why `LiveTickScope.of(context)` is a deliberate
// non-dependency lookup, and why only the log-list leaf may subscribe to it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/app_log.dart';
import 'package:soft_plc_mobile/screens/logs_screen.dart';
import 'package:soft_plc_mobile/services/app_logger.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

import 'support/responsive_test_utils.dart';

Widget _app(AppLogger logger, LiveTick tick) {
  return MaterialApp(
    home: LiveTickScope(
      notifier: tick,
      child: LogsScreen(logger: logger),
    ),
  );
}

/// The live scroll offset of the entry list. Read through the `ListView`'s own
/// controller (the screen's `_scrollController`), so it reports the offset of
/// whatever `ScrollPosition` is attached RIGHT NOW — which is exactly what a
/// position dispose/recreate would reset.
double _listOffset(WidgetTester tester) {
  final list = tester.widget<ListView>(find.byKey(const Key('logs_list_view')));
  return list.controller!.offset;
}

void main() {
  testWidgets('seeded entries render (time, level, source, message)', (tester) async {
    final logger = AppLogger();
    logger.log(kLogSourceModbus, LogLevel.info, 'Modbus client connected', tMs: 1000);
    logger.log(kLogSourceS7, LogLevel.warn, 'Unsupported ROSCTR 0x07', tMs: 2000);

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    expect(find.text('Modbus client connected'), findsOneWidget);
    expect(find.text('Unsupported ROSCTR 0x07'), findsOneWidget);
    expect(find.textContaining(kLogSourceModbus), findsWidgets);
    expect(find.textContaining(kLogSourceS7), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the free-text filter narrows visible rows', (tester) async {
    final logger = AppLogger();
    logger.log(kLogSourceModbus, LogLevel.info, 'Modbus client connected', tMs: 1000);
    logger.log(kLogSourceS7, LogLevel.warn, 'Unsupported ROSCTR 0x07', tMs: 2000);

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('logs_text_filter')), 'ROSCTR');
    await tester.pumpAndSettle();

    expect(find.text('Unsupported ROSCTR 0x07'), findsOneWidget);
    expect(find.text('Modbus client connected'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the source multi-select narrows visible rows', (tester) async {
    final logger = AppLogger();
    logger.log(kLogSourceModbus, LogLevel.info, 'Modbus client connected', tMs: 1000);
    logger.log(kLogSourceS7, LogLevel.warn, 'Unsupported ROSCTR 0x07', tMs: 2000);

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    // The source multi-select lives behind its own collapsed-by-default
    // disclosure panel (see logs_screen.dart's `_buildSourcesPanel`) so the
    // persistent filter bar stays compact at narrow widths.
    await tester.tap(find.byKey(const Key('logs_sources_panel')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('logs_source_chip_$kLogSourceS7')));
    await tester.pumpAndSettle();

    expect(find.text('Unsupported ROSCTR 0x07'), findsOneWidget);
    expect(find.text('Modbus client connected'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the minimum-level dropdown narrows visible rows', (tester) async {
    final logger = AppLogger();
    logger.log(kLogSourceModbus, LogLevel.info, 'Everything is fine', tMs: 1000);
    logger.log(kLogSourceS7, LogLevel.error, 'Bind failed: EACCES', tMs: 2000);

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    expect(find.text('Everything is fine'), findsOneWidget);
    expect(find.text('Bind failed: EACCES'), findsOneWidget);

    await tester.tap(find.byKey(const Key('logs_min_level_dropdown')));
    await tester.pumpAndSettle();
    // Two 'ERROR' texts exist once the menu is open (the row's level badge,
    // already on screen, plus the freshly-opened menu item) — the menu item
    // is the one added last, mirroring the disambiguation already used
    // elsewhere in this suite (see gateway_screen_test.dart's
    // 'RTU over TCP'.last selection).
    await tester.tap(find.text('ERROR').last);
    await tester.pumpAndSettle();

    expect(find.text('Bind failed: EACCES'), findsOneWidget);
    expect(find.text('Everything is fine'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row with detail expands to reveal it and collapses again', (tester) async {
    final logger = AppLogger();
    logger.log(
      kLogSourceS7,
      LogLevel.warn,
      'Unsupported ROSCTR 0x07',
      detail: 'raw=03000b0200f00032010000000000000800',
      tMs: 1000,
    );

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    expect(find.textContaining('raw=03000b0200f00032010000000000000800'), findsNothing);

    await tester.tap(find.text('Unsupported ROSCTR 0x07'));
    await tester.pumpAndSettle();
    expect(find.textContaining('raw=03000b0200f00032010000000000000800'), findsOneWidget);

    await tester.tap(find.text('Unsupported ROSCTR 0x07'));
    await tester.pumpAndSettle();
    expect(find.textContaining('raw=03000b0200f00032010000000000000800'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'live-tail off freezes the view (a new entry does not appear); '
      'live-tail on shows it via LiveTick', (tester) async {
    final logger = AppLogger();
    logger.log(kLogSourceModbus, LogLevel.info, 'Existing entry', tMs: 1000);
    final tick = LiveTick();

    await tester.pumpWidget(_app(logger, tick));
    await tester.pumpAndSettle();

    // Live-tail defaults ON; turn it OFF.
    await tester.tap(find.byKey(const Key('logs_live_tail_switch')));
    await tester.pump();

    logger.log(kLogSourceModbus, LogLevel.info, 'New entry while frozen', tMs: 2000);
    tick.pulse();
    await tester.pump();

    expect(find.text('New entry while frozen'), findsNothing,
        reason: 'live-tail OFF must freeze the view — new entries must not appear');
    expect(find.text('Existing entry'), findsOneWidget);

    // Turn live-tail back ON.
    await tester.tap(find.byKey(const Key('logs_live_tail_switch')));
    await tester.pump();
    tick.pulse();
    await tester.pump();

    expect(find.text('New entry while frozen'), findsOneWidget,
        reason: 'live-tail ON must show entries added while it was on, via LiveTick');
    expect(tester.takeException(), isNull);
  });

  // *** THE PRIMARY INTERACTION ***
  // An operator pinned at the tail watching drops scroll past flips live-tail
  // OFF precisely so they can read the one that just went by. If that toggle
  // resets the list to offset 0 they land on the OLDEST entry of a 2000-entry
  // buffer, which destroys the only reason the control exists.
  //
  // The mechanism this guards: `Widget.canUpdate` compares `runtimeType`, so
  // returning a `ListenableBuilder` in one branch and a bare list in the other
  // at the SAME slot deactivates the subtree, disposes the `Scrollable`, and
  // takes the `ScrollPosition` with it. A `ScrollController` does NOT carry an
  // offset across a position dispose/recreate — only `oldPosition` absorption
  // or `PageStorage` (which needs a `PageStorageKey` on the path) does. So the
  // fix is to keep element identity stable across the toggle.
  testWidgets('toggling live-tail OFF preserves the scroll position', (tester) async {
    final logger = AppLogger();
    for (var i = 0; i < 300; i++) {
      logger.log(kLogSourceModbus, LogLevel.info, 'Entry $i', tMs: 1000 + i);
    }

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    // Live-tail ON follows the tail, so start there, then scroll back up to a
    // known non-zero offset — the "reading something that just went by" state.
    await tester.drag(find.byKey(const Key('logs_list_view')), const Offset(0, 400));
    await tester.pumpAndSettle();

    final before = _listOffset(tester);
    expect(before, greaterThan(0.0),
        reason: 'the fixture must actually be scrolled for this test to mean anything');

    await tester.tap(find.byKey(const Key('logs_live_tail_switch')));
    await tester.pumpAndSettle();

    expect(_listOffset(tester), closeTo(before, 1.0),
        reason: 'turning live-tail OFF must leave the operator where they were '
            'reading, not jump to the oldest entry in the buffer');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty buffer renders a clear empty-state message', (tester) async {
    final logger = AppLogger();

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    expect(find.textContaining('No log entries'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a filter matching nothing renders a clear empty-state message', (tester) async {
    final logger = AppLogger();
    logger.log(kLogSourceModbus, LogLevel.info, 'Something happened', tMs: 1000);

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    // Deliberately avoid the substring "match" in the typed filter text
    // itself — the TextField's own EditableText would then also contain
    // "match", making `find.textContaining('match')` below ambiguous.
    await tester.enterText(find.byKey(const Key('logs_text_filter')), 'zzz_nope_zzz');
    await tester.pumpAndSettle();

    expect(find.text('Something happened'), findsNothing);
    expect(find.textContaining('match'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a per-source verbosity toggle calls through to setSourceLevel', (tester) async {
    final logger = AppLogger();

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    expect(logger.sourceLevel(kLogSourceModbus), LogLevel.info);

    await tester.tap(find.text('Per-source verbosity (DEBUG)'));
    await tester.pumpAndSettle();

    // The verbosity panel lives inside its own scrollable region (see
    // logs_screen.dart's Expanded(flex: 3, child: SingleChildScrollView(...))
    // — with 11 sources' switches, Modbus's switch may sit below the fold.
    await tester.ensureVisible(find.byKey(const Key('logs_verbosity_switch_$kLogSourceModbus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logs_verbosity_switch_$kLogSourceModbus')));
    await tester.pump();

    expect(logger.sourceLevel(kLogSourceModbus), LogLevel.debug);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Clear control empties the buffer', (tester) async {
    final logger = AppLogger();
    logger.log(kLogSourceModbus, LogLevel.info, 'Something happened', tMs: 1000);

    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();
    expect(find.text('Something happened'), findsOneWidget);

    await tester.tap(find.byKey(const Key('logs_clear_button')));
    await tester.pumpAndSettle();

    expect(logger.entries, isEmpty);
    expect(find.text('Something happened'), findsNothing);
    expect(find.textContaining('No log entries'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> stressed(WidgetTester tester, AppLogger logger) async {
    await tester.pumpWidget(_app(logger, LiveTick()));
    await tester.pumpAndSettle();

    // Turn live-tail off first so the auto-follow-the-tail behavior doesn't
    // fight this test for scroll position while it drives the detail row.
    await tester.tap(find.byKey(const Key('logs_live_tail_switch')));
    await tester.pump();

    // Expand a detail row (ensureVisible first — the list area is small at
    // narrow widths, and the target row may not be the one nearest the top).
    await tester.ensureVisible(find.text('Unsupported ROSCTR 0x07'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unsupported ROSCTR 0x07'));
    await tester.pump();

    // Expand the sources and verbosity sections — each is an animated
    // ExpansionTile, so settle the expand animation before its children
    // (the chips/switches) are hit-testable.
    await tester.ensureVisible(find.byKey(const Key('logs_sources_panel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logs_sources_panel')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Per-source verbosity (DEBUG)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Per-source verbosity (DEBUG)'));
    await tester.pumpAndSettle();

    // Select a couple of source chips.
    await tester.ensureVisible(find.byKey(const Key('logs_source_chip_$kLogSourceS7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logs_source_chip_$kLogSourceS7')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('logs_source_chip_$kLogSourceModbus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logs_source_chip_$kLogSourceModbus')));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('logs_text_filter')), 'a');
    await tester.pump();
  }

  AppLogger stressLogger() {
    final logger = AppLogger();
    logger.log(kLogSourceModbus, LogLevel.info, 'Modbus client connected', tMs: 1000);
    logger.log(
      kLogSourceS7,
      LogLevel.warn,
      'Unsupported ROSCTR 0x07',
      detail: 'raw=03000b0200f00032010000000000000800',
      tMs: 2000,
    );
    logger.log(kLogSourceMqtt, LogLevel.error, 'Bind failed: EACCES', tMs: 3000);
    return logger;
  }

  testWidgets('no overflow at 320 width', (tester) async {
    await setSurface(tester, smallPhoneSize);
    await stressed(tester, stressLogger());
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 360 width', (tester) async {
    await setSurface(tester, phoneSize);
    await stressed(tester, stressLogger());
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1400 width', (tester) async {
    await setSurface(tester, desktopSize);
    await stressed(tester, stressLogger());
    expect(tester.takeException(), isNull);
  });
}
