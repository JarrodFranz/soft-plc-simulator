// Tests for the dart:io FINS UDP host (mobile/lib/services/fins_host.dart) —
// the suite's FIRST `RawDatagramSocket` host. Uses REAL datagram sockets bound
// to an ephemeral loopback port (port 0). Every test is bounded so a stalled
// server/socket can never hang the suite.
//
// SCOPE: the host serves Memory Area Read (0x0101) and Write (0x0102) against
// an image backed by the project's tags via `FinsMap` (auto-generated per
// datagram). The project below declares two INT16 tags and one ReadOnly INT16
// tag; `FinsMap.autoGenerate` packs them into DM words 0, 1 and 2 in leaf
// order, which is what these tests address.
//
// These tests prove the host's DATAGRAM handling: one datagram -> one reply to
// the sender, a malformed datagram dropped WITHOUT wedging the bind, two peers
// answered independently and correlated by the echoed SID, and a write that
// lands / is refused. They cannot prove wire conformance — every frame here is
// one this project built — which is why `tool/fins_e2e.sh` drives a real
// third-party client (`fins`) against the same shared dispatch.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_frame.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_memory.dart';
import 'package:soft_plc_mobile/services/fins_host.dart';

// DM word addresses the auto-generated map assigns to the fixture tags, in
// declaration order. Each seeded word's two bytes DIFFER so a byte-order fault
// cannot pass a read-back.
const int _w0Address = 0;
const int _w0Value = 0x1234;
const int _w1Address = 1;
const int _w1Value = 0x5678;
const int _lockedAddress = 2;

/// A project with two writable INT16 tags and one ReadOnly INT16 tag. Built
/// once per test (see [setUp]) and shared by reference through `projectProvider`
/// so a Memory Area Write lands and a following read observes it.
PlcProject _buildHostProject() {
  return PlcProject(
    id: 'proj_fins_host_test',
    name: 'FINS Host Test',
    controllerName: 'PLC_TEST',
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    tags: [
      PlcTag(name: 'W0', path: 'W0', dataType: 'INT16', value: _w0Value, ioType: 'Internal'),
      PlcTag(name: 'W1', path: 'W1', dataType: 'INT16', value: _w1Value, ioType: 'Internal'),
      PlcTag(name: 'Locked', path: 'Locked', dataType: 'INT16', value: 42, ioType: 'Internal', access: 'ReadOnly'),
    ],
  );
}

/// Builds a FINS Memory Area Read command datagram: 10-byte header, command
/// code 0x0101 (BIG-ENDIAN), then the 6-byte item spec.
Uint8List _memAreaReadCmd({
  int icf = 0x80,
  int sid = 0x60,
  int dna = 0x01,
  int da1 = 0x02,
  int da2 = 0x03,
  int sna = 0x04,
  int sa1 = 0x05,
  int sa2 = 0x06,
  required int areaCode,
  required int wordAddress,
  int bit = 0,
  required int count,
}) {
  final out = <int>[
    icf, 0x00, 0x07, dna, da1, da2, sna, sa1, sa2, sid, // header
    0x01, 0x01, // command code: Memory Area Read (BIG-ENDIAN)
    areaCode,
    (wordAddress >> 8) & 0xFF, wordAddress & 0xFF,
    bit,
    (count >> 8) & 0xFF, count & 0xFF,
  ];
  return Uint8List.fromList(out);
}

/// Builds a FINS Memory Area Write command datagram: the same header + 6-byte
/// item spec as a read, command code 0x0102, then `count` BIG-ENDIAN words.
Uint8List _memAreaWriteCmd({
  int sid = 0x60,
  required int areaCode,
  required int wordAddress,
  required List<int> words,
}) {
  final out = <int>[
    0x80, 0x00, 0x07, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, sid, // header
    0x01, 0x02, // command code: Memory Area Write (BIG-ENDIAN)
    areaCode,
    (wordAddress >> 8) & 0xFF, wordAddress & 0xFF,
    0x00, // bit
    (words.length >> 8) & 0xFF, words.length & 0xFF,
  ];
  for (final w in words) {
    out.add((w >> 8) & 0xFF);
    out.add(w & 0xFF);
  }
  return Uint8List.fromList(out);
}

/// A UDP client that binds an ephemeral loopback port, sends one datagram to
/// the host, and awaits (up to [timeout]) the single reply datagram.
class _UdpClient {
  final RawDatagramSocket socket;
  _UdpClient(this.socket);

  static Future<_UdpClient> bind() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _UdpClient(s);
  }

  Future<Uint8List?> request(
    Uint8List data,
    int hostPort, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final completer = Completer<Uint8List?>();
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final dg = socket.receive();
      if (dg != null && !completer.isCompleted) {
        completer.complete(dg.data);
      }
    });
    socket.send(data, InternetAddress.loopbackIPv4, hostPort);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      await sub.cancel();
    }
  }

  void sendOnly(Uint8List data, int hostPort) {
    socket.send(data, InternetAddress.loopbackIPv4, hostPort);
  }

  void close() => socket.close();
}

void main() {
  late FinsHost host;
  late PlcProject project;

  setUp(() async {
    project = _buildHostProject();
    host = FinsHost()..port = 0; // ephemeral loopback port
    await host.start(() => project);
    expect(host.status, FinsHostStatus.running,
        reason: 'host should bind and run: ${host.lastError}');
    expect(host.boundPort, isNotNull);
    expect(host.endpointUrl, isNotNull);
  });

  tearDown(() async {
    await host.stop();
    expect(host.status, FinsHostStatus.stopped);
  });

  test('a Memory Area Read datagram gets a correct response datagram', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    final reply = await client.request(
      _memAreaReadCmd(areaCode: kFinsAreaDM, wordAddress: _w0Address, count: 1),
      host.boundPort!,
    );

    expect(reply, isNotNull, reason: 'the host must answer a valid read');
    final r = reply!;

    // Response header: the response ICF bit is set (0x80 | 0x40 = 0xC0), the
    // DNA/DA1/DA2 <-> SNA/SA1/SA2 nodes are SWAPPED, the SID echoed unchanged.
    expect(r[0], 0xC0, reason: 'ICF response bit set on 0x80');
    expect(r[3], 0x04, reason: 'DNA <- request SNA');
    expect(r[4], 0x05, reason: 'DA1 <- request SA1');
    expect(r[5], 0x06, reason: 'DA2 <- request SA2');
    expect(r[6], 0x01, reason: 'SNA <- request DNA');
    expect(r[7], 0x02, reason: 'SA1 <- request DA1');
    expect(r[8], 0x03, reason: 'SA2 <- request DA2');
    expect(r[9], 0x60, reason: 'SID echoed unchanged');

    // Command-code echo (0x0101), NORMAL end code (0x0000), then the tag value
    // BIG-ENDIAN. W0 is 0x1234, whose two bytes differ.
    expect(r.sublist(10, 12), [0x01, 0x01], reason: 'command code echoed');
    expect(r.sublist(12, 14), [0x00, 0x00], reason: 'normal end code');
    expect(r.sublist(14), [(_w0Value >> 8) & 0xFF, _w0Value & 0xFF],
        reason: 'DM word big-endian');
  });

  test('a malformed/short datagram does NOT crash the bind — a following valid '
      'datagram is still answered', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    client.sendOnly(Uint8List.fromList([0x00, 0x01, 0x02]), host.boundPort!);
    client.sendOnly(Uint8List.fromList(List<int>.filled(40, 0xEE)), host.boundPort!);

    final reply = await client.request(
      _memAreaReadCmd(areaCode: kFinsAreaDM, wordAddress: _w1Address, count: 1),
      host.boundPort!,
    );

    expect(reply, isNotNull,
        reason: 'the bind survived the malformed datagrams and still answers');
    expect(host.status, FinsHostStatus.running);
    final r = reply!;
    expect(r.sublist(10, 12), [0x01, 0x01]);
    expect(r.sublist(12, 14), [0x00, 0x00]);
    expect(r.sublist(14), [(_w1Value >> 8) & 0xFF, _w1Value & 0xFF]);
  });

  test('two peers get independent replies correlated by SID', () async {
    final clientA = await _UdpClient.bind();
    final clientB = await _UdpClient.bind();
    addTearDown(clientA.close);
    addTearDown(clientB.close);

    const sidA = 0x11;
    const sidB = 0x22;

    final futureA = clientA.request(
      _memAreaReadCmd(sid: sidA, areaCode: kFinsAreaDM, wordAddress: _w0Address, count: 1),
      host.boundPort!,
    );
    final futureB = clientB.request(
      _memAreaReadCmd(sid: sidB, areaCode: kFinsAreaDM, wordAddress: _w1Address, count: 1),
      host.boundPort!,
    );

    final replyA = await futureA;
    final replyB = await futureB;

    expect(replyA, isNotNull);
    expect(replyB, isNotNull);

    expect(replyA![9], sidA, reason: "peer A's reply echoes peer A's SID");
    expect(replyB![9], sidB, reason: "peer B's reply echoes peer B's SID");

    expect(replyA.sublist(14), [(_w0Value >> 8) & 0xFF, _w0Value & 0xFF]);
    expect(replyB.sublist(14), [(_w1Value >> 8) & 0xFF, _w1Value & 0xFF]);

    expect(host.recentPeerCount, greaterThanOrEqualTo(2),
        reason: 'both source endpoints were seen');
  });

  test('an unknown area code yields a FINS error end code, not a drop', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    // 0x00 is not a served FINS word-area code.
    final reply = await client.request(
      _memAreaReadCmd(areaCode: 0x00, wordAddress: 0, count: 1),
      host.boundPort!,
    );

    expect(reply, isNotNull, reason: 'a well-formed read of an unknown area '
        'gets an error RESPONSE, not silence');
    final r = reply!;
    expect(r.sublist(10, 12), [0x01, 0x01]);
    final endCode = (r[12] << 8) | r[13];
    expect(endCode, kFinsEndNoArea);
    expect(r.length, kFinsHeaderLen + 4, reason: 'error response carries no data');
  });

  test('a Memory Area Write lands on the tag and a following read observes it', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    final writeReply = await client.request(
      _memAreaWriteCmd(areaCode: kFinsAreaDM, wordAddress: _w0Address, words: [0x00AB]),
      host.boundPort!,
    );
    expect(writeReply, isNotNull);
    final wr = writeReply!;
    expect(wr.sublist(10, 12), [0x01, 0x02], reason: 'write command echoed');
    expect(wr.sublist(12, 14), [0x00, 0x00], reason: 'normal end code');
    expect(wr.length, kFinsHeaderLen + 4, reason: 'a write response carries no data');

    // The tag itself changed...
    expect(readPath(project, 'W0'), 0x00AB);
    // ...and a read now returns the new value. A raw datagram socket is
    // single-subscription (it cannot be re-listened after a cancel), so the
    // read-back uses a fresh client.
    final reader = await _UdpClient.bind();
    addTearDown(reader.close);
    final readReply = await reader.request(
      _memAreaReadCmd(areaCode: kFinsAreaDM, wordAddress: _w0Address, count: 1),
      host.boundPort!,
    );
    expect(readReply!.sublist(14), [0x00, 0xAB]);
  });

  test('a Memory Area Write to a ReadOnly tag is refused with NOT-WRITABLE, tag unchanged', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    final reply = await client.request(
      _memAreaWriteCmd(areaCode: kFinsAreaDM, wordAddress: _lockedAddress, words: [0x0063]),
      host.boundPort!,
    );

    expect(reply, isNotNull);
    final r = reply!;
    expect(r.sublist(10, 12), [0x01, 0x02]);
    final endCode = (r[12] << 8) | r[13];
    expect(endCode, kFinsEndNotWritable, reason: 'a refused write reports not-writable');
    expect(readPath(project, 'Locked'), 42, reason: 'the refused write must not land');
  });
}
