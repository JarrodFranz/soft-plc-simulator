// Tests for the SLMP device word-image (SLMP workstream, Task 4).
//
// This is the highest-risk unit in the workstream: it is where an external MC
// client materializes the app's named tags into a packed WORD image and, in the
// write direction, decodes a word range back onto the tags it overlaps.
//
// *** ENDIANNESS + THE 32-BIT WORD-ORDER TRAP (provisional pending Task 5) ***
// SLMP 3E binary word data is LITTLE-ENDIAN within each 16-bit word (the
// EXACT INVERSE of FINS, which is big-endian). A 32-bit value (DINT/REAL) spans
// TWO consecutive words, and which word holds the high half is the documented
// Mitsubishi gotcha. This suite pins the layout with LITERAL expected bytes AND
// a hand-built two-word assertion of a known DINT: a build->parse round-trip
// would cancel a word-order error and prove nothing.
//
// PROVISIONAL ORDER: little-endian within each word, LOW WORD FIRST (least
// significant word at the lower device address) -- the natural SLMP
// little-endian layout, matching Mitsubishi's documented D(n)=low / D(n+1)=high
// 32-bit convention. Task 5's real `pymcprotocol` read-back E2E settles it. DINT
// 0x12345678 => low word 0x5678 at the lower address (bytes 0x78,0x56), high
// word 0x1234 at the higher (bytes 0x34,0x12).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/slmp_map.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_commands.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_device_image.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_dispatch.dart';
import 'package:soft_plc_mobile/protocols/slmp/slmp_frame.dart';

void main() {
  PlcProject buildProject() => PlcProject(
        id: 'slmp_img',
        name: 'SLMP Image',
        controllerName: 'PLC_SLMP',
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

  // Word layout inside D used below. Address 1, address 3, addresses 6..7 (past
  // Dint1) are deliberately UNMAPPED (gaps).
  SlmpMap buildMap() => SlmpMap(entries: [
        SlmpMapEntry(tag: 'Flag3', device: 'D', address: 0, bitOffset: 3),
        SlmpMapEntry(tag: 'Flag5', device: 'D', address: 0, bitOffset: 5),
        SlmpMapEntry(tag: 'Word1', device: 'D', address: 2, bitOffset: 0),
        SlmpMapEntry(tag: 'Dint1', device: 'D', address: 4, bitOffset: 0),
        SlmpMapEntry(tag: 'Lint1', device: 'D', address: 8, bitOffset: 0),
        SlmpMapEntry(tag: 'Real1', device: 'D', address: 12, bitOffset: 0),
        SlmpMapEntry(tag: 'RoTag', device: 'D', address: 14, bitOffset: 0, access: 'ReadOnly'),
        SlmpMapEntry(tag: 'Forced1', device: 'D', address: 15, bitOffset: 0),
        SlmpMapEntry(tag: 'Tank.Level', device: 'D', address: 16, bitOffset: 0),
        SlmpMapEntry(tag: 'Vessel.Level', device: 'D', address: 17, bitOffset: 0),
        // Both entries deliberately 'ReadWrite' (backstop fixtures).
        SlmpMapEntry(tag: 'System.Cmd', device: 'D', address: 18, bitOffset: 0),
        SlmpMapEntry(tag: 'SimOut', device: 'D', address: 19, bitOffset: 0),
      ]);

  group('readDeviceImage — encoding, width and LITTLE-ENDIAN byte order', () {
    test('INT16 encodes as one little-endian word at its mapped address', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102); // the two bytes DIFFER.
      final img = readDeviceImage(p, buildMap(), 'D', 2, 1);
      expect(img.length, 2);
      expect(img[0], 0x02, reason: 'low byte first (little-endian)');
      expect(img[1], 0x01);
    });

    // THE WORD-ORDER TRAP: a hand-built assertion of a known DINT across two
    // words. PROVISIONAL LOW-WORD-FIRST: 0x12345678 => low word 0x5678 at the
    // LOWER address (bytes 0x78,0x56), high word 0x1234 at the higher (bytes
    // 0x34,0x12). A high-word-first implementation FAILS here even though it
    // would pass a build->parse round-trip.
    test('INT32 spans two words LOW-WORD-FIRST, little-endian within each word', () {
      final p = buildProject();
      writePath(p, 'Dint1', 0x12345678);
      final img = readDeviceImage(p, buildMap(), 'D', 4, 2);
      expect(img.length, 4);
      expect(img, equals([0x78, 0x56, 0x34, 0x12]));
      // Word 4 (bytes 0..1) holds the LOW half; word 5 (bytes 2..3) the high.
      expect(img.sublist(0, 2), equals([0x78, 0x56]), reason: 'low word at lower address');
      expect(img.sublist(2, 4), equals([0x34, 0x12]), reason: 'high word at higher address');
    });

    test('INT64 encodes as four little-endian words, low word first', () {
      final p = buildProject();
      writePath(p, 'Lint1', 0x0102030405060708);
      final img = readDeviceImage(p, buildMap(), 'D', 8, 4);
      // Whole value little-endian, low word first: least significant byte first.
      expect(img, equals([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]));
    });

    test('a negative INT16 encodes in two\'s complement, little-endian', () {
      final p = buildProject();
      writePath(p, 'Word1', -2);
      final img = readDeviceImage(p, buildMap(), 'D', 2, 1);
      expect(img, equals([0xFE, 0xFF]));
    });

    test('FLOAT64 NARROWS to a 4-byte little-endian IEEE-754 REAL (two words)', () {
      const original = 1234.5678;
      final p = buildProject();
      writePath(p, 'Real1', original);
      final img = readDeviceImage(p, buildMap(), 'D', 12, 2);
      expect(img.length, 4, reason: 'REAL is 4 bytes / 2 words, not 8');
      // float32(1234.5678) big-endian is 44 9A 52 2B; little-endian (low word
      // first) is the byte-reverse: 2B 52 9A 44.
      expect(img[0], 0x2B);
      expect(img[1], 0x52);
      expect(img[2], 0x9A);
      expect(img[3], 0x44);

      final back = decodeSlmpReal(img);
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
      var img = readDeviceImage(p, buildMap(), 'D', 0, 1);
      // Bit 3 lives in the LOW byte of the little-endian word (bits 0..7).
      expect(img, equals([0x08, 0x00]), reason: 'bit 3 only, low byte');

      writePath(p, 'Flag5', true);
      img = readDeviceImage(p, buildMap(), 'D', 0, 1);
      expect(img, equals([0x28, 0x00]), reason: 'bits 3 and 5');

      writePath(p, 'Flag3', false);
      img = readDeviceImage(p, buildMap(), 'D', 0, 1);
      expect(img, equals([0x20, 0x00]), reason: 'bit 5 only');
    });

    test('a BOOL in the high byte of a word (bit >= 8) is placed correctly', () {
      final p = buildProject();
      final m = SlmpMap(entries: [
        SlmpMapEntry(tag: 'Flag3', device: 'D', address: 0, bitOffset: 11),
      ]);
      writePath(p, 'Flag3', true);
      final img = readDeviceImage(p, m, 'D', 0, 1);
      // Bit 11 -> high byte (bits 8..15), bit 3 of that byte -> 0x08.
      expect(img, equals([0x00, 0x08]));
    });
  });

  group('readDeviceImage — gaps and bounds', () {
    test('unmapped words inside a requested range read as 0x0000', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102);
      final img = readDeviceImage(p, buildMap(), 'D', 0, 4);
      expect(img.sublist(2, 4), equals([0x00, 0x00]), reason: 'gap word 1');
    });

    test('a range entirely outside any mapping reads all zeros', () {
      final img = readDeviceImage(buildProject(), buildMap(), 'D', 200, 8);
      expect(img.length, 16);
      expect(img.every((b) => b == 0), isTrue);
    });

    test('a different device reads all zeros', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102);
      final img = readDeviceImage(p, buildMap(), 'M', 0, 8);
      expect(img.every((b) => b == 0), isTrue);
    });

    test('a range partially overlapping a multi-word tag returns the overlapping words', () {
      final p = buildProject();
      writePath(p, 'Dint1', 0x12345678);
      // Read just the SECOND word of Dint1 (address 5). Low-word-first puts the
      // LOW word at address 4, so address 5 holds the HIGH half (0x1234).
      final img = readDeviceImage(p, buildMap(), 'D', 5, 1);
      expect(img, equals([0x34, 0x12]));
    });

    test('malformed / out-of-range read arguments never throw', () {
      final p = buildProject();
      final m = buildMap();
      expect(readDeviceImage(p, m, 'D', 0, 0), isEmpty);
      expect(readDeviceImage(p, m, 'D', 0, -5), isEmpty);
      expect(readDeviceImage(p, m, 'D', -10, 4), isEmpty);
      expect(readDeviceImage(p, m, 'ZZ', 0, 4).length, 8); // 4 words = 8 bytes, all zero
      expect(readDeviceImage(p, m, 'D', 0, 1 << 24).isEmpty, isTrue);
    });

    test('an entry naming a nonexistent tag is skipped, not thrown on', () {
      final p = buildProject();
      final m = SlmpMap(entries: [
        SlmpMapEntry(tag: 'NoSuchTag', device: 'D', address: 0, bitOffset: 0),
      ]);
      final img = readDeviceImage(p, m, 'D', 0, 4);
      expect(img.every((b) => b == 0), isTrue);
    });
  });

  group('applyDeviceWrite', () {
    test('a fully covered INT16 is decoded little-endian and written', () {
      final p = buildProject();
      final results = applyDeviceWrite(p, buildMap(), 'D', 2, toBytes([0x02, 0x01]));
      expect(readPath(p, 'Word1'), 0x0102);
      expect(results.where((r) => r.status == SlmpWriteStatus.written).map((r) => r.tag), contains('Word1'));
    });

    test('a fully covered INT32 and INT64 are decoded little-endian, low word first', () {
      final p = buildProject();
      // Wire is LOW-WORD-FIRST, little-endian: [78 56][34 12] decodes to 0x12345678.
      applyDeviceWrite(p, buildMap(), 'D', 4, toBytes([0x78, 0x56, 0x34, 0x12]));
      expect(readPath(p, 'Dint1'), 0x12345678);
      // [08 07][06 05][04 03][02 01] decodes to 0x0102030405060708.
      applyDeviceWrite(
        p, buildMap(), 'D', 8,
        toBytes([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]),
      );
      expect(readPath(p, 'Lint1'), 0x0102030405060708);
    });

    test('a REAL write decodes into the FLOAT64 tag (narrowing canary)', () {
      final p = buildProject();
      // float32 1234.5678 little-endian (low word first) is 2B 52 9A 44.
      applyDeviceWrite(p, buildMap(), 'D', 12, toBytes([0x2B, 0x52, 0x9A, 0x44]));
      final v = readPath(p, 'Real1');
      expect(v, isA<double>());
      expect(v as double, closeTo(1234.5678, 1e-4));
      expect(v, isNot(equals(1234.5678)));
    });

    test('a BOOL write sets only its own bit', () {
      final p = buildProject();
      writePath(p, 'Flag5', true);
      // Word 0, bit 3 set (low byte 0x08), bit 5 clear.
      applyDeviceWrite(p, buildMap(), 'D', 0, toBytes([0x08, 0x00]));
      expect(readPath(p, 'Flag3'), isTrue);
      expect(readPath(p, 'Flag5'), isFalse);
    });

    test('writes to gap words are DISCARDED — no tag changes, nothing reported', () {
      final p = buildProject();
      final before = readPath(p, 'Word1');
      final results = applyDeviceWrite(p, buildMap(), 'D', 1, toBytes([0xAA, 0xBB]));
      expect(readPath(p, 'Word1'), before);
      expect(results, isEmpty);
    });

    test('a PARTIALLY covered multi-word tag is NOT written and IS reported', () {
      final p = buildProject();
      final before = readPath(p, 'Dint1');
      // Dint1 spans words 4..5; this range covers only word 4.
      final results = applyDeviceWrite(p, buildMap(), 'D', 4, toBytes([0xAA, 0xBB]));
      expect(readPath(p, 'Dint1'), before, reason: 'a partial write would corrupt the value');
      final partial = results.where((r) => r.status == SlmpWriteStatus.partiallyCovered);
      expect(partial.map((r) => r.tag), contains('Dint1'));
    });

    test('a write to a ReadOnly map entry is REFUSED, tag unchanged', () {
      final p = buildProject();
      final results = applyDeviceWrite(p, buildMap(), 'D', 14, toBytes([0x02, 0x01]));
      expect(readPath(p, 'RoTag'), 11);
      final refused = results.where((r) => r.status == SlmpWriteStatus.refusedReadOnly);
      expect(refused.map((r) => r.tag), contains('RoTag'));
    });

    test('a write to a FORCED scalar tag is REFUSED, tag unchanged', () {
      final p = buildProject();
      final forced = p.tags.firstWhere((t) => t.name == 'Forced1');
      forced.isForced = true;
      forced.forcedValue = 99;
      final results = applyDeviceWrite(p, buildMap(), 'D', 15, toBytes([0x02, 0x01]));
      expect(forced.value, 11, reason: 'the underlying tag value must be untouched');
      final refused = results.where((r) => r.status == SlmpWriteStatus.refusedForced);
      expect(refused.map((r) => r.tag), contains('Forced1'));
    });

    // The force check must be made against the ROOT tag with NO
    // `root.name == tag` clause — otherwise a MEMBER path bypasses it.
    test('a write to a MEMBER beneath a FORCED root is REFUSED, member unchanged', () {
      final p = buildProject();
      final tank = p.tags.firstWhere((t) => t.name == 'Tank');
      tank.isForced = true;
      final results = applyDeviceWrite(p, buildMap(), 'D', 16, toBytes([0x02, 0x01]));
      expect((tank.value as Map)['Level'], 11, reason: 'member write must not bypass the force');
      final refused = results.where((r) => r.status == SlmpWriteStatus.refusedForced);
      expect(refused.map((r) => r.tag), contains('Tank.Level'));
    });

    // CONTRAST CASE — proves the refusal above is not over-broad.
    test('a write to a member of a NON-forced composite SUCCEEDS', () {
      final p = buildProject();
      final vessel = p.tags.firstWhere((t) => t.name == 'Vessel');
      expect(vessel.isForced, isFalse);
      final results = applyDeviceWrite(p, buildMap(), 'D', 17, toBytes([0x02, 0x01]));
      expect((vessel.value as Map)['Level'], 0x0102);
      final ok = results.where((r) => r.status == SlmpWriteStatus.written);
      expect(ok.map((r) => r.tag), contains('Vessel.Level'));
    });

    test('one refused item does not prevent another item in the same range from being written', () {
      final p = buildProject();
      final forced = p.tags.firstWhere((t) => t.name == 'Forced1');
      forced.isForced = true;
      // Words 14..16: RoTag (ReadOnly) at 14, Forced1 (forced) at 15,
      // Tank.Level (writable) at 16.
      final results = applyDeviceWrite(
        p, buildMap(), 'D', 14,
        toBytes([0x01, 0x02, 0x03, 0x04, 0x06, 0x05]),
      );
      expect(readPath(p, 'RoTag'), 11);
      expect(forced.value, 11);
      expect(readPath(p, 'Tank.Level'), 0x0506);
      expect(results.length, 3);
    });

    test('malformed / out-of-range write arguments never throw', () {
      final p = buildProject();
      final m = buildMap();
      expect(applyDeviceWrite(p, m, 'D', 0, toBytes([])), isEmpty);
      expect(applyDeviceWrite(p, m, 'D', -4, toBytes([0x01, 0x02])), isEmpty);
      expect(applyDeviceWrite(p, m, 'ZZ', 0, toBytes([0x01, 0x02])), isEmpty);
      // A mapping naming a tag that does not exist must be REPORTED as
      // unsupported rather than silently succeeding.
      final missingTag = applyDeviceWrite(
        p,
        SlmpMap(entries: [
          SlmpMapEntry(tag: 'NoSuchTag', device: 'D', address: 0, bitOffset: 0),
        ]),
        'D', 0, toBytes([0x01, 0x02]),
      );
      expect(missingTag, hasLength(1));
      expect(missingTag.single.tag, 'NoSuchTag');
      expect(missingTag.single.status, SlmpWriteStatus.unsupported);
    });

    test('a write to a STRING-typed mapping is refused, not thrown on', () {
      final p = buildProject();
      p.tags.add(PlcTag(name: 'Txt', path: 'Txt', dataType: 'STRING', value: 'x', ioType: 'Internal'));
      final m = SlmpMap(entries: [
        SlmpMapEntry(tag: 'Txt', device: 'D', address: 0, bitOffset: 0),
      ]);
      final results = applyDeviceWrite(p, m, 'D', 0, toBytes([0x41, 0x42]));
      expect(readPath(p, 'Txt'), 'x');
      expect(results.every((r) => r.status != SlmpWriteStatus.written), isTrue);
    });

    group('write-time backstop', () {
      test(
          'a WRITABLE map entry pointing at a System member is REFUSED, member unchanged '
          '(the map entry alone would otherwise allow this write)', () {
        final p = buildProject();
        final systemTag = p.tags.firstWhere((t) => t.name == 'System');
        expect(systemTag.access, 'ReadWrite', reason: "the tag's OWN access is deliberately not ReadOnly");
        final before = (systemTag.value as Map)['Cmd'];

        final results = applyDeviceWrite(p, buildMap(), 'D', 18, toBytes([0xE7, 0x03]));
        final after = (p.tags.firstWhere((t) => t.name == 'System').value as Map)['Cmd'];
        expect(after, before, reason: 'a refused write must never land');
        final refused = results.where((r) => r.tag == 'System.Cmd');
        expect(refused, isNotEmpty);
        expect(refused.single.status, SlmpWriteStatus.refusedNotExternallyWritable);
      });

      test('a WRITABLE map entry pointing at a SimulatedOutput tag still succeeds (deliberate override survives)', () {
        final p = buildProject();
        final results = applyDeviceWrite(p, buildMap(), 'D', 19, toBytes([0x41, 0x01]));
        expect(readPath(p, 'SimOut'), 0x0141);
        final ok = results.where((r) => r.tag == 'SimOut' && r.status == SlmpWriteStatus.written);
        expect(ok, isNotEmpty);
      });

      test('a normal Internal ReadWrite tag still writes successfully — the backstop is not over-broad', () {
        final p = buildProject();
        final results = applyDeviceWrite(p, buildMap(), 'D', 2, toBytes([0x64, 0x00]));
        expect(readPath(p, 'Word1'), 100);
        final ok = results.where((r) => r.tag == 'Word1' && r.status == SlmpWriteStatus.written);
        expect(ok, isNotEmpty);
      });
    });
  });

  // The Task-3 dispatch write branch (command 0x1401) was built but left
  // unexercised. These tests exercise it through the tag-backed SlmpTagImage:
  // a Batch Write frame decoded back onto a real tag, and a refused write
  // reporting an access end code with the tag unchanged.
  group('dispatchSlmpFrame — Batch Write against the tag-backed image', () {
    test('a Batch Write to a writable tag lands and returns the normal end code', () {
      final p = buildProject();
      final image = SlmpTagImage(p, buildMap());
      // Write 0x0102 into Word1 (D2): little-endian word 0x02, 0x01.
      final frame = _buildBatchWriteD(2, [0x0102]);
      final reply = dispatchSlmpFrame(frame, image);
      expect(reply, isNotNull);
      expect(_endCodeOf(reply!), kSlmpEndNormal);
      expect(readPath(p, 'Word1'), 0x0102);
    });

    test('a Batch Write to a ReadOnly tag is refused with an access end code, tag unchanged', () {
      final p = buildProject();
      final image = SlmpTagImage(p, buildMap());
      // D14 is RoTag (ReadOnly).
      final frame = _buildBatchWriteD(14, [0x0102]);
      final reply = dispatchSlmpFrame(frame, image);
      expect(reply, isNotNull);
      expect(_endCodeOf(reply!), kSlmpEndWriteProtect);
      expect(readPath(p, 'RoTag'), 11, reason: 'a refused write must never land');
    });

    test('a Batch Read against the tag-backed image returns the mapped word little-endian', () {
      final p = buildProject();
      writePath(p, 'Word1', 0x0102);
      final image = SlmpTagImage(p, buildMap());
      final frame = _buildBatchReadD(2, 1);
      final reply = dispatchSlmpFrame(frame, image);
      expect(reply, isNotNull);
      expect(_endCodeOf(reply!), kSlmpEndNormal);
      // Word data begins after the 11-byte fixed response header, little-endian.
      final bd = ByteData.sublistView(reply);
      expect(bd.getUint16(kSlmpResponseFixedLen, Endian.little), 0x0102);
    });
  });
}

/// Shorthand for a literal byte buffer.
Uint8List toBytes(List<int> b) => Uint8List.fromList(b);

/// The response end code (little-endian u16 at offset 9) of a built reply.
int _endCodeOf(Uint8List reply) =>
    ByteData.sublistView(reply).getUint16(9, Endian.little);

/// Builds a 3E Batch Read (word) request for [count] words at D[deviceNumber].
Uint8List _buildBatchReadD(int deviceNumber, int count) {
  const requestDataLength = 2 + 2 + 2 + kSlmpDeviceSpecLen; // timer+cmd+subcmd+spec
  final out = Uint8List(9 + requestDataLength);
  final bd = ByteData.sublistView(out);
  bd.setUint16(0, kSlmpRequestSubheader, Endian.big);
  out[2] = 0x00; // network
  out[3] = 0xFF; // pc
  bd.setUint16(4, 0x03FF, Endian.little); // destModuleIo
  out[6] = 0x00; // destModuleStation
  bd.setUint16(7, requestDataLength, Endian.little);
  bd.setUint16(9, 0x0000, Endian.little); // monitoringTimer
  bd.setUint16(11, kSlmpCmdBatchReadWord, Endian.little);
  bd.setUint16(13, kSlmpSubcmdWord, Endian.little);
  out[15] = deviceNumber & 0xFF;
  out[16] = (deviceNumber >> 8) & 0xFF;
  out[17] = (deviceNumber >> 16) & 0xFF;
  out[18] = kSlmpDevD;
  bd.setUint16(19, count, Endian.little);
  return out;
}

/// Builds a 3E Batch Write (word) request writing [words] into D[deviceNumber].
Uint8List _buildBatchWriteD(int deviceNumber, List<int> words) {
  final requestDataLength = 2 + 2 + 2 + kSlmpDeviceSpecLen + words.length * 2;
  final out = Uint8List(9 + requestDataLength);
  final bd = ByteData.sublistView(out);
  bd.setUint16(0, kSlmpRequestSubheader, Endian.big);
  out[2] = 0x00; // network
  out[3] = 0xFF; // pc
  bd.setUint16(4, 0x03FF, Endian.little); // destModuleIo
  out[6] = 0x00; // destModuleStation
  bd.setUint16(7, requestDataLength, Endian.little);
  bd.setUint16(9, 0x0000, Endian.little); // monitoringTimer
  bd.setUint16(11, kSlmpCmdBatchWriteWord, Endian.little);
  bd.setUint16(13, kSlmpSubcmdWord, Endian.little);
  out[15] = deviceNumber & 0xFF;
  out[16] = (deviceNumber >> 8) & 0xFF;
  out[17] = (deviceNumber >> 16) & 0xFF;
  out[18] = kSlmpDevD;
  bd.setUint16(19, words.length, Endian.little);
  for (var i = 0; i < words.length; i++) {
    bd.setUint16(21 + i * 2, words[i] & 0xFFFF, Endian.little);
  }
  return out;
}
