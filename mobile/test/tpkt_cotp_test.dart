// Byte-exact fixtures for the TPKT (RFC 1006) + COTP (ISO 8073) framing
// codec (mobile/lib/protocols/s7/tpkt_cotp.dart). This is the bottom
// transport layer for S7comm on TCP 102; the S7 PDU (Task 2) is carried as
// the payload of a COTP DT (data) TPDU, which is in turn carried as the
// payload of a TPKT frame.
//
// CRITICAL: S7comm/TPKT/COTP are BIG-ENDIAN, unlike the little-endian
// EtherNet/IP codec next door (protocols/enip/enip_encap.dart). A pure
// build -> parse round trip cannot catch an endianness bug (it cancels out
// perfectly even when fully broken), so every fixture below asserts literal
// expected bytes against hand-built buffers, and the very first test uses a
// length whose two bytes differ (0x01, 0x02 -> 258, not 513) so that a
// little-endian implementation fails instead of passing.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/s7/tpkt_cotp.dart';

void main() {
  group('TPKT (RFC 1006)', () {
    test('parseTpkt decodes a hand-built header, asserting big-endian length', () {
      // version=0x03, reserved=0x00, length=0x0016 (22) big-endian.
      final bytes = Uint8List.fromList([0x03, 0x00, 0x00, 0x16]);
      final header = parseTpkt(bytes);
      expect(header, isNotNull);
      expect(header!.version, 3);
      expect(header.length, 22);
    });

    test('parseTpkt reads length big-endian, NOT little-endian (byte-order canary)', () {
      // length bytes are 0x01, 0x02. Big-endian => 0x0102 == 258.
      // A little-endian implementation would read 0x0201 == 513 and fail
      // this assertion.
      final bytes = Uint8List.fromList([0x03, 0x00, 0x01, 0x02]);
      final header = parseTpkt(bytes);
      expect(header, isNotNull);
      expect(header!.length, 258);
      expect(header.length, isNot(513));
    });

    test('buildTpkt emits version/reserved then the big-endian TOTAL length (payload + 4)', () {
      final payload = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
      final framed = buildTpkt(payload);
      // total = 3 (payload) + 4 (TPKT header) = 7 = 0x0007.
      expect(framed, equals(Uint8List.fromList([0x03, 0x00, 0x00, 0x07, 0xAA, 0xBB, 0xCC])));
    });

    test('parseTpkt returns null (never throws) for a buffer shorter than 4 bytes', () {
      expect(parseTpkt(Uint8List(0)), isNull);
      expect(parseTpkt(Uint8List.fromList([0x03, 0x00, 0x00])), isNull);
    });
  });

  group('COTP (ISO 8073) — CR/CC', () {
    test('parseCotp extracts pduType, both refs, and both TSAPs from a hand-built CR regardless of parameter order', () {
      // LI=0x11(17), type=0xE0 (CR), dstRef=0x0000, srcRef=0x1234, class/option=0x00,
      // then parameters in a deliberately non-canonical order: dst TSAP (0xC2)
      // before src TSAP (0xC1), followed by an unrelated TPDU-size param (0xC0)
      // that parseCotp must skip over without choking on it.
      final bytes = Uint8List.fromList([
        0x11, // LI = 17 (header length excluding this byte)
        0xE0, // CR
        0x00, 0x00, // dstRef
        0x12, 0x34, // srcRef
        0x00, // class/option
        0xC2, 0x02, 0x01, 0x02, // dst TSAP param = 0x0102 (258)
        0xC1, 0x02, 0x03, 0x04, // src TSAP param = 0x0304 (772)
        0xC0, 0x01, 0x0A, // TPDU size param (ignored by this codec's interface)
      ]);
      expect(bytes.length, 18); // 1 (LI) + 17 (declared header)

      final packet = parseCotp(bytes);
      expect(packet, isNotNull);
      expect(packet!.pduType, 0xE0);
      expect(packet.dstRef, 0x0000);
      expect(packet.srcRef, 0x1234);
      expect(packet.dstTsap, 0x0102);
      expect(packet.srcTsap, 0x0304);
    });

    test('buildCotpConnectConfirm emits exact literal bytes for every multi-byte field (byte-order canary), and round-trips through parseCotp', () {
      final cc = buildCotpConnectConfirm(srcRef: 0x1234, dstRef: 0x5678, srcTsap: 0x0100, dstTsap: 0x0203);
      // Literal expected bytes at every offset -- NOT just a round-trip.
      // A coordinated endianness bug present identically in both
      // buildCotpConnectConfirm and parseCotp would cancel out and a
      // round-trip-only assertion would still pass. Each reference value
      // below has two bytes that differ from each other, so a
      // little-endian implementation of any field fails this assertion:
      //   [0]      LI = 0x0E (14): type(1)+dstRef(2)+srcRef(2)+class/opt(1)+params(8)
      //   [1]      PDU type = 0xD0 (CC)
      //   [2..4)   dstRef = 0x5678 big-endian -> 0x56, 0x78
      //   [4..6)   srcRef = 0x1234 big-endian -> 0x12, 0x34
      //   [6]      class/option = 0x00
      //   [7]      param code = 0xC2 (dst TSAP)
      //   [8]      param len = 0x02
      //   [9..11)  dstTsap = 0x0203 big-endian -> 0x02, 0x03
      //   [11]     param code = 0xC1 (src TSAP)
      //   [12]     param len = 0x02
      //   [13..15) srcTsap = 0x0100 big-endian -> 0x01, 0x00
      expect(
        cc,
        equals(Uint8List.fromList([
          0x0E, 0xD0, // LI, PDU type
          0x56, 0x78, // dstRef
          0x12, 0x34, // srcRef
          0x00, // class/option
          0xC2, 0x02, 0x02, 0x03, // dst TSAP param: code, len, value
          0xC1, 0x02, 0x01, 0x00, // src TSAP param: code, len, value
        ])),
      );
      expect(cc.length, 15); // 1 (LI) + 14 (declared header)

      final parsed = parseCotp(cc);
      expect(parsed, isNotNull);
      expect(parsed!.pduType, 0xD0);
      expect(parsed.srcRef, 0x1234);
      expect(parsed.dstRef, 0x5678);
      expect(parsed.srcTsap, 0x0100);
      expect(parsed.dstTsap, 0x0203);
    });
  });

  group('TPKT boundary', () {
    test('buildTpkt clamps an oversized payload and keeps the declared length field self-consistent with the actual emitted bytes', () {
      // total = kTpktHeaderLen + payload.length would be 4 + 65535 = 65539,
      // which overflows the u16 length field. buildTpkt must clamp so the
      // declared length always matches the bytes actually present in the
      // frame -- a self-inconsistent frame (declared length != actual byte
      // count) is worse than a truncated one, since a socket host trusts
      // the declared length to find the next frame boundary. (This exact
      // class of bug -- length field masked while the full payload was
      // still copied -- was found and fixed in the EtherNet/IP codec.)
      final payload = Uint8List.fromList(List<int>.generate(0xFFFF, (i) => i & 0xFF));
      final framed = buildTpkt(payload);

      final declaredLength = ByteData.sublistView(framed, 2, 4).getUint16(0, Endian.big);
      expect(declaredLength, 0xFFFF);
      expect(framed.length, declaredLength);

      const expectedPayloadLen = 0xFFFF - kTpktHeaderLen;
      expect(framed.length, kTpktHeaderLen + expectedPayloadLen);
      expect(
        framed.sublist(kTpktHeaderLen),
        equals(payload.sublist(0, expectedPayloadLen)),
      );
    });
  });

  group('COTP (ISO 8073) — DT', () {
    test('buildCotpData emits LI 0x02, type 0xF0, EOT 0x80, then the payload; parseCotp returns the payload unchanged', () {
      final payload = Uint8List.fromList([0x01, 0x02, 0x03]);
      final dt = buildCotpData(payload);
      expect(dt, equals(Uint8List.fromList([0x02, 0xF0, 0x80, 0x01, 0x02, 0x03])));

      final parsed = parseCotp(dt);
      expect(parsed, isNotNull);
      expect(parsed!.pduType, 0xF0);
      expect(parsed.payload, equals(payload));
    });
  });

  group('COTP (ISO 8073) — malformed input never throws', () {
    test('parseCotp returns null on a truncated packet', () {
      // LI declares a 17-byte header but only 3 bytes actually follow.
      final bytes = Uint8List.fromList([0x11, 0xE0, 0x00]);
      expect(parseCotp(bytes), isNull);
    });

    test('parseCotp returns null when the length indicator overruns the buffer', () {
      final bytes = Uint8List.fromList([0xFF, 0xE0]);
      expect(parseCotp(bytes), isNull);
    });

    test('parseCotp returns null when a CR parameter length overruns the buffer', () {
      // LI=8: header content = type(1)+dstRef(2)+srcRef(2)+class/option(1)
      // + paramCode(1)+paramLen(1) = 8, leaving zero bytes in the header for
      // the param's declared 0xFF-byte value.
      final bytes = Uint8List.fromList([
        0x08, // LI = 8
        0xE0, // CR
        0x00, 0x00, // dstRef
        0x00, 0x00, // srcRef
        0x00, // class/option
        0xC1, 0xFF, // param code=srcTsap, len=255 (way beyond what's left)
      ]);
      expect(parseCotp(bytes), isNull);
    });

    test('parseCotp returns null for an empty buffer', () {
      expect(parseCotp(Uint8List(0)), isNull);
    });

    test('parseCotp returns null for an unrecognized-but-well-formed COTP PDU type, and never throws', () {
      // 0x80 is ISO 8073 Disconnect Request (DR): a real, defined COTP PDU
      // type that this codec simply does not implement (only CR/CC/DT are
      // supported). The parse contract is that unrecognized input yields
      // null -- not a partially-populated CotpPacket -- so a later socket
      // host can drop the frame instead of acting on a PDU type it can't
      // interpret. LI=0x02 declares a well-formed 2-byte header (type +
      // one trailing byte), so this is not truncated/malformed by any
      // other measure -- only the PDU type itself is unsupported.
      final bytes = Uint8List.fromList([0x02, 0x80, 0x00]);
      expect(() => parseCotp(bytes), returnsNormally);
      expect(parseCotp(bytes), isNull);
    });
  });
}
