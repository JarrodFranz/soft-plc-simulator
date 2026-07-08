// A tiny `dart run` CLI that builds a small fixture project in code (a RW
// coil, a RW holding INT16, and a RO input INT16), hosts it over a real
// `ServerSocket` (MBAP-length-prefixed frame reassembly, same rules as
// `mobile/lib/services/modbus_host.dart`), prints `READY` on listening, then
// serves until killed. Used ONLY by `tool/modbus_e2e.sh` as the Dart half of
// the WS24 Task 4 E2E machine-proof (a real Rust `tokio-modbus`-crate
// client, `gateway/examples/modbus_probe.rs`, connects here).
//
// IMPORTANT: this does NOT import `services/modbus_host.dart`. `ModbusHost
// extends ChangeNotifier` (`package:flutter/foundation.dart`), which
// transitively pulls in Flutter/`dart:ui` machinery unavailable under a
// plain `dart run` (only `flutter test`'s harness provides a `dart:ui`
// shim, and this must run as a standalone process) — see
// `mobile/tool/opcua_host_probe.dart`'s identical note, which this mirrors.
// The wire codec + register-file handler
// (`protocols/modbus/modbus_pdu.dart`) is pure Dart with zero Flutter
// dependency, so this tool talks to `ModbusServer`/`parseMbap`/`buildMbap`
// directly, reimplementing just the same small MBAP reassembly loop
// `ModbusHost`'s `_Connection` uses — see that file for the authoritative
// version this mirrors.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/modbus_host_probe.dart <port>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart' show writePath;
import 'package:soft_plc_mobile/protocols/modbus/modbus_pdu.dart';

/// The Modbus TCP spec caps a whole ADU (MBAP header + PDU) at 260 bytes —
/// mirrors `modbus_host.dart`'s `_maxFrameBytes` guard.
const int _maxFrameBytes = 260;

/// Value the `Speed` holding-register tag is mutated to at T+3s after
/// `READY`, entirely independently of any client connection — this is what
/// the Rust probe (`gateway/examples/modbus_probe.rs`) polls
/// `read_holding_registers(0, 1)` for, proving a real server-side change is
/// observable over the wire (not merely an echo of a client-issued write).
const int _mutatedSpeedValue = 4242;

/// Builds the fixture project the E2E probe expects:
///   - `Start_PB` : BOOL,  ReadWrite -> coil address 0
///   - `Speed`    : INT16, ReadWrite -> holding address 0 (mutated to 4242 at T+3s)
///   - `Temp`     : INT16, ReadOnly  -> input address 0
PlcProject _fixtureProject() {
  final project = PlcProject(
    id: 'proj_modbus_e2e_fixture',
    name: 'Modbus E2E Fixture',
    controllerName: 'PLC_E2E',
    tags: [
      PlcTag(
        name: 'Start_PB',
        path: 'Inputs.Start_PB',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'Speed',
        path: 'Internal.Speed',
        dataType: 'INT16',
        value: 100,
        ioType: 'Internal',
      ),
      PlcTag(
        name: 'Temp',
        path: 'Inputs.Temp',
        dataType: 'INT16',
        value: 55,
        ioType: 'SimulatedOutput',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );

  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.modbus = ModbusProtocolConfig(
    enabled: true,
    port: 502, // overwritten in main() with the real bound port before use
    map: ModbusMap(entries: [
      ModbusMapEntry(tag: 'Start_PB', table: 'coil', address: 0, access: 'ReadWrite'),
      ModbusMapEntry(tag: 'Speed', table: 'holding', address: 0, access: 'ReadWrite'),
      ModbusMapEntry(tag: 'Temp', table: 'input', address: 0, access: 'ReadOnly'),
    ]),
  );
  return project;
}

/// Per-connection byte-frame reassembly, mirroring `ModbusHost`'s
/// `_Connection` (see `mobile/lib/services/modbus_host.dart`): accumulate
/// arbitrary TCP chunks; once at least 6 bytes are present, `length =
/// (buf[4]<<8)|buf[5]` (the MBAP length field) tells us the total frame
/// size is `6 + length`; once the buffer holds that many bytes, slice it,
/// decode via `parseMbap`, dispatch through [handle], and write the
/// `buildMbap`-wrapped response back.
class _Connection {
  final Socket socket;
  final Uint8List Function(ModbusFrame) handle;
  final List<int> _buffer = [];
  bool _closed = false;

  _Connection(this.socket, this.handle);

  void onData(List<int> data) {
    if (_closed) return;
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < 6) {
          return; // not even the length field yet
        }
        final length = (_buffer[4] << 8) | _buffer[5];
        final totalSize = 6 + length;
        if (length < 1 || totalSize > _maxFrameBytes) {
          close();
          return;
        }
        if (_buffer.length < totalSize) {
          return; // wait for more bytes
        }
        final rawFrame = Uint8List.fromList(_buffer.sublist(0, totalSize));
        _buffer.removeRange(0, totalSize);

        final parsed = parseMbap(rawFrame);
        if (parsed == null) {
          close();
          return;
        }
        final responsePdu = handle(parsed);
        final responseFrame = buildMbap(parsed.transactionId, parsed.unitId, responsePdu);
        socket.add(responseFrame);
      }
    } catch (_) {
      close();
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

/// The list of currently-live connections (tracked only so [_Connection]
/// can remove itself on close — Modbus v1 has no clock-driven push, unlike
/// the OPC UA fixture host, so nothing else iterates this list).
final List<_Connection> _connections = [];

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/modbus_host_probe.dart <port>');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }

  final project = _fixtureProject();
  project.protocols!.modbus!.port = port;

  ServerSocket serverSocket;
  try {
    serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  } catch (e) {
    stderr.writeln('FAILED TO BIND: $e');
    exit(1);
  }

  final server = ModbusServer(projectProvider: () => project);

  serverSocket.listen((socket) {
    try {
      final conn = _Connection(socket, server.handle);
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
  print('READY MODBUS_E2E_FIXTURE');

  // WS24 Task 4 E2E: mutate the served project's `Speed` holding-register
  // tag server-side (via the same `writePath` other fixtures/tests use), on
  // a fixed schedule after READY, entirely independently of any client
  // connection. This is what the Rust `tokio-modbus` client probe
  // (`gateway/examples/modbus_probe.rs`) polls
  // `read_holding_registers(0, 1)` for. `Timer` is fine here: this is a
  // `dart run` dev/test tool, not app code.
  Timer(const Duration(seconds: 3), () {
    writePath(project, 'Speed', _mutatedSpeedValue);
    // ignore: avoid_print
    print('[fixture host] mutated Speed -> $_mutatedSpeedValue at T+3s');
  });

  // Serve until killed. SIGINT is watched for a graceful Ctrl+C exit;
  // SIGTERM is intentionally NOT watched here (unsupported on Windows and
  // throws asynchronously if attempted) — the E2E harness
  // (`tool/modbus_e2e.sh`) simply kills this process outright when done,
  // which is fine for a short-lived fixture host with no state to flush.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  await serverSocket.close();
}
