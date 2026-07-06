import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/gateway_sync.dart';

void main() {
  group('encodeMessage / decodeMessage round-trip', () {
    test('HelloMsg', () {
      const msg = HelloMsg(project: 'MotorProj', controller: 'PLC_01', scanMs: 100);
      final decoded = decodeMessage(encodeMessage(msg));
      expect(decoded, isA<HelloMsg>());
      final h = decoded as HelloMsg;
      expect(h.project, 'MotorProj');
      expect(h.controller, 'PLC_01');
      expect(h.scanMs, 100);
    });

    test('SnapshotMsg', () {
      const msg = SnapshotMsg(tags: [
        ExposedTag(path: 'Inputs/Start_PB', dataType: 'BOOL', value: false, access: 'ReadWrite'),
        ExposedTag(path: 'Outputs/Motor_Run', dataType: 'BOOL', value: true, access: 'ReadOnly'),
      ]);
      final decoded = decodeMessage(encodeMessage(msg));
      expect(decoded, isA<SnapshotMsg>());
      final s = decoded as SnapshotMsg;
      expect(s.tags.length, 2);
      expect(s.tags[0].path, 'Inputs/Start_PB');
      expect(s.tags[0].dataType, 'BOOL');
      expect(s.tags[0].value, false);
      expect(s.tags[0].access, 'ReadWrite');
      expect(s.tags[1].path, 'Outputs/Motor_Run');
      expect(s.tags[1].value, true);
      expect(s.tags[1].access, 'ReadOnly');
    });

    test('DeltaMsg', () {
      const msg = DeltaMsg(changes: [
        TagChange(path: 'Inputs/Start_PB', value: true),
        TagChange(path: 'Internal/Level_SP', value: 42.5),
      ]);
      final decoded = decodeMessage(encodeMessage(msg));
      expect(decoded, isA<DeltaMsg>());
      final d = decoded as DeltaMsg;
      expect(d.changes.length, 2);
      expect(d.changes[0].path, 'Inputs/Start_PB');
      expect(d.changes[0].value, true);
      expect(d.changes[1].path, 'Internal/Level_SP');
      expect(d.changes[1].value, 42.5);
    });

    test('WriteMsg', () {
      const msg = WriteMsg(path: 'Outputs/Motor_Run', value: true);
      final decoded = decodeMessage(encodeMessage(msg));
      expect(decoded, isA<WriteMsg>());
      final w = decoded as WriteMsg;
      expect(w.path, 'Outputs/Motor_Run');
      expect(w.value, true);
    });

    test('ReadyMsg', () {
      const msg = ReadyMsg();
      final decoded = decodeMessage(encodeMessage(msg));
      expect(decoded, isA<ReadyMsg>());
    });

    test('PingMsg', () {
      const msg = PingMsg();
      final decoded = decodeMessage(encodeMessage(msg));
      expect(decoded, isA<PingMsg>());
    });

    test('PongMsg', () {
      const msg = PongMsg();
      final decoded = decodeMessage(encodeMessage(msg));
      expect(decoded, isA<PongMsg>());
    });
  });

  group('malformed / unknown input never throws', () {
    test('not JSON at all -> UnknownMsg', () {
      final decoded = decodeMessage('{not json');
      expect(decoded, isA<UnknownMsg>());
      expect((decoded as UnknownMsg).raw, '{not json');
    });

    test('valid JSON but unknown type -> UnknownMsg', () {
      final decoded = decodeMessage('{"type":"bogus"}');
      expect(decoded, isA<UnknownMsg>());
      expect((decoded as UnknownMsg).raw, '{"type":"bogus"}');
    });

    test('empty string -> UnknownMsg', () {
      final decoded = decodeMessage('');
      expect(decoded, isA<UnknownMsg>());
    });

    test('JSON array (not object) -> UnknownMsg', () {
      final decoded = decodeMessage('[1,2,3]');
      expect(decoded, isA<UnknownMsg>());
    });
  });

  group('tagValueToJson / jsonToTagValue round-trip', () {
    test('BOOL', () {
      final j = tagValueToJson(true, 'BOOL');
      expect(j, true);
      expect(jsonToTagValue(j, 'BOOL'), true);
    });

    test('INT32', () {
      final j = tagValueToJson(42, 'INT32');
      expect(j, 42);
      final back = jsonToTagValue(j, 'INT32');
      expect(back, isA<int>());
      expect(back, 42);
    });

    test('FLOAT64', () {
      final j = tagValueToJson(3.14, 'FLOAT64');
      expect(j, 3.14);
      final back = jsonToTagValue(j, 'FLOAT64');
      expect(back, isA<double>());
      expect(back, 3.14);
    });

    test('STRING', () {
      final j = tagValueToJson('hello', 'STRING');
      expect(j, 'hello');
      expect(jsonToTagValue(j, 'STRING'), 'hello');
    });

    test('jsonToTagValue is total (no throw) on type mismatch', () {
      expect(() => jsonToTagValue('not a number', 'INT32'), returnsNormally);
      expect(() => jsonToTagValue(null, 'BOOL'), returnsNormally);
      expect(() => jsonToTagValue(123, 'STRING'), returnsNormally);
    });
  });
}
