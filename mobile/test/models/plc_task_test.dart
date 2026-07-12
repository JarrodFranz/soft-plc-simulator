import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  group('PlcTask new fields', () {
    test('defaults: triggerTag empty, watchdogMs 0', () {
      final t = PlcTask(name: 'T', type: 'Continuous', programNames: []);
      expect(t.triggerTag, '');
      expect(t.watchdogMs, 0);
    });

    test('round-trips triggerTag + watchdogMs through JSON', () {
      final t = PlcTask(
        name: 'EvtT',
        type: 'Event',
        programNames: ['P1'],
        triggerTag: 'Start_PB',
        watchdogMs: 250,
      );
      final back = PlcTask.fromJson(t.toJson());
      expect(back.triggerTag, 'Start_PB');
      expect(back.watchdogMs, 250);
      expect(back.type, 'Event');
      expect(back.programNames, ['P1']);
    });

    test('fromJson tolerates missing new keys (legacy projects)', () {
      final back = PlcTask.fromJson({
        'name': 'Legacy',
        'type': 'Continuous',
        'period_ms': 100,
        'programs': ['A'],
        'enabled': true,
      });
      expect(back.triggerTag, '');
      expect(back.watchdogMs, 0);
    });
  });
}
