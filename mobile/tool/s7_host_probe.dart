// A tiny `dart run` CLI that hosts S7comm (TPKT/COTP + S7 PDU) over a real
// `ServerSocket`, prints `READY` on listening, then serves until killed. Used
// by `tool/s7_e2e.sh` as the Dart half of the v1 S7comm workstream's Task 3
// EARLY E2E machine-proof: a REAL third-party client — the Python
// `python-snap7` library, driven by `tool/py/s7_probe.py` — connects here and
// completes the COTP Connection Request -> Connection Confirm and S7 Setup
// Communication handshake.
//
// WHY A REAL CLIENT RUNS AT ALL: every S7comm unit test in this repo
// exercises frames our own codec built, which proves self-consistency, not
// conformance. This fixture is where a client written independently of us
// reads our wire bytes. It ran at Task 3 for connect+negotiate — before any
// read/write logic existed — and now also serves Read Var / Write Var, so the
// probe can prove a full read -> write -> independent read-back.
//
// IMPORTANT: this does NOT import `services/s7_host.dart`. `S7Host extends
// ChangeNotifier` (`package:flutter/foundation.dart`), which transitively
// pulls in Flutter/`dart:ui` machinery unavailable under a plain `dart run`
// (only `flutter test`'s harness provides a `dart:ui` shim, and this must run
// as a standalone process) — see `mobile/tool/enip_host_probe.dart`, whose
// identical note this mirrors.
//
// *** HOW THIS STAYS FAITHFUL TO THE SHIPPED HOST ***
// The COTP/Setup path below mirrors `S7Host._Connection` line for line (that
// file is authoritative; if the two ever diverge, it wins). The Read Var /
// Write Var path is NOT mirrored at all — it is SHARED: both this fixture and
// `S7Host` call the single pure `dispatchS7VarJob`
// (`protocols/s7/s7_services.dart`), which builds every response byte. So the
// bytes `python-snap7` validates here are, by construction rather than by
// diff, the same bytes the shipped app puts on the wire.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/s7_host_probe.dart <port>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/s7_map.dart';
import 'package:soft_plc_mobile/protocols/s7/s7_pdu.dart';
import 'package:soft_plc_mobile/protocols/s7/s7_services.dart';
import 'package:soft_plc_mobile/protocols/s7/tpkt_cotp.dart';

// --- Fixture tag values the probe asserts against ---------------------------
//
// These are the values `tool/py/s7_probe.py` expects to READ before it writes
// anything. Keep the two files in step: the probe names each constant it
// depends on in a comment.

/// `Running` — DB1 byte 0, bit 0. Starts FALSE so the probe's bit write to
/// TRUE is an observable change.
const bool _runningInitialValue = false;

/// `Alarm` — DB1 byte 0, bit 3. Starts TRUE. Sharing byte 0 with `Running` is
/// deliberate: it proves a single-bit write does not disturb its neighbours.
const bool _alarmInitialValue = true;

/// `Count16` — DB1 bytes 2..3 (INT16). A value whose two bytes DIFFER, so a
/// byte-order error cannot pass unnoticed: 0x1234.
const int _count16InitialValue = 0x1234;

/// `Speed` — DB1 bytes 4..7 (INT32), all four bytes distinct.
const int _speedInitialValue = 0x01020304;

/// `Level` — DB1 bytes 8..11 (FLOAT64 narrowed to a 4-byte S7 REAL). Exactly
/// representable in float32, so the narrowing does not blur the assertion.
const double _levelInitialValue = 12.5;

/// `Total64` — DB1 bytes 16..23 (INT64).
const int _total64InitialValue = 0x0102030405060708;

/// `Temp` — DB1 bytes 24..25 (INT16), mapped ReadOnly: the probe asserts a
/// write here is REFUSED and the value is unchanged.
const int _tempInitialValue = 250;

/// `Forced_Speed` — DB1 bytes 28..31 (INT32), mapped ReadWrite but FORCED, so
/// the refusal must come from the force check rather than the map's access
/// mode. Reads see the FORCED value.
const int _forcedSpeedLive = 1;
const int _forcedSpeedForced = 777;

/// `MFlag` — M byte 0, bit 1 (merker area, NOT a data block).
const bool _mFlagInitialValue = false;

/// `MCount` — M bytes 2..3 (INT16), the multi-byte numeric in the second area.
const int _mCountInitialValue = 0x0A0B;

/// Builds the fixture project the E2E probe expects: two AREAS (a data block
/// and the merker area), BOOL bits sharing a byte, multi-byte numerics whose
/// bytes all differ, plus a ReadOnly entry and a forced tag for the refusal
/// paths. Offsets are pinned EXPLICITLY here rather than taken from
/// `S7Map.autoGenerate`, so the probe can address literal byte offsets and a
/// future change to the auto-layout cannot silently move them.
PlcProject _fixtureProject() {
  final project = PlcProject(
    id: 'proj_s7_e2e_fixture',
    name: 'S7comm E2E Fixture',
    controllerName: 'PLC_E2E',
    tags: [
      PlcTag(name: 'Running', path: 'Internal.Running', dataType: 'BOOL', value: _runningInitialValue, ioType: 'Internal'),
      PlcTag(name: 'Alarm', path: 'Internal.Alarm', dataType: 'BOOL', value: _alarmInitialValue, ioType: 'Internal'),
      PlcTag(name: 'Count16', path: 'Internal.Count16', dataType: 'INT16', value: _count16InitialValue, ioType: 'Internal'),
      PlcTag(name: 'Speed', path: 'Internal.Speed', dataType: 'INT32', value: _speedInitialValue, ioType: 'Internal'),
      PlcTag(name: 'Level', path: 'Internal.Level', dataType: 'FLOAT64', value: _levelInitialValue, ioType: 'Internal'),
      PlcTag(name: 'Total64', path: 'Internal.Total64', dataType: 'INT64', value: _total64InitialValue, ioType: 'Internal'),
      PlcTag(name: 'Temp', path: 'Inputs.Temp', dataType: 'INT16', value: _tempInitialValue, ioType: 'Internal'),
      PlcTag(
        name: 'Forced_Speed',
        path: 'Internal.Forced_Speed',
        dataType: 'INT32',
        value: _forcedSpeedLive,
        ioType: 'Internal',
        isForced: true,
        forcedValue: _forcedSpeedForced,
      ),
      PlcTag(name: 'MFlag', path: 'Internal.MFlag', dataType: 'BOOL', value: _mFlagInitialValue, ioType: 'Internal'),
      PlcTag(name: 'MCount', path: 'Internal.MCount', dataType: 'INT16', value: _mCountInitialValue, ioType: 'Internal'),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );

  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.s7 = S7ProtocolConfig(
    enabled: true,
    port: 102, // overwritten in main() with the real bound port before use
    map: S7Map(entries: [
      // --- DB1 ---------------------------------------------------------
      S7MapEntry(tag: 'Running', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 0, bitOffset: 0),
      S7MapEntry(tag: 'Alarm', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 0, bitOffset: 3),
      S7MapEntry(tag: 'Count16', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 2),
      S7MapEntry(tag: 'Speed', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 4),
      S7MapEntry(tag: 'Level', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 8),
      // Byte 12..15 is deliberately UNMAPPED — a gap, which must read 0x00
      // and discard writes.
      S7MapEntry(tag: 'Total64', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 16),
      // Mapped ReadOnly: a write here must be refused, value unchanged.
      S7MapEntry(tag: 'Temp', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 24, access: 'ReadOnly'),
      // Mapped ReadWrite but the TAG is forced: the refusal must come from
      // the force check in `applyAreaWrite`, not from the access mode.
      S7MapEntry(tag: 'Forced_Speed', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 28),
      // --- Merker area (a SECOND area, with no data-block number) -------
      S7MapEntry(tag: 'MFlag', area: kS7AreaNameMerker, dbNumber: 0, byteOffset: 0, bitOffset: 1),
      S7MapEntry(tag: 'MCount', area: kS7AreaNameMerker, dbNumber: 0, byteOffset: 2),
    ]),
  );
  return project;
}

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

  void onData(List<int> data, PlcProject Function() projectProvider) {
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
        _handleFrame(frame, projectProvider);
      }
    } catch (_) {
      close();
    }
  }

  void _handleFrame(Uint8List frame, PlcProject Function() projectProvider) {
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
      _handleS7(cotp.payload, projectProvider);
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

  void _handleS7(Uint8List s7Bytes, PlcProject Function() projectProvider) {
    final msg = parseS7(s7Bytes);
    if (msg == null) {
      return;
    }
    if (msg.header.rosctr != kS7RosctrJob) {
      return;
    }
    if (msg.parameter.isEmpty) {
      return;
    }
    if (msg.parameter[0] != kS7FunctionSetupCommunication) {
      // Read Var / Write Var — the SHARED definition, byte-for-byte the one
      // `S7Host` uses (see this file's header).
      final project = projectProvider();
      final reply = dispatchS7VarJob(
        project,
        project.protocols?.s7?.map ?? S7Map(entries: []),
        msg,
        negotiatedPduLength: negotiatedPduLength,
      );
      if (reply == null) {
        return;
      }
      socket.add(buildTpkt(buildCotpData(reply)));
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

  final project = _fixtureProject();

  ServerSocket serverSocket;
  try {
    serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  } catch (e) {
    stderr.writeln('FAILED TO BIND: $e');
    exit(1);
  }
  project.protocols!.s7!.port = serverSocket.port;

  serverSocket.listen((socket) {
    try {
      final conn = _Connection(socket, _allocateLocalRef());
      _connections.add(conn);
      socket.listen(
        (data) {
          try {
            conn.onData(data, () => project);
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
