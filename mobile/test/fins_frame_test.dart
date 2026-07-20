// Byte-exact fixtures for the FINS command/response frame codec
// (mobile/lib/protocols/fins/fins_frame.dart) — the bottom layer of the FINS
// stack: the 10-byte header + command/response envelope that later layers
// (memory-area services, the UDP host, the tag map) build on.
//
// CRITICAL #1: FINS multi-byte fields are BIG-ENDIAN. The most recently added
// protocol in this repo (EtherNet/IP, protocols/enip/) is little-endian, and
// Modbus mixes conventions — do not pattern-match either into this codec. A
// pure build -> parse round trip CANNOT catch an endianness bug (it cancels
// out perfectly even when fully broken), so every fixture below asserts
// literal expected bytes against a hand-built buffer, and the command-code
// fixture uses two DIFFERENT bytes (0x01, 0x02 -> 0x0102, NOT 0x0201) so a
// little-endian implementation fails instead of silently passing.
//
// CRITICAL #2: buildFinsResponse does NOT copy the request header verbatim.
// The reply travels back to the requester, so DNA/DA1/DA2 (destination)
// swap with SNA/SA1/SA2 (source). SID is echoed UNCHANGED (the client
// correlates the reply by SID) and the response ICF bit is set. Getting the
// swap backwards sends every reply to the wrong node — this is the one
// semantic this task exists to lock down.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_frame.dart';

void main() {
  group('parseFinsCommand', () {
    test('decodes a hand-built 10-byte header + command 0x0101 + text, exact fields', () {
      final bytes = Uint8List.fromList([
        0x01, // ICF (bit0 response-required set, bit6 clear -> command)
        0x00, // RSV
        0x02, // GCT (gateway count)
        0x10, // DNA
        0x11, // DA1
        0x12, // DA2
        0x20, // SNA
        0x21, // SA1
        0x22, // SA2
        0x55, // SID
        0x01, 0x01, // commandCode = 0x0101
        0xAA, 0xBB, 0xCC, // text
      ]);

      final frame = parseFinsCommand(bytes);
      expect(frame, isNotNull);
      expect(frame!.header.icf, 0x01);
      expect(frame.header.rsv, 0x00);
      expect(frame.header.gct, 0x02);
      expect(frame.header.dna, 0x10);
      expect(frame.header.da1, 0x11);
      expect(frame.header.da2, 0x12);
      expect(frame.header.sna, 0x20);
      expect(frame.header.sa1, 0x21);
      expect(frame.header.sa2, 0x22);
      expect(frame.header.sid, 0x55);
      expect(frame.commandCode, 0x0101);
      expect(frame.text, equals(Uint8List.fromList([0xAA, 0xBB, 0xCC])));
    });

    test('reads commandCode 0x01, 0x02 as 0x0102 — NOT 0x0201 (little-endian canary)', () {
      final bytes = Uint8List.fromList([
        0x00, 0x00, 0x02, 0x10, 0x11, 0x12, 0x20, 0x21, 0x22, 0x55, // header
        0x01, 0x02, // commandCode bytes: 0x01 then 0x02
      ]);

      final frame = parseFinsCommand(bytes);
      expect(frame, isNotNull);
      expect(frame!.commandCode, 0x0102);
      expect(frame.commandCode, isNot(0x0201));
    });

    test('returns null for a buffer shorter than kFinsHeaderLen + 2, no throw', () {
      expect(kFinsHeaderLen, 10);
      // 11 bytes: one short of the required 12 (10-byte header + 2-byte command code).
      final tooShort = Uint8List.fromList(List<int>.filled(11, 0));
      expect(() => parseFinsCommand(tooShort), returnsNormally);
      expect(parseFinsCommand(tooShort), isNull);

      final empty = Uint8List(0);
      expect(() => parseFinsCommand(empty), returnsNormally);
      expect(parseFinsCommand(empty), isNull);
    });

    test('parses successfully at exactly kFinsHeaderLen + 2 bytes with empty text', () {
      final bytes = Uint8List.fromList([
        0x00, 0x00, 0x02, 0x10, 0x11, 0x12, 0x20, 0x21, 0x22, 0x55, // header
        0x01, 0x01, // commandCode
      ]);
      final frame = parseFinsCommand(bytes);
      expect(frame, isNotNull);
      expect(frame!.text, equals(Uint8List(0)));
    });
  });

  group('buildFinsResponse', () {
    test('swaps DNA/DA1/DA2 <-> SNA/SA1/SA2, echoes SID, sets the response ICF bit, '
        'and emits commandCode u16 + endCode u16 + data — asserted against literal bytes', () {
      final requestHeader = FinsHeader(
        icf: 0x01, // bit0 response-required set, bit6 clear (command)
        rsv: 0x00,
        gct: 0x02,
        dna: 0x01,
        da1: 0x02,
        da2: 0x03,
        sna: 0x04,
        sa1: 0x05,
        sa2: 0x06,
        sid: 0x2A,
      );

      final response = buildFinsResponse(
        requestHeader: requestHeader,
        commandCode: 0x0102,
        endCode: kFinsEndNormal,
        data: Uint8List.fromList([0xDE, 0xAD]),
      );

      expect(
        response,
        equals(Uint8List.fromList([
          0x41, // ICF: bit0 (0x01) preserved, bit6 (0x40) set for response -> 0x41
          0x00, // RSV
          0x02, // GCT
          0x04, // DNA <- was SNA
          0x05, // DA1 <- was SA1
          0x06, // DA2 <- was SA2
          0x01, // SNA <- was DNA
          0x02, // SA1 <- was DA1
          0x03, // SA2 <- was DA2
          0x2A, // SID echoed unchanged
          0x01, 0x02, // commandCode = 0x0102
          0x00, 0x00, // endCode = kFinsEndNormal
          0xDE, 0xAD, // data
        ])),
      );
    });

    test('defaults to empty data when [data] is omitted', () {
      final requestHeader = FinsHeader(
        icf: 0x00,
        rsv: 0x00,
        gct: 0x02,
        dna: 0x01,
        da1: 0x02,
        da2: 0x03,
        sna: 0x04,
        sa1: 0x05,
        sa2: 0x06,
        sid: 0x2A,
      );
      final response = buildFinsResponse(
        requestHeader: requestHeader,
        commandCode: 0x0101,
        endCode: kFinsEndNoArea,
      );
      expect(response.length, kFinsHeaderLen + 2 + 2); // header + commandCode + endCode, no data
      expect(response.sublist(kFinsHeaderLen, kFinsHeaderLen + 2), equals(Uint8List.fromList([0x01, 0x01])));
      expect(response.sublist(kFinsHeaderLen + 2, kFinsHeaderLen + 4), equals(Uint8List.fromList([0x11, 0x01])));
    });

    test('a response built from a parsed command round-trips through parseFinsCommand '
        'with addressing swapped', () {
      final requestBytes = Uint8List.fromList([
        0x01, 0x00, 0x02, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x2A, // header
        0x01, 0x02, // commandCode
      ]);
      final request = parseFinsCommand(requestBytes);
      expect(request, isNotNull);

      final responseBytes = buildFinsResponse(
        requestHeader: request!.header,
        commandCode: kFinsEndAddressRange,
        endCode: kFinsEndAddressRange,
      );

      // The response is itself parseable as a command-shaped buffer (same
      // header layout); verify the swap landed via a second parse.
      final reparsed = parseFinsCommand(responseBytes);
      expect(reparsed, isNotNull);
      expect(reparsed!.header.dna, request.header.sna);
      expect(reparsed.header.da1, request.header.sa1);
      expect(reparsed.header.da2, request.header.sa2);
      expect(reparsed.header.sna, request.header.dna);
      expect(reparsed.header.sa1, request.header.da1);
      expect(reparsed.header.sa2, request.header.da2);
      expect(reparsed.header.sid, request.header.sid);
    });
  });

  group('end-code constants', () {
    test('carry their documented literal values', () {
      expect(kFinsEndNormal, 0x0000);
      expect(kFinsEndNoArea, 0x1101);
      expect(kFinsEndAddressRange, 0x1103);
      expect(kFinsEndNotWritable, 0x2101);
    });
  });
}
