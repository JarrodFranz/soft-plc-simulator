// Tests for the dart:io S7comm socket host (mobile/lib/services/s7_host.dart).
// Uses REAL sockets bound to an ephemeral loopback port (port 0) — mirrors
// enip_host_test.dart's pattern. Every test is bounded so a stalled
// server/socket can never hang the suite.
//
// SCOPE: at this task the host serves COTP Connection Request -> Connection
// Confirm and S7 Setup Communication -> its reply, and nothing else. Read Var
// / Write Var arrive in Task 4.
//
// These tests prove the host's REASSEMBLY and DISPATCH behaviour. They cannot
// prove wire conformance — every frame here is one this project built — which
// is exactly why `tool/s7_e2e.sh` drives a real third-party client
// (`python-snap7`) against the same logic at this same task.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/s7/s7_pdu.dart';
import 'package:soft_plc_mobile/protocols/s7/tpkt_cotp.dart';
import 'package:soft_plc_mobile/services/s7_host.dart';

/// Accumulates every byte a [Socket] ever emits behind ONE persistent
/// `listen()` call. A raw `Socket` is a single-subscription stream that cannot
/// be listened to more than once, and several tests here read a socket's
/// response more than once (the CC, then later the Setup Communication reply,
/// on the SAME connection). Mirrors `enip_host_test.dart`'s collector.
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
    }, onError: (Object _, StackTrace __) {}, cancelOnError: false);
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

// --- Expected on-wire reply sizes -------------------------------------------
//
// Asserted as EXACT totals after a settle in the reassembly/coalescing tests,
// so a double-dispatch bug (which would produce a correct-looking first reply
// followed by a second one) cannot pass.

/// A Connection Confirm: TPKT(4) + COTP header — LI(1) + type(1) + dstRef(2)
/// + srcRef(2) + class(1) + two 4-byte TSAP parameters(8) = 15 — so 19 bytes.
const int _kCcReplyLen = 19;

/// A Setup Communication reply: TPKT(4) + COTP DT header(3) + S7 Ack_Data
/// header(12) + Setup Communication parameter(8) = 27 bytes.
const int _kSetupReplyLen = 27;

/// Builds a COTP Connection Request TPKT frame exactly as a client sends one:
/// LI, type 0xE0, dstRef u16 (0 — the server has not assigned one yet), srcRef
/// u16 (the client's own reference), class/option, then the source-TSAP
/// (0xC1) and destination-TSAP (0xC2) parameters, each 2 bytes BIG-ENDIAN.
Uint8List _connectRequestFrame({
  int srcRef = 0x0004,
  int srcTsap = 0x0100,
  int dstTsap = 0x0102, // rack 0 / slot 2, in the conventional encoding
}) {
  final params = <int>[
    kCotpParamSrcTsap, 0x02, (srcTsap >> 8) & 0xFF, srcTsap & 0xFF,
    kCotpParamDstTsap, 0x02, (dstTsap >> 8) & 0xFF, dstTsap & 0xFF,
  ];
  const fixedFieldsLen = 1 + 2 + 2 + 1; // type + dstRef + srcRef + class/option
  final li = fixedFieldsLen + params.length;
  final cotp = Uint8List(1 + li);
  cotp[0] = li;
  cotp[1] = kCotpCr;
  ByteData.sublistView(cotp, 2, 4).setUint16(0, 0x0000, Endian.big); // dstRef
  ByteData.sublistView(cotp, 4, 6).setUint16(0, srcRef, Endian.big);
  cotp[6] = 0x00; // class 0
  cotp.setRange(7, 7 + params.length, params);
  return buildTpkt(cotp);
}

/// Builds a Setup Communication job TPKT frame as a client sends one: an S7
/// Job (10-byte header) whose 8-byte parameter is
/// `0xF0, reserved, maxAmqCalling, maxAmqCalled, pduLength` (all multi-byte
/// fields BIG-ENDIAN), carried in a COTP data TPDU.
Uint8List _setupCommunicationFrame({
  int pduReference = 0x0100,
  int maxAmqCalling = 1,
  int maxAmqCalled = 1,
  int pduLength = 960, // deliberately ABOVE this device's maximum
}) {
  final parameter = Uint8List(8);
  parameter[0] = kS7FunctionSetupCommunication;
  parameter[1] = 0x00;
  ByteData.sublistView(parameter, 2, 4).setUint16(0, maxAmqCalling, Endian.big);
  ByteData.sublistView(parameter, 4, 6).setUint16(0, maxAmqCalled, Endian.big);
  ByteData.sublistView(parameter, 6, 8).setUint16(0, pduLength, Endian.big);
  final s7 = buildS7(
    rosctr: kS7RosctrJob,
    pduReference: pduReference,
    parameter: parameter,
  );
  return buildTpkt(buildCotpData(s7));
}

/// Connects a client socket to [host]'s bound port.
Future<Socket> _connect(S7Host host) async {
  final endpoint = Uri.parse(host.endpointUrl!.replaceFirst('s7-tcp://', 'tcp://'));
  return Socket.connect('127.0.0.1', endpoint.port);
}

void main() {
  group('S7Host — start/stop lifecycle', () {
    test('start on port 0 binds an ephemeral port and reports running', () async {
      final host = S7Host();
      await host.start(port: 0);

      expect(host.status, S7HostStatus.running);
      expect(host.endpointUrl, isNotNull);
      expect(host.endpointUrl, contains('s7-tcp://'));
      expect(host.clientCount, 0);

      await host.stop();
      expect(host.status, S7HostStatus.stopped);
      expect(host.endpointUrl, isNull);
    });

    test('stop is safe to call when never started', () async {
      final host = S7Host();
      await host.stop();
      expect(host.status, S7HostStatus.stopped);
    });

    test('stop then start again works (restart lifecycle)', () async {
      final host = S7Host();
      await host.start(port: 0);
      expect(host.status, S7HostStatus.running);

      await host.stop();
      expect(host.status, S7HostStatus.stopped);

      await host.start(port: 0);
      expect(host.status, S7HostStatus.running);
      expect(host.endpointUrl, isNotNull);

      await host.stop();
    });
  });

  group('S7Host — COTP connect', () {
    test('a Connection Request is answered with a Connection Confirm echoing the TSAPs', () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      socket.add(_connectRequestFrame(srcRef: 0x0004, srcTsap: 0x0100, dstTsap: 0x0102));
      await socket.flush();

      final reply = await rx.readAtLeast(_kCcReplyLen);
      final tpkt = parseTpkt(reply);
      expect(tpkt, isNotNull);
      expect(tpkt!.version, kTpktVersion);
      // The TPKT length counts the WHOLE packet, its own 4-byte header
      // included — the exact inverse of EtherNet/IP's encapsulation length.
      expect(tpkt.length, _kCcReplyLen);

      final cotp = parseCotp(Uint8List.sublistView(reply, kTpktHeaderLen));
      expect(cotp, isNotNull);
      expect(cotp!.pduType, kCotpCc);
      // The confirm's DESTINATION reference is the reference the CLIENT chose.
      expect(cotp.dstRef, 0x0004);
      expect(cotp.srcRef, isNonZero);
      // Rack/slot are accepted permissively and the client's TSAPs echoed back.
      expect(cotp.srcTsap, 0x0100);
      expect(cotp.dstTsap, 0x0102);
    });

    test('an unusual rack/slot in the destination TSAP is still accepted (permissive simulator)',
        () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      socket.add(_connectRequestFrame(dstTsap: 0x0307)); // rack 3 / slot 7
      await socket.flush();

      final reply = await rx.readAtLeast(_kCcReplyLen);
      final cotp = parseCotp(Uint8List.sublistView(reply, kTpktHeaderLen));
      expect(cotp, isNotNull);
      expect(cotp!.pduType, kCotpCc);
      expect(cotp.dstTsap, 0x0307);
    });
  });

  group('S7Host — Setup Communication', () {
    test('a Setup Communication job is answered with a negotiated PDU size at or below our maximum',
        () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      socket.add(_connectRequestFrame());
      await socket.flush();
      await rx.readAtLeast(_kCcReplyLen);

      // Proposes 960, which is above this device's maximum: the reply must
      // negotiate DOWN, never up.
      socket.add(_setupCommunicationFrame(pduReference: 0x0100, pduLength: 960));
      await socket.flush();

      final full = await rx.readAtLeast(_kCcReplyLen + _kSetupReplyLen);
      final reply = Uint8List.sublistView(full, _kCcReplyLen);

      final tpkt = parseTpkt(reply);
      expect(tpkt, isNotNull);
      expect(tpkt!.length, _kSetupReplyLen);

      final cotp = parseCotp(Uint8List.sublistView(reply, kTpktHeaderLen));
      expect(cotp, isNotNull);
      expect(cotp!.pduType, kCotpDt);

      final s7 = parseS7(cotp.payload);
      expect(s7, isNotNull);
      expect(s7!.header.rosctr, kS7RosctrAckData);
      expect(s7.header.pduReference, 0x0100); // echoed back
      expect(s7.header.errorClass, 0);
      expect(s7.header.errorCode, 0);

      final setup = parseSetupCommunication(s7.parameter);
      expect(setup, isNotNull);
      expect(setup!.function, kS7FunctionSetupCommunication);
      expect(setup.pduLength, lessThanOrEqualTo(kS7MaxPduLength));
      expect(setup.pduLength, kS7MaxPduLength); // clamped down from 960
      expect(setup.maxAmqCalling, 1); // negotiated down from the proposal
      expect(setup.maxAmqCalled, 1);
    });

    test('a Setup Communication arriving BEFORE the COTP connect is confirmed gets no reply',
        () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      socket.add(_setupCommunicationFrame());
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(rx.received, isEmpty);
      expect(host.status, S7HostStatus.running);
    });
  });

  group('S7Host — reassembly', () {
    test('a Connection Request split mid-TPKT-header reassembles into exactly one reply', () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      final frame = _connectRequestFrame();
      const splitAt = 2; // mid-TPKT-header: the length field is bytes 2-3
      socket.add(frame.sublist(0, splitAt));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.add(frame.sublist(splitAt));
      await socket.flush();

      final reply = await rx.readAtLeast(_kCcReplyLen);
      final cotp = parseCotp(Uint8List.sublistView(reply, kTpktHeaderLen));
      expect(cotp, isNotNull);
      expect(cotp!.pduType, kCotpCc);

      // Settle, then confirm EXACTLY one reply was ever sent — no
      // double-dispatch from a reassembly bug.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rx.received.length, _kCcReplyLen);
    });

    test('a Setup Communication split mid-body reassembles into exactly one reply', () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      socket.add(_connectRequestFrame());
      await socket.flush();
      await rx.readAtLeast(_kCcReplyLen);

      final frame = _setupCommunicationFrame();
      // Split partway through the body, well past the 4-byte TPKT header.
      const splitAt = kTpktHeaderLen + 9;
      socket.add(frame.sublist(0, splitAt));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.add(frame.sublist(splitAt));
      await socket.flush();

      final full = await rx.readAtLeast(_kCcReplyLen + _kSetupReplyLen);
      final reply = Uint8List.sublistView(full, _kCcReplyLen);
      final cotp = parseCotp(Uint8List.sublistView(reply, kTpktHeaderLen));
      expect(cotp, isNotNull);
      expect(cotp!.pduType, kCotpDt);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rx.received.length, _kCcReplyLen + _kSetupReplyLen);
    });
  });

  group('S7Host — coalesced frames', () {
    test('a Connection Request and a Setup Communication coalesced in one chunk are both answered',
        () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      final cr = _connectRequestFrame();
      final setup = _setupCommunicationFrame(pduReference: 0x0abc);
      socket.add(Uint8List.fromList([...cr, ...setup]));
      await socket.flush();

      const totalLen = _kCcReplyLen + _kSetupReplyLen;
      final full = await rx.readAtLeast(totalLen);

      final ccCotp = parseCotp(Uint8List.sublistView(full, kTpktHeaderLen, _kCcReplyLen));
      expect(ccCotp, isNotNull);
      expect(ccCotp!.pduType, kCotpCc);

      final setupReply = Uint8List.sublistView(full, _kCcReplyLen, totalLen);
      final setupCotp = parseCotp(Uint8List.sublistView(setupReply, kTpktHeaderLen));
      expect(setupCotp, isNotNull);
      expect(setupCotp!.pduType, kCotpDt);
      final s7 = parseS7(setupCotp.payload);
      expect(s7, isNotNull);
      expect(s7!.header.pduReference, 0x0abc);

      // EXACT total after a settle: a double-dispatch bug would append a
      // third reply here and this assertion is what catches it.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rx.received.length, totalLen);
    });
  });

  group('S7Host — hostile input', () {
    test('garbage bytes do not crash the host and leave it serving new connections', () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      // Not a TPKT frame at all: a plausible-looking length whose payload is
      // meaningless, then trailing noise.
      socket.add(Uint8List.fromList([0xFF, 0xEE, 0x00, 0x0C, 1, 2, 3, 4, 5, 6, 7, 8, 0x99, 0x88]));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(host.status, S7HostStatus.running);

      // A fresh, well-formed connection is still served.
      final socket2 = await _connect(host);
      addTearDown(socket2.destroy);
      final rx2 = _SocketCollector(socket2);
      addTearDown(rx2.cancel);
      socket2.add(_connectRequestFrame());
      await socket2.flush();
      final reply = await rx2.readAtLeast(_kCcReplyLen);
      expect(parseCotp(Uint8List.sublistView(reply, kTpktHeaderLen))!.pduType, kCotpCc);
    });

    test('a hostile TPKT length below the header size is rejected without hanging the host',
        () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socket = await _connect(host);
      addTearDown(socket.destroy);
      final rx = _SocketCollector(socket);
      addTearDown(rx.cancel);

      // Declared length 0: consuming `length` bytes per iteration would make
      // the reassembly loop spin forever without forward progress. The host
      // must reject it and close only this connection.
      socket.add(Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0xAA, 0xBB]));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(host.status, S7HostStatus.running);
      expect(rx.received, isEmpty);

      // Same for a declared length of 1 (below kTpktHeaderLen) on a fresh
      // connection, and the host still serves a well-formed client after both.
      final socket2 = await _connect(host);
      addTearDown(socket2.destroy);
      final rx2 = _SocketCollector(socket2);
      addTearDown(rx2.cancel);
      socket2.add(Uint8List.fromList([0x03, 0x00, 0x00, 0x01]));
      await socket2.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(host.status, S7HostStatus.running);
      expect(rx2.received, isEmpty);

      final socket3 = await _connect(host);
      addTearDown(socket3.destroy);
      final rx3 = _SocketCollector(socket3);
      addTearDown(rx3.cancel);
      socket3.add(_connectRequestFrame());
      await socket3.flush();
      final reply = await rx3.readAtLeast(_kCcReplyLen);
      expect(parseCotp(Uint8List.sublistView(reply, kTpktHeaderLen))!.pduType, kCotpCc);
    });
  });

  group('S7Host — isolated state across sockets', () {
    test('two sockets get independent COTP references and independent connect state', () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final socketA = await _connect(host);
      addTearDown(socketA.destroy);
      final rxA = _SocketCollector(socketA);
      addTearDown(rxA.cancel);
      final socketB = await _connect(host);
      addTearDown(socketB.destroy);
      final rxB = _SocketCollector(socketB);
      addTearDown(rxB.cancel);

      socketA.add(_connectRequestFrame(srcRef: 0x0011));
      await socketA.flush();
      final ccA = parseCotp(
        Uint8List.sublistView(await rxA.readAtLeast(_kCcReplyLen), kTpktHeaderLen),
      );
      socketB.add(_connectRequestFrame(srcRef: 0x0022));
      await socketB.flush();
      final ccB = parseCotp(
        Uint8List.sublistView(await rxB.readAtLeast(_kCcReplyLen), kTpktHeaderLen),
      );

      expect(ccA, isNotNull);
      expect(ccB, isNotNull);
      // Each confirm addresses its OWN client's reference...
      expect(ccA!.dstRef, 0x0011);
      expect(ccB!.dstRef, 0x0022);
      // ...and the host's own per-connection references never collide.
      expect(ccA.srcRef, isNot(equals(ccB.srcRef)));
      expect(host.clientCount, 2);

      // Socket A completing Setup Communication must not leak connect state
      // to socket B: B has confirmed COTP too, so its own Setup Communication
      // is answered independently, with its own pduReference echoed.
      socketA.add(_setupCommunicationFrame(pduReference: 0x00aa));
      await socketA.flush();
      final replyA = Uint8List.sublistView(
        await rxA.readAtLeast(_kCcReplyLen + _kSetupReplyLen),
        _kCcReplyLen,
      );
      final s7A = parseS7(parseCotp(Uint8List.sublistView(replyA, kTpktHeaderLen))!.payload);
      expect(s7A, isNotNull);
      expect(s7A!.header.pduReference, 0x00aa);

      socketB.add(_setupCommunicationFrame(pduReference: 0x00bb));
      await socketB.flush();
      final replyB = Uint8List.sublistView(
        await rxB.readAtLeast(_kCcReplyLen + _kSetupReplyLen),
        _kCcReplyLen,
      );
      final s7B = parseS7(parseCotp(Uint8List.sublistView(replyB, kTpktHeaderLen))!.payload);
      expect(s7B, isNotNull);
      expect(s7B!.header.pduReference, 0x00bb);
    });

    test('a socket that never sent a Connection Request stays unserved while another is served',
        () async {
      final host = S7Host();
      await host.start(port: 0);
      addTearDown(host.stop);

      final served = await _connect(host);
      addTearDown(served.destroy);
      final rxServed = _SocketCollector(served);
      addTearDown(rxServed.cancel);
      final unserved = await _connect(host);
      addTearDown(unserved.destroy);
      final rxUnserved = _SocketCollector(unserved);
      addTearDown(rxUnserved.cancel);

      served.add(_connectRequestFrame());
      await served.flush();
      await rxServed.readAtLeast(_kCcReplyLen);
      served.add(_setupCommunicationFrame());
      await served.flush();
      await rxServed.readAtLeast(_kCcReplyLen + _kSetupReplyLen);

      // The other socket skipped the COTP handshake entirely: its Setup
      // Communication is dropped, and the first socket's established state
      // does not serve it.
      unserved.add(_setupCommunicationFrame());
      await unserved.flush();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(rxUnserved.received, isEmpty);
      expect(host.status, S7HostStatus.running);
    });
  });
}
