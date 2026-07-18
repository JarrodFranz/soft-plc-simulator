// A tiny `dart run` CLI that builds a small fixture project in code (a RW
// coil, a forced RW coil, a RW holding INT16, a struct-member INT32 mapped
// across two holding registers, and a RO input INT16), hosts it over a real
// `ServerSocket` (MBAP-length-prefixed frame reassembly, same rules as
// `mobile/lib/services/modbus_host.dart`), prints `READY` on listening, then
// serves until killed. Used by `tool/modbus_e2e.sh` as the Dart half of the
// WS24 Task 4 E2E machine-proof (a real Rust `tokio-modbus`-crate client,
// `gateway/examples/modbus_probe.rs`, connects here) and by the
// "Protocol Interop Fixes" workstream's Task 4 as the falsifiable proof that
// (a) a forced tag's value reads through to Modbus and (b) a dotted
// struct-member map entry (`Motor.Speed`) decodes at the correct register
// width/value.
//
// Also hosts the simulated-test-tags workstream's Task 8 E2E machine-proof:
// a small `buildTestSet` (2 phase-staggered `ramp` tags) appended onto the
// same Modbus map via `appendToModbusMap`, driven every tick by
// `applySignalGens` on a real `Timer.periodic` (mirroring
// `scan_tick.dart`'s per-scan call), so a real external client can observe
// (a) two simultaneously-read, phase-staggered generated tags differing and
// (b) one generated tag's value changing between two reads spaced apart in
// wall-clock time — see `_appendGeneratedRampTestSet` below.
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
// version this mirrors. Likewise, `protocols/modbus/modbus_rtu.dart` (CRC-16,
// `buildRtu`/`parseRtu`/`rtuRequestLength`) is also pure Dart with zero
// Flutter dependency, so the optional RTU-over-TCP framing path below
// reimplements just the small RTU reassembly loop `ModbusHost`'s
// `_Connection._onDataRtu` uses — see that file for the authoritative
// version this mirrors.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/modbus_host_probe.dart <port> [tcp|rtuOverTcp]
//   The second argument selects the wire framing, mirroring
//   `ModbusProtocolConfig.framing`; defaults to `tcp` (classic MBAP-header
//   Modbus TCP, unchanged from before this option existed) when omitted.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/signal_engine.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart' show writePath;
import 'package:soft_plc_mobile/models/test_tag_set.dart';
import 'package:soft_plc_mobile/protocols/modbus/modbus_pdu.dart';
import 'package:soft_plc_mobile/protocols/modbus/modbus_rtu.dart';

/// The Modbus TCP spec caps a whole ADU (MBAP header + PDU) at 260 bytes —
/// mirrors `modbus_host.dart`'s `_maxFrameBytes` guard.
const int _maxFrameBytes = 260;

/// Value the `Speed` holding-register tag is mutated to at T+3s after
/// `READY`, entirely independently of any client connection — this is what
/// the Rust probe (`gateway/examples/modbus_probe.rs`) polls
/// `read_holding_registers(0, 1)` for, proving a real server-side change is
/// observable over the wire (not merely an echo of a client-issued write).
const int _mutatedSpeedValue = 4242;

/// Value the `Forced_Bool` tag is force-read as, over the map's coil
/// address 1 -- the falsifiable proof (Task 4) that a tag's `isForced`
/// state reaches Modbus reads: the tag's live `value` is `false`, so a
/// non-force-aware read would report `0`/`false`, but `forcedValue` is
/// `true` and `readPath` (the same force-aware resolver the scan engine,
/// OPC UA server, and Modbus register handler all read through) always
/// prefers `forcedValue` for a forced scalar tag.
const bool _forcedCoilValue = true;

/// Value the `Motor.Speed` struct-member field is initialized to, read back
/// over the map's holding registers 1-2 as an INT32 (high-word-first) --
/// the Task 4 proof that a dotted struct-member map entry decodes at the
/// correct register width/value, not just a top-level scalar tag.
const int _structMemberSpeedValue = 9001;

/// Generated test-set parameters (simulated-test-tags workstream, Task 8
/// E2E). Two `ramp` tags, phase-staggered half a period apart, ranging
/// [0, 1000] over a 20s period -- long enough that the probe (which runs in
/// well under a second after `READY`) never crosses the wrap point, short
/// enough that a few-hundred-ms gap between two reads produces a clearly
/// non-zero delta (~1000 * dt/20000 = ~15 for a 300ms gap).
const int _rampTestSetCount = 2;
const double _rampMin = 0;
const double _rampMax = 1000;
const int _rampPeriodMs = 20000;

/// Input-register addresses the two generated ramp tags land on via
/// `appendToModbusMap`'s next-free-address bookkeeping. Derived, not
/// arbitrary: the fixture's only pre-existing `input`-table entry is `Temp`
/// at address 0, and `appendToModbusMap` conservatively reserves the
/// worst-case width (`ModbusMap.regsForType('FLOAT64')` == 4 registers) for
/// every existing register-table entry regardless of its real type, so the
/// next free `input` address is 4 -- `Ramp1` lands at 4 (4 registers, since
/// `ramp` tags are FLOAT64), `Ramp2` immediately after at 8. See
/// `gateway/examples/modbus_probe.rs`, which reads these same fixed
/// addresses.
const int rampInputAddr1 = 4;
const int rampInputAddr2 = 8;

/// Builds the `buildTestSet` ramp fixture and appends it onto both
/// `project.tags`/`project.signalGens` and the Modbus map, asserting the
/// computed addresses match the documented constants above (so a future
/// change to the fixture's other entries -- or to `appendToModbusMap`'s
/// bookkeeping -- fails loudly here instead of silently desyncing the Rust
/// probe's hardcoded addresses).
void _appendGeneratedRampTestSet(PlcProject project) {
  final testSet = buildTestSet(TestSetSpec(
    folder: 'E2ESim',
    baseName: 'Ramp',
    count: _rampTestSetCount,
    type: 'ramp',
    minValue: _rampMin,
    maxValue: _rampMax,
    periodMs: _rampPeriodMs,
  ));
  project.tags.addAll(testSet.tags);
  project.signalGens.addAll(testSet.gens);
  appendToModbusMap(project.protocols!.modbus!.map, testSet.tags);

  final entryByTag = {for (final e in project.protocols!.modbus!.map.entries) e.tag: e};
  final ramp1 = entryByTag['Ramp1'];
  final ramp2 = entryByTag['Ramp2'];
  if (ramp1 == null || ramp1.table != 'input' || ramp1.address != rampInputAddr1 ||
      ramp2 == null || ramp2.table != 'input' || ramp2.address != rampInputAddr2) {
    stderr.writeln(
        'FIXTURE INVARIANT BROKEN: expected Ramp1 @ input:$rampInputAddr1 and '
        'Ramp2 @ input:$rampInputAddr2, got Ramp1=$ramp1 Ramp2=$ramp2 -- update '
        'the addresses in both this file and gateway/examples/modbus_probe.rs');
    exit(1);
  }
}

/// Builds the fixture project the E2E probe expects:
///   - `Start_PB`   : BOOL,  ReadWrite -> coil address 0
///   - `Forced_Bool` : BOOL, ReadWrite -> coil address 1, isForced=true/
///     forcedValue=true (Task 4 forced-coil proof)
///   - `Speed`      : INT16, ReadWrite -> holding address 0 (mutated to 4242 at T+3s)
///   - `Motor`      : struct (`MotorType { Speed: INT32 }`) -> `Motor.Speed`
///     mapped to holding addresses 1-2 (Task 4 struct-member proof)
///   - `Temp`       : INT16, ReadOnly  -> input address 0
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
        name: 'Forced_Bool',
        path: 'Internal.Forced_Bool',
        dataType: 'BOOL',
        value: false,
        ioType: 'Internal',
        isForced: true,
        forcedValue: _forcedCoilValue,
      ),
      PlcTag(
        name: 'Speed',
        path: 'Internal.Speed',
        dataType: 'INT16',
        value: 100,
        ioType: 'Internal',
      ),
      PlcTag(
        name: 'Motor',
        path: 'Internal.Motor',
        dataType: 'MotorType',
        value: {'Speed': _structMemberSpeedValue},
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
    structDefs: [
      PlcStructDef(name: 'MotorType', fields: [
        StructFieldDef(name: 'Speed', dataType: 'INT32', defaultValue: 0),
      ]),
    ],
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
      ModbusMapEntry(tag: 'Forced_Bool', table: 'coil', address: 1, access: 'ReadWrite'),
      ModbusMapEntry(tag: 'Speed', table: 'holding', address: 0, access: 'ReadWrite'),
      ModbusMapEntry(tag: 'Motor.Speed', table: 'holding', address: 1, access: 'ReadOnly'),
      ModbusMapEntry(tag: 'Temp', table: 'input', address: 0, access: 'ReadOnly'),
    ]),
  );
  return project;
}

/// Per-connection byte-frame reassembly, mirroring `ModbusHost`'s
/// `_Connection` (see `mobile/lib/services/modbus_host.dart`): for the
/// default `tcp` framing, accumulate arbitrary TCP chunks; once at least 6
/// bytes are present, `length = (buf[4]<<8)|buf[5]` (the MBAP length field)
/// tells us the total frame size is `6 + length`; once the buffer holds that
/// many bytes, slice it, decode via `parseMbap`, dispatch through [handle],
/// and write the `buildMbap`-wrapped response back. For `rtuOverTcp` framing,
/// [rtuRequestLength] derives the total frame length from the function code
/// instead (RTU carries no length field), and frames are decoded/encoded via
/// [parseRtu]/[buildRtu] — mirroring `ModbusHost`'s `_onDataRtu` exactly.
class _Connection {
  final Socket socket;
  final Uint8List? Function(ModbusFrame) handle;

  /// Wire framing mode for this connection — `kModbusFramingTcp` (the
  /// existing MBAP-header reassembly, unmodified) or
  /// `kModbusFramingRtuOverTcp` (RTU framing: no MBAP header, CRC-16 framed,
  /// function-code-derived length).
  final String framing;
  final List<int> _buffer = [];
  bool _closed = false;

  _Connection(this.socket, this.handle, {this.framing = kModbusFramingTcp});

  void onData(List<int> data) {
    if (_closed) return;
    _buffer.addAll(data);
    try {
      if (framing == kModbusFramingRtuOverTcp) {
        _onDataRtu();
      } else {
        _onDataTcp();
      }
    } catch (_) {
      close();
    }
  }

  /// The original Modbus TCP (MBAP header) reassembly path — unchanged from
  /// before the RTU-over-TCP framing option existed.
  void _onDataTcp() {
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
      if (responsePdu != null) {
        final responseFrame = buildMbap(parsed.transactionId, parsed.unitId, responsePdu);
        socket.add(responseFrame);
      }
    }
  }

  /// The Modbus RTU-over-TCP reassembly path: no MBAP header, so the total
  /// frame length is derived purely from the function code (and, for the
  /// variable-length write-multiple codes, the byteCount field) via
  /// [rtuRequestLength]. A bad-CRC frame (or a resync after an unsupported
  /// function code) is dropped silently (no reply, connection stays open)
  /// rather than closing the connection — mirrors `ModbusHost`'s
  /// `_onDataRtu`. Unit id 0 (broadcast) is likewise never replied to, even
  /// though [handle] still runs and any write still takes effect.
  void _onDataRtu() {
    while (true) {
      final buf = Uint8List.fromList(_buffer);
      final total = rtuRequestLength(buf);
      if (total == null) {
        return; // need more bytes to decide the frame length
      }
      if (total < 0 || total > _maxFrameBytes) {
        // Unsupported function code or an oversized/hostile frame: resync by
        // dropping everything buffered for this connection so far.
        _buffer.clear();
        return;
      }
      if (_buffer.length < total) {
        return; // wait for more bytes
      }
      final rawFrame = Uint8List.fromList(_buffer.sublist(0, total));
      _buffer.removeRange(0, total);

      final parsed = parseRtu(rawFrame);
      if (parsed == null) {
        // Bad CRC: drop this frame silently and keep the connection open.
        _buffer.clear();
        return;
      }
      final responsePdu = handle(parsed);
      // Unit id 0 is the RTU broadcast address: the request is still
      // executed (handle() ran above, so any write took effect), but a real
      // RTU outstation MUST NOT reply to a broadcast — staying silent is
      // part of the protocol, not an error case. Replying here would hand a
      // master its own unexpected broadcast echo, which it would then
      // consume as the response to whatever unicast request it sends next,
      // desyncing every subsequent transaction on the link.
      if (responsePdu != null && parsed.unitId != 0) {
        socket.add(buildRtu(parsed.unitId, responsePdu));
      }
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
    stderr.writeln('usage: dart run tool/modbus_host_probe.dart <port> [tcp|rtuOverTcp]');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }
  final framing = args.length > 1 ? args[1] : kModbusFramingTcp;
  if (framing != kModbusFramingTcp && framing != kModbusFramingRtuOverTcp) {
    stderr.writeln('invalid framing argument: $framing (expected tcp or rtuOverTcp)');
    exit(64);
  }

  final project = _fixtureProject();
  project.protocols!.modbus!.port = port;
  project.protocols!.modbus!.framing = framing;
  _appendGeneratedRampTestSet(project);

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
      final conn = _Connection(socket, server.handle, framing: framing);
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

  // Simulated-test-tags workstream, Task 8 E2E: drive the generated ramp
  // tags' `SignalGen`s every tick, exactly as `scan_tick.dart`'s
  // `runScanTick` drives `p.signalGens` every real scan (same function,
  // same per-tick `dtMs` accounting via `SignalRuntime`). This is what makes
  // `Ramp1`/`Ramp2`'s input-register values actually move over wall-clock
  // time for the Rust probe to observe.
  const signalTickMs = 100;
  final signalRuntime = SignalRuntime();
  Timer.periodic(const Duration(milliseconds: signalTickMs), (_) {
    applySignalGens(project, project.signalGens, signalTickMs, signalRuntime);
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
