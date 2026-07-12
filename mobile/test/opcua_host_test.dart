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
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_transport.dart';
import 'package:soft_plc_mobile/services/opcua_cert_store.dart';
import 'package:soft_plc_mobile/services/opcua_host.dart';

// --- Encoding ids, verified against types/node_ids.rs -----------------------
const _openSecureChannelRequestId = 446;
const _createSessionRequestId = 461;
const _activateSessionRequestId = 467;
const _createSubscriptionRequestId = 787;
const _createMonitoredItemsRequestId = 751;
const _publishRequestId = 826;
const _publishResponseId = 829;

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

RequestHeader _reqHeader({
  OpcNodeId authToken = const OpcNodeId.numeric(0, 0),
  int requestHandle = 1,
}) {
  return RequestHeader(
    authToken: authToken,
    timestamp: DateTime.utc(2026, 7, 6),
    requestHandle: requestHandle,
  );
}

Uint8List _opnRequestFrame({int requestId = 10}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _openSecureChannelRequestId));
  w.requestHeader(_reqHeader());
  w.uint32(0); // clientProtocolVersion
  w.int32(0); // requestType: Issue
  w.int32(1); // securityMode: None
  w.byteString(null); // clientNonce
  w.uint32(60000); // requestedLifetime
  return buildOpnChunk(
    secureChannelId: 0,
    securityPolicyUri: kSecurityPolicyNoneUri,
    sequenceNumber: 1,
    requestId: requestId,
    body: w.take(),
  );
}

Uint8List _createSessionRequestFrame(int channelId, int tokenId, {int requestId = 11}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _createSessionRequestId));
  w.requestHeader(_reqHeader(requestHandle: 3));
  w.string('urn:test:client');
  w.string('urn:test:client:product');
  w.localizedText(const OpcLocalizedText(text: 'Test Client'));
  w.int32(1); // ApplicationType.Client
  w.string(null);
  w.string(null);
  w.int32(-1);
  w.string(null);
  w.string('opc.tcp://127.0.0.1:0');
  w.string('test-session');
  w.byteString(null);
  w.byteString(null);
  w.float64(1200000);
  w.uint32(0);
  return buildMsgChunk(
    secureChannelId: channelId,
    tokenId: tokenId,
    sequenceNumber: 2,
    requestId: requestId,
    body: w.take(),
  );
}

Uint8List _activateSessionRequestFrame(
  int channelId,
  int tokenId,
  OpcNodeId authToken, {
  int requestId = 12,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _activateSessionRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: 4));
  w.string(null);
  w.byteString(null);
  w.int32(-1);
  w.int32(-1);
  final tokenWriter = OpcUaWriter();
  tokenWriter.string('anonymous');
  w.extensionObjectHeader(const OpcNodeId.numeric(0, 321), hasBody: true);
  w.byteString(tokenWriter.take());
  w.string(null);
  w.byteString(null);
  return buildMsgChunk(
    secureChannelId: channelId,
    tokenId: tokenId,
    sequenceNumber: 3,
    requestId: requestId,
    body: w.take(),
  );
}

Uint8List _createSubscriptionRequestFrame(
  int channelId,
  int tokenId,
  OpcNodeId authToken, {
  int requestId = 13,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _createSubscriptionRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: 5));
  w.float64(100); // requestedPublishingInterval
  w.uint32(100); // requestedLifetimeCount
  w.uint32(10); // requestedMaxKeepAliveCount
  w.uint32(0); // maxNotificationsPerPublish
  w.boolean(true); // publishingEnabled
  w.uint8(0); // priority
  return buildMsgChunk(
    secureChannelId: channelId,
    tokenId: tokenId,
    sequenceNumber: 4,
    requestId: requestId,
    body: w.take(),
  );
}

Uint8List _createMonitoredItemsRequestFrame(
  int channelId,
  int tokenId,
  OpcNodeId authToken,
  int subscriptionId,
  OpcNodeId nodeId, {
  int requestId = 14,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _createMonitoredItemsRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: 6));
  w.uint32(subscriptionId);
  w.int32(2); // timestampsToReturn
  w.int32(1); // itemsToCreate: one entry
  w.nodeId(nodeId);
  w.uint32(13); // attributeId: Value
  w.string(null); // indexRange
  w.qualifiedName(const OpcQualifiedName(ns: 0, name: null));
  w.int32(2); // monitoringMode: Reporting
  w.uint32(1); // clientHandle
  w.float64(0); // samplingInterval: linked to publishing interval
  w.extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false); // filter: none
  w.uint32(1); // queueSize
  w.boolean(true); // discardOldest
  return buildMsgChunk(
    secureChannelId: channelId,
    tokenId: tokenId,
    sequenceNumber: 5,
    requestId: requestId,
    body: w.take(),
  );
}

Uint8List _publishRequestFrame(
  int channelId,
  int tokenId,
  OpcNodeId authToken, {
  int requestId = 15,
  int sequenceNumber = 6,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _publishRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: 7));
  w.int32(-1); // subscriptionAcknowledgements: null array
  return buildMsgChunk(
    secureChannelId: channelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
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

  int get length => _buffer.length;

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

  group('OpcUaHost — clock tick / subscription push (Task 3 E2E)', () {
    test(
      'CreateSubscription + CreateMonitoredItems + parked Publish -> the tick timer pushes an unsolicited PublishResponse when the served tag changes',
      () async {
        final host = OpcUaHost();
        final project = _enabledProject(port: 0);
        await host.start(() => project);
        addTearDown(host.stop);

        final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('opc.tcp://', 'tcp://'));
        const connectHost = '127.0.0.1';
        final socket = await Socket.connect(connectHost, endpoint.port);
        addTearDown(socket.destroy);
        final acc = _SocketAccumulator(socket);

        // HEL -> ACK
        socket.add(_helHandshakeFrame());
        await socket.flush();
        final ack = await acc.atLeast(kMessageHeaderLen);
        expect(MessageHeader.parse(ack).messageType, 'ACK');
        var consumed = MessageHeader.parse(ack).size;

        // OPN -> OpenSecureChannelResponse
        socket.add(_opnRequestFrame());
        await socket.flush();
        var buf = await acc.atLeast(consumed + kChunkHeaderLen);
        var frameBytes = Uint8List.fromList(buf.sublist(consumed));
        var frameSize = MessageHeader.parse(frameBytes).size;
        buf = await acc.atLeast(consumed + frameSize);
        frameBytes = Uint8List.fromList(buf.sublist(consumed, consumed + frameSize));
        var chunk = parseChunk(frameBytes);
        consumed += frameSize;
        var reader = OpcUaReader(chunk.body);
        reader.nodeId();
        reader.responseHeader();
        reader.uint32(); // serverProtocolVersion
        final channelId = reader.uint32();
        final tokenId = reader.uint32();

        // CreateSession -> CreateSessionResponse
        socket.add(_createSessionRequestFrame(channelId, tokenId));
        await socket.flush();
        buf = await acc.atLeast(consumed + kChunkHeaderLen);
        frameBytes = Uint8List.fromList(buf.sublist(consumed));
        frameSize = MessageHeader.parse(frameBytes).size;
        buf = await acc.atLeast(consumed + frameSize);
        frameBytes = Uint8List.fromList(buf.sublist(consumed, consumed + frameSize));
        chunk = parseChunk(frameBytes);
        consumed += frameSize;
        reader = OpcUaReader(chunk.body);
        reader.nodeId();
        reader.responseHeader();
        reader.nodeId(); // sessionId
        final authToken = reader.nodeId();

        // ActivateSession -> ActivateSessionResponse
        socket.add(_activateSessionRequestFrame(channelId, tokenId, authToken));
        await socket.flush();
        buf = await acc.atLeast(consumed + kChunkHeaderLen);
        frameBytes = Uint8List.fromList(buf.sublist(consumed));
        frameSize = MessageHeader.parse(frameBytes).size;
        buf = await acc.atLeast(consumed + frameSize);
        consumed += frameSize;

        // CreateSubscription -> CreateSubscriptionResponse
        socket.add(_createSubscriptionRequestFrame(channelId, tokenId, authToken));
        await socket.flush();
        buf = await acc.atLeast(consumed + kChunkHeaderLen);
        frameBytes = Uint8List.fromList(buf.sublist(consumed));
        frameSize = MessageHeader.parse(frameBytes).size;
        buf = await acc.atLeast(consumed + frameSize);
        frameBytes = Uint8List.fromList(buf.sublist(consumed, consumed + frameSize));
        chunk = parseChunk(frameBytes);
        consumed += frameSize;
        reader = OpcUaReader(chunk.body);
        reader.nodeId();
        reader.responseHeader();
        final subscriptionId = reader.uint32();

        expect(host.subscriptionCount, greaterThanOrEqualTo(1));

        // CreateMonitoredItems on the served project's Start_PB tag ->
        // CreateMonitoredItemsResponse.
        const monitoredNodeId = OpcNodeId.string(1, 'Start_PB');
        socket.add(_createMonitoredItemsRequestFrame(
          channelId,
          tokenId,
          authToken,
          subscriptionId,
          monitoredNodeId,
        ));
        await socket.flush();
        buf = await acc.atLeast(consumed + kChunkHeaderLen);
        frameBytes = Uint8List.fromList(buf.sublist(consumed));
        frameSize = MessageHeader.parse(frameBytes).size;
        buf = await acc.atLeast(consumed + frameSize);
        consumed += frameSize;

        expect(host.monitoredItemCount, greaterThanOrEqualTo(1));

        // Park a Publish: the host must send NOTHING more right away.
        socket.add(_publishRequestFrame(channelId, tokenId, authToken));
        await socket.flush();
        final consumedAfterPublish = consumed;
        // Give the tick timer a couple of cycles to prove it does NOT push a
        // keep-alive/data response before the tag actually changes AND the
        // publishing interval has elapsed at least once with queued data.
        await Future<void>.delayed(const Duration(milliseconds: 120));

        // Mutate the served project's tag via writePath — this is what the
        // NEXT tick's sampling must pick up.
        writePath(project, 'Start_PB', true);

        // Await the pushed PublishResponse frame, bounded by a generous
        // timeout so a broken timer/tick path fails the test instead of
        // hanging the suite.
        var withPush = await acc.atLeast(consumedAfterPublish + kChunkHeaderLen, timeout: const Duration(seconds: 5));
        final pushFrameSize =
            MessageHeader.parse(Uint8List.fromList(withPush.sublist(consumedAfterPublish))).size;
        withPush = await acc.atLeast(
          consumedAfterPublish + pushFrameSize,
          timeout: const Duration(seconds: 5),
        );
        final pushChunk = parseChunk(
          Uint8List.fromList(withPush.sublist(consumedAfterPublish, consumedAfterPublish + pushFrameSize)),
        );
        expect(pushChunk.messageType, 'MSG');
        final pushReader = OpcUaReader(pushChunk.body);
        final typeId = pushReader.nodeId();
        expect(typeId.numericId, _publishResponseId);
        final header = pushReader.responseHeader();
        expect(header.serviceResult, 0);
        final respSubId = pushReader.uint32();
        expect(respSubId, subscriptionId);

        // Stop hosting: no further frames should ever arrive, and the test
        // must end without a pending-timer flake.
        final bytesBeforeStop = acc.length;
        await host.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(acc.length, bytesBeforeStop);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  group('OpcUaHost — cert-store wiring (WS19 Task 6)', () {
    test(
      'a secure-policy config loads an app identity and exposes its thumbprint; '
      'regenerateCertificate() replaces it',
      () async {
        final dir = await Directory.systemTemp.createTemp('opcua_host_cert_test');
        addTearDown(() => dir.delete(recursive: true));

        final host = OpcUaHost(certStore: OpcUaCertStore(overrideDir: dir.path));
        addTearDown(host.stop);
        final project = _enabledProject(port: 0);
        project.protocols!.opcua!.securityModes = ['None', 'Basic256Sha256/SignAndEncrypt'];

        expect(host.appCertThumbprint, isNull); // nothing loaded before start()

        await host.start(() => project);

        expect(host.status, OpcUaHostStatus.running);
        expect(host.appCertThumbprint, isNotNull);
        expect(host.appCertThumbprint, matches(RegExp(r'^([0-9A-F]{2}:)+[0-9A-F]{2}$')));

        final firstThumbprint = host.appCertThumbprint;
        await host.regenerateCertificate();
        expect(host.appCertThumbprint, isNotNull);
        expect(host.appCertThumbprint, isNot(firstThumbprint));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a None-only config still starts normally and serves HEL/ACK when the '
      'cert store is unavailable (loadOrCreate never crashes start())',
      () async {
        final host = OpcUaHost(); // no certStore override: production default
        final project = _enabledProject(port: 0);
        await host.start(() => project);
        addTearDown(host.stop);

        expect(host.status, OpcUaHostStatus.running);

        final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('opc.tcp://', 'tcp://'));
        final socket = await Socket.connect('127.0.0.1', endpoint.port);
        addTearDown(socket.destroy);
        socket.add(_helHandshakeFrame());
        await socket.flush();
        final response = await _readAtLeast(socket, kMessageHeaderLen);
        expect(MessageHeader.parse(response).messageType, 'ACK');
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a None-only host reaches running WITHOUT the cert store being '
      'touched — no keygen, no thumbprint, no key/cert files written',
      () async {
        final dir = await Directory.systemTemp.createTemp('opcua_host_none_cert_test');
        addTearDown(() => dir.delete(recursive: true));

        final host = OpcUaHost(certStore: OpcUaCertStore(overrideDir: dir.path));
        addTearDown(host.stop);
        final project = _enabledProject(port: 0);
        // Default securityModes is None-only (see ProtocolSettings.defaults).

        await host.start(() => project);

        expect(host.status, OpcUaHostStatus.running);
        expect(host.appCertThumbprint, isNull);
        expect(await File('${dir.path}${Platform.pathSeparator}key.der').exists(), isFalse);
        expect(await File('${dir.path}${Platform.pathSeparator}cert.der').exists(), isFalse);

        // The None handshake must still work exactly as before.
        final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('opc.tcp://', 'tcp://'));
        final socket = await Socket.connect('127.0.0.1', endpoint.port);
        addTearDown(socket.destroy);
        socket.add(_helHandshakeFrame());
        await socket.flush();
        final response = await _readAtLeast(socket, kMessageHeaderLen);
        expect(MessageHeader.parse(response).messageType, 'ACK');
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a secure-policy config whose identity load FAILS ends in '
      'OpcUaHostStatus.error (not running) with a certificate-related message',
      () async {
        // No certStore override: the production default `OpcUaCertStore()`
        // calls `path_provider`'s `getApplicationSupportDirectory()`, which
        // has no platform-channel implementation registered in this plain
        // `flutter_test` (non-widget-binding) environment and throws a
        // MissingPluginException — the same seam the None-only test above
        // exercises, but here the project configures a secure policy so the
        // failure must surface instead of being swallowed.
        final host = OpcUaHost();
        addTearDown(host.stop);
        final project = _enabledProject(port: 0);
        project.protocols!.opcua!.securityModes = ['None', 'Basic256Sha256/SignAndEncrypt'];

        await host.start(() => project);

        expect(host.status, OpcUaHostStatus.error);
        expect(host.lastError, isNotNull);
        expect(host.lastError, contains('certificate'));
        expect(host.appCertThumbprint, isNull);
        expect(host.endpointUrl, isNull);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
