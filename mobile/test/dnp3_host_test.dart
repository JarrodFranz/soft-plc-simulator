// Tests for the dart:io DNP3 outstation TCP socket host
// (mobile/lib/services/dnp3_host.dart). Uses REAL sockets bound to an
// ephemeral loopback port (port 0) — mirrors modbus_host_test.dart's
// pattern. Every test is bounded so a stalled server/socket can never hang
// the suite.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_app.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_link.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_transport.dart';
import 'package:soft_plc_mobile/services/dnp3_host.dart';

const int _kOutstationAddress = 1024;
const int _kMasterAddress = 1;

PlcProject _enabledProject({int port = 0, int outstationAddress = _kOutstationAddress, int masterAddress = _kMasterAddress}) {
  final project = PlcProject(
    id: 'proj_dnp3_host_test',
    name: 'DNP3 Host Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'Speed',
        path: 'Internal.Speed',
        dataType: 'INT32',
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
  project.protocols!.dnp3 = DnpProtocolConfig(
    enabled: true,
    port: port,
    outstationAddress: outstationAddress,
    masterAddress: masterAddress,
    map: DnpMap(entries: [
      DnpMapEntry(tag: 'Speed', pointType: 'analogInput', index: 0),
    ]),
  );
  return project;
}

/// Builds a real, valid, fully link-framed + transport-framed Class 0
/// integrity-poll READ request — exactly what a real master sends — using
/// only the Task 2/3 codecs (`buildTransport`/`buildLinkFrame`), addressed
/// from [masterAddress] to [dest].
Uint8List _class0ReadFrame({required int dest, required int src, int seq = 0}) {
  final out = BytesBuilder();
  out.addByte(0xC0 | (seq & 0x0F)); // APP_CONTROL: FIR|FIN, sequence
  out.addByte(DnpFunc.read);
  out.add(encodeObjectHeader(group: 60, variation: 1, qualifier: DnpQualifier.allPoints));
  final appFragment = out.toBytes();
  final segment = buildTransport(0, fir: true, fin: true, appData: appFragment);
  return buildLinkFrame(control: 0xC4, dest: dest, src: src, userData: segment);
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
  group('DnpHost — start/stop lifecycle', () {
    test('start on a disabled project moves to error status, binds nothing', () async {
      final host = DnpHost();
      final project = _enabledProject();
      project.protocols!.dnp3!.enabled = false;

      await host.start(() => project);

      expect(host.status, DnpHostStatus.error);
      expect(host.lastError, isNotNull);
      expect(host.endpointUrl, isNull);

      await host.stop();
    });

    test('start when protocols.dnp3 is null moves to error status', () async {
      final host = DnpHost();
      final project = _enabledProject();
      project.protocols!.dnp3 = null;

      await host.start(() => project);

      expect(host.status, DnpHostStatus.error);
      expect(host.lastError, isNotNull);

      await host.stop();
    });

    test('start on an enabled project (port 0) binds an ephemeral port and reports running', () async {
      final host = DnpHost();
      final project = _enabledProject(port: 0);

      await host.start(() => project);

      expect(host.status, DnpHostStatus.running);
      expect(host.endpointUrl, isNotNull);
      expect(host.endpointUrl, contains('dnp3://'));
      expect(host.clientCount, 0);

      await host.stop();
      expect(host.status, DnpHostStatus.stopped);
      expect(host.endpointUrl, isNull);
    });

    test('stop is safe to call when never started', () async {
      final host = DnpHost();
      await host.stop();
      expect(host.status, DnpHostStatus.stopped);
    });

    test('stop then start again works (restart lifecycle)', () async {
      final host = DnpHost();
      final project = _enabledProject(port: 0);

      await host.start(() => project);
      expect(host.status, DnpHostStatus.running);
      final firstEndpoint = host.endpointUrl;

      await host.stop();
      expect(host.status, DnpHostStatus.stopped);

      await host.start(() => project);
      expect(host.status, DnpHostStatus.running);
      expect(host.endpointUrl, isNotNull);
      expect(firstEndpoint, isNotNull);

      await host.stop();
    });
  });

  group('DnpHost — real socket Class 0 read request/response', () {
    test('a raw Socket sending a real link-framed Class 0 read gets a well-formed response frame back', () async {
      final host = DnpHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('dnp3://', 'tcp://'));
      const connectHost = '127.0.0.1';
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      final frame = _class0ReadFrame(dest: _kOutstationAddress, src: _kMasterAddress);
      socket.add(frame);
      await socket.flush();

      // Minimum well-formed response: 10-byte header block + at least one
      // data block (here, well over 16 bytes of object data) + its CRC.
      final response = await _readAtLeast(socket, 12);
      expect(response[0], 0x05);
      expect(response[1], 0x64);

      final parsed = parseLinkFrame(response);
      expect(parsed, isNotNull, reason: 'header + block CRCs must all validate');
      expect(parsed!.dest, _kMasterAddress);
      expect(parsed.src, _kOutstationAddress);

      // Strip the transport header and confirm this is a DNP3 application
      // RESPONSE fragment (function code 0x81) that is not device-restart
      // silent (i.e. an actual answer, not just an echoed error).
      final reassembler = DnpTransportReassembler();
      final appFragment = reassembler.addSegment(parsed.userData);
      expect(appFragment, isNotNull);
      expect(appFragment!.length, greaterThanOrEqualTo(4));
      expect(appFragment[1], DnpFunc.response);
    });

    test('a frame addressed to a different outstation address is ignored (no response)', () async {
      final host = DnpHost();
      final project = _enabledProject(port: 0, outstationAddress: _kOutstationAddress);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('dnp3://', 'tcp://'));
      const connectHost = '127.0.0.1';
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      // Addressed to some OTHER outstation (not _kOutstationAddress).
      final frame = _class0ReadFrame(dest: _kOutstationAddress + 1, src: _kMasterAddress);
      socket.add(frame);
      await socket.flush();

      // No response should ever arrive — assert nothing shows up within a
      // short bounded window rather than waiting for a timeout to prove a
      // negative indefinitely.
      var gotData = false;
      final sub = socket.listen((_) => gotData = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      expect(gotData, isFalse);
      expect(host.status, DnpHostStatus.running);
    });

    test('a malformed burst drops only that connection, server survives', () async {
      final host = DnpHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('dnp3://', 'tcp://'));
      const connectHost = '127.0.0.1';

      // Flood a connection with pure garbage far exceeding the DNP3 link
      // frame's max size (~292 bytes) and containing no valid sync bytes —
      // the host's pending-bytes flood guard should close this connection
      // without throwing and without affecting the server.
      final garbageSocket = await Socket.connect(connectHost, endpoint.port);
      final garbage = Uint8List(8000)..fillRange(0, 8000, 0xAA);
      garbageSocket.add(garbage);
      await garbageSocket.flush();

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(host.status, DnpHostStatus.running);
      garbageSocket.destroy();

      // A second, well-behaved client must still be served normally.
      final goodSocket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(goodSocket.destroy);
      final frame = _class0ReadFrame(dest: _kOutstationAddress, src: _kMasterAddress);
      goodSocket.add(frame);
      await goodSocket.flush();
      final response = await _readAtLeast(goodSocket, 12);
      final parsed = parseLinkFrame(response);
      expect(parsed, isNotNull);
      expect(parsed!.dest, _kMasterAddress);
      expect(host.status, DnpHostStatus.running);
    });

    test('a truncated/CRC-corrupt frame drops only that connection, server survives', () async {
      final host = DnpHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('dnp3://', 'tcp://'));
      const connectHost = '127.0.0.1';

      final badSocket = await Socket.connect(connectHost, endpoint.port);
      final frame = _class0ReadFrame(dest: _kOutstationAddress, src: _kMasterAddress);
      // Corrupt the header CRC bytes (offset 8-9) so parseLinkFrame rejects it.
      final corrupted = Uint8List.fromList(frame);
      corrupted[8] ^= 0xFF;
      corrupted[9] ^= 0xFF;
      badSocket.add(corrupted);
      await badSocket.flush();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.status, DnpHostStatus.running);
      badSocket.destroy();
    });
  });
}
