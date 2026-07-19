// Tests for the S7 area byte-image (S7comm workstream, Task 4).
//
// This is the highest-risk unit in the workstream: it is where an external
// network protocol materializes the app's named tags into a packed byte
// image and, in the write direction, decodes a byte range back onto the tags
// it overlaps.
//
// *** ENDIANNESS ***
// S7comm is BIG-ENDIAN. Every encoding assertion below uses LITERAL expected
// bytes whose values DIFFER byte-to-byte, so a little-endian implementation
// FAILS. A build->parse round-trip would cancel the error and prove nothing.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/s7_map.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/s7/s7_area_image.dart';

void main() {
  PlcProject buildProject() => PlcProject(
        id: 's7_img',
        name: 'S7 Image',
        controllerName: 'PLC_S7',
        programs: [],
        tasks: [],
        hmis: [],
        structDefs: [
          PlcStructDef(name: 'VesselType', fields: [
            StructFieldDef(name: 'Level', dataType: 'INT16', defaultValue: 0),
          ]),
        ],
        tags: [
          PlcTag(name: 'Flag3', path: 'Flag3', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'Flag5', path: 'Flag5', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'Word1', path: 'Word1', dataType: 'INT16', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Dint1', path: 'Dint1', dataType: 'INT32', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Lint1', path: 'Lint1', dataType: 'INT64', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Real1', path: 'Real1', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
          PlcTag(name: 'RoTag', path: 'RoTag', dataType: 'INT16', value: 11, ioType: 'Internal', access: 'ReadOnly'),
          PlcTag(name: 'Forced1', path: 'Forced1', dataType: 'INT16', value: 11, ioType: 'Internal'),
          PlcTag(
            name: 'Tank',
            path: 'Tank',
            dataType: 'VesselType',
            value: {'Level': 11},
            ioType: 'Internal',
          ),
          PlcTag(
            name: 'Vessel',
            path: 'Vessel',
            dataType: 'VesselType',
            value: {'Level': 11},
            ioType: 'Internal',
          ),
        ],
      );

  // Byte layout inside DB1 used by every test below. Byte 1, byte 3 and
  // bytes 12..15 are deliberately UNMAPPED (gaps).
  S7Map buildMap() => S7Map(entries: [
        S7MapEntry(tag: 'Flag3', area: 'DB', dbNumber: 1, byteOffset: 0, bitOffset: 3),
        S7MapEntry(tag: 'Flag5', area: 'DB', dbNumber: 1, byteOffset: 0, bitOffset: 5),
        S7MapEntry(tag: 'Word1', area: 'DB', dbNumber: 1, byteOffset: 2, bitOffset: 0),
        S7MapEntry(tag: 'Dint1', area: 'DB', dbNumber: 1, byteOffset: 4, bitOffset: 0),
        S7MapEntry(tag: 'Lint1', area: 'DB', dbNumber: 1, byteOffset: 16, bitOffset: 0),
        S7MapEntry(tag: 'Real1', area: 'DB', dbNumber: 1, byteOffset: 24, bitOffset: 0),
        S7MapEntry(tag: 'RoTag', area: 'DB', dbNumber: 1, byteOffset: 28, bitOffset: 0, access: 'ReadOnly'),
        S7MapEntry(tag: 'Forced1', area: 'DB', dbNumber: 1, byteOffset: 30, bitOffset: 0),
        S7MapEntry(tag: 'Tank.Level', area: 'DB', dbNumber: 1, byteOffset: 32, bitOffset: 0),
        S7MapEntry(tag: 'Vessel.Level', area: 'DB', dbNumber: 1, byteOffset: 34, bitOffset: 0),
      ]);

  group('readAreaImage — encoding, width and BIG-ENDIAN byte order', () {
    test('INT16 encodes as 2 big-endian bytes at its mapped offset', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102); // 258 — the two bytes DIFFER.
      final img = readAreaImage(p, buildMap(), 'DB', 1, 0, 8);
      expect(img[2], 0x01, reason: 'high byte first (big-endian)');
      expect(img[3], 0x02);
    });

    test('INT32 encodes as 4 big-endian bytes', () {
      final p = buildProject();
      writePath(p, 'Dint1', 0x01020304);
      final img = readAreaImage(p, buildMap(), 'DB', 1, 0, 8);
      expect(img.sublist(4, 8), equals([0x01, 0x02, 0x03, 0x04]));
    });

    test('INT64 encodes as 8 big-endian bytes', () {
      final p = buildProject();
      writePath(p, 'Lint1', 0x0102030405060708);
      final img = readAreaImage(p, buildMap(), 'DB', 1, 16, 8);
      expect(
        img,
        equals([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
      );
    });

    test('a negative INT16 encodes in two\'s complement, big-endian', () {
      final p = buildProject();
      writePath(p, 'Word1', -2);
      final img = readAreaImage(p, buildMap(), 'DB', 1, 2, 2);
      expect(img, equals([0xFF, 0xFE]));
    });

    test('FLOAT64 NARROWS to a 4-byte big-endian IEEE-754 REAL', () {
      const original = 1234.5678;
      final p = buildProject();
      writePath(p, 'Real1', original);
      final img = readAreaImage(p, buildMap(), 'DB', 1, 24, 4);
      expect(img.length, 4, reason: 'REAL is 4 bytes, not 8');
      // Sign+exponent high bits land FIRST — big-endian.
      expect(img[0], 0x44);
      expect(img[1], 0x9A);

      final back = decodeS7Real(img);
      // Tolerance sits just above the true float32 round-trip error
      // (~5.1e-5 for this value), so a wide-open tolerance cannot hide a
      // non-narrowing implementation...
      expect(back, closeTo(original, 1e-4));
      // ...and this asserts the narrowing ACTUALLY happened: a double-width
      // implementation would return the original value exactly and FAIL.
      expect(back, isNot(equals(original)));
    });

    test('two BOOLs in the same byte land in their own bits and do not disturb each other', () {
      final p = buildProject();
      writePath(p, 'Flag3', true);
      writePath(p, 'Flag5', false);
      var img = readAreaImage(p, buildMap(), 'DB', 1, 0, 1);
      expect(img[0], 0x08, reason: 'bit 3 only');

      writePath(p, 'Flag5', true);
      img = readAreaImage(p, buildMap(), 'DB', 1, 0, 1);
      expect(img[0], 0x28, reason: 'bits 3 and 5');

      writePath(p, 'Flag3', false);
      img = readAreaImage(p, buildMap(), 'DB', 1, 0, 1);
      expect(img[0], 0x20, reason: 'bit 5 only');
    });
  });

  group('readAreaImage — gaps and bounds', () {
    test('unmapped bytes inside a requested range read as 0x00', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102);
      final img = readAreaImage(p, buildMap(), 'DB', 1, 0, 8);
      expect(img[1], 0x00, reason: 'gap byte');
    });

    test('a range entirely outside any mapping reads all zeros', () {
      final img = readAreaImage(buildProject(), buildMap(), 'DB', 1, 200, 16);
      expect(img.length, 16);
      expect(img.every((b) => b == 0), isTrue);
    });

    test('a different DB number reads all zeros', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102);
      final img = readAreaImage(p, buildMap(), 'DB', 2, 0, 8);
      expect(img.every((b) => b == 0), isTrue);
    });

    test('a different area reads all zeros', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102);
      final img = readAreaImage(p, buildMap(), 'M', 1, 0, 8);
      expect(img.every((b) => b == 0), isTrue);
    });

    test('a range partially overlapping a multi-byte tag returns the overlapping bytes', () {
      final p = buildProject();
      writePath(p, 'Dint1', 0x01020304);
      final img = readAreaImage(p, buildMap(), 'DB', 1, 6, 2);
      expect(img, equals([0x03, 0x04]));
    });

    test('malformed / out-of-range read arguments never throw', () {
      final p = buildProject();
      final m = buildMap();
      expect(readAreaImage(p, m, 'DB', 1, 0, 0), isEmpty);
      expect(readAreaImage(p, m, 'DB', 1, 0, -5), isEmpty);
      expect(readAreaImage(p, m, 'DB', 1, -10, 4), isEmpty);
      expect(readAreaImage(p, m, 'ZZ', 1, 0, 4).length, 4);
      expect(readAreaImage(p, m, 'DB', 1, 0, 1 << 24).isEmpty, isTrue);
    });

    test('an entry naming a nonexistent tag is skipped, not thrown on', () {
      final p = buildProject();
      final m = S7Map(entries: [
        S7MapEntry(tag: 'NoSuchTag', area: 'DB', dbNumber: 1, byteOffset: 0, bitOffset: 0),
      ]);
      final img = readAreaImage(p, m, 'DB', 1, 0, 4);
      expect(img.every((b) => b == 0), isTrue);
    });
  });

  group('applyAreaWrite', () {
    test('a fully covered INT16 is decoded big-endian and written', () {
      final p = buildProject();
      final results = applyAreaWrite(
        p, buildMap(), 'DB', 1, 2, toBytes([0x01, 0x02]),
      );
      expect(readPath(p, 'Word1'), 0x0102);
      expect(results.where((r) => r.status == S7WriteStatus.written).map((r) => r.tag), contains('Word1'));
    });

    test('a fully covered INT32 and INT64 are decoded big-endian', () {
      final p = buildProject();
      applyAreaWrite(p, buildMap(), 'DB', 1, 4, toBytes([0x01, 0x02, 0x03, 0x04]));
      expect(readPath(p, 'Dint1'), 0x01020304);
      applyAreaWrite(
        p, buildMap(), 'DB', 1, 16,
        toBytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
      );
      expect(readPath(p, 'Lint1'), 0x0102030405060708);
    });

    test('a REAL write decodes into the FLOAT64 tag', () {
      final p = buildProject();
      applyAreaWrite(p, buildMap(), 'DB', 1, 24, toBytes([0x44, 0x9A, 0x52, 0x2B]));
      final v = readPath(p, 'Real1');
      expect(v, isA<double>());
      // Tolerance sits just above the true float32 round-trip error for this
      // value (~5.1e-5), matching the encode test above. A looser bound would
      // pass on a decoder that never went through float32 at all.
      expect(v as double, closeTo(1234.5678, 1e-4));
      // ...and this is the narrowing canary: a decode that widened the 4 wire
      // bytes without a float32 step could not land exactly on the double
      // literal, so an EQUAL value means the narrowing did not happen.
      expect(v, isNot(equals(1234.5678)));
    });

    test('a BOOL write sets only its own bit', () {
      final p = buildProject();
      writePath(p, 'Flag5', true);
      applyAreaWrite(p, buildMap(), 'DB', 1, 0, toBytes([0x08]));
      expect(readPath(p, 'Flag3'), isTrue);
      expect(readPath(p, 'Flag5'), isFalse);
    });

    test('writes to gap bytes are DISCARDED — no tag changes, nothing reported', () {
      final p = buildProject();
      final before = readPath(p, 'Word1');
      final results = applyAreaWrite(p, buildMap(), 'DB', 1, 1, toBytes([0xAA]));
      expect(readPath(p, 'Word1'), before);
      expect(results, isEmpty);
    });

    test('a PARTIALLY covered multi-byte tag is NOT written and IS reported', () {
      final p = buildProject();
      final before = readPath(p, 'Dint1');
      // Dint1 spans bytes 4..7; this range covers only 5..6.
      final results = applyAreaWrite(p, buildMap(), 'DB', 1, 5, toBytes([0xAA, 0xBB]));
      expect(readPath(p, 'Dint1'), before, reason: 'a partial write would corrupt the value');
      final partial = results.where((r) => r.status == S7WriteStatus.partiallyCovered);
      expect(partial.map((r) => r.tag), contains('Dint1'));
    });

    test('a write to a ReadOnly map entry is REFUSED, tag unchanged', () {
      final p = buildProject();
      final results = applyAreaWrite(p, buildMap(), 'DB', 1, 28, toBytes([0x01, 0x02]));
      expect(readPath(p, 'RoTag'), 11);
      final refused = results.where((r) => r.status == S7WriteStatus.refusedReadOnly);
      expect(refused.map((r) => r.tag), contains('RoTag'));
    });

    test('a write to a FORCED scalar tag is REFUSED, tag unchanged', () {
      final p = buildProject();
      final forced = p.tags.firstWhere((t) => t.name == 'Forced1');
      forced.isForced = true;
      forced.forcedValue = 99;
      final results = applyAreaWrite(p, buildMap(), 'DB', 1, 30, toBytes([0x01, 0x02]));
      expect(forced.value, 11, reason: 'the underlying tag value must be untouched');
      final refused = results.where((r) => r.status == S7WriteStatus.refusedForced);
      expect(refused.map((r) => r.tag), contains('Forced1'));
    });

    // THE REGRESSION THAT MATTERS: the force check must be made against the
    // ROOT tag with NO `root.name == tagPath` clause. With such a clause the
    // comparison is false for a member path and the check is SKIPPED, so the
    // write lands silently — and because reads seed from `forcedValue`, the
    // corruption only surfaces when the force is released.
    test('a write to a MEMBER beneath a FORCED root is REFUSED, member unchanged', () {
      final p = buildProject();
      final tank = p.tags.firstWhere((t) => t.name == 'Tank');
      tank.isForced = true;
      final results = applyAreaWrite(p, buildMap(), 'DB', 1, 32, toBytes([0x01, 0x02]));
      expect((tank.value as Map)['Level'], 11, reason: 'member write must not bypass the force');
      final refused = results.where((r) => r.status == S7WriteStatus.refusedForced);
      expect(refused.map((r) => r.tag), contains('Tank.Level'));
    });

    // CONTRAST CASE — proves the refusal above is not over-broad. A
    // refusal-only suite would pass against an implementation that refuses
    // every composite member write.
    test('a write to a member of a NON-forced composite SUCCEEDS', () {
      final p = buildProject();
      final vessel = p.tags.firstWhere((t) => t.name == 'Vessel');
      expect(vessel.isForced, isFalse);
      final results = applyAreaWrite(p, buildMap(), 'DB', 1, 34, toBytes([0x01, 0x02]));
      expect((vessel.value as Map)['Level'], 0x0102);
      final ok = results.where((r) => r.status == S7WriteStatus.written);
      expect(ok.map((r) => r.tag), contains('Vessel.Level'));
    });

    test('one refused item does not prevent another item in the same range from being written', () {
      final p = buildProject();
      final forced = p.tags.firstWhere((t) => t.name == 'Forced1');
      forced.isForced = true;
      // Bytes 28..31: RoTag (ReadOnly) at 28, Forced1 (forced) at 30.
      // Extend to 32..33 (Tank.Level, writable).
      final results = applyAreaWrite(
        p, buildMap(), 'DB', 1, 28,
        toBytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
      );
      expect(readPath(p, 'RoTag'), 11);
      expect(forced.value, 11);
      expect(readPath(p, 'Tank.Level'), 0x0506);
      expect(results.length, 3);
    });

    // THE CASE A HOISTED REFUSAL CHECK WOULD SILENTLY BREAK: two BOOLs
    // sharing one byte, one forced and one not. The correct behaviour is a
    // PER-ENTRY decision — the forced bit is protected while its non-forced
    // neighbour in the SAME byte still updates. A refactor that hoists the
    // refusal check out of the per-entry loop (checking it once per byte
    // instead of once per entry) would turn this into either a force bypass
    // (both bits update) or an over-broad refusal (neither bit updates), and
    // without this test the suite would stay green either way.
    test('two BOOLs in the same byte: a FORCED bit is protected, its neighbour still updates', () {
      final p = buildProject();
      final flag3 = p.tags.firstWhere((t) => t.name == 'Flag3');
      writePath(p, 'Flag3', false);
      writePath(p, 'Flag5', false);
      flag3.isForced = true;
      flag3.forcedValue = false;
      // Byte 0: bit3 = Flag3 (forced), bit5 = Flag5 (not forced). The
      // incoming byte sets BOTH bits.
      final results = applyAreaWrite(p, buildMap(), 'DB', 1, 0, toBytes([0x28]));
      expect(readPath(p, 'Flag3'), isFalse, reason: 'the forced bit must stay unchanged even though the incoming byte set it');
      expect(readPath(p, 'Flag5'), isTrue, reason: 'the non-forced neighbour in the SAME byte must still update');
      final flag3Result = results.firstWhere((r) => r.tag == 'Flag3');
      final flag5Result = results.firstWhere((r) => r.tag == 'Flag5');
      expect(flag3Result.status, S7WriteStatus.refusedForced);
      expect(flag5Result.status, S7WriteStatus.written);
    });

    test('two BOOLs in the same byte: a ReadOnly bit is protected, its neighbour still updates', () {
      final p = buildProject();
      final m = S7Map(entries: [
        S7MapEntry(tag: 'Flag3', area: 'DB', dbNumber: 1, byteOffset: 0, bitOffset: 3, access: 'ReadOnly'),
        S7MapEntry(tag: 'Flag5', area: 'DB', dbNumber: 1, byteOffset: 0, bitOffset: 5),
      ]);
      writePath(p, 'Flag3', false);
      writePath(p, 'Flag5', false);
      // Byte 0: bit3 = Flag3 (ReadOnly), bit5 = Flag5 (writable). The
      // incoming byte sets BOTH bits.
      final results = applyAreaWrite(p, m, 'DB', 1, 0, toBytes([0x28]));
      expect(readPath(p, 'Flag3'), isFalse, reason: 'the ReadOnly bit must stay unchanged even though the incoming byte set it');
      expect(readPath(p, 'Flag5'), isTrue, reason: 'the writable neighbour in the SAME byte must still update');
      final flag3Result = results.firstWhere((r) => r.tag == 'Flag3');
      final flag5Result = results.firstWhere((r) => r.tag == 'Flag5');
      expect(flag3Result.status, S7WriteStatus.refusedReadOnly);
      expect(flag5Result.status, S7WriteStatus.written);
    });

    test('malformed / out-of-range write arguments never throw', () {
      final p = buildProject();
      final m = buildMap();
      expect(applyAreaWrite(p, m, 'DB', 1, 0, toBytes([])), isEmpty);
      expect(applyAreaWrite(p, m, 'DB', 1, -4, toBytes([0x01, 0x02])), isEmpty);
      expect(applyAreaWrite(p, m, 'ZZ', 1, 0, toBytes([0x01])), isEmpty);
      expect(applyAreaWrite(p, m, 'DB', 99, 0, toBytes([0x01, 0x02])), isEmpty);
      // A mapping naming a tag that does not exist must be REPORTED as
      // unsupported rather than silently succeeding. (Asserting `isNotNull`
      // here would be vacuous: `applyAreaWrite` returns a non-nullable
      // `List<S7WriteResult>`, so that expectation cannot fail under any
      // implementation.)
      final missingTag = applyAreaWrite(
        p,
        S7Map(entries: [
          S7MapEntry(tag: 'NoSuchTag', area: 'DB', dbNumber: 1, byteOffset: 0, bitOffset: 0),
        ]),
        'DB', 1, 0, toBytes([0x01]),
      );
      expect(missingTag, hasLength(1));
      expect(missingTag.single.tag, 'NoSuchTag');
      expect(missingTag.single.status, S7WriteStatus.unsupported);
    });

    test('a write to a STRING-typed mapping is refused, not thrown on', () {
      final p = buildProject();
      p.tags.add(PlcTag(name: 'Txt', path: 'Txt', dataType: 'STRING', value: 'x', ioType: 'Internal'));
      final m = S7Map(entries: [
        S7MapEntry(tag: 'Txt', area: 'DB', dbNumber: 1, byteOffset: 0, bitOffset: 0),
      ]);
      final results = applyAreaWrite(p, m, 'DB', 1, 0, toBytes([0x41, 0x42]));
      expect(readPath(p, 'Txt'), 'x');
      expect(results.every((r) => r.status != S7WriteStatus.written), isTrue);
    });
  });
}

/// Shorthand for a literal byte buffer.
Uint8List toBytes(List<int> b) => Uint8List.fromList(b);
