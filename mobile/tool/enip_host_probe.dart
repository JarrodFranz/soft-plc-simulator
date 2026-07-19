// A tiny `dart run` CLI that builds a small fixture project in code (one tag
// of every CIP-mappable type, plus a forced tag and a ReadOnly-mapped tag),
// hosts it over a real `ServerSocket` speaking EtherNet/IP encapsulation +
// CIP explicit messaging, prints `READY` on listening, then serves until
// killed. Used by `tool/enip_e2e.sh` as the Dart half of the v1 EtherNet/IP
// + CIP workstream's Task 6 E2E machine-proof: a REAL third-party client —
// the Python `pycomm3` library, driven by `tool/py/enip_probe.py` — connects
// here and performs RegisterSession -> Forward Open -> Read Tag -> Write Tag
// -> independent read-back -> Forward Close.
//
// IMPORTANT: this does NOT import `services/enip_host.dart`. `EnipHost
// extends ChangeNotifier` (`package:flutter/foundation.dart`), which
// transitively pulls in Flutter/`dart:ui` machinery unavailable under a
// plain `dart run` (only `flutter test`'s harness provides a `dart:ui`
// shim, and this must run as a standalone process) — see
// `mobile/tool/modbus_host_probe.dart` and `mobile/tool/opcua_host_probe.dart`,
// whose identical notes this mirrors. The whole EtherNet/IP + CIP codec
// (`protocols/enip/enip_encap.dart`, `cip.dart`, `cip_connection.dart`,
// `cip_tags.dart`) and the `CipMap` exposure model
// (`models/cip_map.dart`) are pure Dart with zero Flutter dependency, so
// this tool talks to them directly, reimplementing just the same small
// encapsulation-header reassembly + command-dispatch loop `EnipHost`'s
// `_Connection` uses — see `mobile/lib/services/enip_host.dart` for the
// authoritative version this mirrors. If the two ever diverge, that file
// wins and this one must be updated to match.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/enip_host_probe.dart <port>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/models/cip_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_connection.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_tags.dart';
import 'package:soft_plc_mobile/protocols/enip/enip_encap.dart';

/// Encapsulation-layer status codes, mirroring `enip_host.dart`'s private
/// constants of the same names.
const int _kEncapStatusUnsupportedCommand = 0x01;
const int _kEncapStatusIncorrectData = 0x03;
const int _kEncapStatusInvalidSessionHandle = 0x64;

/// Hostile/garbage frame-size guard — mirrors `enip_host.dart`.
const int _maxFrameBytes = kEnipHeaderLen + 0xFFFF;

// --- Fixture tag values the Python probe asserts against --------------------
//
// Each of these is read by `tool/py/enip_probe.py` at its documented name;
// changing one here without changing it there breaks the E2E.

/// `Speed` (INT32 -> CIP DINT 0xC4), ReadWrite. The probe reads this, writes
/// [_speedWrittenValue] to it, then INDEPENDENTLY reads it back and asserts
/// the exact written value — the read -> write -> read-back proof.
const int _speedInitialValue = 100;

/// The value the probe writes to `Speed`. Deliberately not the initial
/// value, and outside 16-bit range, so a truncating/aliasing bug in the
/// DINT path cannot pass by accident.
const int _speedWrittenValue = 123456;

/// `Running` (BOOL -> CIP BOOL 0xC1), ReadWrite.
const bool _runningInitialValue = true;

/// `Count16` (INT16 -> CIP INT 0xC3), ReadWrite.
const int _count16InitialValue = -1234;

/// `Total64` (INT64 -> CIP LINT 0xC5), ReadWrite.
const int _total64InitialValue = 8589934592; // 2^33: needs the full 64 bits.

/// `Level` (FLOAT64 -> CIP REAL 0xCA, a NARROWING conversion to IEEE-754
/// single precision). Chosen to be exactly representable as a float32 so the
/// probe can assert an exact value and still document the narrowing.
const double _levelInitialValue = 12.5;

/// `Temp` (FLOAT64), mapped ReadOnly — the probe asserts a Write Tag against
/// it is REFUSED with CIP general status 0x0F (Privilege Violation).
const double _tempInitialValue = 21.75;

/// `Forced_Speed` (INT32), forced. `readPath` reports [_forcedSpeedForced]
/// (the forced value), not [_forcedSpeedLive] — and a write is refused with
/// 0x0F. Both are asserted by the probe: the force-aware read-through and
/// the force-aware VISIBLE write refusal.
const int _forcedSpeedLive = 1;
const int _forcedSpeedForced = 777;

/// Builds the fixture project the E2E probe expects. Every mapped tag's
/// name is a bare (non-dotted) symbol so the probe's CIP EPATH is a single
/// ANSI Extended Symbol segment — v1's symbolic tag addressing.
PlcProject _fixtureProject() {
  final project = PlcProject(
    id: 'proj_enip_e2e_fixture',
    name: 'EtherNet/IP E2E Fixture',
    controllerName: 'PLC_E2E',
    tags: [
      PlcTag(name: 'Running', path: 'Internal.Running', dataType: 'BOOL', value: _runningInitialValue, ioType: 'Internal'),
      PlcTag(name: 'Count16', path: 'Internal.Count16', dataType: 'INT16', value: _count16InitialValue, ioType: 'Internal'),
      PlcTag(name: 'Speed', path: 'Internal.Speed', dataType: 'INT32', value: _speedInitialValue, ioType: 'Internal'),
      PlcTag(name: 'Total64', path: 'Internal.Total64', dataType: 'INT64', value: _total64InitialValue, ioType: 'Internal'),
      PlcTag(name: 'Level', path: 'Internal.Level', dataType: 'FLOAT64', value: _levelInitialValue, ioType: 'Internal'),
      PlcTag(name: 'Temp', path: 'Inputs.Temp', dataType: 'FLOAT64', value: _tempInitialValue, ioType: 'SimulatedOutput'),
      PlcTag(
        name: 'Forced_Speed',
        path: 'Internal.Forced_Speed',
        dataType: 'INT32',
        value: _forcedSpeedLive,
        ioType: 'Internal',
        isForced: true,
        forcedValue: _forcedSpeedForced,
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );

  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.ethernetIp = CipProtocolConfig(
    enabled: true,
    port: 44818, // overwritten in main() with the real bound port before use
    map: CipMap(entries: [
      CipMapEntry(tagName: 'Running', access: 'ReadWrite'),
      CipMapEntry(tagName: 'Count16', access: 'ReadWrite'),
      CipMapEntry(tagName: 'Speed', access: 'ReadWrite'),
      CipMapEntry(tagName: 'Total64', access: 'ReadWrite'),
      CipMapEntry(tagName: 'Level', access: 'ReadWrite'),
      // Deliberately ReadOnly: the probe asserts a Write Tag here is refused
      // with 0x0F and leaves the value unchanged.
      CipMapEntry(tagName: 'Temp', access: 'ReadOnly'),
      // Mapped ReadWrite, but the tag itself is FORCED: the refusal must
      // come from the force check, not from the map's access mode.
      CipMapEntry(tagName: 'Forced_Speed', access: 'ReadWrite'),
      // NOTE: `Unexposed` is deliberately absent from this map — the probe
      // asserts a read of a name that is not mapped returns 0x05.
    ]),
  );
  return project;
}

/// Per-connection encapsulation-frame reassembly and dispatch, mirroring
/// `EnipHost`'s `_Connection` (see `mobile/lib/services/enip_host.dart` —
/// the authoritative version). Accumulates arbitrary TCP chunks; once at
/// least `kEnipHeaderLen` (24) bytes are present the header's own `length`
/// field says the whole frame is `kEnipHeaderLen + length` bytes; once that
/// many bytes are buffered the frame is sliced off, decoded, dispatched, and
/// the reply written back.
class _Connection {
  final Socket socket;
  final CipConnectionManager connMgr = CipConnectionManager();
  final List<int> _buffer = [];
  bool _closed = false;
  int? sessionHandle;

  _Connection(this.socket);

  void onData(
    List<int> data,
    PlcProject Function() projectProvider,
    int Function() allocateSessionHandle,
  ) {
    if (_closed) {
      return;
    }
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < kEnipHeaderLen) {
          return;
        }
        final headerBytes = Uint8List.fromList(_buffer.sublist(0, kEnipHeaderLen));
        final header = parseEnipHeader(headerBytes);
        if (header == null) {
          close();
          return;
        }
        final total = kEnipHeaderLen + header.length;
        if (total > _maxFrameBytes) {
          close();
          return;
        }
        if (_buffer.length < total) {
          return;
        }
        final frame = Uint8List.fromList(_buffer.sublist(0, total));
        _buffer.removeRange(0, total);
        _handleFrame(frame, header, projectProvider, allocateSessionHandle);
      }
    } catch (_) {
      close();
    }
  }

  void _handleFrame(
    Uint8List frame,
    EnipHeader header,
    PlcProject Function() projectProvider,
    int Function() allocateSessionHandle,
  ) {
    final data = Uint8List.sublistView(frame, kEnipHeaderLen);
    switch (header.command) {
      case kEnipCommandNop:
        return;
      case kEnipCommandRegisterSession:
        _handleRegisterSession(header, data, allocateSessionHandle);
        return;
      case kEnipCommandUnRegisterSession:
        _handleUnRegisterSession(header);
        return;
      case kEnipCommandSendRRData:
        _handleSendRRData(header, data, projectProvider);
        return;
      case kEnipCommandSendUnitData:
        _handleSendUnitData(header, data, projectProvider);
        return;
      default:
        socket.add(_reply(header, _kEncapStatusUnsupportedCommand, Uint8List(0)));
    }
  }

  void _handleRegisterSession(
    EnipHeader header,
    Uint8List data,
    int Function() allocateSessionHandle,
  ) {
    if (sessionHandle != null) {
      connMgr.releaseAll();
    }
    final handle = allocateSessionHandle();
    sessionHandle = handle;
    final replyHeader = EnipHeader(
      command: kEnipCommandRegisterSession,
      length: data.length,
      sessionHandle: handle,
      status: 0,
      senderContext: header.senderContext,
      options: 0,
    );
    socket.add(buildEnipFrame(replyHeader, data));
  }

  void _handleUnRegisterSession(EnipHeader header) {
    if (sessionHandle != null && header.sessionHandle == sessionHandle) {
      connMgr.releaseAll();
      sessionHandle = null;
    }
  }

  void _handleSendRRData(
    EnipHeader header,
    Uint8List data,
    PlcProject Function() projectProvider,
  ) {
    if (sessionHandle == null || header.sessionHandle != sessionHandle) {
      socket.add(_reply(header, _kEncapStatusInvalidSessionHandle, Uint8List(0)));
      return;
    }
    if (data.length < 6) {
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    final items = parseCpf(Uint8List.sublistView(data, 6));
    if (items == null) {
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    Uint8List? cipBytes;
    for (final item in items) {
      if (item.typeId == kCpfTypeUnconnectedData) {
        cipBytes = item.data;
        break;
      }
    }
    if (cipBytes == null) {
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    final req = parseCipRequest(cipBytes);
    if (req == null) {
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }

    final CipResponse resp;
    if (req.service == kCipServiceForwardOpen) {
      resp = connMgr.forwardOpen(req);
    } else if (req.service == kCipServiceForwardClose) {
      resp = connMgr.forwardClose(req);
    } else {
      final project = projectProvider();
      resp = dispatchCipService(project, _currentMap(project), req);
    }

    final replyCpfBytes = buildCpf([
      CpfItem(typeId: kCpfTypeNullAddress, data: Uint8List(0)),
      CpfItem(typeId: kCpfTypeUnconnectedData, data: buildCipResponse(resp)),
    ]);
    final replyData = Uint8List(6 + replyCpfBytes.length);
    replyData.setRange(6, replyData.length, replyCpfBytes);
    socket.add(_reply(header, 0, replyData));
  }

  void _handleSendUnitData(
    EnipHeader header,
    Uint8List data,
    PlcProject Function() projectProvider,
  ) {
    if (sessionHandle == null || header.sessionHandle != sessionHandle) {
      socket.add(_reply(header, _kEncapStatusInvalidSessionHandle, Uint8List(0)));
      return;
    }
    if (data.length < 6) {
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    final items = parseCpf(Uint8List.sublistView(data, 6));
    if (items == null) {
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }

    int? connectionId;
    Uint8List? connectedData;
    for (final item in items) {
      if (item.typeId == kCpfTypeConnectedAddress && item.data.length >= 4) {
        connectionId = ByteData.sublistView(item.data, 0, 4).getUint32(0, Endian.little);
      } else if (item.typeId == kCpfTypeConnectedData) {
        connectedData = item.data;
      }
    }
    if (connectionId == null || connectedData == null || connectedData.length < 2) {
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }

    final conn = connMgr.byConnectionId(connectionId);
    if (conn == null) {
      socket.add(_reply(header, _kEncapStatusInvalidSessionHandle, Uint8List(0)));
      return;
    }

    // Sequence count is only ever needed locally for this one request/reply
    // pair, so it is tracked in the local `seq` variable below rather than
    // on the connection object — mirrors `enip_host.dart`.
    final seq = ByteData.sublistView(connectedData, 0, 2).getUint16(0, Endian.little);
    final cipBytes = Uint8List.sublistView(connectedData, 2);
    final req = parseCipRequest(cipBytes);

    final CipResponse resp;
    if (req == null) {
      resp = CipResponse(service: 0x00, generalStatus: kCipStatusServiceNotSupported, data: Uint8List(0));
    } else {
      final project = projectProvider();
      resp = dispatchCipService(project, _currentMap(project), req);
    }

    final respBytes = buildCipResponse(resp);
    final connectedReplyData = Uint8List(2 + respBytes.length);
    ByteData.sublistView(connectedReplyData, 0, 2).setUint16(0, seq, Endian.little);
    connectedReplyData.setRange(2, connectedReplyData.length, respBytes);

    // Connected Address item on the reply must carry the T->O id the
    // originator allocated and consumes — mirrors `enip_host.dart`'s fix;
    // see cip_connection.dart:20-38 for the consumer-allocates rule.
    final addrItemData = Uint8List(4);
    ByteData.sublistView(addrItemData).setUint32(0, conn.connectionIdTO, Endian.little);

    final replyCpfBytes = buildCpf([
      CpfItem(typeId: kCpfTypeConnectedAddress, data: addrItemData),
      CpfItem(typeId: kCpfTypeConnectedData, data: connectedReplyData),
    ]);
    final replyData = Uint8List(6 + replyCpfBytes.length);
    replyData.setRange(6, replyData.length, replyCpfBytes);
    socket.add(_reply(header, 0, replyData));
  }

  CipMap _currentMap(PlcProject project) => project.protocols?.ethernetIp?.map ?? CipMap(entries: []);

  Uint8List _reply(EnipHeader reqHeader, int status, Uint8List data) {
    final replyHeader = EnipHeader(
      command: reqHeader.command,
      length: data.length,
      sessionHandle: reqHeader.sessionHandle,
      status: status,
      senderContext: reqHeader.senderContext,
      options: 0,
    );
    return buildEnipFrame(replyHeader, data);
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    connMgr.releaseAll();
    _connections.remove(this);
    try {
      socket.destroy();
    } catch (_) {
      // Ignore.
    }
  }
}

/// Live connections (tracked only so [_Connection] can remove itself on
/// close — EtherNet/IP v1 has no clock-driven push, so nothing else
/// iterates this list).
final List<_Connection> _connections = [];

/// One monotonic session-handle counter shared by every accepted socket —
/// mirrors `EnipHost._allocateSessionHandle`.
int _nextSessionHandle = 1;

int _allocateSessionHandle() {
  final handle = _nextSessionHandle;
  _nextSessionHandle += 1;
  return handle;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/enip_host_probe.dart <port>');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }

  final project = _fixtureProject();
  project.protocols!.ethernetIp!.port = port;

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
            conn.onData(data, () => project, _allocateSessionHandle);
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
  print('READY enip-tcp://127.0.0.1:${serverSocket.port}');

  // Serve until killed. SIGINT is watched for a graceful Ctrl+C exit;
  // SIGTERM is intentionally NOT watched (unsupported on Windows and throws
  // asynchronously if attempted) — the E2E harness (`tool/enip_e2e.sh`)
  // simply kills this process outright when done, which is fine for a
  // short-lived fixture host with no state to flush.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  await serverSocket.close();
}
