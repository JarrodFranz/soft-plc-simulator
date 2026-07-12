// Tests for the DNP3 Transport Function + Application Layer codec (DNP3
// outstation Task 3): the transport segment header + reassembler, the
// object-header group/variation/qualifier/range encoding, the static-object
// point encoders, the CROB/analog-output-block control decoders, IIN
// packing, and end-to-end request-fragment parsing. Byte fixtures below are
// hand-derived from IEEE 1815 (see the comments at each fixture) rather than
// copied from the implementation, so they double as an independent check on
// the wire format.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_app.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_transport.dart';

void main() {
  group('buildTransport (transport segment header)', () {
    // Bit layout (real IEEE 1815 Transport header, verified against spec):
    // FIN = bit 7 (0x80), FIR = bit 6 (0x40), SEQUENCE = bits 0-5 (0x3F).
    test('fir=true, fin=true, seq=0 -> header 0xC0 (0x40|0x80|0)', () {
      final seg = buildTransport(0, fir: true, fin: true, appData: Uint8List.fromList([0xAA]));
      expect(seg, Uint8List.fromList([0xC0, 0xAA]));
    });

    test('fir=false, fin=true, seq=5 -> header 0x85 (0x80|5)', () {
      final seg = buildTransport(5, fir: false, fin: true, appData: Uint8List(0));
      expect(seg, Uint8List.fromList([0x85]));
    });

    test('fir=true, fin=false, seq=63 -> header 0x7F (0x40|63)', () {
      final seg = buildTransport(63, fir: true, fin: false, appData: Uint8List.fromList([1, 2]));
      expect(seg, Uint8List.fromList([0x7F, 1, 2]));
    });

    test('sequence number is masked to 6 bits (65 & 0x3F == 1)', () {
      final seg = buildTransport(65, fir: true, fin: true, appData: Uint8List(0));
      expect(seg[0], 0x40 | 0x80 | 1);
    });
  });

  group('DnpTransportReassembler', () {
    test('a single fir=fin=true segment reassembles immediately', () {
      final r = DnpTransportReassembler();
      final seg = buildTransport(0, fir: true, fin: true, appData: Uint8List.fromList([1, 2, 3]));
      final result = r.addSegment(seg);
      expect(result, Uint8List.fromList([1, 2, 3]));
    });

    test('two segments (fir then fin) concatenate their app data in order', () {
      final r = DnpTransportReassembler();
      final first = buildTransport(0, fir: true, fin: false, appData: Uint8List.fromList([1, 2]));
      final second = buildTransport(1, fir: false, fin: true, appData: Uint8List.fromList([3, 4]));

      expect(r.addSegment(first), isNull);
      final result = r.addSegment(second);
      expect(result, Uint8List.fromList([1, 2, 3, 4]));
    });

    test('an out-of-sequence segment aborts the in-progress fragment', () {
      final r = DnpTransportReassembler();
      final first = buildTransport(0, fir: true, fin: false, appData: Uint8List.fromList([1]));
      final wrongSeq = buildTransport(5, fir: false, fin: true, appData: Uint8List.fromList([2]));

      expect(r.addSegment(first), isNull);
      expect(r.addSegment(wrongSeq), isNull);
    });

    test('an empty segment is ignored, never throws', () {
      final r = DnpTransportReassembler();
      expect(() => r.addSegment(Uint8List(0)), returnsNormally);
      expect(r.addSegment(Uint8List(0)), isNull);
    });

    test('a non-fir segment with no fragment in progress is ignored', () {
      final r = DnpTransportReassembler();
      final seg = buildTransport(3, fir: false, fin: true, appData: Uint8List.fromList([9]));
      expect(r.addSegment(seg), isNull);
    });
  });

  group('object header encode/decode round trip, one per qualifier', () {
    test('qualifier 0x00 (1-byte range): group=1 var=2 start=5 stop=9', () {
      final bytes = encodeObjectHeader(group: 1, variation: 2, qualifier: DnpQualifier.range8, start: 5, stop: 9);
      expect(bytes, Uint8List.fromList([1, 2, 0x00, 5, 9]));

      final decoded = decodeObjectHeader(bytes, 0);
      expect(decoded, isNotNull);
      expect(decoded!.header.group, 1);
      expect(decoded.header.variation, 2);
      expect(decoded.header.qualifier, DnpQualifier.range8);
      expect(decoded.header.start, 5);
      expect(decoded.header.stop, 9);
      expect(decoded.nextOffset, 5);
    });

    test('qualifier 0x01 (2-byte LE range): group=30 var=1 start=300 stop=301', () {
      // 300 = 0x012C -> LE bytes 0x2C,0x01. 301 = 0x012D -> LE bytes 0x2D,0x01.
      final bytes = encodeObjectHeader(group: 30, variation: 1, qualifier: DnpQualifier.range16, start: 300, stop: 301);
      expect(bytes, Uint8List.fromList([30, 1, 0x01, 0x2C, 0x01, 0x2D, 0x01]));

      final decoded = decodeObjectHeader(bytes, 0);
      expect(decoded, isNotNull);
      expect(decoded!.header.start, 300);
      expect(decoded.header.stop, 301);
      expect(decoded.nextOffset, 7);
    });

    test('qualifier 0x06 (all points): group=60 var=1, no range field', () {
      final bytes = encodeObjectHeader(group: 60, variation: 1, qualifier: DnpQualifier.allPoints);
      expect(bytes, Uint8List.fromList([60, 1, 0x06]));

      final decoded = decodeObjectHeader(bytes, 0);
      expect(decoded, isNotNull);
      expect(decoded!.header.start, isNull);
      expect(decoded.header.stop, isNull);
      expect(decoded.header.count, isNull);
      expect(decoded.nextOffset, 3);
    });

    test('qualifier 0x17 (1-byte count + index-prefix objects): group=12 var=1 count=1', () {
      final bytes = encodeObjectHeader(group: 12, variation: 1, qualifier: DnpQualifier.indexPrefix8, count: 1);
      expect(bytes, Uint8List.fromList([12, 1, 0x17, 1]));

      final decoded = decodeObjectHeader(bytes, 0);
      expect(decoded, isNotNull);
      expect(decoded!.header.count, 1);
      expect(decoded.nextOffset, 4);
    });

    test('qualifier 0x28 (2-byte LE count + index-prefix objects): group=41 var=1 count=300', () {
      final bytes = encodeObjectHeader(group: 41, variation: 1, qualifier: DnpQualifier.indexPrefix16, count: 300);
      expect(bytes, Uint8List.fromList([41, 1, 0x28, 0x2C, 0x01]));

      final decoded = decodeObjectHeader(bytes, 0);
      expect(decoded, isNotNull);
      expect(decoded!.header.count, 300);
      expect(decoded.nextOffset, 5);
    });

    test('unrecognized qualifier -> decode returns null', () {
      final bytes = encodeObjectHeader(group: 1, variation: 1, qualifier: 0xFF);
      expect(bytes, Uint8List.fromList([1, 1, 0xFF])); // header-only, best-effort encode.
      expect(decodeObjectHeader(bytes, 0), isNull);
    });

    test('truncated range field -> null, never throws', () {
      final full = encodeObjectHeader(group: 30, variation: 1, qualifier: DnpQualifier.range16, start: 1, stop: 2);
      for (var cut = 0; cut < full.length; cut++) {
        final truncated = Uint8List.fromList(full.sublist(0, cut));
        expect(() => decodeObjectHeader(truncated, 0), returnsNormally);
        expect(decodeObjectHeader(truncated, 0), isNull);
      }
    });
  });

  group('Class 0 response fragment: byte-exact hand-derived fixture', () {
    test('one BI (g1v2), one AI int (g30v1), one AI float (g30v5), each at index 0', () {
      // --- Point 1: g1v2 Binary Input, index 0, ONLINE flag + value=true ---
      // Flags byte: bit0 ONLINE (0x01) | bit7 STATE (0x80) = 0x81.
      // Header: group=1 variation=2 qualifier=0x00(range8) start=0 stop=0
      //   -> [0x01, 0x02, 0x00, 0x00, 0x00]
      final obj1Header = encodeObjectHeader(group: 1, variation: 2, qualifier: DnpQualifier.range8, start: 0, stop: 0);
      final obj1Data = encodeG1V2(value: true, flags: DnpFlags.online);
      expect(obj1Header, Uint8List.fromList([0x01, 0x02, 0x00, 0x00, 0x00]));
      expect(obj1Data, Uint8List.fromList([0x81]));

      // --- Point 2: g30v1 Analog Input (32-bit), index 0, value=12345 ---
      // Flags byte: ONLINE = 0x01.
      // 12345 = 0x00003039 -> int32 LE bytes: 0x39, 0x30, 0x00, 0x00.
      // Header: group=30 variation=1 qualifier=0x00 start=0 stop=0
      //   -> [0x1E, 0x01, 0x00, 0x00, 0x00]  (30 == 0x1E)
      final obj2Header = encodeObjectHeader(group: 30, variation: 1, qualifier: DnpQualifier.range8, start: 0, stop: 0);
      final obj2Data = encodeG30V1(value: 12345, flags: DnpFlags.online);
      expect(obj2Header, Uint8List.fromList([30, 1, 0x00, 0x00, 0x00]));
      expect(obj2Data, Uint8List.fromList([0x01, 0x39, 0x30, 0x00, 0x00]));

      // --- Point 3: g30v5 Analog Input (float), index 0, value=100.0 ---
      // Flags byte: ONLINE = 0x01.
      // 100.0 as IEEE-754 single precision: 100 = 1.5625 * 2^6.
      //   sign=0, exponent=6+127=133=0b10000101, mantissa=0b10010000000000000000000
      //   -> big-endian bytes 0x42 0xC8 0x00 0x00 (the well-known 100.0f pattern)
      //   -> little-endian (wire order) bytes: 0x00 0x00 0xC8 0x42.
      // Header: group=30 variation=5 qualifier=0x00 start=0 stop=0
      final obj3Header = encodeObjectHeader(group: 30, variation: 5, qualifier: DnpQualifier.range8, start: 0, stop: 0);
      final obj3Data = encodeG30V5(value: 100.0, flags: DnpFlags.online);
      expect(obj3Header, Uint8List.fromList([30, 5, 0x00, 0x00, 0x00]));
      expect(obj3Data, Uint8List.fromList([0x01, 0x00, 0x00, 0xC8, 0x42]));

      final objectData = BytesBuilder()
        ..add(obj1Header)
        ..add(obj1Data)
        ..add(obj2Header)
        ..add(obj2Data)
        ..add(obj3Header)
        ..add(obj3Data);

      // APP_CONTROL: FIR(0x80)|FIN(0x40)|CON(0)|UNS(0)|SEQ(0) = 0xC0.
      // FUNCTION_CODE = RESPONSE = 129 = 0x81.
      // IIN = 0 -> two zero bytes.
      final response = buildAppResponse(
        seq: 0,
        fir: true,
        fin: true,
        con: false,
        iin: 0,
        objectData: objectData.toBytes(),
      );

      final expected = Uint8List.fromList([
        0xC0, 0x81, 0x00, 0x00, // APP_CONTROL, FUNCTION_CODE, IIN1, IIN2
        1, 2, 0x00, 0x00, 0x00, 0x81, // g1v2 header + data
        30, 1, 0x00, 0x00, 0x00, 0x01, 0x39, 0x30, 0x00, 0x00, // g30v1 header + data
        30, 5, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0xC8, 0x42, // g30v5 header + data
      ]);
      expect(response, expected);
    });
  });

  group('IIN packing', () {
    test('packIin/unpackIin round trip', () {
      final packed = packIin(DnpIin1.deviceRestart, DnpIin2.objectUnknown);
      expect(packed, 0x0080 | (0x0002 << 8)); // 0x0280
      final unpacked = unpackIin(packed);
      expect(unpacked.iin1, DnpIin1.deviceRestart);
      expect(unpacked.iin2, DnpIin2.objectUnknown);
    });

    test('buildAppResponse writes IIN1 then IIN2 (little-endian wire order)', () {
      final iin = packIin(DnpIin1.deviceRestart, 0);
      final response = buildAppResponse(seq: 0, fir: true, fin: true, con: false, iin: iin, objectData: Uint8List(0));
      expect(response[2], DnpIin1.deviceRestart); // IIN1, transmitted first.
      expect(response[3], 0x00); // IIN2, transmitted second.
    });
  });

  group('parseAppRequest: Class 0 read request', () {
    test('g60v1, qualifier 0x06 (all points)', () {
      // APP_CONTROL: FIR|FIN|seq=0 = 0xC0. FUNCTION_CODE = READ = 1.
      final header = encodeObjectHeader(group: 60, variation: 1, qualifier: DnpQualifier.allPoints);
      final frag = Uint8List.fromList([0xC0, DnpFunc.read, ...header]);

      final req = parseAppRequest(frag);
      expect(req, isNotNull);
      expect(req!.appControl, 0xC0);
      expect(req.fir, isTrue);
      expect(req.fin, isTrue);
      expect(req.functionCode, DnpFunc.read);
      expect(req.objects, hasLength(1));
      expect(req.objects[0].group, 60);
      expect(req.objects[0].variation, 1);
      expect(req.objects[0].qualifier, DnpQualifier.allPoints);
      expect(req.objects[0].objectData, isEmpty);
      expect(req.rawObjectData, Uint8List.fromList(header));
    });
  });

  group('parseAppRequest + decodeCrob: DIRECT_OPERATE request for a CROB', () {
    test('g12v1, index-prefixed (0x17), one point: LATCH_ON, on-time=1000ms', () {
      final headerBytes = encodeObjectHeader(group: 12, variation: 1, qualifier: DnpQualifier.indexPrefix8, count: 1);
      final crobBytes = encodeCrob(
        controlCode: DnpControlCode.latchOn,
        count: 1,
        onTimeMs: 1000,
        offTimeMs: 0,
        status: 0,
      );
      // 1000 = 0x000003E8 -> LE bytes 0xE8, 0x03, 0x00, 0x00.
      expect(crobBytes, Uint8List.fromList([DnpControlCode.latchOn, 1, 0xE8, 0x03, 0x00, 0x00, 0, 0, 0, 0, 0]));

      final frag = Uint8List.fromList([
        0xC1, // APP_CONTROL: FIR|FIN|seq=1
        DnpFunc.directOperate,
        ...headerBytes,
        0x00, // 1-byte index prefix: point index 0
        ...crobBytes,
      ]);

      final req = parseAppRequest(frag);
      expect(req, isNotNull);
      expect(req!.functionCode, DnpFunc.directOperate);
      expect(req.objects, hasLength(1));
      final obj = req.objects[0];
      expect(obj.group, 12);
      expect(obj.variation, 1);
      expect(obj.indices, [0]);
      expect(obj.objectData, crobBytes);

      final crob = decodeCrob(obj.objectData);
      expect(crob, isNotNull);
      expect(crob!.controlCode, DnpControlCode.latchOn);
      expect(crob.count, 1);
      expect(crob.onTimeMs, 1000);
      expect(crob.offTimeMs, 0);
      expect(crob.status, 0);
    });

    test('decodeCrob on fewer than 11 bytes returns null, never throws', () {
      final crobBytes = encodeCrob(controlCode: DnpControlCode.pulseOn, count: 1, onTimeMs: 500, offTimeMs: 0, status: 0);
      for (var cut = 0; cut < crobBytes.length; cut++) {
        final truncated = Uint8List.fromList(crobBytes.sublist(0, cut));
        expect(() => decodeCrob(truncated), returnsNormally);
        expect(decodeCrob(truncated), isNull);
      }
    });
  });

  group('parseAppRequest + decodeAnalogOutput*: OPERATE request for a g41 AO block', () {
    test('g41v1 (32-bit), index-prefixed (0x17), one point: value=5000', () {
      final headerBytes = encodeObjectHeader(group: 41, variation: 1, qualifier: DnpQualifier.indexPrefix8, count: 1);
      final aoBytes = encodeAnalogOutputInt(value: 5000, status: 0);
      // 5000 = 0x00001388 -> LE bytes 0x88, 0x13, 0x00, 0x00.
      expect(aoBytes, Uint8List.fromList([0x88, 0x13, 0x00, 0x00, 0x00]));

      final frag = Uint8List.fromList([
        0xC2, // APP_CONTROL: FIR|FIN|seq=2
        DnpFunc.operate,
        ...headerBytes,
        0x00, // index prefix: point index 0
        ...aoBytes,
      ]);

      final req = parseAppRequest(frag);
      expect(req, isNotNull);
      expect(req!.functionCode, DnpFunc.operate);
      final obj = req.objects.single;
      expect(obj.group, 41);
      expect(obj.variation, 1);
      expect(obj.indices, [0]);

      final decoded = decodeAnalogOutputInt(obj.objectData);
      expect(decoded, isNotNull);
      expect(decoded!.value, 5000);
      expect(decoded.status, 0);
    });

    test('g41v3 (float), index-prefixed (0x17), one point: value=12.5', () {
      final headerBytes = encodeObjectHeader(group: 41, variation: 3, qualifier: DnpQualifier.indexPrefix8, count: 1);
      final aoBytes = encodeAnalogOutputFloat(value: 12.5, status: 0);

      final frag = Uint8List.fromList([
        0xC3,
        DnpFunc.directOperate,
        ...headerBytes,
        0x02, // index prefix: point index 2
        ...aoBytes,
      ]);

      final req = parseAppRequest(frag);
      expect(req, isNotNull);
      final obj = req!.objects.single;
      expect(obj.indices, [2]);

      final decoded = decodeAnalogOutputFloat(obj.objectData);
      expect(decoded, isNotNull);
      expect(decoded!.value, closeTo(12.5, 1e-6));
      expect(decoded.status, 0);
    });

    test('decodeAnalogOutputInt/Float on fewer than 5 bytes returns null, never throws', () {
      final bytes = encodeAnalogOutputInt(value: 1, status: 0);
      for (var cut = 0; cut < bytes.length; cut++) {
        final truncated = Uint8List.fromList(bytes.sublist(0, cut));
        expect(() => decodeAnalogOutputInt(truncated), returnsNormally);
        expect(decodeAnalogOutputInt(truncated), isNull);
        expect(() => decodeAnalogOutputFloat(truncated), returnsNormally);
        expect(decodeAnalogOutputFloat(truncated), isNull);
      }
    });
  });

  group('parseAppRequest: malformed/short/garbage input never throws', () {
    test('empty fragment -> null', () {
      expect(() => parseAppRequest(Uint8List(0)), returnsNormally);
      expect(parseAppRequest(Uint8List(0)), isNull);
    });

    test('single byte fragment (no function code) -> null', () {
      expect(parseAppRequest(Uint8List.fromList([0xC0])), isNull);
    });

    test('a range-qualified data-bearing object promising more data than present -> null', () {
      // functionCode=OPERATE with a g41v1 object over a 2-point range (0x00),
      // but only one point's worth of data actually follows.
      final headerBytes = encodeObjectHeader(group: 41, variation: 1, qualifier: DnpQualifier.range8, start: 0, stop: 1);
      final onePointOfData = encodeAnalogOutputInt(value: 1, status: 0); // only 5 bytes; 10 needed.
      final frag = Uint8List.fromList([0xC0, DnpFunc.operate, ...headerBytes, ...onePointOfData]);
      expect(parseAppRequest(frag), isNull);
    });

    test('an unrecognized group/variation in a data-bearing request -> null', () {
      final headerBytes = encodeObjectHeader(group: 99, variation: 99, qualifier: DnpQualifier.range8, start: 0, stop: 0);
      final frag = Uint8List.fromList([0xC0, DnpFunc.operate, ...headerBytes, 0x00]);
      expect(parseAppRequest(frag), isNull);
    });

    test('random garbage never throws', () {
      final garbage = Uint8List.fromList(List<int>.generate(40, (i) => (i * 53 + 7) & 0xFF));
      expect(() => parseAppRequest(garbage), returnsNormally);
    });
  });

  group('event object encoders + 48-bit time (Task 3)', () {
    test('g2v2 binary event encodes flags+state and 48-bit LE time', () {
      final bytes = encodeG2V2(value: true, flags: DnpFlags.online, timeMs: 0x0102030405);
      expect(bytes.length, 7);
      // flags byte: online (0x01) | state (0x80) = 0x81
      expect(bytes[0], 0x81);
      // 48-bit LE time 0x0102030405 -> 05 04 03 02 01 00
      expect(bytes.sublist(1), [0x05, 0x04, 0x03, 0x02, 0x01, 0x00]);
      expect(getDnpTime48(bytes, 1), 0x0102030405);
    });

    test('g32v3 analog int event: flags + int32 LE + 48-bit time', () {
      final bytes = encodeG32V3(value: 0x11223344, flags: DnpFlags.online, timeMs: 1000);
      expect(bytes.length, 11);
      expect(bytes[0], 0x01);
      expect(bytes.sublist(1, 5), [0x44, 0x33, 0x22, 0x11]);
      expect(getDnpTime48(bytes, 5), 1000);
    });

    test('g32v7 analog float event: flags + float32 LE + 48-bit time', () {
      final bytes = encodeG32V7(value: 1.5, flags: DnpFlags.online, timeMs: 2000);
      expect(bytes.length, 11);
      expect(bytes[0], 0x01);
      final bd = ByteData.sublistView(bytes, 1, 5);
      expect(bd.getFloat32(0, Endian.little), 1.5);
      expect(getDnpTime48(bytes, 5), 2000);
    });

    test('48-bit time survives a value above 2^32 (dart2js-safe)', () {
      const t = 1893456000000; // ~2030, exceeds 32 bits
      final bytes = encodeG2V2(value: false, flags: 0, timeMs: t);
      expect(getDnpTime48(bytes, 1), t);
    });

    test('dnpClassOfG60Variation maps variations to classes', () {
      expect(dnpClassOfG60Variation(1), 0);
      expect(dnpClassOfG60Variation(2), 1);
      expect(dnpClassOfG60Variation(3), 2);
      expect(dnpClassOfG60Variation(4), 3);
      expect(dnpClassOfG60Variation(9), isNull);
    });

    test('parse ENABLE_UNSOLICITED (fc20) naming class 1 via g60v2/all-points', () {
      // APP_CONTROL, fc=20, then object header g60 v2 qualifier 0x06 (all points).
      final frag = Uint8List.fromList([0xC0, 20, 60, 2, 0x06]);
      final req = parseAppRequest(frag);
      expect(req, isNotNull);
      expect(req!.functionCode, DnpFunc.enableUnsolicited);
      expect(req.objects.single.group, 60);
      expect(req.objects.single.variation, 2);
    });

    test('parse a CONFIRM (fc0) with no objects', () {
      final frag = Uint8List.fromList([0xD0, 0]); // UNS+... fc0
      final req = parseAppRequest(frag);
      expect(req, isNotNull);
      expect(req!.functionCode, DnpFunc.confirm);
      expect(req.objects, isEmpty);
      expect(req.uns, isTrue);
      expect(req.seq, 0);
    });

    test('buildUnsolicitedResponse sets fc130 and FIR|FIN|CON|UNS', () {
      final resp = buildUnsolicitedResponse(seq: 5, iin: packIin(0, 0), objectData: Uint8List(0));
      // app control = 0x80|0x40|0x20|0x10|seq = 0xF5
      expect(resp[0], 0xF5);
      expect(resp[1], 130);
      expect(resp.length, 4); // control + func + IIN(2)
    });
  });
}
