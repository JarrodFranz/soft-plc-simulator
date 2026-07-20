// Byte-exact fixtures for the SLMP 3E binary command/response frame codec
// (mobile/lib/protocols/slmp/slmp_frame.dart) — the bottom layer of the SLMP
// stack: the fixed routing header + command/response envelope that later
// layers (batch read/write commands, the device image, the TCP host, the
// tag map) build on.
//
// CRITICAL #1: SLMP 3E binary is LITTLE-ENDIAN for its body, with ONE
// documented exception — the 2-byte `subheader` is BIG-ENDIAN (0x5000 ->
// bytes `0x50, 0x00`; 0xD000 -> `0xD0, 0x00`). This is what the real
// `pymcprotocol` client emits (`type3e.py`: `subheader.to_bytes(2, "big")`,
// everything else `"little"`) and it settled an earlier draft that wrongly
// wrote the subheader little-endian. The two area protocols built immediately
// before this one in this repo — S7comm (protocols/s7/) and Omron FINS
// (protocols/fins/) — are both BIG-ENDIAN throughout. Do NOT pattern-match an
// `Endian.big` from either neighbouring file onto a body field. A pure build
// -> parse round trip CANNOT catch an endianness bug (it cancels out perfectly
// even when fully broken), so every fixture below asserts literal expected
// bytes against a hand-built buffer, and the command fixture uses two
// DIFFERENT bytes (0x01, 0x04 -> 0x0401, NOT 0x0104) so a big-endian
// implementation fails instead of silently passing.
//
// CRITICAL #2: buildSlmpResponse does NOT echo the request verbatim. It
// emits the RESPONSE subheader (0xD000, not the request's 0x5000), the
// request's routing echoed back, and a `responseDataLength` that counts a
// DIFFERENT span than the request's `requestDataLength` (end code + data,
// not monitoring timer + command + subcommand + data). Getting that length
// field wrong is exactly the kind of framing bug a real SLMP client's
// length checks catch immediately — this fixture asserts the literal bytes
// including that field.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_frame.dart';

void main() {
  group('parseSlmpRequest', () {
    test('decodes a hand-built little-endian request, exact fields', () {
      final bytes = Uint8List.fromList([
        0x50, 0x00, // subheader = 0x5000 (BIG-ENDIAN)
        0x01, // network
        0xFF, // pc (host station)
        0xFF, 0x03, // destModuleIo = 0x03FF (LE)
        0x00, // destModuleStation
        0x0A, 0x00, // requestDataLength = 10 (LE): timer(2)+cmd(2)+subcmd(2)+data(4)
        0x10, 0x00, // monitoringTimer = 0x0010 (LE)
        0x01, 0x04, // command bytes: 0x01 then 0x04
        0x02, 0x00, // subcommand = 0x0002 (LE)
        0xAA, 0xBB, 0xCC, 0xDD, // data
      ]);

      final frame = parseSlmpRequest(bytes);
      expect(frame, isNotNull);
      expect(frame!.header.network, 0x01);
      expect(frame.header.pc, 0xFF);
      expect(frame.header.destModuleIo, 0x03FF);
      expect(frame.header.destModuleStation, 0x00);
      expect(frame.header.monitoringTimer, 0x0010);
      expect(frame.command, 0x0401); // little-endian: 0x01 low byte, 0x04 high byte
      expect(frame.command, isNot(0x0104)); // canary: fails if read big-endian
      expect(frame.subcommand, 0x0002);
      expect(frame.data, equals(Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD])));
    });

    test('reads destModuleIo 0xFF, 0x03 as 0x03FF — NOT 0xFF03 (little-endian canary)', () {
      final bytes = Uint8List.fromList([
        0x50, 0x00, // subheader (BIG-ENDIAN)
        0x00, // network
        0xFF, // pc
        0xFF, 0x03, // destModuleIo bytes: 0xFF then 0x03
        0x00, // destModuleStation
        0x06, 0x00, // requestDataLength = 6 (no data)
        0x00, 0x00, // monitoringTimer
        0x00, 0x00, // command
        0x00, 0x00, // subcommand
      ]);

      final frame = parseSlmpRequest(bytes);
      expect(frame, isNotNull);
      expect(frame!.header.destModuleIo, 0x03FF);
      expect(frame.header.destModuleIo, isNot(0xFF03));
    });

    test('returns null for a buffer shorter than kSlmpRequestFixedLen, no throw', () {
      expect(kSlmpRequestFixedLen, 15);
      // 14 bytes: one short of the required 15 (fixed header through subcommand).
      final tooShort = Uint8List.fromList(List<int>.filled(14, 0));
      expect(() => parseSlmpRequest(tooShort), returnsNormally);
      expect(parseSlmpRequest(tooShort), isNull);

      final empty = Uint8List(0);
      expect(() => parseSlmpRequest(empty), returnsNormally);
      expect(parseSlmpRequest(empty), isNull);
    });

    test('parses successfully at exactly kSlmpRequestFixedLen bytes with empty data', () {
      final bytes = Uint8List.fromList([
        0x50, 0x00, // subheader (BIG-ENDIAN)
        0x01, // network
        0xFF, // pc
        0xFF, 0x03, // destModuleIo
        0x00, // destModuleStation
        0x06, 0x00, // requestDataLength = 6 (no data)
        0x00, 0x00, // monitoringTimer
        0x01, 0x04, // command = 0x0401
        0x02, 0x00, // subcommand = 0x0002
      ]);
      final frame = parseSlmpRequest(bytes);
      expect(frame, isNotNull);
      expect(frame!.command, 0x0401);
      expect(frame.subcommand, 0x0002);
      expect(frame.data, equals(Uint8List(0)));
    });
  });

  group('buildSlmpResponse', () {
    test('emits 0xD000 subheader, echoed routing, correct responseDataLength, endCode, '
        'and data — asserted against literal bytes', () {
      final requestHeader = SlmpHeader(
        network: 0x01,
        pc: 0xFF,
        destModuleIo: 0x03FF,
        destModuleStation: 0x00,
        monitoringTimer: 0x0010,
      );

      final response = buildSlmpResponse(
        requestHeader: requestHeader,
        endCode: kSlmpEndNormal,
        data: Uint8List.fromList([0x11, 0x22]),
      );

      expect(
        response,
        equals(Uint8List.fromList([
          0xD0, 0x00, // subheader = 0xD000 (BIG-ENDIAN)
          0x01, // network echoed
          0xFF, // pc echoed
          0xFF, 0x03, // destModuleIo echoed = 0x03FF (LE)
          0x00, // destModuleStation echoed
          0x04, 0x00, // responseDataLength = 4 (LE): endCode(2) + data(2)
          0x00, 0x00, // endCode = kSlmpEndNormal (LE)
          0x11, 0x22, // data
        ])),
      );
    });

    test('defaults to empty data when [data] is omitted; responseDataLength = 2', () {
      final requestHeader = SlmpHeader(
        network: 0x00,
        pc: 0xFF,
        destModuleIo: 0x03FF,
        destModuleStation: 0x00,
        monitoringTimer: 0x0000,
      );

      final response = buildSlmpResponse(
        requestHeader: requestHeader,
        endCode: kSlmpEndCommandError,
      );

      expect(response.length, kSlmpResponseFixedLen); // header + endCode, no data
      expect(
        response,
        equals(Uint8List.fromList([
          0xD0, 0x00, // subheader (BIG-ENDIAN)
          0x00, // network
          0xFF, // pc
          0xFF, 0x03, // destModuleIo
          0x00, // destModuleStation
          0x02, 0x00, // responseDataLength = 2 (endCode only, no data)
          0x59, 0xC0, // endCode = kSlmpEndCommandError = 0xC059 (LE)
        ])),
      );
    });

    test('a response built from a parsed request round-trips through parseSlmpRequest-shaped '
        'assertions on routing', () {
      final requestBytes = Uint8List.fromList([
        0x50, 0x00, // subheader (BIG-ENDIAN)
        0x02, // network
        0xFF, // pc
        0xFF, 0x03, // destModuleIo
        0x03, // destModuleStation
        0x06, 0x00, // requestDataLength
        0x00, 0x00, // monitoringTimer
        0x01, 0x04, // command
        0x00, 0x00, // subcommand
      ]);
      final request = parseSlmpRequest(requestBytes);
      expect(request, isNotNull);

      final responseBytes = buildSlmpResponse(
        requestHeader: request!.header,
        endCode: kSlmpEndAddressRange,
      );

      expect(responseBytes.sublist(0, 2), equals(Uint8List.fromList([0xD0, 0x00])));
      expect(responseBytes[2], request.header.network);
      expect(responseBytes[3], request.header.pc);
      expect(responseBytes.sublist(4, 6), equals(Uint8List.fromList([0xFF, 0x03])));
      expect(responseBytes[6], request.header.destModuleStation);
    });
  });

  group('subheader and end-code constants', () {
    test('carry their documented literal values', () {
      expect(kSlmpRequestSubheader, 0x5000);
      expect(kSlmpResponseSubheader, 0xD000);
      expect(kSlmpEndNormal, 0x0000);
      expect(kSlmpEndCommandError, 0xC059);
      expect(kSlmpEndAddressRange, 0xC056);
      expect(kSlmpEndPointCount, 0xC051);
    });
  });
}
