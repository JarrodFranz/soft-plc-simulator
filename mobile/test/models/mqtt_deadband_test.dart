// Tests for the MQTT analog deadband gate (Task 4, event-loop-flood fix):
// `MqttProtocolConfig.deadband` suppresses a `changedPublishes` publish for a
// NUMERIC metric whose value moved by no more than `deadband` since the last
// published baseline. BOOL/STRING metrics and `deadband == 0.0` (the
// default) behave exactly as report-by-exception did before this field
// existed — see mqtt_publisher_test.dart for that baseline behavior; this
// file only covers the new gate.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_publisher.dart';

PlcProject _fixtureProject({required double deadband, bool includeBool = false}) {
  final tags = [
    PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedInput'),
    if (includeBool) PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
  ];
  final entries = [
    MqttMapEntry(tag: 'A', metric: 'A', writable: false),
    if (includeBool) MqttMapEntry(tag: 'B', metric: 'B', writable: false),
  ];
  final cfg = MqttProtocolConfig(
    enabled: true,
    host: 'localhost',
    port: 1883,
    format: 'json',
    baseTopic: 'softplc',
    edgeNodeId: 'Node1',
    map: MqttMap(entries: entries),
    deadband: deadband,
  );
  return PlcProject(
    id: 'p1',
    name: 'Deadband Project',
    controllerName: 'PLC_01',
    structDefs: const [],
    programs: const [],
    tasks: const [],
    hmis: const [],
    tags: tags,
    protocols: ProtocolSettings(mqtt: cfg),
  );
}

PlcTag _tag(PlcProject p, String name) => p.tags.firstWhere((t) => t.name == name);

void main() {
  group('MqttProtocolConfig.publishIntervalMs / deadband', () {
    test('default publishIntervalMs is 250 and deadband is 0.0', () {
      final cfg = MqttProtocolConfig(map: MqttMap(entries: []));
      expect(cfg.publishIntervalMs, 250);
      expect(cfg.deadband, 0.0);
    });

    test('round-trip through toJson/fromJson preserves custom values', () {
      final cfg = MqttProtocolConfig(
        map: MqttMap(entries: []),
        publishIntervalMs: 1000,
        deadband: 2.5,
      );
      final json = cfg.toJson();
      expect(json['publish_interval_ms'], 1000);
      expect(json['deadband'], 2.5);

      final rt = MqttProtocolConfig.fromJson(json);
      expect(rt.publishIntervalMs, 1000);
      expect(rt.deadband, 2.5);
    });

    test('fromJson on a legacy record with no publish_interval_ms/deadband keys back-fills 250/0.0', () {
      final cfg = MqttProtocolConfig.fromJson({'enabled': true, 'host': 'localhost'});
      expect(cfg.publishIntervalMs, 250);
      expect(cfg.deadband, 0.0);
    });
  });

  group('changedPublishes — analog deadband gate', () {
    test('a change within the deadband is suppressed (not published, baseline unchanged)', () {
      final p = _fixtureProject(deadband: 5.0);
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 0); // seeds baseline at A=0.0

      _tag(p, 'A').value = 3.0; // |3-0| = 3 <= 5 -> suppressed
      expect(publisher.changedPublishes(p, 1000), isEmpty);
    });

    test('a change beyond the deadband publishes and advances the baseline', () {
      final p = _fixtureProject(deadband: 5.0);
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 0); // seeds baseline at A=0.0

      _tag(p, 'A').value = 10.0; // |10-0| = 10 > 5 -> publishes
      final changed = publisher.changedPublishes(p, 1000);
      expect(changed, hasLength(1));
      expect(changed.single.topic, 'softplc/PLC_01/tags/A');

      // Baseline is now 10.0 — a further move back within 5 of it (e.g. to
      // 6.0, |6-10| = 4 <= 5) must again be suppressed.
      _tag(p, 'A').value = 6.0;
      expect(publisher.changedPublishes(p, 2000), isEmpty);
    });

    test('deadband 0.0 (default/off): any change publishes, however small', () {
      final p = _fixtureProject(deadband: 0.0);
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 0);

      _tag(p, 'A').value = 10.0000001;
      final changed = publisher.changedPublishes(p, 1000);
      expect(changed, hasLength(1));
      expect(changed.single.topic, 'softplc/PLC_01/tags/A');
    });

    test('a BOOL metric always publishes on change regardless of deadband', () {
      final p = _fixtureProject(deadband: 100.0, includeBool: true);
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 0);

      _tag(p, 'B').value = true;
      final changed = publisher.changedPublishes(p, 1000);
      expect(changed, hasLength(1));
      expect(changed.single.topic, 'softplc/PLC_01/tags/B');
    });
  });
}
