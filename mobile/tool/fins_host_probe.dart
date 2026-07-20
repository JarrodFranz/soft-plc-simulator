// A tiny `dart run` CLI that hosts Omron FINS over a real `RawDatagramSocket`
// (UDP), prints `READY` once bound, then serves until killed. Used by
// `tool/fins_e2e.sh` as the Dart half of the v1 FINS workstream's Task 3 EARLY
// E2E machine-proof: a REAL third-party client — the pure-Python `fins`
// library, driven by `tool/py/fins_probe.py` — connects here and completes a
// Memory Area Read.
//
// WHY A REAL CLIENT RUNS AT ALL: every FINS unit test in this repo exercises
// frames our own codec built, which proves self-consistency, not conformance.
// This fixture is where a client written independently of us reads our wire
// bytes — the FIRST time our UDP framing (the suite's first `RawDatagramSocket`
// host) is seen by anything but ourselves.
//
// IMPORTANT: this does NOT import `services/fins_host.dart`. `FinsHost extends
// ChangeNotifier` (`package:flutter/foundation.dart`), which transitively pulls
// in Flutter/`dart:ui` machinery unavailable under a plain `dart run` (only
// `flutter test`'s harness provides a `dart:ui` shim, and this must run as a
// standalone process) — see `mobile/tool/s7_host_probe.dart`, whose identical
// note this mirrors.
//
// *** HOW THIS STAYS FAITHFUL TO THE SHIPPED HOST ***
// The Memory Area Read path below is NOT mirrored — it is SHARED: both this
// fixture and `FinsHost` call the single pure `dispatchFinsDatagram`
// (`protocols/fins/fins_dispatch.dart`), which builds every response byte. So
// the bytes the `fins` client validates here are, by construction rather than
// by diff, the same bytes the shipped app puts on the wire. Only the small
// `RawDatagramSocket` receive loop is re-implemented here (as
// `s7_host_probe.dart` re-implements the TCP accept/reassembly loop).
//
// *** THE UDP SHAPE ***
// One datagram = one complete FINS frame. There is no reassembly, no
// per-connection state; a reply goes back to the datagram's own source
// address/port, correlated by the echoed SID inside the frame.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/fins_host_probe.dart <port>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/protocols/fins/fins_dispatch.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_memory.dart';

// --- Fixture values the probe asserts against -------------------------------
//
// These are the DM words `tool/py/fins_probe.py` expects to READ. Keep the two
// files in step: the probe names each constant it depends on in a comment.
// Each word's two bytes DIFFER, so a byte-order fault cannot pass unnoticed.

/// Number of DM words in the fixture bank (zero-filled; only the seeded words
/// below hold a non-zero value).
const int _dmWordCount = 512;

/// `DM100` — first seeded word. 0x1234's two bytes differ.
const int _dm100Address = 100;
const int _dm100Value = 0x1234;

/// `DM101` — adjacent seeded word, so a 2-word read proves word ordering.
const int _dm101Address = 101;
const int _dm101Value = 0x5678;

/// Builds the fixture image the E2E probe reads from: a zero-filled DM word
/// bank with two seeded words. Mirrors `FinsHost`'s Task-3 fixture shape (both
/// go through the same `FinsWordImage`/`dispatchFinsDatagram`), but the values
/// are pinned HERE for the Python probe to assert.
FinsWordImage _fixtureImage() {
  final dm = Uint16List(_dmWordCount);
  dm[_dm100Address] = _dm100Value;
  dm[_dm101Address] = _dm101Value;
  return FinsWordImage(<int, Uint16List>{kFinsAreaDM: dm});
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/fins_host_probe.dart <port>');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }

  final image = _fixtureImage();

  RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
  } catch (e) {
    stderr.writeln('FAILED TO BIND: $e');
    exit(1);
  }

  socket.listen((event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    // Drain every queued datagram: one `read` event can cover several, and
    // `receive()` returns null once the queue is empty.
    while (true) {
      Datagram? dg;
      try {
        dg = socket.receive();
      } catch (_) {
        return;
      }
      if (dg == null) {
        return;
      }
      try {
        final reply = dispatchFinsDatagram(dg.data, image);
        if (reply == null) {
          // Malformed / unserved datagram: drop it, keep the bind alive.
          continue;
        }
        socket.send(reply, dg.address, dg.port);
      } catch (_) {
        // One bad datagram must never wedge the bind.
      }
    }
  });

  // ignore: avoid_print
  print('READY fins-udp://127.0.0.1:${socket.port}');

  // Serve until killed. SIGINT is watched for a graceful Ctrl+C exit; SIGTERM
  // is intentionally NOT watched (unsupported on Windows and throws
  // asynchronously if attempted) — the E2E harness (`tool/fins_e2e.sh`) simply
  // kills this process outright when done, which is fine for a short-lived
  // fixture host with no state to flush.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  socket.close();
}
