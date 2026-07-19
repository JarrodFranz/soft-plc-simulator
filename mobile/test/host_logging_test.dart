// Tests for the protocol-host instrumentation (Task 3 of the in-app log
// feature). These prove the thing the whole feature exists for: a request a
// host PARSES but does not SERVE must leave a record naming the offending
// code, instead of vanishing while the Outbound Protocols card still reads
// "Running".
//
// They drive REAL sockets bound to an ephemeral loopback port (port 0),
// exactly like `mobile/test/s7_host_test.dart` and `mobile/test/
// mqtt_host_test.dart` do, so the instrumentation is exercised on the same
// code path a real client takes. Every wait is bounded so a stalled socket
// can never hang the suite.
//
// SECURITY: one test drives an authentication path with a known password and
// scans EVERY entry's `message` AND `detail` for that string. Credentials
// must never reach a log call — outcomes only.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/app_log.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/s7_map.dart';
import 'package:soft_plc_mobile/protocols/mqtt/mqtt_codec.dart';
import 'package:soft_plc_mobile/protocols/s7/s7_pdu.dart';
import 'package:soft_plc_mobile/protocols/s7/tpkt_cotp.dart';
import 'package:soft_plc_mobile/services/app_logger.dart';
import 'package:soft_plc_mobile/services/mqtt_host.dart';
import 'package:soft_plc_mobile/services/s7_host.dart';

// --- shared helpers ---------------------------------------------------------

/// Polls [logger]'s buffer until an entry satisfying [match] appears, bounded
/// by [timeout]. Returns that entry. Polling (rather than a listener) is
/// deliberate: `AppLogger` never notifies per entry, by design.
Future<LogEntry> _waitForEntry(
  AppLogger logger,
  bool Function(LogEntry) match, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (final e in logger.entries) {
      if (match(e)) {
        return e;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw TimeoutException('no log entry matched within $timeout');
}

/// Lets the event loop (and the socket) settle so an entry that was going to
/// be recorded has had ample opportunity to be.
Future<void> _settle([int ms = 400]) => Future<void>.delayed(Duration(milliseconds: ms));

bool _mentions(LogEntry e, String needle) {
  final n = needle.toLowerCase();
  return e.message.toLowerCase().contains(n) || (e.detail?.toLowerCase().contains(n) ?? false);
}

// --- S7 fixtures ------------------------------------------------------------

PlcProject Function() _s7Project({int port = 0}) {
  final project = PlcProject(
    id: 'proj_host_logging_s7',
    name: 'Host Logging S7',
    controllerName: 'PLC_LOG',
    tags: [
      PlcTag(name: 'Running', path: 'Internal.Running', dataType: 'BOOL', value: false, ioType: 'Internal'),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.s7 = S7ProtocolConfig(
    enabled: true,
    port: port,
    map: S7Map(entries: [
      S7MapEntry(tag: 'Running', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 0, bitOffset: 0),
    ]),
  );
  return () => project;
}

/// A COTP Connection Request frame, as a client sends one.
Uint8List _connectRequestFrame() {
  const srcTsap = 0x0100;
  const dstTsap = 0x0102;
  final params = <int>[
    kCotpParamSrcTsap, 0x02, (srcTsap >> 8) & 0xFF, srcTsap & 0xFF,
    kCotpParamDstTsap, 0x02, (dstTsap >> 8) & 0xFF, dstTsap & 0xFF,
  ];
  const fixedFieldsLen = 1 + 2 + 2 + 1;
  final li = fixedFieldsLen + params.length;
  final cotp = Uint8List(1 + li);
  cotp[0] = li;
  cotp[1] = kCotpCr;
  ByteData.sublistView(cotp, 2, 4).setUint16(0, 0x0000, Endian.big);
  ByteData.sublistView(cotp, 4, 6).setUint16(0, 0x0004, Endian.big);
  cotp[6] = 0x00;
  cotp.setRange(7, 7 + params.length, params);
  return buildTpkt(cotp);
}

/// A well-formed TPKT/COTP frame carrying an S7 message whose ROSCTR is
/// [rosctr] — `kS7RosctrUserdata` (0x07) is a ROSCTR this host parses but
/// does not serve.
Uint8List _rosctrFrame(int rosctr) {
  final s7 = buildS7(
    rosctr: rosctr,
    pduReference: 0x0300,
    parameter: Uint8List.fromList([0x00]),
  );
  return buildTpkt(buildCotpData(s7));
}

/// A well-formed S7 Job whose function code is one this device does not
/// serve.
Uint8List _unsupportedFunctionFrame(int function) {
  final s7 = buildS7(
    rosctr: kS7RosctrJob,
    pduReference: 0x0400,
    parameter: Uint8List.fromList([function, 0x00]),
  );
  return buildTpkt(buildCotpData(s7));
}

Future<Socket> _connectToS7(S7Host host) async {
  final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('s7-tcp://', 'tcp://'));
  return Socket.connect('127.0.0.1', endpoint.port);
}

/// Connects, completes the COTP handshake, and returns the client socket. The
/// socket is listened to (and the bytes discarded) so a raw single-
/// subscription `Socket` never buffers indefinitely.
Future<Socket> _establishedS7Client(S7Host host) async {
  final socket = await _connectToS7(host);
  socket.listen((_) {}, onError: (Object _, StackTrace __) {}, cancelOnError: false);
  socket.add(_connectRequestFrame());
  await socket.flush();
  await _settle(200);
  return socket;
}

// --- MQTT fixtures ----------------------------------------------------------

PlcProject Function() _mqttProject({
  required int port,
  bool allowRemoteWrites = false,
}) {
  final project = PlcProject(
    id: 'proj_host_logging_mqtt',
    name: 'Host Logging MQTT',
    controllerName: 'PLC_LOG',
    tags: [
      PlcTag(name: 'Speed', path: 'Speed', dataType: 'FLOAT64', value: 1.5, ioType: 'SimulatedInput'),
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
    heartbeatSeconds: 3600,
    allowRemoteWrites: allowRemoteWrites,
    username: 'operator',
    map: MqttMap(entries: [
      MqttMapEntry(tag: 'Speed', metric: 'Speed', writable: true),
    ]),
  );
  return () => project;
}

/// The test-side "broker": one accepted connection whose inbound bytes are
/// reassembled with the same pure codec the host uses.
class _FakeBroker {
  final ServerSocket server;
  final List<Uint8List> packets = [];
  final MqttFrameBuffer _buffer = MqttFrameBuffer();
  Socket? _socket;

  _FakeBroker(this.server, {required void Function(_FakeBroker) onConnect}) {
    server.listen((socket) {
      _socket = socket;
      socket.listen(
        (data) => packets.addAll(_buffer.add(data)),
        onError: (Object _, StackTrace __) {},
        cancelOnError: false,
      );
      onConnect(this);
    });
  }

  void sendRaw(List<int> bytes) => _socket?.add(Uint8List.fromList(bytes));

  /// CONNACK, session-not-present, with the given return code (0 = accepted,
  /// 5 = not authorized).
  void sendConnack(int returnCode) => sendRaw([0x20, 0x02, 0x00, returnCode]);

  Future<void> close() async {
    try {
      _socket?.destroy();
    } catch (_) {
      // Ignore.
    }
    await server.close();
  }
}

void main() {
  group('S7Host — the silent-drop closure', () {
    test('an unsupported ROSCTR is logged at debug, naming the offending code', () async {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceS7, LogLevel.debug);
      final host = S7Host(logger: logger);
      await host.start(_s7Project());
      final socket = await _establishedS7Client(host);

      socket.add(_rosctrFrame(kS7RosctrUserdata));
      await socket.flush();

      final entry = await _waitForEntry(
        logger,
        (e) => e.source == kLogSourceS7 && _mentions(e, 'rosctr') && _mentions(e, '0x07'),
      );
      expect(entry.level, LogLevel.debug);

      socket.destroy();
      await host.stop();
    });

    test('at the default info level that same drop records no such entry', () async {
      final logger = AppLogger(); // kLogSourceS7 stays at the default: info
      expect(logger.sourceLevel(kLogSourceS7), LogLevel.info);
      final host = S7Host(logger: logger);
      await host.start(_s7Project());
      final socket = await _establishedS7Client(host);

      socket.add(_rosctrFrame(kS7RosctrUserdata));
      await socket.flush();
      await _settle();

      expect(
        logger.entries.where((e) => _mentions(e, 'rosctr')),
        isEmpty,
        reason: 'the verbosity gate must actually gate, not always log',
      );

      socket.destroy();
      await host.stop();
    });

    test('an unsupported S7 function code is logged at debug, naming the code', () async {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceS7, LogLevel.debug);
      final host = S7Host(logger: logger);
      await host.start(_s7Project());
      final socket = await _establishedS7Client(host);

      socket.add(_unsupportedFunctionFrame(0x99));
      await socket.flush();

      final entry = await _waitForEntry(
        logger,
        (e) => e.source == kLogSourceS7 && _mentions(e, 'function') && _mentions(e, '0x99'),
      );
      expect(entry.level, LogLevel.debug);

      socket.destroy();
      await host.stop();
    });

    test('at the default info level the unsupported function records no entry', () async {
      final logger = AppLogger();
      final host = S7Host(logger: logger);
      await host.start(_s7Project());
      final socket = await _establishedS7Client(host);

      socket.add(_unsupportedFunctionFrame(0x99));
      await socket.flush();
      await _settle();

      expect(logger.entries.where((e) => _mentions(e, '0x99')), isEmpty);

      socket.destroy();
      await host.stop();
    });
  });

  group('S7Host — lifecycle logging', () {
    test('a successful bind records an info entry', () async {
      final logger = AppLogger();
      final host = S7Host(logger: logger);
      await host.start(_s7Project());

      expect(
        logger.entries.where((e) => e.source == kLogSourceS7 && _mentions(e, 'listening')),
        isNotEmpty,
      );

      await host.stop();
    });

    test('a bind failure on an unusable port records a warn/error entry', () async {
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final logger = AppLogger();
      final host = S7Host(logger: logger);

      await host.start(_s7Project(port: occupied.port));

      expect(host.status, S7HostStatus.error);
      final failures = logger.entries
          .where((e) => e.source == kLogSourceS7 && e.level.index >= LogLevel.warn.index)
          .toList();
      expect(failures, isNotEmpty);
      expect(failures.any((e) => _mentions(e, 'bind')), isTrue);

      await host.stop();
      await occupied.close();
    });

    test('a client connect and a client disconnect each record an entry', () async {
      final logger = AppLogger();
      final host = S7Host(logger: logger);
      await host.start(_s7Project());

      final socket = await _connectToS7(host);
      socket.listen((_) {}, onError: (Object _, StackTrace __) {}, cancelOnError: false);
      await _waitForEntry(logger, (e) => e.source == kLogSourceS7 && _mentions(e, 'client connected'));

      socket.destroy();
      await _waitForEntry(logger, (e) => e.source == kLogSourceS7 && _mentions(e, 'client disconnected'));

      await host.stop();
    });

    test('a bare host with no logger still serves (the parameter is optional)', () async {
      final host = S7Host();
      await host.start(_s7Project());
      expect(host.status, S7HostStatus.running);
      final socket = await _establishedS7Client(host);
      socket.add(_rosctrFrame(kS7RosctrUserdata));
      await socket.flush();
      await _settle(200);
      expect(host.status, S7HostStatus.running);
      socket.destroy();
      await host.stop();
    });
  });

  group('MqttHost — credentials never reach the log', () {
    test('a rejected CONNACK logs the outcome and never the password', () async {
      const password = 'sup3r-s3cret-hunter2-passw0rd';
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final broker = _FakeBroker(server, onConnect: (b) => b.sendConnack(5));

      final logger = AppLogger();
      // Maximum verbosity on EVERY source this test could touch, so a leak
      // has nowhere to hide behind a level gate.
      for (final source in <String>[kLogSourceMqtt, kLogSourceOpcUa, kLogSourceProject]) {
        logger.setSourceLevel(source, LogLevel.trace);
      }
      final host = MqttHost(logger: logger);
      await host.connect(_mqttProject(port: server.port), password: password);

      await _waitForEntry(
        logger,
        (e) => e.source == kLogSourceMqtt && _mentions(e, 'refused'),
      );

      for (final e in logger.entries) {
        expect(e.message.contains(password), isFalse,
            reason: 'password leaked into a log message: ${e.message}');
        expect(e.detail?.contains(password) ?? false, isFalse,
            reason: 'password leaked into a log detail: ${e.detail}');
      }

      await host.disconnect();
      host.dispose();
      await broker.close();
    });
  });

  group('MqttHost — write refusal', () {
    test('a remote write arriving while remote writes are disabled is logged', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final broker = _FakeBroker(server, onConnect: (b) => b.sendConnack(0));

      final logger = AppLogger();
      final host = MqttHost(logger: logger);
      await host.connect(_mqttProject(port: server.port), password: '');

      await _waitForEntry(logger, (e) => e.source == kLogSourceMqtt && _mentions(e, 'connected'));

      broker.sendRaw(encodePublish(
        topic: 'softplc/SoftPLC/Node1/cmd/Speed',
        payload: Uint8List.fromList('{"value":1}'.codeUnits),
        qos: 0,
        retain: false,
      ));

      final entry = await _waitForEntry(
        logger,
        (e) => e.source == kLogSourceMqtt && _mentions(e, 'refused'),
      );
      expect(entry.level.index >= LogLevel.warn.index, isTrue);

      await host.disconnect();
      host.dispose();
      await broker.close();
    });
  });
}
