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

  final outstation = DnpOutstation(projectProvider: () => project);

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

  // ignore: avoid_print
  print('READY DNP3_E2E_FIXTURE');

  // Serve until killed -- SIGINT watched for a graceful Ctrl+C exit;
  // SIGTERM intentionally NOT watched (unsupported on Windows) -- the E2E
  // harness (`tool/dnp3_e2e.sh`) simply kills this process outright when
  // done, fine for a short-lived fixture host with no state to flush.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  await serverSocket.close();
}
