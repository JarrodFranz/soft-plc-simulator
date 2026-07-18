// Tests for the dart:io Modbus TCP socket host
// (mobile/lib/services/modbus_host.dart). Uses REAL sockets bound to an
// ephemeral loopback port (port 0) — mirrors opcua_host_test.dart's pattern.
// Every test is bounded so a stalled server/socket can never hang the suite.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart' show readPath;
import 'package:soft_plc_mobile/protocols/modbus/modbus_pdu.dart';
import 'package:soft_plc_mobile/protocols/modbus/modbus_rtu.dart';
import 'package:soft_plc_mobile/services/modbus_host.dart';

PlcProject _enabledProject({int port = 0, String framing = kModbusFramingTcp}) {
  final project = PlcProject(
    id: 'proj_modbus_host_test',
    name: 'Modbus Host Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'Speed',
        path: 'Internal.Speed',
        dataType: 'INT16',
        value: 1234,
        ioType: 'Internal',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.modbus = ModbusProtocolConfig(
    enabled: true,
    port: port,
    map: ModbusMap(entries: [
      ModbusMapEntry(tag: 'Speed', table: 'holding', address: 0, access: 'ReadWrite'),
    ]),
    framing: framing,
  );
  return project;
}

/// Reads until at least [n] bytes are available on [socket], bounded by a
/// timeout so a server that never responds fails the test instead of
/// hanging the suite.
Future<Uint8List> _readAtLeast(Socket socket, int n, {Duration timeout = const Duration(seconds: 5)}) async {
  final buffer = <int>[];
  await for (final chunk in socket.timeout(timeout)) {
    buffer.addAll(chunk);
    if (buffer.length >= n) {
      break;
    }
  }
  return Uint8List.fromList(buffer);
}

void main() {
  group('ModbusHost — start/stop lifecycle', () {
    test('start on a disabled project moves to error status, binds nothing', () async {
      final host = ModbusHost();
      final project = _enabledProject();
      project.protocols!.modbus!.enabled = false;

      await host.start(() => project);

      expect(host.status, ModbusHostStatus.error);
      expect(host.lastError, isNotNull);
      expect(host.endpointUrl, isNull);

      await host.stop();
    });

    test('start when protocols.modbus is null moves to error status', () async {
      final host = ModbusHost();
      final project = _enabledProject();
      project.protocols!.modbus = null;

      await host.start(() => project);

      expect(host.status, ModbusHostStatus.error);
      expect(host.lastError, isNotNull);

      await host.stop();
    });

    test('start on an enabled project (port 0) binds an ephemeral port and reports running', () async {
      final host = ModbusHost();
      final project = _enabledProject(port: 0);

      await host.start(() => project);

      expect(host.status, ModbusHostStatus.running);
      expect(host.endpointUrl, isNotNull);
      expect(host.endpointUrl, contains('modbus-tcp://'));
      expect(host.clientCount, 0);

      await host.stop();
      expect(host.status, ModbusHostStatus.stopped);
      expect(host.endpointUrl, isNull);
    });

    test('stop is safe to call when never started', () async {
      final host = ModbusHost();
      await host.stop();
      expect(host.status, ModbusHostStatus.stopped);
    });

    test('stop then start again works (restart lifecycle)', () async {
      final host = ModbusHost();
      final project = _enabledProject(port: 0);

      await host.start(() => project);
      expect(host.status, ModbusHostStatus.running);
      final firstEndpoint = host.endpointUrl;

      await host.stop();
      expect(host.status, ModbusHostStatus.stopped);

      await host.start(() => project);
      expect(host.status, ModbusHostStatus.running);
      expect(host.endpointUrl, isNotNull);
      expect(firstEndpoint, isNotNull);

      await host.stop();
    });
  });

  group('ModbusHost — real socket FC03 request/response', () {
    test('a raw Socket sending a real MBAP+FC03 request gets the framed response back', () async {
      final host = ModbusHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('modbus-tcp://', 'tcp://'));
      const connectHost = '127.0.0.1';
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      // Read holding register 0, qty 1, transaction id 1, unit id 1.
      final pdu = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01]);
      final frame = buildMbap(1, 1, pdu);
      socket.add(frame);
      await socket.flush();

      final response = await _readAtLeast(socket, 7);
      final parsed = parseMbap(response);
      expect(parsed, isNotNull);
      expect(parsed!.transactionId, 1);
      expect(parsed.unitId, 1);
      // FC03 response: fc(1) + byteCount(1) + 2 bytes for Speed=1234=0x04D2.
      expect(parsed.pdu, [0x03, 0x02, 0x04, 0xD2]);
    });

    test('a garbage burst with a hostile declared length drops only that connection', () async {
      final host = ModbusHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('modbus-tcp://', 'tcp://'));
      const connectHost = '127.0.0.1';

      final garbageSocket = await Socket.connect(connectHost, endpoint.port);
      // Declared length (bytes 4-5) way beyond the 260-byte max ADU guard.
      final garbage = Uint8List.fromList([0x00, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x01, 0x03]);
      garbageSocket.add(garbage);
      await garbageSocket.flush();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.status, ModbusHostStatus.running);
      garbageSocket.destroy();

      // A second, well-behaved client must still be served normally.
      final goodSocket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(goodSocket.destroy);
      final pdu = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01]);
      goodSocket.add(buildMbap(2, 1, pdu));
      await goodSocket.flush();
      final response = await _readAtLeast(goodSocket, 7);
      final parsed = parseMbap(response);
      expect(parsed, isNotNull);
      expect(parsed!.transactionId, 2);
      expect(host.status, ModbusHostStatus.running);
    });

    test('a truly malformed frame (bad protocolId) drops only that connection, server survives', () async {
      final host = ModbusHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('modbus-tcp://', 'tcp://'));
      const connectHost = '127.0.0.1';

      final badSocket = await Socket.connect(connectHost, endpoint.port);
      // protocolId (bytes 2-3) non-zero -> parseMbap returns null.
      final bad = Uint8List.fromList([0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x01, 0x03]);
      badSocket.add(bad);
      await badSocket.flush();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.status, ModbusHostStatus.running);
      badSocket.destroy();
    });
  });

  group('ModbusHost — rtuOverTcp framing (Task 2)', () {
    test('a request split across two TCP chunks yields exactly one correct response', () async {
      final host = ModbusHost();
      final project = _enabledProject(port: 0, framing: kModbusFramingRtuOverTcp);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('modbus-tcp://', 'tcp://'));
      const connectHost = '127.0.0.1';
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      // Read holding register 0, qty 1, unit id 1.
      final pdu = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01]);
      final frame = buildRtu(1, pdu);

      // Split the frame across two chunks, with a delay in between so the
      // second chunk cannot possibly race ahead of the first being buffered.
      final splitAt = frame.length ~/ 2;
      socket.add(frame.sublist(0, splitAt));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.add(frame.sublist(splitAt));
      await socket.flush();

      // Response: unitId(1) + pdu(fc+byteCount+2 data bytes = 4) + crc(2) = 7.
      final response = await _readAtLeast(socket, 7);
      final parsed = parseRtu(response);
      expect(parsed, isNotNull);
      expect(parsed!.unitId, 1);
      // FC03 response: fc(1) + byteCount(1) + 2 bytes for Speed=1234=0x04D2.
      expect(parsed.pdu, [0x03, 0x02, 0x04, 0xD2]);
    });

    test('two coalesced requests in one chunk yield two responses in order', () async {
      final host = ModbusHost();
      final project = _enabledProject(port: 0, framing: kModbusFramingRtuOverTcp);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('modbus-tcp://', 'tcp://'));
      const connectHost = '127.0.0.1';
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      final pdu1 = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01]); // unit 1
      final pdu2 = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01]); // unit 2
      final frame1 = buildRtu(1, pdu1);
      final frame2 = buildRtu(2, pdu2);
      socket.add(Uint8List.fromList([...frame1, ...frame2]));
      await socket.flush();

      // Two 7-byte responses back-to-back = 14 bytes total.
      final response = await _readAtLeast(socket, 14);
      final firstParsed = parseRtu(response.sublist(0, 7));
      final secondParsed = parseRtu(response.sublist(7, 14));
      expect(firstParsed, isNotNull);
      expect(firstParsed!.unitId, 1);
      expect(secondParsed, isNotNull);
      expect(secondParsed!.unitId, 2);
    });

    test('a corrupted-CRC frame yields no response and the connection still answers '
        'a subsequent valid request', () async {
      final host = ModbusHost();
      final project = _enabledProject(port: 0, framing: kModbusFramingRtuOverTcp);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('modbus-tcp://', 'tcp://'));
      const connectHost = '127.0.0.1';
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      final pdu = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01]);
      final goodFrame = buildRtu(1, pdu);
      // Corrupt the last CRC byte so the frame fails its check.
      final corrupted = Uint8List.fromList(goodFrame);
      corrupted[corrupted.length - 1] ^= 0xFF;

      socket.add(corrupted);
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // A subsequent valid request must still be answered — the connection
      // was not torn down by the bad-CRC frame.
      final goodFrame2 = buildRtu(1, pdu);
      socket.add(goodFrame2);
      await socket.flush();

      final response = await _readAtLeast(socket, 7);
      final parsed = parseRtu(response);
      expect(parsed, isNotNull);
      expect(parsed!.unitId, 1);
      expect(parsed.pdu, [0x03, 0x02, 0x04, 0xD2]);
      // Exactly 7 bytes arrived — no stray reply for the corrupted frame.
      expect(response.length, 7);
    });

    test('unit id 0 (broadcast) executes the write but the outstation stays silent, and '
        'a following unicast read is unambiguously answered', () async {
      // Modbus RTU protocol rule: unit id 0 is broadcast — the request MUST
      // still be executed, but the outstation MUST NOT reply. Guards
      // against regressing to answering broadcasts, which would hand a
      // master an unexpected echo it could mistake for the response to
      // whatever unicast request it sends next.
      final host = ModbusHost();
      final project = _enabledProject(port: 0, framing: kModbusFramingRtuOverTcp);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('modbus-tcp://', 'tcp://'));
      const connectHost = '127.0.0.1';
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      final received = <int>[];
      final gotSeven = Completer<void>();
      final sub = socket.listen((data) {
        received.addAll(data);
        if (received.length >= 7 && !gotSeven.isCompleted) {
          gotSeven.complete();
        }
      });
      addTearDown(sub.cancel);

      // Broadcast (unit 0) FC06 write single register: Speed (holding addr
      // 0) <- 0x0042.
      final writePdu = Uint8List.fromList([0x06, 0x00, 0x00, 0x00, 0x42]);
      socket.add(buildRtu(0, writePdu));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(received, isEmpty, reason: 'RTU outstation must stay silent on a broadcast');

      // A following unicast FC03 read (unit 1) must observe the broadcast
      // write took effect, and see exactly its own response — no leaked
      // broadcast-echo bytes ahead of it.
      final readPdu = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01]);
      socket.add(buildRtu(1, readPdu));
      await socket.flush();
      await gotSeven.future.timeout(const Duration(seconds: 5));

      expect(received.length, 7);
      final parsed = parseRtu(Uint8List.fromList(received));
      expect(parsed, isNotNull);
      expect(parsed!.unitId, 1);
      expect(parsed.pdu, [0x03, 0x02, 0x00, 0x42], reason: 'read observes the broadcast write');
    });

    test('an RTU-framed FC16 (write multiple registers) request is reassembled via the '
        'byteCount-derived length and dispatched over a real socket', () async {
      // The `9 + buf[6]` variable-length derivation in `rtuRequestLength` is
      // otherwise proven only at the pure (in-memory buffer) level — this
      // exercises it through the real `_Connection` reassembler over an
      // actual socket, with a genuinely multi-register (qty=2) write so the
      // byteCount field actually varies the frame length.
      final host = ModbusHost();
      final project = PlcProject(
        id: 'proj_modbus_host_fc16_test',
        name: 'Modbus Host FC16 Test',
        controllerName: 'PLC_01',
        tags: [
          PlcTag(name: 'Speed', path: 'Internal.Speed', dataType: 'INT16', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Count', path: 'Internal.Count', dataType: 'INT16', value: 0, ioType: 'Internal'),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.modbus = ModbusProtocolConfig(
        enabled: true,
        port: 0,
        map: ModbusMap(entries: [
          ModbusMapEntry(tag: 'Speed', table: 'holding', address: 0, access: 'ReadWrite'),
          ModbusMapEntry(tag: 'Count', table: 'holding', address: 1, access: 'ReadWrite'),
        ]),
        framing: kModbusFramingRtuOverTcp,
      );
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('modbus-tcp://', 'tcp://'));
      const connectHost = '127.0.0.1';
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      // FC16: write holding registers 0-1 (start=0, qty=2, byteCount=4).
      // Speed(0) <- 0x1234, Count(1) <- 0x0007.
      final pdu = Uint8List.fromList([
        0x10,
        0x00, 0x00, // start
        0x00, 0x02, // qty
        0x04, // byteCount = qty * 2
        0x12, 0x34, // Speed
        0x00, 0x07, // Count
      ]);
      final frame = buildRtu(1, pdu);
      // Split across two chunks so the reassembler must actually wait on
      // the byteCount-derived length rather than happening to get the whole
      // frame in one `onData` call.
      const splitAt = 4; // unitId + fc + start(2) -- before qty/byteCount/data
      socket.add(frame.sublist(0, splitAt));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.add(frame.sublist(splitAt));
      await socket.flush();

      // Response: unitId(1) + echo pdu (fc + start + qty = 5 bytes) + crc(2) = 8.
      final response = await _readAtLeast(socket, 8);
      final parsed = parseRtu(response);
      expect(parsed, isNotNull);
      expect(parsed!.unitId, 1);
      expect(parsed.pdu, [0x10, 0x00, 0x00, 0x00, 0x02]);

      // The write actually took effect server-side, not merely echoed.
      expect(readPath(project, 'Speed'), 0x1234);
      expect(readPath(project, 'Count'), 7);
    });
  });
}
