// A tiny `dart run` CLI that hosts S7comm (TPKT/COTP + S7 PDU) over a real
// `ServerSocket`, prints `READY` on listening, then serves until killed. Used
// by `tool/s7_e2e.sh` as the Dart half of the v1 S7comm workstream's Task 3
// EARLY E2E machine-proof: a REAL third-party client — the Python
// `python-snap7` library, driven by `tool/py/s7_probe.py` — connects here and
// completes the COTP Connection Request -> Connection Confirm and S7 Setup
// Communication handshake.
//
// WHY THIS EXISTS BEFORE ANY READ/WRITE LOGIC: every S7comm unit test in this
// repo so far exercises frames our own codec built, which proves
// self-consistency, not conformance. This fixture is where a client written
// independently of us reads our wire bytes — and it runs at Task 3, not at the
// end, so a misread specification detail in the CR/CC or Setup Communication
// layout surfaces before anything is built on top of it. Read Var / Write Var
// coverage is added to this fixture in Task 5.
//
// IMPORTANT: this does NOT import `services/s7_host.dart`. `S7Host extends
// ChangeNotifier` (`package:flutter/foundation.dart`), which transitively
// pulls in Flutter/`dart:ui` machinery unavailable under a plain `dart run`
// (only `flutter test`'s harness provides a `dart:ui` shim, and this must run
// as a standalone process) — see `mobile/tool/enip_host_probe.dart`, whose
// identical note this mirrors. The S7comm codec
// (`protocols/s7/tpkt_cotp.dart`, `protocols/s7/s7_pdu.dart`) is pure Dart
// with zero Flutter dependency, so this tool talks to it directly,
// reimplementing just the same small TPKT reassembly + dispatch loop
// `S7Host`'s `_Connection` uses — see `mobile/lib/services/s7_host.dart` for
// the authoritative version this mirrors. If the two ever diverge, that file
// wins and this one must be updated to match.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/s7_host_probe.dart <port>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/protocols/s7/s7_pdu.dart';
import 'package:soft_plc_mobile/protocols/s7/tpkt_cotp.dart';

/// Hostile/garbage frame-size guard — mirrors `s7_host.dart`. The TPKT
/// `length` field is a u16 counting the whole packet.
const int _maxFrameBytes = 0xFFFF;

/// Largest number of outstanding jobs agreed during Setup Communication —
/// mirrors `s7_host.dart`'s constant of the same name.
const int _kMaxAmq = 8;

/// Per-connection TPKT-frame reassembly and dispatch, mirroring `S7Host`'s
/// `_Connection` (see `mobile/lib/services/s7_host.dart` — the authoritative
/// version). Accumulates arbitrary TCP chunks; once at least `kTpktHeaderLen`
/// (4) bytes are present the header's own big-endian `length` field gives the
/// size of the WHOLE frame — `total = length`, NOT `4 + length` — and once
/// that many bytes are buffered the frame is sliced off, decoded, dispatched,
/// and the reply written back.
class _Connection {
  final Socket socket;
  final int localRef;
  final List<int> _buffer = [];
  bool _closed = false;
  bool cotpEstablished = false;
  int? peerSrcTsap;
  int? peerDstTsap;
  int negotiatedPduLength = kS7MinPduLength;

  _Connection(this.socket, this.localRef);

  void onData(List<int> data) {
    if (_closed) {
      return;
    }
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < kTpktHeaderLen) {
          return;
        }
        final headerBytes = Uint8List.fromList(_buffer.sublist(0, kTpktHeaderLen));
        final header = parseTpkt(headerBytes);
        if (header == null) {
          close();
          return;
        }
        final total = header.length; // whole packet, TPKT header included
        if (total < kTpktHeaderLen || total > _maxFrameBytes) {
          close();
          return;
        }
        if (_buffer.length < total) {
          return;
        }
        final frame = Uint8List.fromList(_buffer.sublist(0, total));
        _buffer.removeRange(0, total);
        _handleFrame(frame);
      }
    } catch (_) {
      close();
    }
  }

  void _handleFrame(Uint8List frame) {
    final cotp = parseCotp(Uint8List.sublistView(frame, kTpktHeaderLen));
    if (cotp == null) {
      return;
    }
    if (cotp.pduType == kCotpCr) {
      _handleConnectRequest(cotp);
      return;
    }
    if (cotp.pduType == kCotpDt) {
      if (!cotpEstablished) {
        return;
      }
      _handleS7(cotp.payload);
      return;
    }
  }

  void _handleConnectRequest(CotpPacket cr) {
    peerSrcTsap = cr.srcTsap;
    peerDstTsap = cr.dstTsap;
    final cc = buildCotpConnectConfirm(
      dstRef: cr.srcRef ?? 0,
      srcRef: localRef,
      srcTsap: cr.srcTsap ?? 0,
      dstTsap: cr.dstTsap ?? 0,
    );
    cotpEstablished = true;
    socket.add(buildTpkt(cc));
  }

  void _handleS7(Uint8List s7Bytes) {
    final msg = parseS7(s7Bytes);
    if (msg == null) {
      return;
    }
    if (msg.header.rosctr != kS7RosctrJob) {
      return;
    }
    if (msg.parameter.isEmpty || msg.parameter[0] != kS7FunctionSetupCommunication) {
      return;
    }
    final setup = parseSetupCommunication(msg.parameter);
    if (setup == null) {
      return;
    }
    final agreedPdu = negotiatePduLength(setup.pduLength);
    negotiatedPduLength = agreedPdu;
    final parameter = buildSetupCommunicationReply(
      maxAmqCalling: setup.maxAmqCalling < _kMaxAmq ? setup.maxAmqCalling : _kMaxAmq,
      maxAmqCalled: setup.maxAmqCalled < _kMaxAmq ? setup.maxAmqCalled : _kMaxAmq,
      pduLength: agreedPdu,
    );
    final reply = buildS7(
      rosctr: kS7RosctrAckData,
      pduReference: msg.header.pduReference,
      parameter: parameter,
    );
    socket.add(buildTpkt(buildCotpData(reply)));
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _connections.remove(this);
    try {
      socket.destroy();
    } catch (_) {
      // Ignore.
    }
  }
}

/// Live connections (tracked only so [_Connection] can remove itself on
/// close — S7comm v1 has no clock-driven push, so nothing else iterates it).
final List<_Connection> _connections = [];

/// One monotonic COTP source-reference counter shared by every accepted
/// socket — mirrors `S7Host._allocateLocalRef`.
int _nextLocalRef = 1;

int _allocateLocalRef() {
  final ref = _nextLocalRef;
  _nextLocalRef = _nextLocalRef >= 0xFFFF ? 1 : _nextLocalRef + 1;
  return ref;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/s7_host_probe.dart <port>');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }

  ServerSocket serverSocket;
  try {
    serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  } catch (e) {
    stderr.writeln('FAILED TO BIND: $e');
    exit(1);
  }

  serverSocket.listen((socket) {
    try {
      final conn = _Connection(socket, _allocateLocalRef());
      _connections.add(conn);
      socket.listen(
        (data) {
          try {
            conn.onData(data);
          } catch (_) {
            conn.close();
          }
        },
        onError: (Object _, StackTrace __) => conn.close(),
        onDone: () => conn.close(),
        cancelOnError: false,
      );
    } catch (_) {
      try {
        socket.destroy();
      } catch (_) {
        // Ignore.
      }
    }
  });

  // ignore: avoid_print
  print('READY s7-tcp://127.0.0.1:${serverSocket.port}');

  // Serve until killed. SIGINT is watched for a graceful Ctrl+C exit; SIGTERM
  // is intentionally NOT watched (unsupported on Windows and throws
  // asynchronously if attempted) — the E2E harness (`tool/s7_e2e.sh`) simply
  // kills this process outright when done, which is fine for a short-lived
  // fixture host with no state to flush.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  await serverSocket.close();
}
