// A tiny `dart run` CLI that hosts Omron FINS over a real `RawDatagramSocket`
// (UDP), prints `READY` once bound, then serves until killed. Used by
// `tool/fins_e2e.sh` as the Dart half of the v1 FINS workstream's E2E
// machine-proof: a REAL third-party client — the pure-Python `fins` library,
// driven by `tool/py/fins_probe.py` — connects here and completes a full
// read -> write -> independent read-back, INCLUDING a 32-bit value that
// settles the two-word order.
//
// WHY A REAL CLIENT RUNS AT ALL: every FINS unit test in this repo exercises
// frames our own codec built, which proves self-consistency, not conformance.
// This fixture is where a client written independently of us reads our wire
// bytes — and, crucially for the 32-bit word order, reads a value this fixture
// SEEDED into a tag independently of the client. A write->read-back round trip
// alone cannot settle the word order (it is byte-transparent through our
// symmetric encode/decode); reading a seeded value is what pins it.
//
// IMPORTANT: this does NOT import `services/fins_host.dart`. `FinsHost extends
// ChangeNotifier` (`package:flutter/foundation.dart`), which transitively pulls
// in Flutter/`dart:ui` machinery unavailable under a plain `dart run` (only
// `flutter test`'s harness provides a `dart:ui` shim, and this must run as a
// standalone process) — see `mobile/tool/s7_host_probe.dart`, whose identical
// note this mirrors.
//
// *** HOW THIS STAYS FAITHFUL TO THE SHIPPED HOST ***
// The Read/Write path below is NOT mirrored — it is SHARED: both this fixture
// and `FinsHost` call the single pure `dispatchFinsDatagram`
// (`protocols/fins/fins_dispatch.dart`) against a `FinsTagImage`
// (`protocols/fins/fins_area_image.dart`), which builds every response byte
// AND performs the multi-word encode/decode. So the bytes the `fins` client
// validates here are, by construction rather than by diff, the same bytes the
// shipped app puts on the wire, and the word order the client round-trips is
// the actual `fins_area_image.dart` word order. Only the small
// `RawDatagramSocket` receive loop is re-implemented here.
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

import 'package:soft_plc_mobile/models/fins_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_dispatch.dart';

// --- Fixture tag values the probe asserts against ---------------------------
//
// Every constant below is pinned in `tool/py/fins_probe.py`. Keep the two files
// in step: the probe names each constant it depends on in a comment. Each
// value's bytes are chosen to DIFFER so a byte-order or word-order fault cannot
// pass unnoticed.

/// `W0` — DM word 100 (INT16). Two bytes differ. (Probe steps 2/3.)
const int _w0Word = 100;
const int _w0Value = 0x1234;

/// `W1` — DM word 101 (INT16), adjacent to W0 so a two-word read proves the
/// order of adjacent WORDS. (Probe step 4.)
const int _w1Word = 101;
const int _w1Value = 0x5678;

/// `Reg32` — DM words 110..111 (INT32). The 32-bit WORD-ORDER settler: all four
/// bytes distinct AND the high word differs from the low, so reading this
/// SEEDED value back through the client's own multi-word decode exposes any
/// word-order disagreement. (Probe steps 5, 7.)
const int _reg32Word = 110;
const int _reg32Value = 0x1A2B3C4D;

/// `Real1` — DM words 112..113 (FLOAT64 narrowed to a 4-byte FINS REAL).
/// 12.5 is exactly representable in float32, so the narrowing does not blur the
/// assertion, and the REAL rides the same two-word order as the DINT. (Step 6.)
const int _real1Word = 112;
const double _real1Value = 12.5;

/// `Flag` — DM word 114, bit 0 (BOOL). Starts FALSE so the probe's write to
/// TRUE (by setting bit 0 of the word) is an observable change. (Step 8.)
const int _flagWord = 114;
const int _flagBit = 0;

/// `CioReg` — CIO word 5 (INT16). A SECOND memory area (CIO, not DM): if the
/// area code were ignored this would read as DM. (Step 9.)
const int _cioRegWord = 5;
const int _cioRegValue = 0x0A0B;

/// `Locked` — DM word 116 (INT16), mapped ReadOnly: the probe asserts a write
/// here is REFUSED and the value is unchanged. (Step 10.)
const int _lockedWord = 116;
const int _lockedValue = 250;

/// Builds the fixture project + FINS map the E2E probe reads and writes. Tag
/// name == path (single top-level names) so a map entry's `tag` resolves
/// directly. Addresses are pinned EXPLICITLY here (not taken from
/// `FinsMap.autoGenerate`), so the probe can address literal words and a future
/// change to the auto-layout cannot silently move them. This is served through
/// the SAME `FinsTagImage`/`dispatchFinsDatagram` the shipped host uses.
PlcProject _fixtureProject() {
  final project = PlcProject(
    id: 'proj_fins_e2e_fixture',
    name: 'FINS E2E Fixture',
    controllerName: 'PLC_E2E',
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    tags: [
      PlcTag(name: 'W0', path: 'W0', dataType: 'INT16', value: _w0Value, ioType: 'Internal'),
      PlcTag(name: 'W1', path: 'W1', dataType: 'INT16', value: _w1Value, ioType: 'Internal'),
      PlcTag(name: 'Reg32', path: 'Reg32', dataType: 'INT32', value: _reg32Value, ioType: 'Internal'),
      PlcTag(name: 'Real1', path: 'Real1', dataType: 'FLOAT64', value: _real1Value, ioType: 'Internal'),
      PlcTag(name: 'Flag', path: 'Flag', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'CioReg', path: 'CioReg', dataType: 'INT16', value: _cioRegValue, ioType: 'Internal'),
      PlcTag(name: 'Locked', path: 'Locked', dataType: 'INT16', value: _lockedValue, ioType: 'Internal'),
    ],
  );

  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.fins = FinsProtocolConfig(
    enabled: true,
    port: 9600, // overwritten in main() with the real bound port before use
    map: FinsMap(entries: [
      FinsMapEntry(tag: 'W0', area: kFinsAreaNameDM, wordAddress: _w0Word),
      FinsMapEntry(tag: 'W1', area: kFinsAreaNameDM, wordAddress: _w1Word),
      FinsMapEntry(tag: 'Reg32', area: kFinsAreaNameDM, wordAddress: _reg32Word),
      FinsMapEntry(tag: 'Real1', area: kFinsAreaNameDM, wordAddress: _real1Word),
      FinsMapEntry(tag: 'Flag', area: kFinsAreaNameDM, wordAddress: _flagWord, bitOffset: _flagBit),
      FinsMapEntry(tag: 'CioReg', area: kFinsAreaNameCIO, wordAddress: _cioRegWord),
      FinsMapEntry(tag: 'Locked', area: kFinsAreaNameDM, wordAddress: _lockedWord, access: 'ReadOnly'),
    ]),
  );
  return project;
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

  final project = _fixtureProject();
  // The image is backed by the project's tags via the persisted FINS map — the
  // same `FinsTagImage` the shipped host serves, so a write mutates the project
  // in place and a following read observes it.
  final image = FinsTagImage(project, project.protocols!.fins!.map);

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
