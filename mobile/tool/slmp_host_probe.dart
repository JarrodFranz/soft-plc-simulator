// A tiny `dart run` CLI that hosts Mitsubishi SLMP (MELSEC Communication, 3E
// binary) over a real `ServerSocket` (TCP), prints `READY` once bound, then
// serves until killed. Used by `tool/slmp_e2e.sh` as the Dart half of the v1
// SLMP workstream's E2E machine-proof: a REAL third-party client — the
// pure-Python `pymcprotocol` library, driven by `tool/py/slmp_probe.py` —
// connects here and completes a full read -> write -> independent read-back,
// INCLUDING a 32-bit value that settles the two-word order.
//
// WHY A REAL CLIENT RUNS AT ALL: every SLMP unit test in this repo exercises
// frames our own codec built, which proves self-consistency, not conformance.
// This fixture is where a client written independently of us reads our wire
// bytes — and, crucially for the 32-bit word order, reads a value this fixture
// SEEDED into a tag independently of the client. A write->read-back round trip
// alone cannot settle the word order (it is byte-transparent through our
// symmetric encode/decode); reading a seeded value is what pins it.
//
// IMPORTANT: this does NOT import `services/slmp_host.dart`. `SlmpHost extends
// ChangeNotifier` (`package:flutter/foundation.dart`), which transitively pulls
// in Flutter/`dart:ui` machinery unavailable under a plain `dart run` (only
// `flutter test`'s harness provides a `dart:ui` shim, and this must run as a
// standalone process) — see `mobile/tool/s7_host_probe.dart`, whose identical
// note this mirrors.
//
// *** HOW THIS STAYS FAITHFUL TO THE SHIPPED HOST ***
// The Read/Write path below is NOT mirrored — it is SHARED: both this fixture
// and `SlmpHost` call the single pure `dispatchSlmpFrame`
// (`protocols/slmp/slmp_dispatch.dart`) against a `SlmpTagImage`
// (`protocols/slmp/slmp_dispatch.dart` over `slmp_device_image.dart`), which
// builds every response byte AND performs the multi-word encode/decode. So the
// bytes the `pymcprotocol` client validates here are, by construction rather
// than by diff, the same bytes the shipped app puts on the wire, and the word
// order the client round-trips is the actual `slmp_device_image.dart` word
// order. Only the small length-prefixed TCP reassembly loop is re-implemented
// here, mirroring `SlmpHost._Connection` line for line (that file is
// authoritative; if the two ever diverge, it wins).
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

import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/slmp_map.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_dispatch.dart';

// --- Fixture tag values the probe asserts against ---------------------------
//
// Every constant below is pinned in `tool/py/slmp_probe.py`. Keep the two files
// in step: the probe names each constant it depends on in a comment. Each
// value's bytes are chosen to DIFFER so a byte-order or word-order fault cannot
// pass unnoticed.

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

/// `Reg32` — D words 110..111 (INT32). The 32-bit WORD-ORDER settler: all four
/// bytes distinct AND the high word differs from the low, so reading this
/// SEEDED value back through the client's own per-word decode exposes any
/// word-order disagreement.
const int _reg32Address = 110;
const int _reg32Value = 0x1A2B3C4D;

/// `Flag` — D word 114, bit 0 (BOOL). Starts FALSE so the probe's write to
/// TRUE (by setting bit 0 of the word) is an observable change.
const int _flagAddress = 114;
const int _flagBit = 0;

/// `Locked` — D word 116 (INT16), mapped ReadOnly: the probe asserts a write
/// here is REFUSED (SLMP end code 0xC05B) and the value is unchanged.
const int _lockedAddress = 116;
const int _lockedValue = 250;

/// Builds the fixture project + SLMP map the E2E probe reads and writes. Tag
/// name == path (single top-level names) so a map entry's `tag` resolves
/// directly. Addresses are pinned EXPLICITLY here (not taken from
/// `SlmpMap.autoGenerate`), so the probe can address literal device numbers and
/// a future change to the auto-layout cannot silently move them. This is served
/// through the SAME `SlmpTagImage`/`dispatchSlmpFrame` the shipped host uses.
PlcProject _fixtureProject() {
  final project = PlcProject(
    id: 'proj_slmp_e2e_fixture',
    name: 'SLMP E2E Fixture',
    controllerName: 'PLC_E2E',
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    tags: [
      PlcTag(name: 'D100v', path: 'D100v', dataType: 'INT16', value: _d100Value, ioType: 'Internal'),
      PlcTag(name: 'D101v', path: 'D101v', dataType: 'INT16', value: _d101Value, ioType: 'Internal'),
      PlcTag(name: 'D102v', path: 'D102v', dataType: 'INT16', value: _d102Value, ioType: 'Internal'),
      PlcTag(name: 'D103v', path: 'D103v', dataType: 'INT16', value: _d103Value, ioType: 'Internal'),
      PlcTag(name: 'W0v', path: 'W0v', dataType: 'INT16', value: _w0Value, ioType: 'Internal'),
      PlcTag(name: 'Reg32', path: 'Reg32', dataType: 'INT32', value: _reg32Value, ioType: 'Internal'),
      PlcTag(name: 'Flag', path: 'Flag', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'Locked', path: 'Locked', dataType: 'INT16', value: _lockedValue, ioType: 'Internal'),
    ],
  );

  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.slmp = SlmpProtocolConfig(
    enabled: true,
    port: 5007, // overwritten in main() with the real bound port before use
    map: SlmpMap(entries: [
      SlmpMapEntry(tag: 'D100v', device: kSlmpDeviceNameD, address: _d100Address),
      SlmpMapEntry(tag: 'D101v', device: kSlmpDeviceNameD, address: _d100Address + 1),
      SlmpMapEntry(tag: 'D102v', device: kSlmpDeviceNameD, address: _d100Address + 2),
      SlmpMapEntry(tag: 'D103v', device: kSlmpDeviceNameD, address: _d100Address + 3),
      SlmpMapEntry(tag: 'W0v', device: kSlmpDeviceNameW, address: _w0Address),
      SlmpMapEntry(tag: 'Reg32', device: kSlmpDeviceNameD, address: _reg32Address),
      SlmpMapEntry(tag: 'Flag', device: kSlmpDeviceNameD, address: _flagAddress, bitOffset: _flagBit),
      SlmpMapEntry(tag: 'Locked', device: kSlmpDeviceNameD, address: _lockedAddress, access: 'ReadOnly'),
    ]),
  );
  return project;
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

  final project = _fixtureProject();
  // The image is backed by the project's tags via the persisted SLMP map — the
  // same `SlmpTagImage` the shipped host serves, so a write mutates the project
  // in place and a following read observes it.
  final image = SlmpTagImage(project, project.protocols!.slmp!.map);

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
