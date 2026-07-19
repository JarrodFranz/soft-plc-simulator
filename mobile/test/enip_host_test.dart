// Tests for the dart:io EtherNet/IP + CIP explicit-messaging socket host
// (mobile/lib/services/enip_host.dart). Uses REAL sockets bound to an
// ephemeral loopback port (port 0) — mirrors modbus_host_test.dart's and
// opcua_host_test.dart's pattern. Every test is bounded so a stalled
// server/socket can never hang the suite.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/cip_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_connection.dart';
import 'package:soft_plc_mobile/protocols/enip/enip_encap.dart';
import 'package:soft_plc_mobile/services/enip_host.dart';

PlcProject _enabledProject({int port = 0}) {
  final project = PlcProject(
    id: 'proj_enip_host_test',
    name: 'EtherNet/IP Host Test',
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
  project.protocols!.ethernetIp = CipProtocolConfig(
    enabled: true,
    port: port,
    map: CipMap(entries: [CipMapEntry(tagName: 'Speed', access: 'ReadWrite')]),
  );
  return project;
}

/// Accumulates every byte a [Socket] ever emits behind ONE persistent
/// `listen()` call. A raw `Socket` is a single-subscription stream that
/// cannot be listened to more than once (even after a previous listener
/// cancels) — several of this file's tests read a socket's response more
/// than once (e.g. the RegisterSession reply, then later the SendRRData
/// reply, on the SAME connection), so a one-shot `socket.timeout(...)` +
/// `await for` helper (as `modbus_host_test.dart`/`opcua_host_test.dart` use,
/// where each test only ever reads a socket once) cannot be reused here.
class _SocketCollector {
  final List<int> received = [];
  final List<_ByteWaiter> _waiters = [];
  late final StreamSubscription<Uint8List> _sub;

  _SocketCollector(Socket socket) {
    _sub = socket.listen((data) {
      received.addAll(data);
      _waiters.removeWhere((w) {
        if (received.length >= w.target) {
          if (!w.completer.isCompleted) {
            w.completer.complete();
          }
          return true;
        }
        return false;
      });
    });
  }

  /// Waits until at least [n] bytes have been received in total (across the
  /// whole connection's lifetime, not just since the last call), bounded by
  /// [timeout], then returns exactly the first [n] bytes.
  Future<Uint8List> readAtLeast(int n, {Duration timeout = const Duration(seconds: 5)}) async {
    if (received.length < n) {
      final completer = Completer<void>();
      _waiters.add(_ByteWaiter(n, completer));
      await completer.future.timeout(timeout);
    }
    return Uint8List.fromList(received.sublist(0, n));
  }

  Future<void> cancel() => _sub.cancel();
}

class _ByteWaiter {
  final int target;
  final Completer<void> completer;
  _ByteWaiter(this.target, this.completer);
}

Uint8List _senderContext(int seed) => Uint8List.fromList(List.generate(8, (i) => (seed + i) & 0xFF));

/// Builds a `RegisterSession` (0x65) request frame: protocol version u16=1,
/// options u16=0, per public EtherNet/IP encapsulation specification
/// material. `sessionHandle` on a *request* is conventionally 0 (unassigned
/// until the server allocates one).
Uint8List _registerSessionFrame({Uint8List? senderContext}) {
  final data = Uint8List(4); // protocolVersion=1 (LE), options=0
  data[0] = 0x01;
  final header = EnipHeader(
    command: kEnipCommandRegisterSession,
    length: 0,
    sessionHandle: 0,
    status: 0,
    senderContext: senderContext ?? _senderContext(1),
    options: 0,
  );
  return buildEnipFrame(header, data);
}

/// Builds the raw CIP Read Tag (0x4C) request bytes for a bare symbolic
/// [tagName]: `service` u8, `pathWords` u8, EPATH bytes, element count u16=1.
Uint8List _readTagCipRequest(String tagName) {
  final epath = buildEpath([CipPathSegment.symbol(tagName)]);
  final out = Uint8List(2 + epath.length + 2);
  out[0] = kCipServiceReadTag;
  out[1] = epath.length ~/ 2;
  out.setRange(2, 2 + epath.length, epath);
  ByteData.sublistView(out, 2 + epath.length).setUint16(0, 1, Endian.little); // element count
  return out;
}

/// Builds a `SendRRData` (0x6F) request frame wrapping [cipRequest] as an
/// Unconnected Data CPF item, per public EtherNet/IP encapsulation
/// specification material (Interface Handle u32=0 + Timeout u16=0 precede
/// the CPF item list).
Uint8List _sendRRDataFrame({
  required int sessionHandle,
  required Uint8List cipRequest,
  Uint8List? senderContext,
}) {
  final cpf = buildCpf([
    CpfItem(typeId: kCpfTypeNullAddress, data: Uint8List(0)),
    CpfItem(typeId: kCpfTypeUnconnectedData, data: cipRequest),
  ]);
  final data = Uint8List(6 + cpf.length);
  data.setRange(6, data.length, cpf);
  final header = EnipHeader(
    command: kEnipCommandSendRRData,
    length: 0,
    sessionHandle: sessionHandle,
    status: 0,
    senderContext: senderContext ?? _senderContext(2),
    options: 0,
  );
  return buildEnipFrame(header, data);
}

const List<int> _kConnMgrPath = [0x20, 0x06, 0x24, 0x01]; // Connection Manager, class 6 / instance 1.

/// Builds the raw wire bytes (service + EPATH + service data) of a Forward
/// Open (0x54) CIP request to the Connection Manager object, per public CIP
/// specification material — mirrors `cip_connection_test.dart`'s
/// `_buildForwardOpenData`, but as the on-wire request bytes `SendRRData`
/// actually carries, rather than a pre-parsed `CipRequest`.
Uint8List _forwardOpenCipRequest({
  required int connIdTO,
  required int connectionSerial,
  required int vendorId,
  required int originatorSerial,
}) {
  final serviceData = <int>[
    0x0A, // priority/time tick
    0x0E, // timeout ticks
    // O->T connection id: a PLACEHOLDER only. The target consumes O->T
    // data, so the TARGET allocates this direction's id and returns it in
    // the reply; a real client (pycomm3) sends zeros here.
    0, 0, 0, 0,
    // T->O connection id: allocated by the ORIGINATOR, echoed back unchanged.
    ...(ByteData(4)..setUint32(0, connIdTO, Endian.little)).buffer.asUint8List(),
    ...(ByteData(2)..setUint16(0, connectionSerial, Endian.little)).buffer.asUint8List(),
    ...(ByteData(2)..setUint16(0, vendorId, Endian.little)).buffer.asUint8List(),
    ...(ByteData(4)..setUint32(0, originatorSerial, Endian.little)).buffer.asUint8List(),
    0x03, // connection timeout multiplier
    0x00, 0x00, 0x00, // reserved
    ...(ByteData(4)..setUint32(0, 10000, Endian.little)).buffer.asUint8List(), // O->T RPI
    0x02, 0x43, // O->T connection params
    ...(ByteData(4)..setUint32(0, 20000, Endian.little)).buffer.asUint8List(), // T->O RPI
    0x02, 0x43, // T->O connection params
    0xA3, // transport type/trigger
    _kConnMgrPath.length ~/ 2, // connection path size, in words
    ..._kConnMgrPath,
  ];
  final out = Uint8List(2 + _kConnMgrPath.length + serviceData.length);
  out[0] = kCipServiceForwardOpen;
  out[1] = _kConnMgrPath.length ~/ 2;
  out.setRange(2, 2 + _kConnMgrPath.length, _kConnMgrPath);
  out.setRange(2 + _kConnMgrPath.length, out.length, serviceData);
  return out;
}

/// Builds a `SendUnitData` (0x70) request frame carrying [cipRequest] as
/// connected data addressed to [connectionId], per public EtherNet/IP
/// encapsulation specification material: Interface Handle u32=0 + Timeout
/// u16=0, then a CPF item list of a Connected Address item (the connection
/// id) and a Connected Data item (sequence count u16 + the CIP request).
Uint8List _sendUnitDataFrame({
  required int sessionHandle,
  required int connectionId,
  required Uint8List cipRequest,
  int seq = 1,
}) {
  final addrData = Uint8List(4);
  ByteData.sublistView(addrData).setUint32(0, connectionId, Endian.little);
  final connectedData = Uint8List(2 + cipRequest.length);
  ByteData.sublistView(connectedData, 0, 2).setUint16(0, seq, Endian.little);
  connectedData.setRange(2, connectedData.length, cipRequest);
  final cpf = buildCpf([
    CpfItem(typeId: kCpfTypeConnectedAddress, data: addrData),
    CpfItem(typeId: kCpfTypeConnectedData, data: connectedData),
  ]);
  final data = Uint8List(6 + cpf.length);
  data.setRange(6, data.length, cpf);
  final header = EnipHeader(
    command: kEnipCommandSendUnitData,
    length: 0,
    sessionHandle: sessionHandle,
    status: 0,
    senderContext: _senderContext(3),
    options: 0,
  );
  return buildEnipFrame(header, data);
}

void main() {
  group('EnipHost — start/stop lifecycle', () {
    test('start on a disabled project moves to error status, binds nothing', () async {
      final host = EnipHost();
      final project = _enabledProject();
      project.protocols!.ethernetIp!.enabled = false;

      await host.start(() => project);

      expect(host.status, EnipHostStatus.error);
      expect(host.lastError, isNotNull);
      expect(host.endpointUrl, isNull);

      await host.stop();
    });

    test('start when protocols.ethernetIp is null moves to error status', () async {
      final host = EnipHost();
      final project = _enabledProject();
      project.protocols!.ethernetIp = null;

      await host.start(() => project);

      expect(host.status, EnipHostStatus.error);
      expect(host.lastError, isNotNull);

      await host.stop();
    });

    test('start on an enabled project (port 0) binds an ephemeral port and reports running', () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);

      await host.start(() => project);

      expect(host.status, EnipHostStatus.running);
      expect(host.endpointUrl, isNotNull);
      expect(host.endpointUrl, contains('enip-tcp://'));
      expect(host.clientCount, 0);

      await host.stop();
      expect(host.status, EnipHostStatus.stopped);
      expect(host.endpointUrl, isNull);
    });

    test('stop is safe to call when never started', () async {
      final host = EnipHost();
      await host.stop();
      expect(host.status, EnipHostStatus.stopped);
    });

    test('stop then start again works (restart lifecycle)', () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);

      await host.start(() => project);
      expect(host.status, EnipHostStatus.running);

      await host.stop();
      expect(host.status, EnipHostStatus.stopped);

      await host.start(() => project);
      expect(host.status, EnipHostStatus.running);
      expect(host.endpointUrl, isNotNull);

      await host.stop();
    });
  });

  group('EnipHost — RegisterSession', () {
    test('RegisterSession returns a (deterministic, non-zero) session handle', () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('enip-tcp://', 'tcp://'));
      final socket = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socket.destroy);

      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);
      final ctx = _senderContext(42);
      socket.add(_registerSessionFrame(senderContext: ctx));
      await socket.flush();

      final response = await rx.readAtLeast(kEnipHeaderLen);
      final header = parseEnipHeader(response);
      expect(header, isNotNull);
      expect(header!.command, kEnipCommandRegisterSession);
      expect(header.status, 0);
      expect(header.sessionHandle, isNonZero);
      expect(header.sessionHandle, 1); // first connection on a fresh host: deterministic
      expect(header.senderContext, ctx);
    });
  });

  group('EnipHost — unconnected Read Tag over SendRRData', () {
    test("an unconnected Read Tag over SendRRData returns the tag's value", () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('enip-tcp://', 'tcp://'));
      final socket = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      socket.add(_registerSessionFrame());
      await socket.flush();
      final regResponse = await rx.readAtLeast(kEnipHeaderLen + 4);
      final sessionHandle = parseEnipHeader(regResponse)!.sessionHandle;

      socket.add(_sendRRDataFrame(
        sessionHandle: sessionHandle,
        cipRequest: _readTagCipRequest('Speed'),
      ));
      await socket.flush();

      // header(24) + interfaceHandle(4) + timeout(2) + cpf(count(2) +
      // nullAddrItem(4+0) + unconnectedDataItem header(4) + cip reply
      // (4 header + 2 typeCode + 2 INT value = 8)) = 24+6+2+4+4+8 = 48.
      // Cumulative total across the connection: the RegisterSession reply
      // (28 bytes) plus this SendRRData reply (48 bytes) = 76.
      const registerReplyLen = kEnipHeaderLen + 4;
      final full = await rx.readAtLeast(registerReplyLen + 48);
      final response = Uint8List.sublistView(full, registerReplyLen);
      final header = parseEnipHeader(response);
      expect(header, isNotNull);
      expect(header!.command, kEnipCommandSendRRData);
      expect(header.status, 0);

      final data = Uint8List.sublistView(response, kEnipHeaderLen);
      final items = parseCpf(Uint8List.sublistView(data, 6));
      expect(items, isNotNull);
      final unconnected = items!.firstWhere((i) => i.typeId == kCpfTypeUnconnectedData);
      final cipReply = unconnected.data;
      // service|0x80, reserved, generalStatus, reserved, typeCode(u16 LE), value.
      expect(cipReply[0], kCipServiceReadTag | 0x80);
      expect(cipReply[2], kCipStatusSuccess);
      final typeCode = ByteData.sublistView(cipReply, 4, 6).getUint16(0, Endian.little);
      expect(typeCode, kCipTypeInt);
      final value = ByteData.sublistView(cipReply, 6, 8).getInt16(0, Endian.little);
      expect(value, 1234);
    });
  });

  group('EnipHost — reassembly', () {
    test('a frame split mid-header reassembles into exactly one correct reply', () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('enip-tcp://', 'tcp://'));
      final socket = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      final frame = _registerSessionFrame();
      const splitAt = 10; // mid-header (header is 24 bytes)
      socket.add(frame.sublist(0, splitAt));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.add(frame.sublist(splitAt));
      await socket.flush();

      final response = await rx.readAtLeast(kEnipHeaderLen + 4);
      final header = parseEnipHeader(response);
      expect(header, isNotNull);
      expect(header!.command, kEnipCommandRegisterSession);
      expect(header.status, 0);
      // Give any stray extra bytes a chance to arrive, then confirm exactly
      // one reply was ever sent — no double-reply from a reassembly bug.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rx.received.length, kEnipHeaderLen + 4);
    });

    test('a frame split mid-body reassembles into exactly one correct reply', () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('enip-tcp://', 'tcp://'));
      final socket = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      socket.add(_registerSessionFrame());
      await socket.flush();
      const registerReplyLen = kEnipHeaderLen + 4;
      final regResponse = await rx.readAtLeast(registerReplyLen);
      final sessionHandle = parseEnipHeader(regResponse)!.sessionHandle;

      final frame = _sendRRDataFrame(
        sessionHandle: sessionHandle,
        cipRequest: _readTagCipRequest('Speed'),
      );
      // Split partway through the body (well past the 24-byte header).
      const splitAt = kEnipHeaderLen + 8;
      socket.add(frame.sublist(0, splitAt));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.add(frame.sublist(splitAt));
      await socket.flush();

      final full = await rx.readAtLeast(registerReplyLen + 48);
      final response = Uint8List.sublistView(full, registerReplyLen);
      final header = parseEnipHeader(response);
      expect(header, isNotNull);
      expect(header!.command, kEnipCommandSendRRData);
      expect(header.status, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rx.received.length, registerReplyLen + 48);
    });
  });

  group('EnipHost — coalesced frames', () {
    test('two coalesced frames in one chunk both get answered, in order', () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('enip-tcp://', 'tcp://'));
      final socket = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      final ctxA = _senderContext(10);
      final ctxB = _senderContext(20);
      final frameA = _registerSessionFrame(senderContext: ctxA);
      final frameB = _registerSessionFrame(senderContext: ctxB);
      socket.add(Uint8List.fromList([...frameA, ...frameB]));
      await socket.flush();

      // Two RegisterSession replies of (24 + 4) bytes each = 56 bytes total.
      final response = await rx.readAtLeast(56);
      final first = parseEnipHeader(response.sublist(0, 28));
      final second = parseEnipHeader(response.sublist(28, 56));
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(first!.senderContext, ctxA);
      expect(second!.senderContext, ctxB);
      // Two distinct RegisterSession calls on ONE socket: the second
      // overwrites this connection's registered handle, but each reply
      // still carries its own freshly-allocated (monotonically increasing)
      // handle.
      expect(second.sessionHandle, greaterThan(first.sessionHandle));
    });
  });

  group('EnipHost — re-registering a session releases its prior CIP connections', () {
    test(
        'a second RegisterSession on the same socket releases connections opened under the '
        'first session; SendUnitData referencing the old connection id is refused, not crashed',
        () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('enip-tcp://', 'tcp://'));
      final socket = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      // 1) Register the first session.
      const registerReplyLen = kEnipHeaderLen + 4;
      socket.add(_registerSessionFrame());
      await socket.flush();
      var offset = registerReplyLen;
      final firstSessionHandle = parseEnipHeader(await rx.readAtLeast(offset))!.sessionHandle;

      // 2) Forward Open a connection under the first session.
      final forwardOpenReq = _forwardOpenCipRequest(
        connIdTO: 0x1111,
        connectionSerial: 0x2222,
        vendorId: 0x3333,
        originatorSerial: 0x44444444,
      );
      socket.add(_sendRRDataFrame(sessionHandle: firstSessionHandle, cipRequest: forwardOpenReq));
      await socket.flush();

      // Forward Open reply body: header(24) + interfaceHandle(4) + timeout(2)
      // + cpf(count(2) + nullAddrItem(4+0) + unconnectedDataItem header(4) +
      // cip reply (4-byte CIP header + 26-byte Forward Open reply data = 30))
      // = 24 + 6 + 2 + 4 + 4 + 30 = 70.
      const forwardOpenReplyLen = kEnipHeaderLen + 6 + 2 + 4 + 4 + 30;
      offset += forwardOpenReplyLen;
      final foFull = await rx.readAtLeast(offset);
      final foResponse = Uint8List.sublistView(foFull, offset - forwardOpenReplyLen);
      final foHeader = parseEnipHeader(foResponse);
      expect(foHeader, isNotNull);
      expect(foHeader!.status, 0);
      final foData = Uint8List.sublistView(foResponse, kEnipHeaderLen);
      final foItems = parseCpf(Uint8List.sublistView(foData, 6));
      expect(foItems, isNotNull);
      final foUnconnected = foItems!.firstWhere((i) => i.typeId == kCpfTypeUnconnectedData);
      final foCipReply = foUnconnected.data;
      expect(foCipReply[0], kCipServiceForwardOpen | 0x80);
      expect(foCipReply[2], kCipStatusSuccess);
      // Byte layout of the Forward Open reply data (see cip_connection.dart):
      // the TARGET-ALLOCATED O->T connection id — the one a connected
      // message (`SendUnitData`) is addressed to, and the one
      // `byConnectionId` resolves — is at data[0:4]; the echoed T->O id is
      // at data[4:8]. Both are offset by the 4-byte CIP response header this
      // codec prepends.
      final oldConnectionId = ByteData.sublistView(foCipReply, 4, 8).getUint32(0, Endian.little);
      expect(oldConnectionId, kInitialTargetConnectionId);

      // 3) Register a SECOND session on the SAME socket — this must release
      // the connection opened in step 2.
      socket.add(_registerSessionFrame(senderContext: _senderContext(99)));
      await socket.flush();
      offset += registerReplyLen;
      final secondFull = await rx.readAtLeast(offset);
      final secondHeader = parseEnipHeader(Uint8List.sublistView(secondFull, offset - registerReplyLen));
      expect(secondHeader, isNotNull);
      final secondSessionHandle = secondHeader!.sessionHandle;
      expect(secondSessionHandle, greaterThan(firstSessionHandle));

      // 4) SendUnitData under the NEW session referencing the OLD connection
      // id must be refused (not served, not a crash) — the connection was
      // released when the second RegisterSession overwrote the first.
      socket.add(_sendUnitDataFrame(
        sessionHandle: secondSessionHandle,
        connectionId: oldConnectionId,
        cipRequest: _readTagCipRequest('Speed'),
      ));
      await socket.flush();
      offset += kEnipHeaderLen; // error reply carries no data payload.
      final finalFull = await rx.readAtLeast(offset);
      final finalHeader = parseEnipHeader(Uint8List.sublistView(finalFull, offset - kEnipHeaderLen));
      expect(finalHeader, isNotNull);
      expect(finalHeader!.command, kEnipCommandSendUnitData);
      expect(finalHeader.status, isNonZero);

      // The host itself must not have crashed handling any of the above.
      expect(host.status, EnipHostStatus.running);
    });
  });

  group('EnipHost — unregistered session handle', () {
    test('a request bearing an unregistered session handle gets an error status, not a crash',
        () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('enip-tcp://', 'tcp://'));
      final socket = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      // Never registered a session on this socket — 12345 is a foreign,
      // never-allocated handle.
      socket.add(_sendRRDataFrame(sessionHandle: 12345, cipRequest: _readTagCipRequest('Speed')));
      await socket.flush();

      final response = await rx.readAtLeast(kEnipHeaderLen);
      final header = parseEnipHeader(response);
      expect(header, isNotNull);
      expect(header!.command, kEnipCommandSendRRData);
      expect(header.status, isNonZero);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rx.received.length, kEnipHeaderLen); // no data payload on this error reply

      // The host itself must not have crashed — still running and able to
      // serve a subsequent, well-formed request on a fresh connection.
      expect(host.status, EnipHostStatus.running);
      final socket2 = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socket2.destroy);
      final rx2 = _SocketCollector(socket2);
      addTearDown(rx2.cancel);
      socket2.add(_registerSessionFrame());
      await socket2.flush();
      final reg2 = await rx2.readAtLeast(kEnipHeaderLen);
      expect(parseEnipHeader(reg2)!.status, 0);
    });
  });

  group('EnipHost — isolated sessions across sockets', () {
    test('two sockets get isolated, non-colliding session handles', () async {
      final host = EnipHost();
      final project = _enabledProject(port: 0);
      await host.start(() => project);
      addTearDown(host.stop);

      final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('enip-tcp://', 'tcp://'));
      final socketA = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socketA.destroy);
      final rxA = _SocketCollector(socketA);
      addTearDown(rxA.cancel);
      final socketB = await Socket.connect('127.0.0.1', endpoint.port);
      addTearDown(socketB.destroy);
      final rxB = _SocketCollector(socketB);
      addTearDown(rxB.cancel);

      socketA.add(_registerSessionFrame());
      await socketA.flush();
      const registerReplyLen = kEnipHeaderLen + 4;
      final handleA = parseEnipHeader(await rxA.readAtLeast(registerReplyLen))!.sessionHandle;

      socketB.add(_registerSessionFrame());
      await socketB.flush();
      final handleB = parseEnipHeader(await rxB.readAtLeast(registerReplyLen))!.sessionHandle;

      expect(handleA, isNot(equals(handleB)));
      expect(host.clientCount, 2);

      // Socket B's handle is foreign to socket A's connection — using it
      // there must be refused, not silently accepted cross-connection.
      socketA.add(_sendRRDataFrame(sessionHandle: handleB, cipRequest: _readTagCipRequest('Speed')));
      await socketA.flush();
      final crossResponse =
          Uint8List.sublistView(await rxA.readAtLeast(registerReplyLen + kEnipHeaderLen), registerReplyLen);
      expect(parseEnipHeader(crossResponse)!.status, isNonZero);

      // Meanwhile socket B's own (correctly-scoped) request still works.
      socketB.add(_sendRRDataFrame(sessionHandle: handleB, cipRequest: _readTagCipRequest('Speed')));
      await socketB.flush();
      final okResponse =
          Uint8List.sublistView(await rxB.readAtLeast(registerReplyLen + 48), registerReplyLen);
      expect(parseEnipHeader(okResponse)!.status, 0);
    });
  });
}
