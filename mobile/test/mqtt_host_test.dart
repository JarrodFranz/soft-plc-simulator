// Tests for the dart:io MQTT publisher CLIENT host
// (mobile/lib/services/mqtt_host.dart). Unlike the listen-only
// opcua_host_test.dart/modbus_host_test.dart, this host dials OUT to a
// broker, so the test harness plays the broker: a real `ServerSocket` bound
// to an ephemeral loopback port accepts the host's connection, replies with
// a hand-built CONNACK, and captures/decodes whatever the host sends back
// using the pure codec (`mqtt_codec.dart`) the host itself is built on.
// Every test is bounded so a stalled connection can never hang the suite.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_codec.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_sparkplug.dart'
    show SparkplugDatatype, SparkplugMetric, SparkplugPayload, encodePayload;
import 'package:soft_plc_mobile/services/mqtt_host.dart';

// Reuses the test-only Sparkplug B `decodePayload`/`decodeMetric` decoder
// from mqtt_sparkplug_test.dart (production code only ENCODES Sparkplug B —
// see that file's own doc comment for why) rather than hand-rolling a third
// copy of the same decode logic just to read a `bdSeq` metric back out of a
// Will/NBIRTH payload here. Importing a sibling test file only brings its
// top-level declarations into scope — its own `main()` is never invoked as
// part of running this file.
import 'mqtt_sparkplug_test.dart' as sparkplug_decode;

PlcProject _project({
  int port = 0,
  bool allowRemoteWrites = false,
  int heartbeatSeconds = 3600, // long enough to never fire mid-test
}) {
  final project = PlcProject(
    id: 'proj_mqtt_host_test',
    name: 'MQTT Host Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(name: 'Speed', path: 'Speed', dataType: 'FLOAT64', value: 1.5, ioType: 'SimulatedInput'),
      PlcTag(name: 'Alarm', path: 'Alarm', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput'),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.mqtt = MqttProtocolConfig(
    enabled: true,
    host: '127.0.0.1',
    port: port,
    tls: false,
    format: 'json',
    baseTopic: 'softplc',
    groupId: 'SoftPLC',
    edgeNodeId: 'Node1',
    qos: 0,
    heartbeatSeconds: heartbeatSeconds,
    allowRemoteWrites: allowRemoteWrites,
    map: MqttMap(entries: [
      MqttMapEntry(tag: 'Speed', metric: 'Speed', writable: true),
      MqttMapEntry(tag: 'Alarm', metric: 'Alarm', writable: false),
    ]),
  );
  return project;
}

/// Same fixture as [_project] but configured for Sparkplug B (rather than
/// JSON) so the Will/NBIRTH carry a decodable `bdSeq` metric.
PlcProject _sparkplugProject({int port = 0}) {
  final project = _project(port: port);
  project.protocols!.mqtt!.format = 'sparkplug';
  return project;
}

/// Extracts the `bdSeq` metric's value out of a raw Sparkplug B `Payload`
/// (the Will's NDEATH bytes, or an NBIRTH/NDATA PUBLISH payload) — see the
/// `sparkplug_decode` import above.
int _bdSeqOf(Uint8List payload) {
  final decoded = sparkplug_decode.decodePayload(payload);
  final metric = decoded.metrics.firstWhere((m) => m.name == 'bdSeq');
  return metric.value as int;
}

/// The test-side "broker": accepts one connection, reassembles the client's
/// outbound bytes into complete MQTT packets via the same pure
/// `MqttFrameBuffer` the production host uses, and exposes them for
/// assertions/polling.
class _FakeBrokerConnection {
  final Socket socket;
  final MqttFrameBuffer _buffer = MqttFrameBuffer();
  final List<Uint8List> packets = [];

  _FakeBrokerConnection(this.socket) {
    socket.listen(
      (data) => packets.addAll(_buffer.add(data)),
      onError: (_) {},
      onDone: () {},
      cancelOnError: false,
    );
  }

  void sendRaw(List<int> bytes) => socket.add(Uint8List.fromList(bytes));

  /// A minimal accepted CONNACK: session-not-present, return code 0.
  void sendConnackAccepted() => sendRaw(const [0x20, 0x02, 0x00, 0x00]);
}

/// A `ServerSocket`'s stream is single-subscription — it can only ever be
/// `listen`ed to once, so a disconnect/reconnect test can't just call
/// `server.listen(...)` again for the second connection. This wraps ONE
/// `listen()` call in a small accept queue so `acceptOne()` can be awaited
/// repeatedly (once per incoming connection, in order) across a whole test.
class _BrokerServer {
  final List<Socket> _queue = [];
  final List<Completer<Socket>> _waiters = [];

  _BrokerServer(ServerSocket serverSocket) {
    serverSocket.listen((socket) {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(socket);
      } else {
        _queue.add(socket);
      }
    });
  }

  Future<_FakeBrokerConnection> acceptOne() async {
    Socket socket;
    if (_queue.isNotEmpty) {
      socket = _queue.removeAt(0);
    } else {
      final completer = Completer<Socket>();
      _waiters.add(completer);
      socket = await completer.future.timeout(const Duration(seconds: 5));
    }
    return _FakeBrokerConnection(socket);
  }
}

/// Polls [conn.packets] (a synchronously-appended list, so no broadcast-
/// stream "subscribed too late" race) until the [occurrence]-th packet of
/// [type] has arrived, bounded by [timeout].
Future<Uint8List> _waitForPacketType(
  _FakeBrokerConnection conn,
  int type,
  int occurrence, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    var seen = 0;
    for (final p in conn.packets) {
      if (p.isNotEmpty && ((p[0] >> 4) & 0x0F) == type) {
        seen++;
        if (seen == occurrence) {
          return p;
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('packet type $type occurrence $occurrence not observed within $timeout');
}

// --- Test-only CONNECT decoder ----------------------------------------------
// mqtt_codec.dart deliberately has no `parseConnect` (only a broker would
// ever need one; production code here only ENCODES CONNECT) — mirroring
// mqtt_sparkplug_test.dart's own precedent, the decoder needed to verify the
// bytes the host sent lives here, in the test file.

class _DecodedConnect {
  final String protocolName;
  final int level;
  final int flags;
  final int keepAliveSecs;
  final String clientId;
  final String? willTopic;
  final Uint8List? willPayload;

  const _DecodedConnect({
    required this.protocolName,
    required this.level,
    required this.flags,
    required this.keepAliveSecs,
    required this.clientId,
    this.willTopic,
    this.willPayload,
  });

  bool get hasWill => (flags & 0x04) != 0;
  bool get willRetain => (flags & 0x20) != 0;
  int get willQos => (flags >> 3) & 0x03;
}

int _u16(Uint8List data, int offset) => (data[offset] << 8) | data[offset + 1];

_DecodedConnect _decodeConnect(Uint8List packet) {
  final rl = decodeRemainingLength(packet, 1)!;
  var pos = 1 + rl.bytesConsumed;

  final nameLen = _u16(packet, pos);
  pos += 2;
  final name = utf8.decode(packet.sublist(pos, pos + nameLen));
  pos += nameLen;

  final level = packet[pos];
  pos += 1;
  final flags = packet[pos];
  pos += 1;
  final keepAlive = _u16(packet, pos);
  pos += 2;

  final clientIdLen = _u16(packet, pos);
  pos += 2;
  final clientId = utf8.decode(packet.sublist(pos, pos + clientIdLen));
  pos += clientIdLen;

  String? willTopic;
  Uint8List? willPayload;
  if ((flags & 0x04) != 0) {
    final wtLen = _u16(packet, pos);
    pos += 2;
    willTopic = utf8.decode(packet.sublist(pos, pos + wtLen));
    pos += wtLen;
    final wpLen = _u16(packet, pos);
    pos += 2;
    willPayload = Uint8List.sublistView(packet, pos, pos + wpLen);
    pos += wpLen;
  }

  return _DecodedConnect(
    protocolName: name,
    level: level,
    flags: flags,
    keepAliveSecs: keepAlive,
    clientId: clientId,
    willTopic: willTopic,
    willPayload: willPayload,
  );
}

void main() {
  group('MqttHost — lifecycle', () {
    test('connecting when MQTT is disabled moves to error status', () async {
      final host = MqttHost();
      addTearDown(host.dispose);
      final project = _project();
      project.protocols!.mqtt!.enabled = false;

      await host.connect(() => project, password: '');

      expect(host.status, MqttHostStatus.error);
      expect(host.lastError, isNotNull);
    });

    test('connecting when protocols.mqtt is null moves to error status', () async {
      final host = MqttHost();
      addTearDown(host.dispose);
      final project = _project();
      project.protocols!.mqtt = null;

      await host.connect(() => project, password: '');

      expect(host.status, MqttHostStatus.error);
      expect(host.lastError, isNotNull);
    });

    test('disconnect is safe to call when never connected', () async {
      final host = MqttHost();
      await host.disconnect();
      expect(host.status, MqttHostStatus.stopped);
    });
  });

  group('MqttHost — real socket CONNECT/CONNACK/birth', () {
    test('connects and sends a well-formed CONNECT with Will set from willMessage', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _project(port: server.port);
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: 'secret');
      final conn = await connFuture;

      final connectPacket = await _waitForPacketType(conn, MqttPacketType.connect, 1);
      final decoded = _decodeConnect(connectPacket);

      expect(decoded.protocolName, 'MQTT');
      expect(decoded.level, 4);
      expect(decoded.keepAliveSecs, greaterThan(0));
      expect(decoded.hasWill, isTrue);
      expect(decoded.willTopic, 'softplc/PLC_01/status');
      expect(decoded.willRetain, isTrue);
      expect(utf8.decode(decoded.willPayload!), 'OFFLINE');

      expect(host.status, MqttHostStatus.connecting);
      await host.disconnect();
    });

    test('publishes JSON birth (retained ONLINE) then a report-by-exception change on tick', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _project(port: server.port);
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);
      conn.sendConnackAccepted();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.status, MqttHostStatus.running);
      expect(host.connected, isTrue);

      final birth = await _waitForPacketType(conn, MqttPacketType.publish, 1);
      final birthPub = parsePublish(birth)!;
      expect(birthPub.topic, 'softplc/PLC_01/status');
      expect(utf8.decode(birthPub.payload), 'ONLINE');
      expect(birthPub.retain, isTrue);
      expect(host.publishCount, greaterThanOrEqualTo(1));

      // Mutate a mapped tag; the tick (default 250ms) changedPublishes should report it.
      writePath(project, 'Speed', 42.5);

      final changePub = await _waitForPacketType(conn, MqttPacketType.publish, 2);
      final change = parsePublish(changePub)!;
      expect(change.topic, 'softplc/PLC_01/tags/Speed');
      expect(jsonDecode(utf8.decode(change.payload))['value'], 42.5);

      await host.disconnect();
    });

    test('an inbound command PUBLISH applies a force-aware writePath when allowRemoteWrites', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _project(port: server.port, allowRemoteWrites: true);
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);
      conn.sendConnackAccepted();

      // Wait for the SUBSCRIBE the host sends because allowRemoteWrites is on.
      await _waitForPacketType(conn, MqttPacketType.subscribe, 1);

      final cmdPacket = encodePublish(
        topic: 'softplc/PLC_01/tags/Speed/set',
        payload: Uint8List.fromList(utf8.encode('77.5')),
      );
      conn.sendRaw(cmdPacket);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline) && readPath(project, 'Speed') != 77.5) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(readPath(project, 'Speed'), 77.5);

      await host.disconnect();
    });

    test('a forced tag ignores an inbound command write (silent skip)', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _project(port: server.port, allowRemoteWrites: true);
      final speedTag = project.tags.firstWhere((t) => t.name == 'Speed');
      speedTag.isForced = true;
      speedTag.forcedValue = 9.0;
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);
      conn.sendConnackAccepted();
      await _waitForPacketType(conn, MqttPacketType.subscribe, 1);

      final cmdPacket = encodePublish(
        topic: 'softplc/PLC_01/tags/Speed/set',
        payload: Uint8List.fromList(utf8.encode('123.0')),
      );
      conn.sendRaw(cmdPacket);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // The underlying value must NOT have been overwritten by the remote
      // write while forced.
      expect(speedTag.value, isNot(123.0));

      await host.disconnect();
    });

    test('disconnect/reconnect lifecycle updates status', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _project(port: server.port);
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture1 = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn1 = await connFuture1;
      await _waitForPacketType(conn1, MqttPacketType.connect, 1);
      conn1.sendConnackAccepted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.status, MqttHostStatus.running);

      await host.disconnect();
      expect(host.status, MqttHostStatus.stopped);
      expect(host.connected, isFalse);

      final connFuture2 = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn2 = await connFuture2;
      await _waitForPacketType(conn2, MqttPacketType.connect, 1);
      conn2.sendConnackAccepted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.status, MqttHostStatus.running);

      await host.disconnect();
    });
  });

  group('MqttHost — bdSeq monotonicity across reconnects', () {
    test('bdSeq strictly increases across two successive connect cycles', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _sparkplugProject(port: server.port);
      final host = MqttHost();
      addTearDown(host.dispose);

      // --- Session 1: bdSeq must be 1 in both the Will and the NBIRTH. ---
      final connFuture1 = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn1 = await connFuture1;
      final connectPacket1 = await _waitForPacketType(conn1, MqttPacketType.connect, 1);
      final decodedConnect1 = _decodeConnect(connectPacket1);
      expect(decodedConnect1.hasWill, isTrue);
      final willBdSeq1 = _bdSeqOf(decodedConnect1.willPayload!);
      expect(willBdSeq1, 1);

      conn1.sendConnackAccepted();
      final birth1 = await _waitForPacketType(conn1, MqttPacketType.publish, 1);
      final birthBdSeq1 = _bdSeqOf(parsePublish(birth1)!.payload);
      expect(birthBdSeq1, 1, reason: 'NBIRTH must carry the SAME bdSeq as its paired Will');

      await host.disconnect();

      // --- Session 2 (fresh connect after disconnect): bdSeq must climb to
      // 2, not reset — this is the spec violation this fix corrects. ---
      final connFuture2 = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn2 = await connFuture2;
      final connectPacket2 = await _waitForPacketType(conn2, MqttPacketType.connect, 1);
      final decodedConnect2 = _decodeConnect(connectPacket2);
      final willBdSeq2 = _bdSeqOf(decodedConnect2.willPayload!);
      expect(willBdSeq2, greaterThan(willBdSeq1));
      expect(willBdSeq2, 2);

      conn2.sendConnackAccepted();
      final birth2 = await _waitForPacketType(conn2, MqttPacketType.publish, 1);
      final birthBdSeq2 = _bdSeqOf(parsePublish(birth2)!.payload);
      expect(birthBdSeq2, 2);

      await host.disconnect();
    });
  });

  group('MqttHost — keepalive ping never throws on a closed socket', () {
    test('the guarded PINGREQ send survives the broker closing the connection', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _project(port: server.port);
      // Shrinks the 30s production ping interval so several ping attempts
      // land inside this test's bounded window, without changing default
      // (no-argument) MqttHost behavior anywhere else.
      final host = MqttHost(pingIntervalOverride: const Duration(milliseconds: 20));
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);
      conn.sendConnackAccepted();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.status, MqttHostStatus.running);

      // Abruptly close the broker side out from under the still-"running"
      // host — this is the race the guard covers: the host's own socket
      // object may still be non-null (and a subsequent write may throw) for
      // a brief window before the host notices the connection died and
      // cancels the ping timer. Several 20ms-spaced ping attempts land in
      // that window; the test's own success (no uncaught exception
      // propagating out of the Timer.periodic callback's Zone, which would
      // otherwise fail this test) is the assertion.
      //
      // NOTE on platform determinism: whether `Socket.add()` can actually
      // throw synchronously in this exact window is platform-dependent —
      // confirmed empirically that on Windows/this SDK, `add()` after the
      // peer (or even the same local socket) is destroyed does NOT throw
      // synchronously, so this test cannot force a pre-fix failure on every
      // platform. It's kept anyway as a bounded (well under a second,
      // versus the real 30s interval), non-flaky regression guard: it
      // exercises the exact code path the guard covers and protects
      // whichever platform's dart:io implementation (e.g. Linux/macOS,
      // where a synchronous `SocketException: Broken pipe` from `add()` is
      // a documented real occurrence) does throw here.
      await conn.socket.close();
      conn.socket.destroy();

      await Future<void>.delayed(const Duration(milliseconds: 300));

      // No crash occurred (the try/catch guard absorbed it, if it fired at
      // all) and the host recovered to a non-running state via the normal
      // onDone/onError path.
      expect(host.status, isNot(MqttHostStatus.running));
    });
  });

  group('MqttHost — wall-clock message timestamps (Bug 1)', () {
    test('NBIRTH and NDATA carry the injected wall-clock epoch, not a stopwatch value', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _sparkplugProject(port: server.port);
      // A real-world UTC epoch ms value — unmistakably NOT a small
      // Stopwatch.elapsedMilliseconds reading (which would start near 0).
      const fixedEpochMs = 1750000000000;
      final host = MqttHost(nowMsOverride: () => fixedEpochMs);
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);
      conn.sendConnackAccepted();

      final birth = await _waitForPacketType(conn, MqttPacketType.publish, 1);
      final birthPayload = sparkplug_decode.decodePayload(parsePublish(birth)!.payload);
      expect(birthPayload.timestampMs, fixedEpochMs);

      writePath(project, 'Speed', 42.5);
      final change = await _waitForPacketType(conn, MqttPacketType.publish, 2);
      final changePayload = sparkplug_decode.decodePayload(parsePublish(change)!.payload);
      expect(changePayload.timestampMs, fixedEpochMs);

      await host.disconnect();
    });
  });

  group('MqttHost — Sparkplug rebirth (Bug 2)', () {
    test('an inbound Node Control/Rebirth NCMD re-sends NBIRTH even when allowRemoteWrites is false', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _sparkplugProject(port: server.port); // allowRemoteWrites: false by default
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);
      conn.sendConnackAccepted();

      // Initial NBIRTH (publish #1).
      await _waitForPacketType(conn, MqttPacketType.publish, 1);

      // Even with allowRemoteWrites false, the host must still subscribe to
      // the Sparkplug NCMD topic so it can service rebirth requests.
      await _waitForPacketType(conn, MqttPacketType.subscribe, 1);

      final rebirthPayload = encodePayload(const SparkplugPayload(
        timestampMs: 0,
        seq: 0,
        metrics: [
          SparkplugMetric(name: 'Node Control/Rebirth', datatype: SparkplugDatatype.boolean, value: true),
        ],
      ));
      final ncmdPacket = encodePublish(
        topic: 'spBv1.0/SoftPLC/NCMD/Node1',
        payload: rebirthPayload,
      );
      conn.sendRaw(ncmdPacket);

      // The next PUBLISH (occurrence 2) must be a fresh NBIRTH.
      final secondPublish = await _waitForPacketType(conn, MqttPacketType.publish, 2);
      final secondPub = parsePublish(secondPublish)!;
      expect(secondPub.topic, 'spBv1.0/SoftPLC/NBIRTH/Node1');
      expect(secondPub.retain, isTrue);

      await host.disconnect();
    });
  });

  group('MqttHost — manual requestRebirth() (mqtt-rebirth-live-tags)', () {
    test('requestRebirth() after connect+birth sends a fresh NBIRTH publish', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _sparkplugProject(port: server.port);
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);
      conn.sendConnackAccepted();

      // Initial NBIRTH (publish #1).
      final firstBirth = await _waitForPacketType(conn, MqttPacketType.publish, 1);
      final firstPub = parsePublish(firstBirth)!;
      expect(firstPub.topic, 'spBv1.0/SoftPLC/NBIRTH/Node1');
      final countBeforeRebirth = host.publishCount;

      // Simulate a live tag-map edit (mirrors what the Gateway screen's map
      // editor does directly on the project object while connected), then
      // request a manual rebirth — a fresh NBIRTH must be re-sent (a second
      // occurrence of the NBIRTH topic) without ever disconnecting.
      project.protocols!.mqtt!.map.entries.add(
        MqttMapEntry(tag: 'Alarm', metric: 'AlarmRenamed', writable: false),
      );
      host.requestRebirth();

      final secondPublish = await _waitForPacketType(conn, MqttPacketType.publish, 2);
      final secondPub = parsePublish(secondPublish)!;
      expect(secondPub.topic, 'spBv1.0/SoftPLC/NBIRTH/Node1');
      expect(secondPub.retain, isTrue);
      expect(host.status, MqttHostStatus.running, reason: 'a manual rebirth must not disconnect the host');
      expect(host.publishCount, greaterThan(countBeforeRebirth));

      // bdSeq must be UNCHANGED by a manual rebirth (same pairing rule as an
      // inbound NCMD rebirth — see the group above): re-decode both NBIRTHs'
      // bdSeq metric and compare.
      expect(_bdSeqOf(secondPub.payload), _bdSeqOf(firstPub.payload));

      await host.disconnect();
    });

    test('requestRebirth() on a never-connected host is a safe no-op', () async {
      final host = MqttHost();
      addTearDown(host.dispose);

      expect(() => host.requestRebirth(), returnsNormally);
      expect(host.status, MqttHostStatus.stopped);
    });

    test('requestRebirth() on a stopped (previously connected, now disconnected) host is a safe no-op',
        () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _sparkplugProject(port: server.port);
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);
      conn.sendConnackAccepted();
      await _waitForPacketType(conn, MqttPacketType.publish, 1);

      await host.disconnect();

      expect(() => host.requestRebirth(), returnsNormally);
      expect(host.status, MqttHostStatus.stopped);
    });
  });

  group('MqttHost — hostile broker input never crashes', () {
    test('garbage bytes from the broker drop the connection without throwing', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _project(port: server.port);
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);

      // A reserved/unrecognized fixed-header type nibble (0) with a short
      // body — a well-formed MQTT frame shape, but not any packet type this
      // client understands.
      conn.sendRaw([0x0F, 0x02, 0xAB, 0xCD]);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(host.status, isNot(MqttHostStatus.running));
      expect(host.lastError, isNotNull);
    });

    test('an over-limit declared frame size drops the connection', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final broker = _BrokerServer(server);
      addTearDown(server.close);
      final project = _project(port: server.port);
      final host = MqttHost();
      addTearDown(host.dispose);

      final connFuture = broker.acceptOne();
      await host.connect(() => project, password: '');
      final conn = await connFuture;
      await _waitForPacketType(conn, MqttPacketType.connect, 1);

      // CONNACK type nibble, but a declared remaining length (~268M, the
      // MQTT varint max) far beyond the host's 4 MB cap.
      conn.sendRaw([0x20, 0xFF, 0xFF, 0xFF, 0x7F]);

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(host.status, isNot(MqttHostStatus.running));
      expect(host.lastError, isNotNull);
    });
  });
}
