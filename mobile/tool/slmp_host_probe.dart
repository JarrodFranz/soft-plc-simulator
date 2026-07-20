// A tiny `dart run` CLI that hosts Mitsubishi SLMP (MELSEC Communication, 3E
// binary) over a real `ServerSocket` (TCP), prints `READY` once bound, then
// serves until killed. Used by `tool/slmp_e2e.sh` as the Dart half of the v1
// SLMP workstream's EARLY E2E machine-proof: a REAL third-party client — the
// pure-Python `pymcprotocol` library, driven by `tool/py/slmp_probe.py` —
// connects here and batch-reads a known device word.
//
// WHY A REAL CLIENT RUNS AT ALL: every SLMP unit test in this repo exercises
// frames our own codec built, which proves self-consistency, not conformance.
// This fixture is where a client written independently of us reads our wire
// bytes. It runs at Task 3 — before any tag-map logic exists — precisely so the
// framing (the length-field convention, the big-endian subheader vs
// little-endian body, the device codes, the end code) is settled against a real
// client at the earliest possible point.
//
// IMPORTANT: this does NOT import `services/slmp_host.dart`. `SlmpHost extends
// ChangeNotifier` (`package:flutter/foundation.dart`), which transitively pulls
// in Flutter/`dart:ui` machinery unavailable under a plain `dart run` (only
// `flutter test`'s harness provides a `dart:ui` shim, and this must run as a
// standalone process) — see `mobile/tool/s7_host_probe.dart`, whose identical
// note this mirrors.
//
// *** HOW THIS STAYS FAITHFUL TO THE SHIPPED HOST ***
// The dispatch path below is NOT mirrored — it is SHARED: both this fixture and
// `SlmpHost` call the single pure `dispatchSlmpFrame`
// (`protocols/slmp/slmp_dispatch.dart`), which builds every response byte. So
// the bytes `pymcprotocol` validates here are, by construction rather than by
// diff, the same bytes the shipped app puts on the wire. Only the small
// length-prefixed TCP reassembly loop is re-implemented here, mirroring
// `SlmpHost._Connection` line for line (that file is authoritative; if the two
// ever diverge, it wins).
//
// *** THE LENGTH CONVENTION ***
// The 3E `requestDataLength` u16 (little-endian, at byte offset 7) counts the
// bytes AFTER it, NOT the fixed 9-byte prefix before it. So `total = 9 +
// requestDataLength`. See `slmp_host.dart`'s header for the full note; this
// value was verified against `pymcprotocol` at Task 3.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/slmp_host_probe.dart <port>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/protocols/slmp/slmp_commands.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_dispatch.dart';

// --- Fixture device values the probe asserts against ------------------------
//
// Every constant below is pinned in `tool/py/slmp_probe.py`. Keep the two files
// in step: the probe names each constant it depends on in a comment. Each
// value's two bytes DIFFER so a byte-order fault cannot pass unnoticed.

/// `D100` (INT16). Two bytes differ so little-endian word data is testable.
const int _d100Address = 100;
const int _d100Value = 0x1234;

/// `D101`..`D103` — adjacent D words, so a multi-word read proves the order of
/// adjacent WORDS and the length reassembly of a longer request.
const int _d101Value = 0x5678;
const int _d102Value = 0x9ABC;
const int _d103Value = 0xDEF0;

/// `W0` (link register) — a DIFFERENT device code (0xB4, not D's 0xA8), so a
/// read here proves the device code is not ignored.
const int _w0Address = 0;
const int _w0Value = 0x0A0B;

/// Builds the fixture device image the E2E probe reads: a D word bank and a W
/// word bank with the known values above. Served through the SAME
/// `SlmpWordImage`/`dispatchSlmpFrame` seam the shipped host uses.
SlmpDeviceImage _fixtureImage() {
  final dBank = Uint16List(256);
  dBank[_d100Address] = _d100Value;
  dBank[_d100Address + 1] = _d101Value;
  dBank[_d100Address + 2] = _d102Value;
  dBank[_d100Address + 3] = _d103Value;
  final wBank = Uint16List(64);
  wBank[_w0Address] = _w0Value;
  return SlmpWordImage({
    kSlmpDevD: dBank,
    kSlmpDevW: wBank,
  });
}

// --- Length-prefixed reassembly constants — mirror `slmp_host.dart` ---------

/// Offset of the little-endian `requestDataLength` u16 in a 3E frame.
const int _kLengthFieldOffset = 7;

/// Bytes that must be buffered before the length field is readable.
const int _kLengthPrefixEnd = _kLengthFieldOffset + 2;

/// Hostile/garbage frame-size guard — mirrors `slmp_host.dart`.
const int _maxFrameBytes = _kLengthPrefixEnd + 0xFFFF;

/// Per-connection 3E-frame reassembly and dispatch, mirroring `SlmpHost`'s
/// `_Connection` (see `mobile/lib/services/slmp_host.dart` — the authoritative
/// version). Accumulates arbitrary TCP chunks; once the length field is
/// readable, `total = _kLengthPrefixEnd + requestDataLength` gives the whole
/// frame; once that many bytes are buffered the frame is sliced off,
/// dispatched via the shared `dispatchSlmpFrame`, and the reply written back.
class _Connection {
  final Socket socket;
  final List<int> _buffer = [];
  bool _closed = false;

  _Connection(this.socket);

  void onData(List<int> data, SlmpDeviceImage image) {
    if (_closed) {
      return;
    }
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < _kLengthPrefixEnd) {
          return;
        }
        final requestDataLength =
            _buffer[_kLengthFieldOffset] | (_buffer[_kLengthFieldOffset + 1] << 8);
        final total = _kLengthPrefixEnd + requestDataLength;
        if (total > _maxFrameBytes) {
          close();
          return;
        }
        if (_buffer.length < total) {
          return;
        }
        final frame = Uint8List.fromList(_buffer.sublist(0, total));
        _buffer.removeRange(0, total);
        final reply = dispatchSlmpFrame(frame, image);
        if (reply != null) {
          socket.add(reply);
        }
      }
    } catch (_) {
      close();
    }
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

/// Live connections (tracked only so [_Connection] can remove itself on close).
final List<_Connection> _connections = [];

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/slmp_host_probe.dart <port>');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }

  final image = _fixtureImage();

  ServerSocket serverSocket;
  try {
    serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  } catch (e) {
    stderr.writeln('FAILED TO BIND: $e');
    exit(1);
  }

  serverSocket.listen((socket) {
    try {
      final conn = _Connection(socket);
      _connections.add(conn);
      socket.listen(
        (data) {
          try {
            conn.onData(data, image);
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
  print('READY slmp-tcp://127.0.0.1:${serverSocket.port}');

  // Serve until killed. SIGINT is watched for a graceful Ctrl+C exit; SIGTERM
  // is intentionally NOT watched (unsupported on Windows and throws
  // asynchronously if attempted) — the E2E harness (`tool/slmp_e2e.sh`) simply
  // kills this process outright when done.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  await serverSocket.close();
}
