// Regression coverage for the MQTT-panel lag (WS-perf task 1): the gateway
// screen used to wrap its ENTIRE body in a `ListenableBuilder` merging all
// four protocol hosts, so any single host's `notifyListeners()` (the MQTT
// host fires ~4Hz while publishing) rebuilt every protocol card — including
// an eagerly-built `Column` of every map row (100+ for a large tag map).
//
// This proves both halves of the fix:
//  1. an MQTT host notify repaints only the connection/status subtree, not
//     the (virtualized) map rows below it — instrumented via the
//     `mqttRowBuildCount` test hook incremented once per `_mqttRow` build.
//  2. the MQTT map list is virtualized: a far-down row is not built (not in
//     the widget tree at all) until it is scrolled into view.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/services/bacnet_host.dart';
import 'package:soft_plc_mobile/services/dnp3_host.dart';
import 'package:soft_plc_mobile/services/enip_host.dart';
import 'package:soft_plc_mobile/services/fins_host.dart';
import 'package:soft_plc_mobile/services/slmp_host.dart';
import 'package:soft_plc_mobile/services/s7_host.dart';
import 'package:soft_plc_mobile/services/modbus_host.dart';
import 'package:soft_plc_mobile/services/mqtt_host.dart';
import 'package:soft_plc_mobile/services/opcua_host.dart';

/// `ChangeNotifier.notifyListeners()` is `@protected`; this thin subclass
/// exposes a same-library-safe way to fire the notification the real host
/// emits ~4Hz while publishing, without exercising any real network I/O —
/// mirrors the fakes already used in `gateway_screen_test.dart`.
class _NotifyableMqttHost extends MqttHost {
  void fireNotify() => notifyListeners();
}

/// Large enough that the old eager `Column` of every map row would have
/// been a real, measurable cost — and large enough that a "far-down" row
/// can't plausibly be within the virtualized list's first on-screen page.
const int _entryCount = 60;

PlcProject _project() {
  final tags = [
    for (var i = 0; i < _entryCount; i++)
      PlcTag(
        name: 'Tag_$i',
        path: 'Internal.Tag_$i',
        dataType: 'BOOL',
        value: false,
        ioType: 'Internal',
      ),
  ];
  final project = PlcProject(
    id: 'proj_gateway_panel_perf_test',
    name: 'Gateway Panel Perf Test',
    controllerName: 'PLC_01',
    tags: tags,
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.mqtt!.enabled = true;
  project.protocols!.mqtt!.map.entries
    ..clear()
    ..addAll([
      for (var i = 0; i < _entryCount; i++)
        MqttMapEntry(tag: 'Tag_$i', metric: 'Metric_$i', writable: true),
    ]);
  return project;
}

Widget _app(PlcProject project, MqttHost mqttHost) {
  return MaterialApp(
    home: GatewayScreen(
      currentProject: project,
      host: OpcUaHost(),
      modbusHost: ModbusHost(),
      mqttHost: mqttHost,
      dnpHost: DnpHost(),
      enipHost: EnipHost(),
      s7Host: S7Host(),
      finsHost: FinsHost(),
      slmpHost: SlmpHost(),
      bacnetHost: BacnetHost(),
      onProjectUpdated: () {},
    ),
  );
}

Future<void> _selectMqttTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('protocol_tab_mqtt')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'an mqttHost notify repaints only the status chip, not the (virtualized) map rows',
      (tester) async {
    final project = _project();
    final mqttHost = _NotifyableMqttHost();
    addTearDown(mqttHost.dispose);

    await tester.pumpWidget(_app(project, mqttHost));
    await tester.pumpAndSettle();
    await _selectMqttTab(tester);

    final buildCountAfterInitialLayout = mqttRowBuildCount;
    expect(buildCountAfterInitialLayout, greaterThan(0),
        reason: 'sanity check — some rows must have built during the initial layout');

    // Simulate the ~4Hz notify the real MqttHost fires while publishing.
    mqttHost.fireNotify();
    await tester.pump();

    expect(mqttRowBuildCount, buildCountAfterInitialLayout,
        reason: 'an mqttHost notify must not rebuild any map row — only the '
            'connection/status subtree above the map editor should react to it');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the MQTT map list is virtualized: a far-down row is not built until scrolled into view',
      (tester) async {
    final project = _project();
    final mqttHost = MqttHost();
    addTearDown(mqttHost.dispose);

    await tester.pumpWidget(_app(project, mqttHost));
    await tester.pumpAndSettle();
    await _selectMqttTab(tester);

    const farRowMetric = 'Metric_55';
    expect(find.text(farRowMetric), findsNothing,
        reason: 'row 55 of $_entryCount must not be built up front — the map list must be lazy');

    final listFinder = find.byKey(const Key('mqtt_map_list'));
    expect(listFinder, findsOneWidget);
    // The MQTT card has many fields above its map editor, so the (bounded,
    // internally-scrolling) map list itself first needs scrolling into view
    // within the card's own outer `SingleChildScrollView` before its inner
    // `Scrollable` can be dragged.
    await tester.ensureVisible(listFinder);
    await tester.pumpAndSettle();

    // `.first` — a row's own text fields (`EditableText`) each nest their own
    // `Scrollable` too, so a plain descendant search matches more than one;
    // the list's own `Scrollable` is the outermost (first in build order).
    await tester.scrollUntilVisible(
      find.text(farRowMetric),
      300,
      scrollable: find.descendant(of: listFinder, matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();

    expect(find.text(farRowMetric), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
