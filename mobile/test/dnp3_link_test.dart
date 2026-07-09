// Tests for the DNP3 Data Link Layer codec (DNP3 outstation Task 2): the
// reflected CRC-16/DNP, the 0x0564 link frame (10-byte header block + 16-byte
// user-data blocks each with its own CRC), and the streaming DnpLinkBuffer
// TCP reassembler.
//
// CRC cross-validation: `dnpCrc` is checked against reference values computed
// TWO independent ways outside this codebase (see task-2-report.md for the
// exact commands/output):
//   (a) Python's `crcmod` library's predefined `crc-16-dnp` CRC function
//       (a third-party, independently-authored implementation using the
//       standard width/poly/init/refin/refout/xorout parameter model).
//   (b) A from-scratch Python MSB-first bit-by-bit polynomial-division
//       implementation with explicit input/output bit reflection -- written
//       independently of the reflected shift-register trick this Dart file
//       uses (no shared code/constants with dnp3_link.dart).
// Both independent methods agree exactly on every vector below. Task 6's
// real Rust `dnp3` master remains the final wire-level authority.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_link.dart';

void main() {
  group('dnpCrc (CRC-16/DNP) cross-validated against independent references', () {
    test('empty input', () {
      expect(dnpCrc(const <int>[]), 0xFFFF);
    });

    test('single zero byte', () {
      expect(dnpCrc(const <int>[0x00]), 0xFFFF);
    });

    test('single 0xFF byte', () {
      expect(dnpCrc(const <int>[0xFF]), 0xEDCA);
    });

    test('the 8-byte link-header field bytes', () {
      // [start1, start2, length, control, destLo, destHi, srcLo, srcHi]
      const headerBytes = <int>[0x05, 0x64, 0x05, 0xC0, 0x01, 0x00, 0x00, 0x04];
      expect(dnpCrc(headerBytes), 0x21E9);
    });

    test('16 bytes 0x00..0x0F (a full data block)', () {
      final block = List<int>.generate(16, (i) => i);
      expect(dnpCrc(block), 0x10EC);
    });

    test(r'ASCII "123456789" (classic CRC catalogue check string)', () {
      expect(dnpCrc('123456789'.codeUnits), 0xEA82);
    });
  });

  group('buildLinkFrame / parseLinkFrame', () {
    test('round-trips a frame with no user data', () {
      final frame = buildLinkFrame(
        control: 0xC0,
        dest: 1,
        src: 4,
        userData: Uint8List(0),
      );
      // 10-byte header block only.
      expect(frame.length, 10);
      expect(frame[0], 0x05);
      expect(frame[1], 0x64);
      expect(frame[2], 5); // LENGTH = 5 + 0 user data bytes.

      final parsed = parseLinkFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.control, 0xC0);
      expect(parsed.dest, 1);
      expect(parsed.src, 4);
      expect(parsed.userData, isEmpty);
    });

    test('header block CRC matches dnpCrc of the first 8 bytes', () {
      final frame = buildLinkFrame(
        control: 0xC0,
        dest: 1,
        src: 4,
        userData: Uint8List(0),
      );
      final expectedCrc = dnpCrc(frame.sublist(0, 8));
      final actualCrc = frame[8] | (frame[9] << 8);
      expect(actualCrc, expectedCrc);
    });

    test('round-trips a small user-data payload (single partial block)', () {
      final userData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = buildLinkFrame(control: 0x44, dest: 1234, src: 5678, userData: userData);
      // header(10) + data(5) + block CRC(2)
      expect(frame.length, 17);

      final parsed = parseLinkFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.control, 0x44);
      expect(parsed.dest, 1234);
      expect(parsed.src, 5678);
      expect(parsed.userData, userData);
    });

    test('round-trips a payload spanning exactly two blocks (16 + 16 bytes)', () {
      final userData = Uint8List.fromList(List<int>.generate(32, (i) => i & 0xFF));
      final frame = buildLinkFrame(control: 0x44, dest: 1, src: 2, userData: userData);
      // header(10) + block1 data(16) + block1 crc(2) + block2 data(16) + block2 crc(2)
      expect(frame.length, 10 + 16 + 2 + 16 + 2);

      final parsed = parseLinkFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.userData, userData);
    });

    test('round-trips a payload spanning a full block + partial block (16 + 3 bytes)', () {
      final userData = Uint8List.fromList(List<int>.generate(19, (i) => 0xA0 + i));
      final frame = buildLinkFrame(control: 0x44, dest: 1, src: 2, userData: userData);
      expect(frame.length, 10 + 16 + 2 + 3 + 2);

      final parsed = parseLinkFrame(frame);
      expect(parsed, isNotNull);
      expect(parsed!.userData, userData);
    });

    test('wrong start bytes -> null', () {
      final frame = buildLinkFrame(control: 0xC0, dest: 1, src: 4, userData: Uint8List(0));
      final corrupted = Uint8List.fromList(frame);
      corrupted[0] = 0x00;
      expect(parseLinkFrame(corrupted), isNull);
    });

    test('corrupted header CRC -> null', () {
      final frame = buildLinkFrame(control: 0xC0, dest: 1, src: 4, userData: Uint8List(0));
      final corrupted = Uint8List.fromList(frame);
      corrupted[8] ^= 0xFF;
      expect(parseLinkFrame(corrupted), isNull);
    });

    test('corrupted data-block CRC -> null', () {
      final userData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = buildLinkFrame(control: 0x44, dest: 1, src: 2, userData: userData);
      final corrupted = Uint8List.fromList(frame);
      corrupted[corrupted.length - 1] ^= 0xFF;
      expect(parseLinkFrame(corrupted), isNull);
    });

    test('flipped user-data byte (CRC no longer matches) -> null', () {
      final userData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = buildLinkFrame(control: 0x44, dest: 1, src: 2, userData: userData);
      final corrupted = Uint8List.fromList(frame);
      corrupted[10] ^= 0xFF; // first user-data byte, inside the block.
      expect(parseLinkFrame(corrupted), isNull);
    });

    test('short/truncated frame -> null (never throws)', () {
      final frame = buildLinkFrame(control: 0x44, dest: 1, src: 2, userData: Uint8List.fromList([1, 2, 3]));
      for (var cut = 0; cut < frame.length; cut++) {
        final truncated = Uint8List.fromList(frame.sublist(0, cut));
        expect(() => parseLinkFrame(truncated), returnsNormally);
        if (cut < frame.length) {
          expect(parseLinkFrame(truncated), isNull);
        }
      }
    });

    test('empty input -> null (never throws)', () {
      expect(() => parseLinkFrame(Uint8List(0)), returnsNormally);
      expect(parseLinkFrame(Uint8List(0)), isNull);
    });

    test('random garbage never throws', () {
      final garbage = Uint8List.fromList(List<int>.generate(64, (i) => (i * 37 + 11) & 0xFF));
      expect(() => parseLinkFrame(garbage), returnsNormally);
    });
  });

  group('DnpLinkBuffer streaming reassembly', () {
    test('a frame split across two add() calls emits once complete', () {
      final frame = buildLinkFrame(
        control: 0xC0,
        dest: 1,
        src: 4,
        userData: Uint8List.fromList([9, 8, 7]),
      );
      final buf = DnpLinkBuffer();
      final splitPoint = frame.length ~/ 2;

      final first = buf.add(frame.sublist(0, splitPoint));
      expect(first, isEmpty);

      final second = buf.add(frame.sublist(splitPoint));
      expect(second.length, 1);
      expect(second.first.control, 0xC0);
      expect(second.first.dest, 1);
      expect(second.first.src, 4);
      expect(second.first.userData, Uint8List.fromList([9, 8, 7]));
    });

    test('a frame split across many tiny add() calls (byte at a time)', () {
      final frame = buildLinkFrame(
        control: 0x44,
        dest: 42,
        src: 7,
        userData: Uint8List.fromList(List<int>.generate(20, (i) => i)),
      );
      final buf = DnpLinkBuffer();
      final emitted = <DnpLinkFrame>[];
      for (final b in frame) {
        emitted.addAll(buf.add(Uint8List.fromList([b])));
      }
      expect(emitted.length, 1);
      expect(emitted.first.userData, Uint8List.fromList(List<int>.generate(20, (i) => i)));
    });

    test('two coalesced frames in a single add() emit two frames', () {
      final frameA = buildLinkFrame(control: 0xC0, dest: 1, src: 4, userData: Uint8List.fromList([1, 2]));
      final frameB = buildLinkFrame(control: 0x44, dest: 2, src: 5, userData: Uint8List.fromList([3, 4, 5]));
      final combined = Uint8List.fromList([...frameA, ...frameB]);

      final buf = DnpLinkBuffer();
      final frames = buf.add(combined);
      expect(frames.length, 2);
      expect(frames[0].dest, 1);
      expect(frames[0].userData, Uint8List.fromList([1, 2]));
      expect(frames[1].dest, 2);
      expect(frames[1].userData, Uint8List.fromList([3, 4, 5]));
    });

    test('leading garbage before a valid frame is skipped without throwing', () {
      final frame = buildLinkFrame(control: 0xC0, dest: 9, src: 1, userData: Uint8List.fromList([1]));
      final garbage = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x05, 0x00, 0x64]);
      final combined = Uint8List.fromList([...garbage, ...frame]);

      final buf = DnpLinkBuffer();
      List<DnpLinkFrame> frames = const [];
      expect(() => frames = buf.add(combined), returnsNormally);
      expect(frames.length, 1);
      expect(frames.first.dest, 9);
    });

    test('pure garbage (never a valid start sequence) never throws and emits nothing', () {
      final garbage = Uint8List.fromList(List<int>.generate(200, (i) => (i * 13 + 3) & 0xFF));
      final buf = DnpLinkBuffer();
      List<DnpLinkFrame> frames = const [];
      expect(() => frames = buf.add(garbage), returnsNormally);
      expect(frames, isEmpty);
    });

    test('a frame with a corrupted CRC embedded in a stream is dropped, not emitted, and does not wedge later frames', () {
      final badFrame = buildLinkFrame(control: 0xC0, dest: 1, src: 1, userData: Uint8List.fromList([1, 2]));
      badFrame[8] ^= 0xFF; // corrupt header CRC
      final goodFrame = buildLinkFrame(control: 0x44, dest: 2, src: 2, userData: Uint8List.fromList([3, 4]));
      final combined = Uint8List.fromList([...badFrame, ...goodFrame]);

      final buf = DnpLinkBuffer();
      final frames = buf.add(combined);
      expect(frames.length, 1);
      expect(frames.first.dest, 2);
    });
  });
}
