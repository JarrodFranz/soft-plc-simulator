// A tiny `dart run` CLI that builds a small fixture project in code (a
// Binary Input, an Analog Input INT32, an Analog Input FLOAT64, a Binary
// Output, and an Analog Output INT32 -- with the Binary Output FORCED),
// hosts it over a real `ServerSocket` using the DNP3 data-link + transport +
// application layers (WS26 DNP3 outstation Tasks 2-4), prints `READY` on
// listening, then serves until killed. Used by `tool/dnp3_e2e.sh` as the
// Dart half of Task 6's E2E machine-proof: a REAL, independent, third-party
// DNP3 master (Step Function I/O's `dnp3` crate, driven by
// `gateway/examples/dnp3_probe.rs`) connects here, runs a Class 0 integrity
// poll, and issues SELECT/DIRECT_OPERATE control.
//
// IMPORTANT: this does NOT import `services/dnp3_host.dart`. `DnpHost
// extends ChangeNotifier` (`package:flutter/foundation.dart`), which
// transitively pulls in Flutter/`dart:ui` machinery unavailable under a
// plain `dart run` -- see `mobile/tool/modbus_host_probe.dart`'s/
// `mqtt_host_probe.dart`'s identical note, which this mirrors. The wire
// codecs (`dnp3_link.dart`/`dnp3_transport.dart`/`dnp3_app.dart`) and the
// outstation handler (`dnp3_outstation.dart`) are pure Dart with zero
// Flutter dependency, so this tool reimplements the small per-connection
// byte-reassembly + response-framing loop `DnpHost`'s `_Connection` /
// `_buildResponseFrames` use directly against those pure modules -- see
// `mobile/lib/services/dnp3_host.dart` for the authoritative version this
// mirrors (link CONTROL byte, transport segmentation, dest-address
// filtering).
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Fixture project (must match the constants `gateway/examples/dnp3_probe.rs`
// hardcodes: outstation address 1024, master address 1):
//   - `LimitSwitch` : BOOL,    SimulatedInput -> binaryInput  index 0 (g1v2)
//     value = true.
//   - `Temperature`  : INT32,   SimulatedInput -> analogInput  index 0 (g30v1)
//     value = 4222.
//   - `FlowRate`     : FLOAT64, SimulatedInput -> analogInput  index 1 (g30v5)
//     value = 88.5 (exactly representable in float32, so the master's f64
//     read-back compares bit-for-bit equal after the outstation's
//     float64->float32 narrowing).
//   - `Motor`        : BOOL,    Internal       -> binaryOutput index 0
//     (g10v2/g12v1) -- FORCED: live `value` is `false`, `forcedValue` is
//     `true`. Proves two things over the real wire in one tag: (a) a forced
//     point's forced value reaches a DNP3 read (Class 0), and (b) a
//     DIRECT_OPERATE CROB targeting a forced point is rejected
//     (NOT_AUTHORIZED) and never changes the point -- Task 4's flagged
//     force-aware-control-skip concern, now machine-proved against a real
//     master.
//   - `Setpoint`     : INT32,   Internal       -> analogOutput index 0
//     (g40v1/g41v1) value = 1000, NOT forced -- the DIRECT_OPERATE
//     analog-output-block target that IS expected to succeed and change.
//   - `SimulatedBinary` : BOOL, SimulatedInput -> binaryInput  index 1,
//     eventClass 1 -- a DEDICATED, change-driven event point (Task 6).
//   - `SimulatedAnalog` : INT32, SimulatedInput -> analogInput index 2,
//     eventClass 2 -- a DEDICATED, change-driven event point (Task 6).
//
// The two dedicated event points are flipped/incremented on a ~1 s timer
// (`changeTimer` in `main`), and a ~300 ms `tickTimer` runs the same
// change-detection + unsolicited push/retry loop `DnpHost.tickForTest` uses
// (see `_UnsolDriver`) -- so a real master driving solicited Class 1/2/3
// polls, or enabling unsolicited reporting, observes those changes as g2/g32
// events. The original five points above are NEVER mutated by the fixture, so
// every WS26 static/control probe assertion stays valid.
//
// Usage: dart run tool/dnp3_host_probe.dart <port>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_link.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_outstation.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_transport.dart';

/// Fixed outstation/master link addresses, matching
/// `gateway/examples/dnp3_probe.rs`'s hardcoded association addresses.
const int _kOutstationAddress = 1024;
const int _kMasterAddress = 1;

/// A single transport segment's application-data budget (250-byte link
/// user-data max, minus the 1-byte transport header) -- mirrors
/// `dnp3_host.dart`'s `_maxSegmentPayload`.
const int _maxSegmentPayload = 249;

/// Link-layer CONTROL byte used on every outgoing (outstation -> master)
/// response frame -- mirrors `dnp3_host.dart`'s `_responseLinkControl`
/// ("unconfirmed user data" from an outstation to a master), since this v1
/// outstation does not implement the data-link confirmation/FCB state
/// machine.
const int _responseLinkControl = 0x44;

/// Hostile/never-resolving buffer guard, mirroring `dnp3_host.dart`'s
/// `_maxPendingBytes`.
const int _maxPendingBytes = 4096;

PlcProject _fixtureProject() {
  final project = PlcProject(
    id: 'proj_dnp3_e2e_fixture',
    name: 'DNP3 E2E Fixture',
    controllerName: 'PLC_E2E',
    tags: [
      PlcTag(
        name: 'LimitSwitch',
        path: 'Inputs.LimitSwitch',
        dataType: 'BOOL',
        value: true,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'Temperature',
        path: 'Inputs.Temperature',
        dataType: 'INT32',
        value: 4222,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'FlowRate',
        path: 'Inputs.FlowRate',
        dataType: 'FLOAT64',
        value: 88.5,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'Motor',
        path: 'Internal.Motor',
        dataType: 'BOOL',
        value: false,
        ioType: 'Internal',
        isForced: true,
        forcedValue: true,
      ),
      PlcTag(
        name: 'Setpoint',
        path: 'Internal.Setpoint',
        dataType: 'INT32',
        value: 1000,
        ioType: 'Internal',
      ),
      // --- DEDICATED event points (Task 6 events E2E) -----------------------
      // Two extra, change-driven points the fixture flips/increments on a
      // timer (see `_startChangeDriver`) so a real master observes changes ->
      // events. These are ADDITIVE: the original five points above are never
      // mutated, so every existing static/control probe assertion still holds.
      PlcTag(
        name: 'SimulatedBinary',
        path: 'Inputs.SimulatedBinary',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'SimulatedAnalog',
        path: 'Inputs.SimulatedAnalog',
        dataType: 'INT32',
        value: 1000,
        ioType: 'SimulatedInput',
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
    port: 20000, // overwritten in main() with the real bound port before use
    outstationAddress: _kOutstationAddress,
    masterAddress: _kMasterAddress,
    map: DnpMap(entries: [
      DnpMapEntry(tag: 'LimitSwitch', pointType: 'binaryInput', index: 0),
      DnpMapEntry(tag: 'Temperature', pointType: 'analogInput', index: 0),
      DnpMapEntry(tag: 'FlowRate', pointType: 'analogInput', index: 1),
      DnpMapEntry(tag: 'Motor', pointType: 'binaryOutput', index: 0),
      DnpMapEntry(tag: 'Setpoint', pointType: 'analogOutput', index: 0),
      // Dedicated event points at FRESH indices (binaryInput 1 / analogInput
      // 2) so they never collide with the static points above. eventClass 1
      // and 2 respectively — their changes are captured into Class 1 / Class 2
      // and reported via solicited Class polls and unsolicited responses.
      DnpMapEntry(tag: 'SimulatedBinary', pointType: 'binaryInput', index: 1, eventClass: 1),
      DnpMapEntry(tag: 'SimulatedAnalog', pointType: 'analogInput', index: 2, eventClass: 2),
    ]),
  );
  return project;
}

/// Per-connection link-layer + transport-layer reassembly and response
/// framing -- a direct reimplementation of `dnp3_host.dart`'s `_Connection`
/// (see that file's doc comment for the full TCP-bytes -> link -> transport
/// -> outstation -> transport -> link pipeline this mirrors).
class _Connection {
  final Socket socket;
  final DnpOutstation outstation;
  final DnpLinkBuffer _linkBuffer = DnpLinkBuffer();
  final DnpTransportReassembler _transport = DnpTransportReassembler();
  bool _closed = false;
  int _pendingBytes = 0;

  _Connection(this.socket, this.outstation);

  void onData(List<int> data) {
    if (_closed) return;
    try {
      _pendingBytes += data.length;
      if (_pendingBytes > _maxPendingBytes) {
        close();
        return;
      }
      final frames = _linkBuffer.add(data);
      if (frames.isNotEmpty) {
        _pendingBytes = 0;
      }
      for (final frame in frames) {
        if (_closed) return;
        _handleFrame(frame);
      }
    } catch (_) {
      close();
    }
  }

  void _handleFrame(DnpLinkFrame frame) {
    if (frame.dest != _kOutstationAddress) {
      return; // Not addressed to this outstation -- silently ignore.
    }
    final appFragment = _transport.addSegment(frame.userData);
    if (appFragment == null) {
      return; // Waiting on more transport segments.
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final response = outstation.handleAppRequest(appFragment, nowMs: nowMs);
    if (response.isEmpty) {
      // A CONFIRM (function code 0) yields an empty response fragment —
      // CONFIRMs never get a reply of their own. Mirrors `dnp3_host.dart`'s
      // identical guard. Critical for the unsolicited leg: without it, an
      // empty fragment would be framed and sent back, confusing the master.
      return;
    }
    for (final respFrame in _buildResponseFrames(response)) {
      if (_closed) return;
      socket.add(respFrame);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _connections.remove(this);
    try {
      socket.destroy();
    } catch (_) {
      // Ignore.
    }
  }
}

/// Splits [appFragment] into one-or-more transport segments and wraps each
/// in a complete `0x0564` link frame addressed from the outstation to the
/// master -- mirrors `dnp3_host.dart`'s `_buildResponseFrames`.
List<Uint8List> _buildResponseFrames(Uint8List appFragment) {
  final frames = <Uint8List>[];
  var offset = 0;
  var seq = 0;
  do {
    final remaining = appFragment.length - offset;
    final chunkLen = remaining < _maxSegmentPayload ? remaining : _maxSegmentPayload;
    final chunk = appFragment.sublist(offset, offset + chunkLen);
    final fir = offset == 0;
    offset += chunkLen;
    final fin = offset >= appFragment.length;
    final segment = buildTransport(seq, fir: fir, fin: fin, appData: chunk);
    frames.add(buildLinkFrame(
      control: _responseLinkControl,
      dest: _kMasterAddress,
      src: _kOutstationAddress,
      userData: segment,
    ));
    seq = (seq + 1) & 0x3F;
  } while (offset < appFragment.length);
  return frames;
}

final List<_Connection> _connections = [];

/// Wraps [appFragment] in transport + link framing (dest = master, src =
/// outstation) and writes it to every live connection — a direct mirror of
/// `dnp3_host.dart`'s `_broadcast`, used by the periodic tick to push
/// unsolicited responses to all connected masters.
void _broadcast(Uint8List appFragment) {
  for (final conn in List<_Connection>.from(_connections)) {
    if (conn._closed) {
      continue;
    }
    for (final frame in _buildResponseFrames(appFragment)) {
      try {
        conn.socket.add(frame);
      } catch (_) {
        // Drop broadcast errors per-connection.
      }
    }
  }
}

/// Periodic change-detection + unsolicited push/retry driver — a direct
/// reimplementation of `dnp3_host.dart`'s `tickForTest`, which the fixture
/// can't import (it lives on `DnpHost extends ChangeNotifier`). Holds the
/// same retry bookkeeping `DnpHost` keeps as instance fields.
class _UnsolDriver {
  final DnpOutstation outstation;
  final int unsolTimeoutMs;
  final int unsolMaxRetries;
  int _unsolSentAtMs = 0;
  int _unsolRetryCount = 0;

  _UnsolDriver(this.outstation, {required this.unsolTimeoutMs, required this.unsolMaxRetries});

  /// One change-detection + unsolicited-push/retry pass. Mirrors
  /// `DnpHost.tickForTest` line-for-line (change detection, CONFIRM-wait
  /// retry up to the cap, then `failUnsolicited`; else the null-then-event
  /// unsolicited push broadcast to every connection).
  void tick(int nowMs) {
    if (_connections.isEmpty) {
      return;
    }
    outstation.detectChanges(nowMs);

    if (outstation.hasUnsolicitedInFlight) {
      if (nowMs - _unsolSentAtMs >= unsolTimeoutMs) {
        if (_unsolRetryCount < unsolMaxRetries) {
          _unsolRetryCount++;
          _unsolSentAtMs = nowMs;
          final bytes = outstation.inFlightUnsolicitedBytes;
          if (bytes != null) {
            _broadcast(bytes);
          }
        } else {
          outstation.failUnsolicited();
          _unsolRetryCount = 0;
        }
      }
      return;
    }

    _unsolRetryCount = 0;
    final frame = outstation.takeNullUnsolicited() ?? outstation.takeEventUnsolicited(nowMs);
    if (frame != null) {
      _unsolSentAtMs = nowMs;
      _broadcast(frame);
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/dnp3_host_probe.dart <port>');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }

  final project = _fixtureProject();
  project.protocols!.dnp3!.port = port;

  ServerSocket serverSocket;
  try {
    serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  } catch (e) {
    stderr.writeln('FAILED TO BIND: $e');
    exit(1);
  }

  final dnp3 = project.protocols!.dnp3!;
  final outstation = DnpOutstation(
    projectProvider: () => project,
    eventBufferPerClass: dnp3.eventBufferPerClass,
  );

  serverSocket.listen((socket) {
    try {
      final conn = _Connection(socket, outstation);
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

  // Establish the change-detection baseline BEFORE any driver tick fires, so
  // the initial values of the two event points don't count as "changes"
  // (mirrors `DnpHost.start` calling nothing until the first tick, whose
  // detectChanges records the baseline without emitting) — here we seed it
  // explicitly so the very first flip below is the first real event.
  outstation.detectChanges(DateTime.now().millisecondsSinceEpoch);

  final driver = _UnsolDriver(
    outstation,
    unsolTimeoutMs: dnp3.unsolConfirmTimeoutMs,
    unsolMaxRetries: dnp3.unsolMaxRetries,
  );

  // Change-detection + unsolicited push/retry tick (~300 ms), mirroring
  // `DnpHost`'s 500 ms production tick but a little faster so the E2E probe
  // observes events promptly.
  final tickTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
    try {
      driver.tick(DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // A tick must never crash the fixture host.
    }
  });

  // Event CHANGE driver (~1 s): flips the dedicated BOOL and increments the
  // dedicated INT32 — and ONLY those two points, never the original five —
  // so a connected master keeps observing changes -> Class 1 / Class 2
  // events. Direct field mutation is what `readPath` (and therefore the event
  // engine's change detection) reads back for these non-forced tags.
  final binTag = project.tags.firstWhere((t) => t.name == 'SimulatedBinary');
  final anaTag = project.tags.firstWhere((t) => t.name == 'SimulatedAnalog');
  final changeTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
    binTag.value = !(binTag.value == true);
    anaTag.value = (anaTag.value is int ? anaTag.value as int : 1000) + 1;
  });

  // ignore: avoid_print
  print('READY DNP3_E2E_FIXTURE');

  // Serve until killed -- SIGINT watched for a graceful Ctrl+C exit;
  // SIGTERM intentionally NOT watched (unsupported on Windows) -- the E2E
  // harness (`tool/dnp3_e2e.sh`) simply kills this process outright when
  // done, fine for a short-lived fixture host with no state to flush.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  tickTimer.cancel();
  changeTimer.cancel();
  await serverSocket.close();
}
