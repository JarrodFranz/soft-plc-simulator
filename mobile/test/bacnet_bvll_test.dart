// Byte-exact fixtures for the BACnet BVLL/NPDU framing codec
// (mobile/lib/protocols/bacnet/bacnet_bvll.dart) — the bottom layer of the
// BACnet/IP stack: the 4-byte BVLL header (type 0x81, function, BE length)
// wrapping a minimal NPDU (version + control [+ optional source/destination
// address fields]) around the APDU payload.
//
// A build -> parse round trip through our OWN codec proves little on its own
// (a symmetric length or byte-order bug cancels out), so every case below
// pins literal hand-built octets for BOTH build output and parse input; a
// couple of extra round-trip checks are included as ADDITIONAL coverage on
// top of, never instead of, the literal-byte assertions.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_bvll.dart';

void main() {
  // A tiny placeholder APDU — its internal structure is irrelevant to this
  // layer, which only frames/unframes it.
  final apdu = Uint8List.fromList([0x10, 0x08]);

  group('buildBvllUnicast / buildBvllBroadcast — literal bytes', () {
    test('buildBvllUnicast prepends minimal NPDU 01 00 and BVLL header with correct BE length', () {
      final out = buildBvllUnicast(apdu);
      expect(
        out,
        equals(Uint8List.fromList([
          0x81, // BVLC type
          0x0A, // Original-Unicast-NPDU
          0x00, 0x08, // BE length: 4 (BVLL) + 2 (NPDU) + 2 (apdu) = 8
          0x01, 0x00, // minimal NPDU: version 1, control 0
          0x10, 0x08, // apdu
        ])),
      );
    });

    test('buildBvllBroadcast prepends minimal NPDU 01 00 and BVLL header with correct BE length', () {
      final out = buildBvllBroadcast(apdu);
      expect(
        out,
        equals(Uint8List.fromList([
          0x81, // BVLC type
          0x0B, // Original-Broadcast-NPDU
          0x00, 0x08,
          0x01, 0x00,
          0x10, 0x08,
        ])),
      );
    });

    test('length field scales correctly with a longer apdu', () {
      final longApdu = Uint8List.fromList(List<int>.filled(10, 0x42));
      final out = buildBvllUnicast(longApdu);
      final len = ByteData.sublistView(out, 2, 4).getUint16(0, Endian.big);
      expect(len, out.length);
      expect(out.length, 4 + 2 + 10);
    });
  });

  group('parseBvllToApdu — unicast and broadcast reach the same APDU', () {
    test('unicast (function 0x0A) with minimal NPDU parses to the exact APDU bytes', () {
      final datagram = Uint8List.fromList([
        0x81, 0x0A, 0x00, 0x08, // BVLL: unicast, length 8
        0x01, 0x00, // NPDU: version 1, control 0
        0x10, 0x08, // APDU
      ]);
      final result = parseBvllToApdu(datagram);
      expect(result, isNotNull);
      expect(result, equals(Uint8List.fromList([0x10, 0x08])));
    });

    test('broadcast (function 0x0B) with minimal NPDU parses to the same APDU bytes', () {
      final datagram = Uint8List.fromList([
        0x81, 0x0B, 0x00, 0x08, // BVLL: broadcast, length 8
        0x01, 0x00, // NPDU: version 1, control 0
        0x10, 0x08, // APDU
      ]);
      final result = parseBvllToApdu(datagram);
      expect(result, isNotNull);
      expect(result, equals(Uint8List.fromList([0x10, 0x08])));
    });

    test('a datagram built by buildBvllUnicast parses back to the original apdu (additional round-trip check)', () {
      final result = parseBvllToApdu(buildBvllUnicast(apdu));
      expect(result, equals(apdu));
    });
  });

  group('parseBvllToApdu — malformed/hostile input never throws, returns null', () {
    test('wrong BVLC type byte (not 0x81) -> null', () {
      final datagram = Uint8List.fromList([0x82, 0x0A, 0x00, 0x08, 0x01, 0x00, 0x10, 0x08]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });

    test('unsupported function code (not 0x0A/0x0B) -> null', () {
      final datagram = Uint8List.fromList([0x81, 0x04, 0x00, 0x08, 0x01, 0x00, 0x10, 0x08]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });

    test('BE length field mismatched against actual datagram length -> null', () {
      final datagram = Uint8List.fromList([
        0x81, 0x0A, 0x00, 0x09, // claims length 9, but datagram is only 8 bytes
        0x01, 0x00,
        0x10, 0x08,
      ]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });

    test('NPDU version != 1 -> null', () {
      final datagram = Uint8List.fromList([
        0x81, 0x0A, 0x00, 0x08,
        0x02, 0x00, // version 2 (unsupported)
        0x10, 0x08,
      ]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });

    test('destination-present control bit (0x20) -> null (router traffic, dropped)', () {
      // Length matches the actual byte count so the destination-present
      // check (not an unrelated length mismatch) is what produces the null.
      // The bytes after version/control are placeholders — this codec drops
      // destination-present traffic without parsing DNET/DLEN/DADR/hop
      // count at all.
      final datagram = Uint8List.fromList([
        0x81, 0x0A, 0x00, 0x09, // length 9 (matches actual byte count below)
        0x01, 0x20, // version 1, control 0x20 destination-present
        0x00, 0x01, 0x00, // placeholder DNET/DLEN bytes
      ]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });

    test('truncated datagram shorter than the 4-byte BVLL header -> null', () {
      final datagram = Uint8List.fromList([0x81, 0x0A, 0x00]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });

    test('datagram with BVLL header only, no room for NPDU version/control -> null', () {
      final datagram = Uint8List.fromList([0x81, 0x0A, 0x00, 0x04]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });

    test('empty datagram -> null, no throw', () {
      final datagram = Uint8List(0);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });
  });

  group('parseBvllToApdu — source-present control bit (0x08) skips source fields correctly', () {
    test('hand-built frame with SNET/SLEN/SADR present parses past them to the exact APDU', () {
      final datagram = Uint8List.fromList([
        0x81, 0x0A, 0x00, 0x0E, // BVLL: unicast, length 14
        0x01, 0x08, // NPDU: version 1, control 0x08 source-present
        0x00, 0x01, // SNET = 1
        0x03, // SLEN = 3
        0xAA, 0xBB, 0xCC, // SADR (3 bytes)
        0x10, 0x08, // APDU
      ]);
      final result = parseBvllToApdu(datagram);
      expect(result, isNotNull);
      expect(result, equals(Uint8List.fromList([0x10, 0x08])));
    });

    test('source-present with SLEN=0 (no SADR bytes) still parses to the exact APDU', () {
      final datagram = Uint8List.fromList([
        0x81, 0x0A, 0x00, 0x0B, // BVLL: unicast, length 11
        0x01, 0x08, // NPDU: version 1, control 0x08 source-present
        0x00, 0x01, // SNET = 1
        0x00, // SLEN = 0
        0x10, 0x08, // APDU
      ]);
      final result = parseBvllToApdu(datagram);
      expect(result, isNotNull);
      expect(result, equals(Uint8List.fromList([0x10, 0x08])));
    });

    test('source-present but truncated before SADR ends -> null, no throw', () {
      final datagram = Uint8List.fromList([
        0x81, 0x0A, 0x00, 0x0A, // claims length 10
        0x01, 0x08, // version 1, control 0x08 source-present
        0x00, 0x01, // SNET = 1
        0x03, // SLEN = 3, but only 1 byte of SADR follows before EOF
        0xAA,
      ]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });

    test('source-present but missing SNET/SLEN entirely -> null, no throw', () {
      final datagram = Uint8List.fromList([
        0x81, 0x0A, 0x00, 0x06, // length 6: BVLL(4) + version/control(2), nothing more
        0x01, 0x08, // version 1, control 0x08 source-present, but no source fields follow
      ]);
      expect(() => parseBvllToApdu(datagram), returnsNormally);
      expect(parseBvllToApdu(datagram), isNull);
    });
  });
}
