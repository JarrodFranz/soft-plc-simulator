// Tests for the pure MQTT/Sparkplug B publisher session logic
// (mobile/lib/protocols/mqtt/mqtt_publisher.dart): birth/will/telemetry
// descriptors for both payload formats, report-by-exception change
// detection, command decoding, and force-awareness (a forced tag's
// telemetry reflects the forced value because the publisher reads every
// value through tag_resolver.dart's force-aware `readPath`).
//
// Sparkplug B payloads are asserted by decoding the produced bytes with a
// small test-only decoder (production code only ENCODES Sparkplug B — see
// mqtt_sparkplug.dart's file doc comment — so, mirroring
// mqtt_sparkplug_test.dart's own precedent, the decoder used to verify
// those bytes lives here, in the test file, not in shipped code).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_publisher.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_sparkplug.dart'
    show SparkplugDatatype, SparkplugMetric, SparkplugPayload, encodePayload;

PlcProject _fixtureProject({required String format, bool allowRemoteWrites = true}) {
  final tags = [
    PlcTag(name: 'Motor', path: 'Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
    PlcTag(name: 'Speed', path: 'Speed', dataType: 'FLOAT64', value: 1.5, ioType: 'SimulatedInput'),
    PlcTag(name: 'Alarm', path: 'Alarm', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput'),
  ];
  final map = MqttMap(entries: [
    MqttMapEntry(tag: 'Motor', metric: 'Motor', writable: true),
    MqttMapEntry(tag: 'Speed', metric: 'Speed', writable: true),
    MqttMapEntry(tag: 'Alarm', metric: 'Alarm', writable: false),
  ]);
  final cfg = MqttProtocolConfig(
    enabled: true,
    host: 'localhost',
    port: 1883,
    format: format,
    baseTopic: 'softplc',
    groupId: 'SoftPLC',
    edgeNodeId: 'Node1',
    qos: 0,
    heartbeatSeconds: 5,
    allowRemoteWrites: allowRemoteWrites,
    map: map,
  );
  return PlcProject(
    id: 'p1',
    name: 'Test Project',
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
  group('birthMessages — JSON', () {
    test('retained status=ONLINE on {base}/{controller}/status', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      final msgs = publisher.birthMessages(p, 1000);
      expect(msgs, hasLength(1));
      expect(msgs.single.topic, 'softplc/PLC_01/status');
      expect(utf8.decode(msgs.single.payload), 'ONLINE');
      expect(msgs.single.retain, isTrue);
    });
  });

  group('birthMessages — Sparkplug', () {
    test('NBIRTH: correct topic, seq 0, one aliased metric per mapped tag + bdSeq', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      final msgs = publisher.birthMessages(p, 1000);
      expect(msgs, hasLength(1));
      final msg = msgs.single;
      expect(msg.topic, 'spBv1.0/SoftPLC/NBIRTH/Node1');
      expect(msg.retain, isTrue);

      final decoded = _decodePayload(msg.payload);
      expect(decoded.seq, 0);
      expect(decoded.timestampMs, 1000);

      final motor = decoded.metrics.firstWhere((m) => m.name == 'Motor');
      final speed = decoded.metrics.firstWhere((m) => m.name == 'Speed');
      final alarm = decoded.metrics.firstWhere((m) => m.name == 'Alarm');
      final bdSeq = decoded.metrics.firstWhere((m) => m.name == 'bdSeq');

      expect(motor.alias, 1); // stable, assigned in map order
      expect(speed.alias, 2);
      expect(alarm.alias, 3);
      expect(motor.value, false);
      expect(speed.value, 1.5);
      expect(bdSeq.alias, isNull);
      expect(bdSeq.datatype, _SparkplugDatatype.uint64);
      expect(bdSeq.value, 0); // no willMessage() call yet -> default bdSeq
    });

    test('willMessage advances bdSeq and the following birth carries the same value', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();

      final will = publisher.willMessage(p)!;
      expect(will.topic, 'spBv1.0/SoftPLC/NDEATH/Node1');
      final willDecoded = _decodePayload(will.payload);
      final willBdSeq = willDecoded.metrics.firstWhere((m) => m.name == 'bdSeq').value;
      expect(willBdSeq, 1);

      final birth = publisher.birthMessages(p, 1000).single;
      final birthDecoded = _decodePayload(birth.payload);
      final birthBdSeq = birthDecoded.metrics.firstWhere((m) => m.name == 'bdSeq').value;
      expect(birthBdSeq, willBdSeq);
    });
  });

  group('willMessage — JSON', () {
    test('retained status=OFFLINE', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      final will = publisher.willMessage(p)!;
      expect(will.topic, 'softplc/PLC_01/status');
      expect(utf8.decode(will.payload), 'OFFLINE');
      expect(will.retain, isTrue);
    });
  });

  group('changedPublishes — report-by-exception', () {
    test('JSON: unchanged tag -> no publish; changed tag -> exactly one publish', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000);

      expect(publisher.changedPublishes(p, 2000), isEmpty);

      _tag(p, 'Motor').value = true;
      final changed = publisher.changedPublishes(p, 3000);
      expect(changed, hasLength(1));
      expect(changed.single.topic, 'softplc/PLC_01/tags/Motor');
      final body = jsonDecode(utf8.decode(changed.single.payload)) as Map;
      expect(body['value'], true);
      expect(body['quality'], 'Good');
      expect(body['timestamp'], 3000);
      expect(body['forced'], false);
    });

    test('Sparkplug: unchanged -> no publish; changed -> single NDATA with alias-only metric, seq incremented', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000); // seq 0

      expect(publisher.changedPublishes(p, 2000), isEmpty);

      _tag(p, 'Speed').value = 9.5;
      final changed = publisher.changedPublishes(p, 3000);
      expect(changed, hasLength(1));
      expect(changed.single.topic, 'spBv1.0/SoftPLC/NDATA/Node1');

      final decoded = _decodePayload(changed.single.payload);
      expect(decoded.seq, 1); // advanced from birth's 0
      expect(decoded.metrics, hasLength(1));
      final metric = decoded.metrics.single;
      expect(metric.name, isNull); // alias-only on NDATA
      expect(metric.alias, 2); // Speed's stable alias from birth
      expect(metric.value, 9.5);
    });
  });

  group('heartbeatPublishes', () {
    test('JSON: all mapped tags regardless of change', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000);
      final hb = publisher.heartbeatPublishes(p, 2000);
      expect(hb, hasLength(3));
      expect(hb.map((m) => m.topic), containsAll([
        'softplc/PLC_01/tags/Motor',
        'softplc/PLC_01/tags/Speed',
        'softplc/PLC_01/tags/Alarm',
      ]));
    });

    test('Sparkplug: single NDATA with all mapped metrics', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000);
      final hb = publisher.heartbeatPublishes(p, 2000);
      expect(hb, hasLength(1));
      final decoded = _decodePayload(hb.single.payload);
      expect(decoded.metrics, hasLength(3));
    });
  });

  group('commandTopicFilters', () {
    test('JSON /set wildcard filter', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      expect(publisher.commandTopicFilters(p), ['softplc/PLC_01/tags/+/set']);
    });

    test('Sparkplug NCMD topic', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      expect(publisher.commandTopicFilters(p), ['spBv1.0/SoftPLC/NCMD/Node1']);
    });

    test('empty when allowRemoteWrites is false', () {
      final p = _fixtureProject(format: 'json', allowRemoteWrites: false);
      final publisher = MqttPublisher();
      expect(publisher.commandTopicFilters(p), isEmpty);
      final sp = _fixtureProject(format: 'sparkplug', allowRemoteWrites: false);
      expect(publisher.commandTopicFilters(sp), isEmpty);
    });
  });

  group('decodeCommand — JSON', () {
    test('raw scalar payload "true" on {base}/{ctrl}/tags/{metric}/set', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      final cmds = publisher.decodeCommand(
        'softplc/PLC_01/tags/Motor/set',
        Uint8List.fromList(utf8.encode('true')),
        p,
      );
      expect(cmds, [(tagPath: 'Motor', value: true)]);
    });

    test('{"value": x} payload', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      final cmds = publisher.decodeCommand(
        'softplc/PLC_01/tags/Motor/set',
        Uint8List.fromList(utf8.encode('{"value": true}')),
        p,
      );
      expect(cmds, [(tagPath: 'Motor', value: true)]);
    });

    test('non-writable metric -> empty', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      final cmds = publisher.decodeCommand(
        'softplc/PLC_01/tags/Alarm/set',
        Uint8List.fromList(utf8.encode('true')),
        p,
      );
      expect(cmds, isEmpty);
    });

    test('unknown topic -> empty, never throws', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      final cmds = publisher.decodeCommand(
        'not/a/known/topic',
        Uint8List.fromList(utf8.encode('true')),
        p,
      );
      expect(cmds, isEmpty);
    });

    test('garbage payload -> empty, never throws', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      final cmds = publisher.decodeCommand(
        'softplc/PLC_01/tags/Motor/set',
        Uint8List.fromList([0xFF, 0xFE, 0x00, 0x80]),
        p,
      );
      expect(cmds, isEmpty);
    });
  });

  group('decodeCommand — Sparkplug', () {
    test('NCMD metric by alias resolves to the right tag', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      // Birth first so the alias table is populated (Motor -> alias 1).
      publisher.birthMessages(p, 1000);

      final ncmd = _encodePayload(0, 0, [
        const _EncMetric(alias: 1, datatype: _SparkplugDatatype.boolean, value: true),
      ]);
      final cmds = publisher.decodeCommand('spBv1.0/SoftPLC/NCMD/Node1', ncmd, p);
      expect(cmds, [(tagPath: 'Motor', value: true)]);
    });

    test('non-writable metric alias (Alarm) -> empty', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000); // Alarm -> alias 3

      final ncmd = _encodePayload(0, 0, [
        const _EncMetric(alias: 3, datatype: _SparkplugDatatype.boolean, value: true),
      ]);
      final cmds = publisher.decodeCommand('spBv1.0/SoftPLC/NCMD/Node1', ncmd, p);
      expect(cmds, isEmpty);
    });

    test('unknown topic -> empty', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000);
      final ncmd = _encodePayload(0, 0, [
        const _EncMetric(alias: 1, datatype: _SparkplugDatatype.boolean, value: true),
      ]);
      final cmds = publisher.decodeCommand('spBv1.0/SoftPLC/NCMD/OtherNode', ncmd, p);
      expect(cmds, isEmpty);
    });

    test('garbage payload -> empty, never throws', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000);
      final cmds = publisher.decodeCommand(
        'spBv1.0/SoftPLC/NCMD/Node1',
        Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        p,
      );
      expect(cmds, isEmpty);
    });
  });

  group('ncmdSubscriptionTopic', () {
    test('Sparkplug returns the NCMD topic', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      expect(publisher.ncmdSubscriptionTopic(p), 'spBv1.0/SoftPLC/NCMD/Node1');
    });

    test('JSON returns null', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      expect(publisher.ncmdSubscriptionTopic(p), isNull);
    });
  });

  group('isRebirthRequest', () {
    Uint8List rebirthPayload({bool value = true, String name = 'Node Control/Rebirth'}) {
      return encodePayload(SparkplugPayload(
        timestampMs: 0,
        seq: 0,
        metrics: [
          SparkplugMetric(name: name, datatype: SparkplugDatatype.boolean, value: value),
        ],
      ));
    }

    test('true for a Sparkplug NCMD payload with Node Control/Rebirth=true on the correct topic', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      final payload = rebirthPayload();
      expect(publisher.isRebirthRequest('spBv1.0/SoftPLC/NCMD/Node1', payload, p), isTrue);
    });

    test('false for the wrong topic', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      final payload = rebirthPayload();
      expect(publisher.isRebirthRequest('spBv1.0/SoftPLC/NCMD/OtherNode', payload, p), isFalse);
    });

    test('false for JSON format (no rebirth concept)', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      final payload = rebirthPayload();
      expect(publisher.isRebirthRequest('spBv1.0/SoftPLC/NCMD/Node1', payload, p), isFalse);
    });

    test('false for a payload without the Rebirth metric', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      final payload = encodePayload(SparkplugPayload(
        timestampMs: 0,
        seq: 0,
        metrics: [
          SparkplugMetric(name: 'Some/Other/Metric', datatype: SparkplugDatatype.boolean, value: true),
        ],
      ));
      expect(publisher.isRebirthRequest('spBv1.0/SoftPLC/NCMD/Node1', payload, p), isFalse);
    });

    test('false when the Rebirth metric value is false', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      final payload = rebirthPayload(value: false);
      expect(publisher.isRebirthRequest('spBv1.0/SoftPLC/NCMD/Node1', payload, p), isFalse);
    });

    test('false for garbage bytes, never throws', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      expect(
        publisher.isRebirthRequest(
          'spBv1.0/SoftPLC/NCMD/Node1',
          Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
          p,
        ),
        isFalse,
      );
    });
  });

  group('force-awareness', () {
    test('a forced tag\'s telemetry reflects the forced value (JSON)', () {
      final p = _fixtureProject(format: 'json');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000); // baseline: Motor=false (unforced)

      final motor = _tag(p, 'Motor');
      motor.isForced = true;
      motor.forcedValue = true; // underlying .value stays false

      final changed = publisher.changedPublishes(p, 2000);
      expect(changed, hasLength(1));
      expect(changed.single.topic, 'softplc/PLC_01/tags/Motor');
      final body = jsonDecode(utf8.decode(changed.single.payload)) as Map;
      expect(body['value'], true); // forced value, not the underlying false
      expect(body['forced'], true);
    });

    test('a forced tag\'s telemetry reflects the forced value (Sparkplug)', () {
      final p = _fixtureProject(format: 'sparkplug');
      final publisher = MqttPublisher();
      publisher.birthMessages(p, 1000); // baseline: Motor=false (unforced)

      final motor = _tag(p, 'Motor');
      motor.isForced = true;
      motor.forcedValue = true;

      final changed = publisher.changedPublishes(p, 2000);
      expect(changed, hasLength(1));
      final decoded = _decodePayload(changed.single.payload);
      expect(decoded.metrics.single.value, true);
    });
  });
}

// ---------------------------------------------------------------------------
// Test-only Sparkplug B encode/decode helpers, mirroring the wire format
// documented in mqtt_sparkplug.dart / duplicated (by that file's own
// precedent, see mqtt_sparkplug_test.dart) rather than exported from
// production code.
// ---------------------------------------------------------------------------

class _SparkplugDatatype {
  static const int int16 = 2;
  static const int int32 = 3;
  static const int uint64 = 8;
  static const int double_ = 10;
  static const int boolean = 11;
}

class _DecodedMetric {
  final String? name;
  final int? alias;
  final int datatype;
  final Object? value;
  const _DecodedMetric({this.name, this.alias, required this.datatype, required this.value});
}

class _DecodedPayload {
  final int timestampMs;
  final int seq;
  final List<_DecodedMetric> metrics;
  const _DecodedPayload({required this.timestampMs, required this.seq, required this.metrics});
}

class _Varint {
  final int value;
  final int nextPos;
  const _Varint(this.value, this.nextPos);
}

_Varint _readVarint(Uint8List data, int pos) {
  int result = 0;
  int shift = 1;
  int p = pos;
  while (true) {
    final b = data[p];
    result += (b & 0x7F) * shift;
    p += 1;
    if ((b & 0x80) == 0) break;
    shift *= 128;
  }
  return _Varint(result, p);
}

String _utf8Decode(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);

int _fromUnsignedWireInt(int datatype, int raw) {
  switch (datatype) {
    case _SparkplugDatatype.int16:
      return raw >= 0x8000 ? raw - 0x10000 : raw;
    case _SparkplugDatatype.int32:
      return raw >= 0x80000000 ? raw - 0x100000000 : raw;
    default:
      return raw;
  }
}

_DecodedMetric _decodeMetric(Uint8List data) {
  String? name;
  int? alias;
  int datatype = -1;
  Object? value;
  int pos = 0;
  while (pos < data.length) {
    final tagVarint = _readVarint(data, pos);
    final tag = tagVarint.value;
    pos = tagVarint.nextPos;
    final fieldNumber = tag >> 3;
    switch (fieldNumber) {
      case 1:
        final len = _readVarint(data, pos);
        pos = len.nextPos;
        name = _utf8Decode(Uint8List.sublistView(data, pos, pos + len.value));
        pos += len.value;
        break;
      case 2:
        final v = _readVarint(data, pos);
        alias = v.value;
        pos = v.nextPos;
        break;
      case 4:
        final v = _readVarint(data, pos);
        datatype = v.value;
        pos = v.nextPos;
        break;
      case 10:
        final v = _readVarint(data, pos);
        value = _fromUnsignedWireInt(datatype, v.value);
        pos = v.nextPos;
        break;
      case 11:
        final v = _readVarint(data, pos);
        value = v.value;
        pos = v.nextPos;
        break;
      case 13:
        final bd = ByteData.sublistView(data, pos, pos + 8);
        value = bd.getFloat64(0, Endian.little);
        pos += 8;
        break;
      case 14:
        final v = _readVarint(data, pos);
        value = v.value != 0;
        pos = v.nextPos;
        break;
      case 15:
        final len = _readVarint(data, pos);
        pos = len.nextPos;
        value = _utf8Decode(Uint8List.sublistView(data, pos, pos + len.value));
        pos += len.value;
        break;
      default:
        throw StateError('unexpected metric field $fieldNumber');
    }
  }
  return _DecodedMetric(name: name, alias: alias, datatype: datatype, value: value);
}

_DecodedPayload _decodePayload(Uint8List data) {
  int timestampMs = 0;
  int seq = 0;
  final metrics = <_DecodedMetric>[];
  int pos = 0;
  while (pos < data.length) {
    final tagVarint = _readVarint(data, pos);
    final tag = tagVarint.value;
    pos = tagVarint.nextPos;
    final fieldNumber = tag >> 3;
    switch (fieldNumber) {
      case 1:
        final v = _readVarint(data, pos);
        timestampMs = v.value;
        pos = v.nextPos;
        break;
      case 2:
        final len = _readVarint(data, pos);
        pos = len.nextPos;
        metrics.add(_decodeMetric(Uint8List.sublistView(data, pos, pos + len.value)));
        pos += len.value;
        break;
      case 3:
        final v = _readVarint(data, pos);
        seq = v.value;
        pos = v.nextPos;
        break;
      default:
        throw StateError('unexpected payload field $fieldNumber');
    }
  }
  return _DecodedPayload(timestampMs: timestampMs, seq: seq, metrics: metrics);
}

class _EncMetric {
  final int? alias;
  final int datatype;
  final Object value;
  const _EncMetric({this.alias, required this.datatype, required this.value});
}

void _writeVarint(BytesBuilder out, int value) {
  int v = value;
  while (true) {
    final byte = v & 0x7F;
    v = v >>> 7;
    if (v == 0) {
      out.addByte(byte);
      break;
    }
    out.addByte(byte | 0x80);
  }
}

void _writeTag(BytesBuilder out, int fieldNumber, int wireType) {
  _writeVarint(out, (fieldNumber << 3) | wireType);
}

Uint8List _encodeMetric(_EncMetric m) {
  final out = BytesBuilder();
  if (m.alias != null) {
    _writeTag(out, 2, 0);
    _writeVarint(out, m.alias!);
  }
  _writeTag(out, 4, 0);
  _writeVarint(out, m.datatype);
  switch (m.datatype) {
    case _SparkplugDatatype.boolean:
      _writeTag(out, 14, 0);
      _writeVarint(out, (m.value as bool) ? 1 : 0);
      break;
    case _SparkplugDatatype.int16:
    case _SparkplugDatatype.int32:
      _writeTag(out, 10, 0);
      _writeVarint(out, m.value as int);
      break;
    case _SparkplugDatatype.double_:
      _writeTag(out, 13, 1);
      final bd = ByteData(8)..setFloat64(0, (m.value as num).toDouble(), Endian.little);
      out.add(bd.buffer.asUint8List());
      break;
    default:
      throw ArgumentError('unsupported test datatype ${m.datatype}');
  }
  return out.toBytes();
}

Uint8List _encodePayload(int timestampMs, int seq, List<_EncMetric> metrics) {
  final out = BytesBuilder();
  _writeTag(out, 1, 0);
  _writeVarint(out, timestampMs);
  for (final m in metrics) {
    final bytes = _encodeMetric(m);
    _writeTag(out, 2, 2);
    _writeVarint(out, bytes.length);
    out.add(bytes);
  }
  _writeTag(out, 3, 0);
  _writeVarint(out, seq);
  return out.toBytes();
}
