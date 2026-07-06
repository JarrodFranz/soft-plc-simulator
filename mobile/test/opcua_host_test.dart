// Tests for the dart:io OPC UA socket host
// (mobile/lib/services/opcua_host.dart). Uses REAL sockets bound to an
// ephemeral loopback port (port 0) — this is the one Task 4 test file
// allowed to touch actual networking. Every test is bounded with a timeout
// so a stalled server/socket can never hang the suite.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_transport.dart';
import 'package:soft_plc_mobile/services/opcua_host.dart';

PlcProject _enabledProject({int port = 0}) {
  final project = PlcProject(
    id: 'proj_opcua_host_test',
    name: 'OPC UA Host Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'Start_PB',
        path: 'Inputs.Start_PB',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedInput',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.opcua = OpcUaProtocolConfig(
    enabled: true,
    namespaceUri: 'urn:softplc:test',
    map: OpcuaMap(
      namespaceUri: 'urn:softplc:test',
      nodes: [OpcuaNode(nodeId: 'ns=1;s=Start_PB', tag: 'Start_PB', access: 'ReadWrite')],
    ),
    port: port,
  );
  return project;
}

Uint8List _helHandshakeFrame() {
  const hello = HelloMessage(
    protocolVersion: 0,
    receiveBufferSize: 65536,
    sendBufferSize: 65536,
    maxMessageSize: 0,
    maxChunkCount: 0,
    endpointUrl: 'opc.tcp://127.0.0.1:0',
  );
  return hello.build();
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

/// Accumulates ALL bytes ever received on a socket (a single `listen` call,
/// since a Dart `Stream` can only be listened to once) so a test can await
/// "at least N bytes total" multiple times without re-listening.
class _SocketAccumulator {
  final List<int> _buffer = [];
  final List<void Function()> _waiters = [];

  _SocketAccumulator(Socket socket) {
    socket.listen((chunk) {
      _buffer.addAll(chunk);
      for (final w in List.of(_waiters)) {
        w();
      }
    });
  }

  Future<Uint8List> atLeast(int n, {Duration timeout = const Duration(seconds: 5)}) async {
    if (_buffer.length >= n) {
      return Uint8List.fromList(_buffer);
    }
    final completer = Completer<void>();
    void waiter() {
      if (_buffer.length >= n && !completer.isCompleted) {
        completer.complete();
      }
    }

    _waiters.add(waiter);
    try {
      await completer.future.timeout(timeout);
    } finally {
      _waiters.remove(waiter);
    }
    return Uint8List.fromList(_buffer);
  }
}

void main() {
  group('OpcUaHost — start/stop lifecycle', () {
    test('start on a disabled project moves to error status, binds nothing', () async {
      final host = OpcUaHost();
      final project = _enabledProject();
      project.protocols!.opcua!.enabled = false;

      await host.start(() => project);

      expect(host.status, OpcUaHostStatus.error);
      expect(host.lastError, isNotNull);
      expect(host.endpointUrl, isNull);

      await host.stop();
    });

    test('start on an enabled project (port 0) binds an ephemeral port and reports running', () async {
      final host = OpcUaHost();
      final project = _enabledProject(port: 0);

      await host.start(() => project);

      expect(host.status, OpcUaHostStatus.running);
      expect(host.endpointUrl, isNotNull);
      expect(host.endpointUrl, contains('opc.tcp://'));
      expect(host.clientCount, 0);

      await host.stop();
      expect(host.status, OpcUaHostStatus.stopped);
      expect(host.endpointUrl, isNull);
    });

    test('stop is safe to call when never started', () async {
      final host = OpcUaHost();
      await host.stop();
      expect(host.status, OpcUaHostStatus.stopped);
    });

    test('stop then start again works (restart lifecycle)', () async {
      final host = OpcUaHost();
      final project = _enabledProject(port: 0);

      await host.start(() => project);
      expect(host.status, OpcUaHostStatus.running);
      final firstEndpoint = host.endpointUrl;

      await host.stop();
      expect(host.status, OpcUaHostStatus.stopped);

      await host.start(() => project);
      expect(host.status, OpcUaHostStatus.running);
      expect(host.endpointUrl, isNotNull);
      // A fresh ephemeral port is picked each time (port 0) — just confirm
      // hosting resumed cleanly, not that the port literally changed.
      expect(firstEndpoint, isNotNull);

      await host.stop();
    });
  });

  group('OpcUaHost — real socket HEL/ACK handshake', () {
    test('connecting a raw Socket and sending a real HEL frame gets an ACK back', () async {
      final host = OpcUaHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('opc.tcp://', 'tcp://'));
      const connectHost = '127.0.0.1'; // loopback: avoids LAN-IP routing flakiness in sandboxed test environments
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      socket.add(_helHandshakeFrame());
      await socket.flush();

      final response = await _readAtLeast(socket, kMessageHeaderLen);
      final header = MessageHeader.parse(response);
      expect(header.messageType, 'ACK');

      expect(host.clientCount, greaterThanOrEqualTo(1));
    });

    test('a HEL frame split across two socket writes still reassembles correctly', () async {
      final host = OpcUaHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('opc.tcp://', 'tcp://'));
      const connectHost = '127.0.0.1'; // loopback: avoids LAN-IP routing flakiness in sandboxed test environments
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);

      final frame = _helHandshakeFrame();
      final splitAt = frame.length ~/ 2;
      socket.add(frame.sublist(0, splitAt));
      await socket.flush();
      // Small delay to make sure the two writes really do land as separate
      // `data` events rather than being coalesced by the OS before the
      // second write is even issued.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      socket.add(frame.sublist(splitAt));
      await socket.flush();

      final response = await _readAtLeast(socket, kMessageHeaderLen);
      final header = MessageHeader.parse(response);
      expect(header.messageType, 'ACK');
    });

    test('two HEL frames sent in one write (multi-frame burst) both get ACKed', () async {
      final host = OpcUaHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('opc.tcp://', 'tcp://'));
      const connectHost = '127.0.0.1'; // loopback: avoids LAN-IP routing flakiness in sandboxed test environments
      final socket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socket.destroy);
      final acc = _SocketAccumulator(socket);

      // A second HEL on the same connection is itself protocol-invalid
      // (HEL is only legal once) but the point here is purely to prove the
      // host's reassembly loop extracts and dispatches BOTH frames from a
      // single `data` event rather than only acting on the first — i.e. an
      // ACK for the first HEL followed promptly by an ERR (protocol
      // violation) for the second, never silence/hang on the second frame.
      final frame = _helHandshakeFrame();
      final burst = BytesBuilder(copy: true)
        ..add(frame)
        ..add(frame);
      socket.add(burst.takeBytes());
      await socket.flush();

      // First response: ACK for the first HEL.
      final first = await acc.atLeast(kMessageHeaderLen);
      final firstHeader = MessageHeader.parse(first);
      expect(firstHeader.messageType, 'ACK');

      // Second response should follow (ERR, since a second HEL isn't legal)
      // — proving the second frame in the burst WAS processed, not dropped.
      final firstAckLen = firstHeader.size;
      final second = await acc.atLeast(firstAckLen + kMessageHeaderLen);
      final remainder = second.sublist(firstAckLen);
      final secondHeader = MessageHeader.parse(Uint8List.fromList(remainder));
      expect(secondHeader.messageType, isIn(['ERR', 'ACK']));
    });

    test('hostile garbage bytes close only that connection; host keeps running for a second client', () async {
      final host = OpcUaHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('opc.tcp://', 'tcp://'));
      const connectHost = '127.0.0.1'; // loopback: avoids LAN-IP routing flakiness in sandboxed test environments

      final garbageSocket = await Socket.connect(connectHost, endpoint.port);
      // A hostile declared size (way over any negotiated max) in the header
      // — the host must close this connection without crashing.
      final garbage = BytesBuilder(copy: true)
        ..add('XXX'.codeUnits)
        ..add([0])
        ..add([0xFF, 0xFF, 0xFF, 0x7F]); // huge bogus size
      garbageSocket.add(garbage.takeBytes());
      await garbageSocket.flush();

      // Give the host a moment to process and drop the connection.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.status, OpcUaHostStatus.running);
      garbageSocket.destroy();

      // A second, well-behaved client must still be served normally.
      final goodSocket = await Socket.connect(connectHost, endpoint.port);
      addTearDown(goodSocket.destroy);
      goodSocket.add(_helHandshakeFrame());
      await goodSocket.flush();
      final response = await _readAtLeast(goodSocket, kMessageHeaderLen);
      final header = MessageHeader.parse(response);
      expect(header.messageType, 'ACK');
      expect(host.status, OpcUaHostStatus.running);
    });

    test('two clients connecting concurrently each get an independent session/ACK', () async {
      final host = OpcUaHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('opc.tcp://', 'tcp://'));
      const connectHost = '127.0.0.1'; // loopback: avoids LAN-IP routing flakiness in sandboxed test environments

      final socketA = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socketA.destroy);
      final socketB = await Socket.connect(connectHost, endpoint.port);
      addTearDown(socketB.destroy);

      socketA.add(_helHandshakeFrame());
      await socketA.flush();
      socketB.add(_helHandshakeFrame());
      await socketB.flush();

      final respA = await _readAtLeast(socketA, kMessageHeaderLen);
      final respB = await _readAtLeast(socketB, kMessageHeaderLen);
      expect(MessageHeader.parse(respA).messageType, 'ACK');
      expect(MessageHeader.parse(respB).messageType, 'ACK');
      expect(host.clientCount, greaterThanOrEqualTo(2));
    });
  });
}
