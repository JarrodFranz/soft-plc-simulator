// Tests for the dart:io SLMP socket host (mobile/lib/services/slmp_host.dart).
// Uses REAL client sockets against a host bound to an ephemeral loopback port
// (port 0) — mirrors s7_host_test.dart. Every test is bounded so a stalled
// server/socket can never hang the suite.
//
// SCOPE: the host serves a Batch Read (word) against the tag-backed image (a
// `SlmpMap.autoGenerate` over the project's tags, Task 4). These tests prove the
// host's length-prefixed REASSEMBLY and DISPATCH behaviour — that a whole frame
// is answered, that a fragmented frame reassembles, that coalesced frames are
// each answered exactly once, and that a malformed frame never wedges the bind.
// The two INT16 tags in `_fixtureProject` auto-generate to D0 and D1, so a read
// of D0 returns a known value through the real tag encode path.
//
// They cannot prove wire conformance — every frame here is one this project
// built — which is exactly why `tool/slmp_e2e.sh` drives a real third-party
// client (`pymcprotocol`) against the SAME shared `dispatchSlmpFrame` at this
// same task.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_commands.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_frame.dart';
import 'package:soft_plc_mobile/services/slmp_host.dart';

/// Accumulates every byte a [Socket] emits behind ONE persistent `listen()`
/// call (a raw `Socket` is single-subscription). Mirrors s7_host_test.dart's
/// collector.
class _SocketCollector {
  final List<int> received = [];
  final List<_ByteWaiter> _waiters = [];
  late final StreamSubscription<Uint8List> _sub;

  _SocketCollector(Socket socket) {
    _sub = socket.listen((data) {
      received.addAll(data);
      _waiters.removeWhere((w) {
        if (received.length >= w.target) {
          if (!w.completer.isCompleted) {
            w.completer.complete();
          }
          return true;
        }
        return false;
      });
    }, onError: (Object _, StackTrace __) {}, cancelOnError: false);
  }

  /// Waits until at least [n] bytes have been received in total, bounded by
  /// [timeout], then returns exactly the first [n] bytes.
  Future<Uint8List> readAtLeast(int n, {Duration timeout = const Duration(seconds: 5)}) async {
    if (received.length < n) {
      final completer = Completer<void>();
      _waiters.add(_ByteWaiter(n, completer));
      await completer.future.timeout(timeout);
    }
    return Uint8List.fromList(received.sublist(0, n));
  }

  Future<void> cancel() => _sub.cancel();
}

class _ByteWaiter {
  final int target;
  final Completer<void> completer;
  _ByteWaiter(this.target, this.completer);
}

// --- Expected on-wire sizes -------------------------------------------------

/// A Batch Read response for 1 word: fixed response header (11) + 1 word (2) =
/// 13 bytes. (Header = subheader 2 + net 1 + pc 1 + destModuleIo 2 +
/// destModuleStation 1 + responseDataLength 2 + endCode 2.)
const int _kOneWordReplyLen = kSlmpResponseFixedLen + 2;

// --- The D-word values the fixture project's two INT16 tags auto-generate to.
// `_fixtureProject`'s `D0Val`/`D1Val` pack into D0/D1 in leaf order.

const int _kD0Value = 0x1234;
const int _kD1Value = 0x5678;

/// Builds a 3E binary Batch Read (word) request for [count] words starting at
/// D[deviceNumber]. Big-endian subheader, little-endian body — exactly what a
/// real client (and `slmp_frame.dart`) put on the wire. The `requestDataLength`
/// counts the bytes that FOLLOW it: timer(2) + command(2) + subcommand(2) +
/// device spec(6) = 12.
Uint8List _buildBatchReadD(int deviceNumber, int count) {
  const requestDataLength = 2 + 2 + 2 + kSlmpDeviceSpecLen; // = 12
  final out = Uint8List(_kLenPrefixEnd + requestDataLength);
  final bd = ByteData.sublistView(out);
  // Subheader BIG-ENDIAN.
  bd.setUint16(0, kSlmpRequestSubheader, Endian.big);
  out[2] = 0x00; // network
  out[3] = 0xFF; // pc
  bd.setUint16(4, 0x03FF, Endian.little); // destModuleIo
  out[6] = 0x00; // destModuleStation
  bd.setUint16(7, requestDataLength, Endian.little); // requestDataLength
  bd.setUint16(9, 0x0000, Endian.little); // monitoringTimer
  bd.setUint16(11, kSlmpCmdBatchReadWord, Endian.little); // command
  bd.setUint16(13, kSlmpSubcmdWord, Endian.little); // subcommand
  // Device spec: 3-byte little-endian device number, 1-byte device code, then
  // little-endian point count.
  out[15] = deviceNumber & 0xFF;
  out[16] = (deviceNumber >> 8) & 0xFF;
  out[17] = (deviceNumber >> 16) & 0xFF;
  out[18] = kSlmpDevD;
  bd.setUint16(19, count, Endian.little);
  return out;
}

/// Offset arithmetic mirror of the host's private length-prefix constants: the
/// requestDataLength field sits at offset 7 and is 2 bytes, so the fixed prefix
/// before the counted body is 9 bytes.
const int _kLenPrefixEnd = 9;

/// Builds a 3E binary Batch Write (word) request writing [values] (one
/// LITTLE-ENDIAN word each) starting at D[deviceNumber]. Same framing as
/// [_buildBatchReadD]; the `requestDataLength` counts timer(2) + command(2) +
/// subcommand(2) + device spec(6) + write data (2 per word).
Uint8List _buildBatchWriteD(int deviceNumber, List<int> values) {
  final requestDataLength = 2 + 2 + 2 + kSlmpDeviceSpecLen + values.length * 2;
  final out = Uint8List(_kLenPrefixEnd + requestDataLength);
  final bd = ByteData.sublistView(out);
  bd.setUint16(0, kSlmpRequestSubheader, Endian.big); // subheader BIG-ENDIAN
  out[2] = 0x00; // network
  out[3] = 0xFF; // pc
  bd.setUint16(4, 0x03FF, Endian.little); // destModuleIo
  out[6] = 0x00; // destModuleStation
  bd.setUint16(7, requestDataLength, Endian.little); // requestDataLength
  bd.setUint16(9, 0x0000, Endian.little); // monitoringTimer
  bd.setUint16(11, kSlmpCmdBatchWriteWord, Endian.little); // command
  bd.setUint16(13, kSlmpSubcmdWord, Endian.little); // subcommand
  out[15] = deviceNumber & 0xFF;
  out[16] = (deviceNumber >> 8) & 0xFF;
  out[17] = (deviceNumber >> 16) & 0xFF;
  out[18] = kSlmpDevD;
  bd.setUint16(19, values.length, Endian.little); // point count
  for (var i = 0; i < values.length; i++) {
    bd.setUint16(21 + i * 2, values[i], Endian.little); // write words, LE
  }
  return out;
}

/// Reads the little-endian word at data offset [wordIndex] out of a Batch Read
/// response (words start at [kSlmpResponseFixedLen]).
int _responseWord(Uint8List response, int wordIndex) {
  final bd = ByteData.sublistView(response);
  return bd.getUint16(kSlmpResponseFixedLen + wordIndex * 2, Endian.little);
}

/// A project whose two INT16 tags auto-generate (in leaf order) to D0 and D1,
/// so the host's tag-backed image serves known values through the real tag
/// encode path. Values have differing bytes so a byte-order fault cannot pass
/// unnoticed.
PlcProject _fixtureProject() => PlcProject(
      id: 'proj_slmp_host_test',
      name: 'SLMP Host Test',
      controllerName: 'PLC_TEST',
      tags: [
        PlcTag(name: 'D0Val', path: 'D0Val', dataType: 'INT16', value: _kD0Value, ioType: 'Internal'),
        PlcTag(name: 'D1Val', path: 'D1Val', dataType: 'INT16', value: _kD1Value, ioType: 'Internal'),
      ],
      structDefs: [],
      programs: [],
      tasks: [],
      hmis: [],
    );

Future<Socket> _connect(SlmpHost host) {
  final endpoint = Uri.parse(host.endpointUrl!);
  return Socket.connect('127.0.0.1', endpoint.port);
}

void main() {
  late SlmpHost host;

  setUp(() {
    host = SlmpHost()..port = 0; // ephemeral loopback port
  });

  tearDown(() async {
    await host.stop();
    host.dispose();
  });

  test('start on port 0 binds an ephemeral port and reports running', () async {
    await host.start(_fixtureProject);
    expect(host.status, SlmpHostStatus.running);
    expect(host.endpointUrl, isNotNull);
    expect(host.endpointUrl, startsWith('slmp-tcp://'));
    expect(Uri.parse(host.endpointUrl!).port, greaterThan(0));
  });

  test('a whole Batch Read frame gets a correct response', () async {
    await host.start(_fixtureProject);
    final socket = await _connect(host);
    final collector = _SocketCollector(socket);

    socket.add(_buildBatchReadD(0, 1));
    await socket.flush();

    final response = await collector.readAtLeast(_kOneWordReplyLen);
    // Response subheader is BIG-ENDIAN (0xD000 -> 0xD0, 0x00).
    expect(response.sublist(0, 2), equals(Uint8List.fromList([0xD0, 0x00])));
    // End code (LE) at offset 9 = normal.
    final bd = ByteData.sublistView(response);
    expect(bd.getUint16(9, Endian.little), kSlmpEndNormal);
    // The word data, little-endian, is the tag D0Val encoded at D0.
    expect(_responseWord(response, 0), _kD0Value);

    await collector.cancel();
    socket.destroy();
  });

  test('a Batch Write updates a mapped tag, observed by a following read', () async {
    final project = _fixtureProject();
    await host.start(() => project);
    final socket = await _connect(host);
    final collector = _SocketCollector(socket);

    // Write a NEW value to D0 (the auto-generated address of tag D0Val).
    const newValue = 0x4321;
    socket.add(_buildBatchWriteD(0, const [newValue]));
    await socket.flush();

    // The Batch Write response is the fixed header + end code only (no data).
    final writeReply = await collector.readAtLeast(kSlmpResponseFixedLen);
    final bd = ByteData.sublistView(writeReply);
    expect(bd.getUint16(9, Endian.little), kSlmpEndNormal);

    // The underlying tag was mutated in place.
    expect(project.tags.firstWhere((t) => t.name == 'D0Val').value, newValue);

    // And an INDEPENDENT read now observes the written value. The read reply
    // follows the write reply (kSlmpResponseFixedLen bytes) in the stream.
    socket.add(_buildBatchReadD(0, 1));
    await socket.flush();
    final both =
        await collector.readAtLeast(kSlmpResponseFixedLen + _kOneWordReplyLen);
    final readReply = Uint8List.sublistView(both, kSlmpResponseFixedLen);
    expect(_responseWord(readReply, 0), newValue);

    await collector.cancel();
    socket.destroy();
  });

  test('a fragmented frame (split mid-header and mid-body) reassembles', () async {
    await host.start(_fixtureProject);
    final socket = await _connect(host);
    final collector = _SocketCollector(socket);

    final frame = _buildBatchReadD(0, 2); // read D0 and D1
    // Split into three chunks: mid-header (before the length field is fully
    // buffered), mid-body (after the length field but before the whole frame),
    // then the remainder — each with a small gap so they arrive separately.
    socket.add(frame.sublist(0, 5));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    socket.add(frame.sublist(5, 12));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    socket.add(frame.sublist(12));
    await socket.flush();

    const replyLen = kSlmpResponseFixedLen + 2 * 2; // 2 words
    final response = await collector.readAtLeast(replyLen);
    expect(response.sublist(0, 2), equals(Uint8List.fromList([0xD0, 0x00])));
    expect(_responseWord(response, 0), _kD0Value);
    expect(_responseWord(response, 1), _kD1Value);

    await collector.cancel();
    socket.destroy();
  });

  test('two coalesced frames in one chunk both get answered exactly once', () async {
    await host.start(_fixtureProject);
    final socket = await _connect(host);
    final collector = _SocketCollector(socket);

    // Two single-word reads back-to-back in ONE write.
    final two = BytesBuilder()
      ..add(_buildBatchReadD(0, 1))
      ..add(_buildBatchReadD(0, 1));
    socket.add(two.toBytes());
    await socket.flush();

    // Exactly two responses' worth of bytes.
    final both = await collector.readAtLeast(_kOneWordReplyLen * 2);
    // Both replies decode correctly.
    final first = Uint8List.sublistView(both, 0, _kOneWordReplyLen);
    final second = Uint8List.sublistView(both, _kOneWordReplyLen, _kOneWordReplyLen * 2);
    expect(_responseWord(first, 0), _kD0Value);
    expect(_responseWord(second, 0), _kD0Value);

    // Settle, then assert NO third reply arrived (a double-dispatch bug would
    // produce more than two).
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(collector.received.length, _kOneWordReplyLen * 2);

    await collector.cancel();
    socket.destroy();
  });

  test('a malformed/short frame does NOT crash the bind', () async {
    await host.start(_fixtureProject);

    // Connection 1: send a complete but UNSERVED frame — a valid length prefix
    // whose command code (0x0000) this host does not serve, so the dispatch
    // returns null and the frame is dropped with no reply.
    final bad = Uint8List(_kLenPrefixEnd + 6); // requestDataLength = 6 -> total 15
    final badBd = ByteData.sublistView(bad);
    badBd.setUint16(0, kSlmpRequestSubheader, Endian.big); // subheader
    bad[3] = 0xFF; // pc (rest left zero, incl. command 0x0000)
    badBd.setUint16(7, 6, Endian.little); // requestDataLength = 6 (timer + cmd + subcmd)
    final conn1 = await _connect(host);
    conn1.add(bad);
    await conn1.flush();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // Also feed a genuinely SHORT fragment (fewer than the length prefix) that
    // can never complete — it must sit buffered, not crash.
    conn1.add(Uint8List.fromList([0x50, 0x00, 0x00]));
    await conn1.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The bind must still accept a fresh client and answer a valid read.
    final conn2 = await _connect(host);
    final collector2 = _SocketCollector(conn2);
    conn2.add(_buildBatchReadD(0, 1));
    await conn2.flush();
    final response = await collector2.readAtLeast(_kOneWordReplyLen);
    expect(_responseWord(response, 0), _kD0Value);
    expect(host.status, SlmpHostStatus.running);

    await collector2.cancel();
    conn1.destroy();
    conn2.destroy();
  });
}
