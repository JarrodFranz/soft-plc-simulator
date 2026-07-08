// Byte-exact fixtures for the pure MQTT 3.1.1 control-packet codec
// (mobile/lib/protocols/mqtt/mqtt_codec.dart), hand-derived against the
// OASIS MQTT Version 3.1.1 spec. No sockets/hosting logic here — just the
// wire-format encode/decode helpers and the streaming reassembler.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_codec.dart';

void main() {
  group('remaining-length varint', () {
    test('encodeRemainingLength at the 1/2/3/4-byte boundaries', () {
      expect(encodeRemainingLength(0), [0x00]);
      expect(encodeRemainingLength(127), [0x7F]);
      expect(encodeRemainingLength(128), [0x80, 0x01]);
      expect(encodeRemainingLength(16383), [0xFF, 0x7F]);
      expect(encodeRemainingLength(16384), [0x80, 0x80, 0x01]);
    });

    test('decodeRemainingLength inverts each boundary', () {
      MqttVarInt? d(List<int> bytes) => decodeRemainingLength(Uint8List.fromList(bytes));
      expect(d([0x00])!.value, 0);
      expect(d([0x00])!.bytesConsumed, 1);
      expect(d([0x7F])!.value, 127);
      expect(d([0x80, 0x01])!.value, 128);
      expect(d([0x80, 0x01])!.bytesConsumed, 2);
      expect(d([0xFF, 0x7F])!.value, 16383);
      expect(d([0x80, 0x80, 0x01])!.value, 16384);
      expect(d([0x80, 0x80, 0x01])!.bytesConsumed, 3);
    });

    test('decodeRemainingLength returns null ("need more") on a truncated varint', () {
      // A single 0x80 byte says "more bytes follow" but none do.
      expect(decodeRemainingLength(Uint8List.fromList([0x80])), isNull);
      // Same, two bytes deep.
      expect(decodeRemainingLength(Uint8List.fromList([0x80, 0x80])), isNull);
      // Empty input.
      expect(decodeRemainingLength(Uint8List.fromList([])), isNull);
    });

    test('decodeRemainingLength honors a nonzero start offset', () {
      final d = decodeRemainingLength(Uint8List.fromList([0xAA, 0x7F]), 1);
      expect(d!.value, 127);
      expect(d.bytesConsumed, 1);
    });
  });

  group('encodeConnect', () {
    test('clientId + will + username/password produces the exact byte sequence', () {
      // Connect flags byte (section 3.1.2.3):
      //   bit7 username=1 (0x80) | bit6 password=1 (0x40) |
      //   bit5 willRetain=1 (0x20) | bits4-3 willQoS=00 (0x00) |
      //   bit2 willFlag=1 (0x04) | bit1 cleanSession=1 (0x02) | bit0 reserved=0
      //   = 0x80+0x40+0x20+0x00+0x04+0x02 = 0xE6 = 0b1110_0110.
      final packet = encodeConnect(
        clientId: 'plc',
        keepAliveSecs: 30,
        cleanSession: true,
        username: 'u',
        password: 'p',
        willTopic: 'softplc/plc/status',
        willPayload: Uint8List.fromList('OFFLINE'.codeUnits),
        willRetain: true,
        willQos: 0,
      );

      final expected = <int>[
        0x10, 0x32, // CONNECT (type 1 << 4, flags 0), remaining length 50
        0x00, 0x04, ...'MQTT'.codeUnits, // protocol name
        0x04, // protocol level: MQTT 3.1.1
        0xE6, // connect flags (derived above)
        0x00, 0x1E, // keep alive = 30
        0x00, 0x03, ...'plc'.codeUnits, // clientId
        0x00, 0x12, ...'softplc/plc/status'.codeUnits, // will topic (18 chars)
        0x00, 0x07, ...'OFFLINE'.codeUnits, // will payload (7 bytes)
        0x00, 0x01, ...'u'.codeUnits, // username
        0x00, 0x01, ...'p'.codeUnits, // password
      ];
      expect(expected.length, 52);
      expect(packet, expected);
    });

    test('no will, no auth: connect flags carry only cleanSession', () {
      final packet = encodeConnect(clientId: 'x', keepAliveSecs: 60, cleanSession: true);
      // flags = cleanSession(0x02) only.
      // variable header = protoName(6) + level(1) + flags(1) + keepAlive(2) = 10;
      // payload = clientId "x" (2+1=3); remaining length = 10+3 = 13 = 0x0D.
      final expected = <int>[
        0x10, 0x0D,
        0x00, 0x04, ...'MQTT'.codeUnits,
        0x04,
        0x02,
        0x00, 0x3C, // keep alive 60
        0x00, 0x01, ...'x'.codeUnits,
      ];
      expect(packet, expected);
    });
  });

  group('encodePublish', () {
    test('QoS0 retain carries no packetId', () {
      final packet = encodePublish(
        topic: 'softplc/plc/status',
        payload: Uint8List.fromList('ONLINE'.codeUnits),
        qos: 0,
        retain: true,
      );
      final expected = <int>[
        0x31, 0x1A, // PUBLISH (type 3 << 4 | flags 0x01 retain), remaining length 26
        0x00, 0x12, ...'softplc/plc/status'.codeUnits, // topic (18 chars)
        ...'ONLINE'.codeUnits, // payload, no length prefix (remainder of the packet)
      ];
      expect(expected.length, 28);
      expect(packet, expected);
    });

    test('QoS1 includes the u16 packetId', () {
      final packet = encodePublish(
        topic: 'a',
        payload: Uint8List.fromList([0x01]),
        qos: 1,
        retain: false,
        packetId: 7,
      );
      final expected = <int>[
        0x32, 0x06, // PUBLISH, flags 0x02 (qos1), remaining length 6
        0x00, 0x01, 0x61, // topic "a"
        0x00, 0x07, // packetId 7
        0x01, // payload
      ];
      expect(packet, expected);
    });
  });

  test('encodeSubscribe exact bytes', () {
    final packet = encodeSubscribe(
      packetId: 1,
      topicFilters: const [MqttTopicFilter('softplc/plc/tags/+/set', qos: 0)],
    );
    final expected = <int>[
      0x82, 0x1B, // SUBSCRIBE (type 8 << 4 | reserved flags 0b0010), remaining length 27
      0x00, 0x01, // packetId 1
      0x00, 0x16, ...'softplc/plc/tags/+/set'.codeUnits, // topic filter (22 chars)
      0x00, // requested QoS 0
    ];
    expect(expected.length, 29);
    expect(packet, expected);
  });

  test('encodePingReq / encodeDisconnect', () {
    expect(encodePingReq(), [0xC0, 0x00]);
    expect(encodeDisconnect(), [0xE0, 0x00]);
  });

  group('response parsers', () {
    test('parseConnack reads sessionPresent + returnCode', () {
      final accepted = parseConnack(Uint8List.fromList([0x20, 0x02, 0x00, 0x00]));
      expect(accepted!.sessionPresent, false);
      expect(accepted.returnCode, 0);

      final resumed = parseConnack(Uint8List.fromList([0x20, 0x02, 0x01, 0x00]));
      expect(resumed!.sessionPresent, true);
      expect(resumed.returnCode, 0);
    });

    test('parseConnack returns null on a wrong-type or short packet', () {
      expect(parseConnack(Uint8List.fromList([0x40, 0x02, 0x00, 0x00])), isNull); // PUBACK type
      expect(parseConnack(Uint8List.fromList([0x20, 0x02, 0x00])), isNull); // short body
      expect(parseConnack(Uint8List.fromList([])), isNull);
    });

    test('parsePuback reads the packetId', () {
      expect(parsePuback(Uint8List.fromList([0x40, 0x02, 0x00, 0x07])), 7);
    });

    test('parsePuback returns null on garbage', () {
      expect(parsePuback(Uint8List.fromList([0x20, 0x02, 0x00, 0x07])), isNull);
      expect(parsePuback(Uint8List.fromList([0x40, 0x02, 0x00])), isNull);
    });

    test('parseSuback reads packetId + return codes', () {
      final single = parseSuback(Uint8List.fromList([0x90, 0x03, 0x00, 0x01, 0x00]));
      expect(single!.packetId, 1);
      expect(single.returnCodes, [0x00]);

      final multi = parseSuback(Uint8List.fromList([0x90, 0x04, 0x00, 0x02, 0x01, 0x80]));
      expect(multi!.packetId, 2);
      expect(multi.returnCodes, [0x01, 0x80]);
    });

    test('parseSuback returns null on a truncated packet', () {
      expect(parseSuback(Uint8List.fromList([0x90, 0x03, 0x00, 0x01])), isNull);
    });

    test('parsePublish round-trips an encoded QoS0 publish', () {
      final wire = encodePublish(
        topic: 'softplc/plc/status',
        payload: Uint8List.fromList('ONLINE'.codeUnits),
        qos: 0,
        retain: true,
      );
      final parsed = parsePublish(wire);
      expect(parsed!.topic, 'softplc/plc/status');
      expect(parsed.payload, 'ONLINE'.codeUnits);
      expect(parsed.qos, 0);
      expect(parsed.packetId, isNull);
      expect(parsed.retain, true);
    });

    test('parsePublish round-trips an encoded QoS1 publish with packetId', () {
      final wire = encodePublish(topic: 'a', payload: Uint8List.fromList([0x01]), qos: 1, packetId: 7);
      final parsed = parsePublish(wire);
      expect(parsed!.topic, 'a');
      expect(parsed.payload, [0x01]);
      expect(parsed.qos, 1);
      expect(parsed.packetId, 7);
      expect(parsed.retain, false);
    });

    test('parsePublish returns null on a truncated topic string', () {
      // Claims a 5-byte topic but only 2 bytes of it are present.
      expect(parsePublish(Uint8List.fromList([0x30, 0x04, 0x00, 0x05, 0x61, 0x62])), isNull);
    });

    test('parsePublish returns null when QoS>0 but no room for the packetId', () {
      // qos=1 flag set, topic "a" present, but nothing left for the packetId.
      expect(parsePublish(Uint8List.fromList([0x32, 0x03, 0x00, 0x01, 0x61])), isNull);
    });
  });

  group('MqttFrameBuffer', () {
    test('emits a packet only once a split CONNACK completes', () {
      final buf = MqttFrameBuffer();
      expect(buf.add(Uint8List.fromList([0x20, 0x02])), isEmpty);
      final second = buf.add(Uint8List.fromList([0x00, 0x00]));
      expect(second.length, 1);
      expect(second.first, [0x20, 0x02, 0x00, 0x00]);
    });

    test('emits two packets from one coalesced add() call', () {
      final buf = MqttFrameBuffer();
      final single = [0x30, 0x04, 0x00, 0x01, 0x61, 0x01]; // PUBLISH topic "a" payload 0x01
      final packets = buf.add(Uint8List.fromList([...single, ...single]));
      expect(packets.length, 2);
      expect(packets[0], single);
      expect(packets[1], single);
    });

    test('waits when the remaining length promises more than has arrived', () {
      final buf = MqttFrameBuffer();
      // Claims remaining length 10 (0x0A) but only 2 body bytes show up.
      final first = buf.add(Uint8List.fromList([0x30, 0x0A, 0x00, 0x01]));
      expect(first, isEmpty);
      // Feed the rest (8 more bytes) and it should complete.
      final rest = buf.add(Uint8List.fromList([0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68]));
      expect(rest.length, 1);
      expect(rest.first.length, 12);
    });

    test('never throws on random/garbage bytes and does not wedge', () {
      final buf = MqttFrameBuffer();
      expect(() => buf.add(Uint8List.fromList(List<int>.filled(20, 0xFF))), returnsNormally);
      // A trailing well-formed PINGREQ after garbage should still eventually
      // be extractable once the garbage byte(s) are dropped/resynced or a
      // legal frame boundary is found; at minimum, feeding more data must
      // never throw.
      expect(() => buf.add(Uint8List.fromList([0xC0, 0x00])), returnsNormally);
    });

    test('an incomplete varint (continuation bit, no follow-up byte) waits, does not throw', () {
      final buf = MqttFrameBuffer();
      expect(() => buf.add(Uint8List.fromList([0x30, 0x80])), returnsNormally);
      expect(buf.add(Uint8List.fromList([0x80])), isEmpty);
    });
  });
}
