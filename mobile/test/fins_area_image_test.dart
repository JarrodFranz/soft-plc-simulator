// Tests for the FINS area word-image (FINS workstream, Task 4).
//
// This is the highest-risk unit in the workstream: it is where an external
// network protocol materializes the app's named tags into a packed WORD image
// and, in the write direction, decodes a word range back onto the tags it
// overlaps.
//
// *** ENDIANNESS + THE 32-BIT WORD-ORDER TRAP ***
// FINS is BIG-ENDIAN within each 16-bit word. A 32-bit value (DINT/REAL)
// spans TWO consecutive words, and which word holds the high half is the
// documented Omron gotcha. This suite pins the layout with LITERAL expected
// bytes AND a hand-built two-word assertion of a known DINT: a build->parse
// round-trip would cancel a word-order error and prove nothing.
//
// CHOSEN ORDER: big-endian throughout, HIGH WORD FIRST (at the lower word
// address) — a 32-bit value's bytes laid out big-endian across both words with
// no word swap. This is consistent with the rest of the FINS stack being
// big-endian. Task 5's real `fins` E2E round-trip of a 32-bit value is the
// ultimate authority; if it disagrees, the client is right.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fins_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/fins/fins_area_image.dart';

void main() {
  PlcProject buildProject() => PlcProject(
        id: 'fins_img',
        name: 'FINS Image',
        controllerName: 'PLC_FINS',
        programs: [],
        tasks: [],
        hmis: [],
        structDefs: [
          PlcStructDef(name: 'VesselType', fields: [
            StructFieldDef(name: 'Level', dataType: 'INT16', defaultValue: 0),
          ]),
          PlcStructDef(name: 'SystemType', fields: [
            StructFieldDef(name: 'Cmd', dataType: 'INT16', defaultValue: 0),
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
          // Reserved System tag; its OWN access is deliberately 'ReadWrite'
          // so the backstop test isolates the NAME-based rule.
          PlcTag(
            name: 'System',
            path: 'System',
            dataType: 'SystemType',
            value: {'Cmd': 0},
            ioType: 'Internal',
            access: 'ReadWrite',
          ),
          // A SimulatedOutput tag with a deliberately writable map entry.
          PlcTag(name: 'SimOut', path: 'SimOut', dataType: 'INT16', value: 7, ioType: 'SimulatedOutput'),
        ],
      );

  // Word layout inside DM used below. Word 1, word 3, words 6..7 (past Dint1)
  // are deliberately UNMAPPED (gaps).
  FinsMap buildMap() => FinsMap(entries: [
        FinsMapEntry(tag: 'Flag3', area: 'DM', wordAddress: 0, bitOffset: 3),
        FinsMapEntry(tag: 'Flag5', area: 'DM', wordAddress: 0, bitOffset: 5),
        FinsMapEntry(tag: 'Word1', area: 'DM', wordAddress: 2, bitOffset: 0),
        FinsMapEntry(tag: 'Dint1', area: 'DM', wordAddress: 4, bitOffset: 0),
        FinsMapEntry(tag: 'Lint1', area: 'DM', wordAddress: 8, bitOffset: 0),
        FinsMapEntry(tag: 'Real1', area: 'DM', wordAddress: 12, bitOffset: 0),
        FinsMapEntry(tag: 'RoTag', area: 'DM', wordAddress: 14, bitOffset: 0, access: 'ReadOnly'),
        FinsMapEntry(tag: 'Forced1', area: 'DM', wordAddress: 15, bitOffset: 0),
        FinsMapEntry(tag: 'Tank.Level', area: 'DM', wordAddress: 16, bitOffset: 0),
        FinsMapEntry(tag: 'Vessel.Level', area: 'DM', wordAddress: 17, bitOffset: 0),
        // Both entries deliberately 'ReadWrite' (backstop fixtures).
        FinsMapEntry(tag: 'System.Cmd', area: 'DM', wordAddress: 18, bitOffset: 0),
        FinsMapEntry(tag: 'SimOut', area: 'DM', wordAddress: 19, bitOffset: 0),
      ]);

  group('readAreaImage — encoding, width and BIG-ENDIAN byte order', () {
    test('INT16 encodes as one big-endian word at its mapped offset', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102); // the two bytes DIFFER.
      final img = readAreaImage(p, buildMap(), 'DM', 2, 1);
      expect(img.length, 2);
      expect(img[0], 0x01, reason: 'high byte first (big-endian)');
      expect(img[1], 0x02);
    });

    // THE WORD-ORDER TRAP: a hand-built assertion of a known DINT across two
    // words. 0x12345678 => high word 0x1234 at the LOWER word address, low word
    // 0x5678 at the higher. A word-swapped implementation FAILS here even
    // though it would pass a build->parse round-trip.
    test('INT32 spans two words HIGH-WORD-FIRST, big-endian within each word', () {
      final p = buildProject();
      writePath(p, 'Dint1', 0x12345678);
      final img = readAreaImage(p, buildMap(), 'DM', 4, 2);
      expect(img.length, 4);
      expect(img, equals([0x12, 0x34, 0x56, 0x78]));
      // Word 4 (bytes 0..1) holds the HIGH half; word 5 (bytes 2..3) the low.
      expect(img.sublist(0, 2), equals([0x12, 0x34]), reason: 'high word at lower address');
      expect(img.sublist(2, 4), equals([0x56, 0x78]), reason: 'low word at higher address');
    });

    test('INT64 encodes as four big-endian words', () {
      final p = buildProject();
      writePath(p, 'Lint1', 0x0102030405060708);
      final img = readAreaImage(p, buildMap(), 'DM', 8, 4);
      expect(img, equals([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]));
    });

    test('a negative INT16 encodes in two\'s complement, big-endian', () {
      final p = buildProject();
      writePath(p, 'Word1', -2);
      final img = readAreaImage(p, buildMap(), 'DM', 2, 1);
      expect(img, equals([0xFF, 0xFE]));
    });

    test('FLOAT64 NARROWS to a 4-byte big-endian IEEE-754 REAL (two words)', () {
      const original = 1234.5678;
      final p = buildProject();
      writePath(p, 'Real1', original);
      final img = readAreaImage(p, buildMap(), 'DM', 12, 2);
      expect(img.length, 4, reason: 'REAL is 4 bytes / 2 words, not 8');
      // Sign+exponent high bits land FIRST — big-endian.
      expect(img[0], 0x44);
      expect(img[1], 0x9A);

      final back = decodeFinsReal(img);
      // Tolerance sits just above the true float32 round-trip error
      // (~5.1e-5 for this value), so a wide-open tolerance cannot hide a
      // non-narrowing implementation...
      expect(back, closeTo(original, 1e-4));
      // ...and this asserts the narrowing ACTUALLY happened: a double-width
      // implementation would return the original value exactly and FAIL.
      expect(back, isNot(equals(original)));
    });

    test('two BOOLs in the same word land in their own bits and do not disturb each other', () {
      final p = buildProject();
      writePath(p, 'Flag3', true);
      writePath(p, 'Flag5', false);
      var img = readAreaImage(p, buildMap(), 'DM', 0, 1);
      // Bit 3 lives in the LOW byte of the big-endian word (bits 0..7).
      expect(img, equals([0x00, 0x08]), reason: 'bit 3 only, low byte');

      writePath(p, 'Flag5', true);
      img = readAreaImage(p, buildMap(), 'DM', 0, 1);
      expect(img, equals([0x00, 0x28]), reason: 'bits 3 and 5');

      writePath(p, 'Flag3', false);
      img = readAreaImage(p, buildMap(), 'DM', 0, 1);
      expect(img, equals([0x00, 0x20]), reason: 'bit 5 only');
    });

    test('a BOOL in the high byte of a word (bit >= 8) is placed correctly', () {
      final p = buildProject();
      final m = FinsMap(entries: [
        FinsMapEntry(tag: 'Flag3', area: 'DM', wordAddress: 0, bitOffset: 11),
      ]);
      writePath(p, 'Flag3', true);
      final img = readAreaImage(p, m, 'DM', 0, 1);
      // Bit 11 -> high byte (bits 8..15), bit 3 of that byte -> 0x08.
      expect(img, equals([0x08, 0x00]));
    });
  });

  group('readAreaImage — gaps and bounds', () {
    test('unmapped words inside a requested range read as 0x0000', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102);
      final img = readAreaImage(p, buildMap(), 'DM', 0, 4);
      expect(img.sublist(2, 4), equals([0x00, 0x00]), reason: 'gap word 1');
    });

    test('a range entirely outside any mapping reads all zeros', () {
      final img = readAreaImage(buildProject(), buildMap(), 'DM', 200, 8);
      expect(img.length, 16);
      expect(img.every((b) => b == 0), isTrue);
    });

    test('a different area reads all zeros', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102);
      final img = readAreaImage(p, buildMap(), 'CIO', 0, 8);
      expect(img.every((b) => b == 0), isTrue);
    });

    test('a range partially overlapping a multi-word tag returns the overlapping words', () {
      final p = buildProject();
      writePath(p, 'Dint1', 0x12345678);
      // Read just the low word of Dint1 (word 5).
      final img = readAreaImage(p, buildMap(), 'DM', 5, 1);
      expect(img, equals([0x56, 0x78]));
    });

    test('malformed / out-of-range read arguments never throw', () {
      final p = buildProject();
      final m = buildMap();
      expect(readAreaImage(p, m, 'DM', 0, 0), isEmpty);
      expect(readAreaImage(p, m, 'DM', 0, -5), isEmpty);
      expect(readAreaImage(p, m, 'DM', -10, 4), isEmpty);
      expect(readAreaImage(p, m, 'ZZ', 0, 4).length, 8); // 4 words = 8 bytes, all zero
      expect(readAreaImage(p, m, 'DM', 0, 1 << 24).isEmpty, isTrue);
    });

    test('an entry naming a nonexistent tag is skipped, not thrown on', () {
      final p = buildProject();
      final m = FinsMap(entries: [
        FinsMapEntry(tag: 'NoSuchTag', area: 'DM', wordAddress: 0, bitOffset: 0),
      ]);
      final img = readAreaImage(p, m, 'DM', 0, 4);
      expect(img.every((b) => b == 0), isTrue);
    });
  });

  group('applyAreaWrite', () {
    test('a fully covered INT16 is decoded big-endian and written', () {
      final p = buildProject();
      final results = applyAreaWrite(p, buildMap(), 'DM', 2, toBytes([0x01, 0x02]));
      expect(readPath(p, 'Word1'), 0x0102);
      expect(results.where((r) => r.status == FinsWriteStatus.written).map((r) => r.tag), contains('Word1'));
    });

    test('a fully covered INT32 and INT64 are decoded big-endian, high word first', () {
      final p = buildProject();
      applyAreaWrite(p, buildMap(), 'DM', 4, toBytes([0x12, 0x34, 0x56, 0x78]));
      expect(readPath(p, 'Dint1'), 0x12345678);
      applyAreaWrite(
        p, buildMap(), 'DM', 8,
        toBytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
      );
      expect(readPath(p, 'Lint1'), 0x0102030405060708);
    });

    test('a REAL write decodes into the FLOAT64 tag (narrowing canary)', () {
      final p = buildProject();
      applyAreaWrite(p, buildMap(), 'DM', 12, toBytes([0x44, 0x9A, 0x52, 0x2B]));
      final v = readPath(p, 'Real1');
      expect(v, isA<double>());
      expect(v as double, closeTo(1234.5678, 1e-4));
      expect(v, isNot(equals(1234.5678)));
    });

    test('a BOOL write sets only its own bit', () {
      final p = buildProject();
      writePath(p, 'Flag5', true);
      // Word 0, bit 3 set (low byte 0x08), bit 5 clear.
      applyAreaWrite(p, buildMap(), 'DM', 0, toBytes([0x00, 0x08]));
      expect(readPath(p, 'Flag3'), isTrue);
      expect(readPath(p, 'Flag5'), isFalse);
    });

    test('writes to gap words are DISCARDED — no tag changes, nothing reported', () {
      final p = buildProject();
      final before = readPath(p, 'Word1');
      final results = applyAreaWrite(p, buildMap(), 'DM', 1, toBytes([0xAA, 0xBB]));
      expect(readPath(p, 'Word1'), before);
      expect(results, isEmpty);
    });

    test('a PARTIALLY covered multi-word tag is NOT written and IS reported', () {
      final p = buildProject();
      final before = readPath(p, 'Dint1');
      // Dint1 spans words 4..5; this range covers only word 4.
      final results = applyAreaWrite(p, buildMap(), 'DM', 4, toBytes([0xAA, 0xBB]));
      expect(readPath(p, 'Dint1'), before, reason: 'a partial write would corrupt the value');
      final partial = results.where((r) => r.status == FinsWriteStatus.partiallyCovered);
      expect(partial.map((r) => r.tag), contains('Dint1'));
    });

    test('a write to a ReadOnly map entry is REFUSED, tag unchanged', () {
      final p = buildProject();
      final results = applyAreaWrite(p, buildMap(), 'DM', 14, toBytes([0x01, 0x02]));
      expect(readPath(p, 'RoTag'), 11);
      final refused = results.where((r) => r.status == FinsWriteStatus.refusedReadOnly);
      expect(refused.map((r) => r.tag), contains('RoTag'));
    });

    test('a write to a FORCED scalar tag is REFUSED, tag unchanged', () {
      final p = buildProject();
      final forced = p.tags.firstWhere((t) => t.name == 'Forced1');
      forced.isForced = true;
      forced.forcedValue = 99;
      final results = applyAreaWrite(p, buildMap(), 'DM', 15, toBytes([0x01, 0x02]));
      expect(forced.value, 11, reason: 'the underlying tag value must be untouched');
      final refused = results.where((r) => r.status == FinsWriteStatus.refusedForced);
      expect(refused.map((r) => r.tag), contains('Forced1'));
    });

    // The force check must be made against the ROOT tag with NO
    // `root.name == tag` clause — otherwise a MEMBER path bypasses it.
    test('a write to a MEMBER beneath a FORCED root is REFUSED, member unchanged', () {
      final p = buildProject();
      final tank = p.tags.firstWhere((t) => t.name == 'Tank');
      tank.isForced = true;
      final results = applyAreaWrite(p, buildMap(), 'DM', 16, toBytes([0x01, 0x02]));
      expect((tank.value as Map)['Level'], 11, reason: 'member write must not bypass the force');
      final refused = results.where((r) => r.status == FinsWriteStatus.refusedForced);
      expect(refused.map((r) => r.tag), contains('Tank.Level'));
    });

    // CONTRAST CASE — proves the refusal above is not over-broad.
    test('a write to a member of a NON-forced composite SUCCEEDS', () {
      final p = buildProject();
      final vessel = p.tags.firstWhere((t) => t.name == 'Vessel');
      expect(vessel.isForced, isFalse);
      final results = applyAreaWrite(p, buildMap(), 'DM', 17, toBytes([0x01, 0x02]));
      expect((vessel.value as Map)['Level'], 0x0102);
      final ok = results.where((r) => r.status == FinsWriteStatus.written);
      expect(ok.map((r) => r.tag), contains('Vessel.Level'));
    });

    test('one refused item does not prevent another item in the same range from being written', () {
      final p = buildProject();
      final forced = p.tags.firstWhere((t) => t.name == 'Forced1');
      forced.isForced = true;
      // Words 14..16: RoTag (ReadOnly) at 14, Forced1 (forced) at 15,
      // Tank.Level (writable) at 16.
      final results = applyAreaWrite(
        p, buildMap(), 'DM', 14,
        toBytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
      );
      expect(readPath(p, 'RoTag'), 11);
      expect(forced.value, 11);
      expect(readPath(p, 'Tank.Level'), 0x0506);
      expect(results.length, 3);
    });

    test('malformed / out-of-range write arguments never throw', () {
      final p = buildProject();
      final m = buildMap();
      expect(applyAreaWrite(p, m, 'DM', 0, toBytes([])), isEmpty);
      expect(applyAreaWrite(p, m, 'DM', -4, toBytes([0x01, 0x02])), isEmpty);
      expect(applyAreaWrite(p, m, 'ZZ', 0, toBytes([0x01, 0x02])), isEmpty);
      // A mapping naming a tag that does not exist must be REPORTED as
      // unsupported rather than silently succeeding.
      final missingTag = applyAreaWrite(
        p,
        FinsMap(entries: [
          FinsMapEntry(tag: 'NoSuchTag', area: 'DM', wordAddress: 0, bitOffset: 0),
        ]),
        'DM', 0, toBytes([0x01, 0x02]),
      );
      expect(missingTag, hasLength(1));
      expect(missingTag.single.tag, 'NoSuchTag');
      expect(missingTag.single.status, FinsWriteStatus.unsupported);
    });

    test('a write to a STRING-typed mapping is refused, not thrown on', () {
      final p = buildProject();
      p.tags.add(PlcTag(name: 'Txt', path: 'Txt', dataType: 'STRING', value: 'x', ioType: 'Internal'));
      final m = FinsMap(entries: [
        FinsMapEntry(tag: 'Txt', area: 'DM', wordAddress: 0, bitOffset: 0),
      ]);
      final results = applyAreaWrite(p, m, 'DM', 0, toBytes([0x41, 0x42]));
      expect(readPath(p, 'Txt'), 'x');
      expect(results.every((r) => r.status != FinsWriteStatus.written), isTrue);
    });

    group('write-time backstop', () {
      test(
          'a WRITABLE map entry pointing at a System member is REFUSED, member unchanged '
          '(the map entry alone would otherwise allow this write)', () {
        final p = buildProject();
        final systemTag = p.tags.firstWhere((t) => t.name == 'System');
        expect(systemTag.access, 'ReadWrite', reason: "the tag's OWN access is deliberately not ReadOnly");
        final before = (systemTag.value as Map)['Cmd'];

        final results = applyAreaWrite(p, buildMap(), 'DM', 18, toBytes([0x03, 0xE7]));
        final after = (p.tags.firstWhere((t) => t.name == 'System').value as Map)['Cmd'];
        expect(after, before, reason: 'a refused write must never land');
        final refused = results.where((r) => r.tag == 'System.Cmd');
        expect(refused, isNotEmpty);
        expect(refused.single.status, FinsWriteStatus.refusedNotExternallyWritable);
      });

      test('a WRITABLE map entry pointing at a SimulatedOutput tag still succeeds (deliberate override survives)', () {
        final p = buildProject();
        final results = applyAreaWrite(p, buildMap(), 'DM', 19, toBytes([0x01, 0x41]));
        expect(readPath(p, 'SimOut'), 0x0141);
        final ok = results.where((r) => r.tag == 'SimOut' && r.status == FinsWriteStatus.written);
        expect(ok, isNotEmpty);
      });

      test('a normal Internal ReadWrite tag still writes successfully — the backstop is not over-broad', () {
        final p = buildProject();
        final results = applyAreaWrite(p, buildMap(), 'DM', 2, toBytes([0x00, 0x64]));
        expect(readPath(p, 'Word1'), 100);
        final ok = results.where((r) => r.tag == 'Word1' && r.status == FinsWriteStatus.written);
        expect(ok, isNotEmpty);
      });
    });
  });
}

/// Shorthand for a literal byte buffer.
Uint8List toBytes(List<int> b) => Uint8List.fromList(b);
