// Tests for the dart:io FINS UDP host (mobile/lib/services/fins_host.dart) —
// the suite's FIRST `RawDatagramSocket` host. Uses REAL datagram sockets bound
// to an ephemeral loopback port (port 0). Every test is bounded so a stalled
// server/socket can never hang the suite.
//
// SCOPE: at this task the host serves a Memory Area Read (0x0101) against a
// small built-in fixture image; Read/Write against the real tag map arrives in
// a later task.
//
// These tests prove the host's DATAGRAM handling: one datagram -> one reply to
// the sender, a malformed datagram dropped WITHOUT wedging the bind, and two
// peers answered independently and correlated by the echoed SID. They cannot
// prove wire conformance — every frame here is one this project built — which
// is exactly why `tool/fins_e2e.sh` drives a real third-party client (`fins`)
// against the same shared dispatch at this same task.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_frame.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_memory.dart';
import 'package:soft_plc_mobile/services/fins_host.dart';

/// A minimal project. The Task-3 host serves reads from a built-in fixture
/// image, so the project's contents are not addressed here — it exists only to
/// satisfy `projectProvider` (called fresh per datagram).
PlcProject _hostProject() {
  return PlcProject(
    id: 'proj_fins_host_test',
    name: 'FINS Host Test',
    controllerName: 'PLC_TEST',
    tags: [],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
}

/// Builds a FINS Memory Area Read command datagram exactly as a client sends
/// one: the 10-byte header (`ICF`, `RSV`, `GCT`, then DNA/DA1/DA2, SNA/SA1/SA2,
/// `SID`), the command code 0x0101 (BIG-ENDIAN), then the 6-byte item spec
/// (`area code`, `word address` u16 BIG-ENDIAN, `bit`, `number of items` u16
/// BIG-ENDIAN).
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

/// A UDP client that binds an ephemeral loopback port, sends one datagram to
/// the host, and awaits (up to [timeout]) the single reply datagram. A raw
/// datagram socket is single-subscription, so each request installs and then
/// cancels its own listener.
class _UdpClient {
  final RawDatagramSocket socket;
  _UdpClient(this.socket);

  static Future<_UdpClient> bind() async {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _UdpClient(s);
  }

  /// Sends [data] to the host at [hostPort] and returns the next reply
  /// datagram's bytes, or `null` if none arrives within [timeout].
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

  /// Fire-and-forget: sends [data] with no expectation of a reply.
  void sendOnly(Uint8List data, int hostPort) {
    socket.send(data, InternetAddress.loopbackIPv4, hostPort);
  }

  void close() => socket.close();
}

void main() {
  late FinsHost host;

  setUp(() async {
    host = FinsHost()..port = 0; // ephemeral loopback port
    await host.start(_hostProject);
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
      _memAreaReadCmd(
        areaCode: kFinsAreaDM,
        wordAddress: kFinsFixtureDmWord0Address,
        count: 1,
      ),
      host.boundPort!,
    );

    expect(reply, isNotNull, reason: 'the host must answer a valid read');
    final r = reply!;

    // Response header: the response ICF bit is set (0x80 | 0x40 = 0xC0), and
    // the DNA/DA1/DA2 <-> SNA/SA1/SA2 nodes are SWAPPED (the reply travels back
    // to the requester), with the SID echoed unchanged.
    expect(r[0], 0xC0, reason: 'ICF response bit set on 0x80');
    expect(r[3], 0x04, reason: 'DNA <- request SNA');
    expect(r[4], 0x05, reason: 'DA1 <- request SA1');
    expect(r[5], 0x06, reason: 'DA2 <- request SA2');
    expect(r[6], 0x01, reason: 'SNA <- request DNA');
    expect(r[7], 0x02, reason: 'SA1 <- request DA1');
    expect(r[8], 0x03, reason: 'SA2 <- request DA2');
    expect(r[9], 0x60, reason: 'SID echoed unchanged');

    // Command-code echo (0x0101), NORMAL end code (0x0000), then the word data
    // BIG-ENDIAN. DM word 0 is 0x1234, whose two bytes differ.
    expect(r.sublist(10, 12), [0x01, 0x01], reason: 'command code echoed');
    expect(r.sublist(12, 14), [0x00, 0x00], reason: 'normal end code');
    expect(r.sublist(14), [
      (kFinsFixtureDmWord0Value >> 8) & 0xFF,
      kFinsFixtureDmWord0Value & 0xFF,
    ], reason: 'DM word big-endian');
  });

  test('a malformed/short datagram does NOT crash the bind — a following valid '
      'datagram is still answered', () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    // A datagram far too short to be a FINS command (no header + command code),
    // and a longer non-FINS one: both must be dropped silently.
    client.sendOnly(Uint8List.fromList([0x00, 0x01, 0x02]), host.boundPort!);
    client.sendOnly(
      Uint8List.fromList(List<int>.filled(40, 0xEE)),
      host.boundPort!,
    );

    // The bind must still answer a well-formed read after the bad ones.
    final reply = await client.request(
      _memAreaReadCmd(
        areaCode: kFinsAreaDM,
        wordAddress: kFinsFixtureDmWord1Address,
        count: 1,
      ),
      host.boundPort!,
    );

    expect(reply, isNotNull,
        reason: 'the bind survived the malformed datagrams and still answers');
    expect(host.status, FinsHostStatus.running);
    final r = reply!;
    expect(r.sublist(10, 12), [0x01, 0x01]);
    expect(r.sublist(12, 14), [0x00, 0x00]);
    expect(r.sublist(14), [
      (kFinsFixtureDmWord1Value >> 8) & 0xFF,
      kFinsFixtureDmWord1Value & 0xFF,
    ]);
  });

  test('two peers get independent replies correlated by SID', () async {
    final clientA = await _UdpClient.bind();
    final clientB = await _UdpClient.bind();
    addTearDown(clientA.close);
    addTearDown(clientB.close);

    // Two distinct SIDs from two distinct source ports. Each reply must go back
    // to its own sender AND echo that sender's own SID — never the other's.
    const sidA = 0x11;
    const sidB = 0x22;

    final futureA = clientA.request(
      _memAreaReadCmd(
        sid: sidA,
        areaCode: kFinsAreaDM,
        wordAddress: kFinsFixtureDmWord0Address,
        count: 1,
      ),
      host.boundPort!,
    );
    final futureB = clientB.request(
      _memAreaReadCmd(
        sid: sidB,
        areaCode: kFinsAreaDM,
        wordAddress: kFinsFixtureDmWord1Address,
        count: 1,
      ),
      host.boundPort!,
    );

    final replyA = await futureA;
    final replyB = await futureB;

    expect(replyA, isNotNull);
    expect(replyB, isNotNull);

    // Correlated by SID (byte 9): each peer sees only its own.
    expect(replyA![9], sidA, reason: "peer A's reply echoes peer A's SID");
    expect(replyB![9], sidB, reason: "peer B's reply echoes peer B's SID");

    // And each carries the word it asked for, proving the replies were not
    // swapped between peers.
    expect(replyA.sublist(14), [
      (kFinsFixtureDmWord0Value >> 8) & 0xFF,
      kFinsFixtureDmWord0Value & 0xFF,
    ]);
    expect(replyB.sublist(14), [
      (kFinsFixtureDmWord1Value >> 8) & 0xFF,
      kFinsFixtureDmWord1Value & 0xFF,
    ]);

    expect(host.recentPeerCount, greaterThanOrEqualTo(2),
        reason: 'both source endpoints were seen');
  });

  test('an unsupported area code yields a FINS error end code, not a drop',
      () async {
    final client = await _UdpClient.bind();
    addTearDown(client.close);

    // CIO word area (0xB0) is not in the fixture image, which holds only DM.
    final reply = await client.request(
      _memAreaReadCmd(areaCode: kFinsAreaCIO, wordAddress: 0, count: 1),
      host.boundPort!,
    );

    expect(reply, isNotNull, reason: 'a well-formed read of a missing area '
        'gets an error RESPONSE, not silence');
    final r = reply!;
    expect(r.sublist(10, 12), [0x01, 0x01]);
    // No-area end code (0x1101), no data.
    final endCode = (r[12] << 8) | r[13];
    expect(endCode, kFinsEndNoArea);
    expect(r.length, kFinsHeaderLen + 4, reason: 'error response carries no data');
  });
}
