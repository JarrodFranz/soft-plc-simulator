// Omron FINS request -> response dispatch — pure Dart, no dart:io / Flutter
// imports. This is the SINGLE definition of FINS command handling that BOTH
// the shipped UDP host (`services/fins_host.dart`) and the E2E fixture host
// (`mobile/tool/fins_host_probe.dart`) call, exactly as the S7comm stack
// shares `dispatchS7VarJob` (`protocols/s7/s7_services.dart`). Because the
// fixture host cannot import the shipped host (it extends `ChangeNotifier`,
// which pulls in `dart:ui`, unavailable under a plain `dart run`), sharing
// ONE dispatch is what makes the real third-party `fins` client's proof
// against the fixture also a proof of the shipped host — the bytes the client
// validates are, by construction rather than by diff, the bytes the app puts
// on the wire.
//
// *** ENDIANNESS ***
// FINS multi-byte fields are BIG-ENDIAN (see fins_frame.dart / fins_memory.dart).
// This file builds the read-response word data big-endian via [FinsWordImage].
//
// *** SCOPE ***
// Serves a Memory Area Read (0x0101) and a Memory Area Write (0x0102) against a
// [FinsMemoryImage]. Two concrete images exist: [FinsTagImage] (Task 4), backed
// by the project's tags via a `FinsMap` and the pure area word-image
// (`fins_area_image.dart`) — this is what BOTH the shipped host and the E2E
// fixture host serve, so the real `fins` client's round-trip exercises the
// actual tag encode/decode; and [FinsWordImage], a simpler seeded per-area word
// bank available for tests. A command this file does not serve returns `null`,
// and the host drops the datagram.
//
// Safety contract: [dispatchFinsDatagram] returns `null` — and never throws —
// on malformed, truncated, unsupported, or otherwise hostile input, since the
// UDP host feeds it arbitrary datagram bytes read straight off the wire and
// must never wedge its bind on one bad datagram.
library fins_dispatch;

import 'dart:typed_data';

import '../../models/fins_map.dart';
import '../../models/project_model.dart';
import 'fins_area_image.dart';
import 'fins_frame.dart';
import 'fins_memory.dart';

/// The outcome of one [FinsMemoryImage.readWords] call: a FINS end code plus,
/// on [kFinsEndNormal], the requested words as BIG-ENDIAN bytes
/// (`count * 2` long). On any error end code [words] is empty — the response
/// then carries the end code and no data, per the FINS wire format.
class FinsReadOutcome {
  final int endCode;
  final Uint8List words;

  const FinsReadOutcome(this.endCode, this.words);

  /// A successful read carrying [words] (BIG-ENDIAN, `count * 2` bytes).
  factory FinsReadOutcome.ok(Uint8List words) =>
      FinsReadOutcome(kFinsEndNormal, words);

  /// A failed read carrying only [endCode] (e.g. [kFinsEndNoArea] or
  /// [kFinsEndAddressRange]) and no data.
  factory FinsReadOutcome.error(int endCode) =>
      FinsReadOutcome(endCode, Uint8List(0));
}

/// The outcome of one [FinsMemoryImage.writeWords] call: a FINS end code.
/// [kFinsEndNormal] means the write landed (or fell entirely into an unmapped
/// gap, which is discarded-as-success by design, mirroring the S7 area image);
/// any other code (e.g. [kFinsEndNotWritable], [kFinsEndAddressRange],
/// [kFinsEndNoArea]) means the write was refused or out of range and the tags
/// were left unchanged.
class FinsWriteOutcome {
  final int endCode;

  const FinsWriteOutcome(this.endCode);

  /// A successful (or discarded-gap) write.
  factory FinsWriteOutcome.ok() => const FinsWriteOutcome(kFinsEndNormal);

  /// A failed write carrying only [endCode].
  factory FinsWriteOutcome.error(int endCode) => FinsWriteOutcome(endCode);
}

/// The memory an incoming Memory Area Read/Write is served against.
/// Deliberately abstract so the shipped host serves a tag-backed
/// [FinsTagImage] while the E2E fixture host serves a seeded [FinsWordImage],
/// both through the one [dispatchFinsDatagram].
abstract class FinsMemoryImage {
  /// Reads [count] words starting at [wordAddress] from the area identified by
  /// the wire [areaCode] (e.g. [kFinsAreaDM]). Must NEVER throw: an
  /// unsupported area or an out-of-range address is reported as an error
  /// [FinsReadOutcome], not an exception.
  FinsReadOutcome readWords(int areaCode, int wordAddress, int count);

  /// Writes the BIG-ENDIAN word bytes [data] (`2 * words` long) starting at
  /// [wordAddress] into the area identified by the wire [areaCode]. Must NEVER
  /// throw: an unsupported area, an out-of-range address, or a refused write is
  /// reported as an error [FinsWriteOutcome], not an exception.
  FinsWriteOutcome writeWords(int areaCode, int wordAddress, Uint8List data);

  /// Reads [count] consecutive BITS starting at bit [bitOffset] (0..15) of
  /// word [wordAddress] from the memory identified by the wire BIT [areaCode]
  /// (e.g. [kFinsAreaDMBit]). On success the outcome's data is ONE byte per
  /// bit (0x01/0x00) — the FINS bit-area wire format. Must NEVER throw.
  FinsReadOutcome readBits(int areaCode, int wordAddress, int bitOffset, int count);

  /// Writes [bits] (ONE byte per bit, 0x00 = clear / anything else = set) to
  /// consecutive bits starting at bit [bitOffset] (0..15) of word
  /// [wordAddress] of the memory identified by the wire BIT [areaCode]. Must
  /// NEVER throw.
  FinsWriteOutcome writeBits(int areaCode, int wordAddress, int bitOffset, Uint8List bits);
}

/// A simple, pure, zero-filled per-area word image: a fixed-size word bank per
/// wire area code, with gap-reads-zero and range-checked semantics. Used to
/// seed both the shipped host's Task-3 fixture and the E2E fixture host; a
/// later task may reuse it (seeded from the real map) or replace it with a
/// tag-backed [FinsMemoryImage].
class FinsWordImage implements FinsMemoryImage {
  /// Wire area code (e.g. [kFinsAreaDM]) -> that area's word bank. Words are
  /// stored host-native in the [Uint16List]; [readWords] emits them BIG-ENDIAN.
  final Map<int, Uint16List> _areas;

  FinsWordImage(Map<int, Uint16List> areas) : _areas = areas;

  @override
  FinsReadOutcome readWords(int areaCode, int wordAddress, int count) {
    final bank = _areas[areaCode];
    if (bank == null) {
      return FinsReadOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 ||
        count < 0 ||
        wordAddress + count > bank.length) {
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    final out = Uint8List(count * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < count; i++) {
      bd.setUint16(i * 2, bank[wordAddress + i] & 0xFFFF, Endian.big);
    }
    return FinsReadOutcome.ok(out);
  }

  @override
  FinsWriteOutcome writeWords(int areaCode, int wordAddress, Uint8List data) {
    final bank = _areas[areaCode];
    if (bank == null) {
      return FinsWriteOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 || data.length.isOdd) {
      return FinsWriteOutcome.error(kFinsEndAddressRange);
    }
    final count = data.length ~/ 2;
    if (wordAddress + count > bank.length) {
      return FinsWriteOutcome.error(kFinsEndAddressRange);
    }
    final bd = ByteData.sublistView(data);
    for (var i = 0; i < count; i++) {
      bank[wordAddress + i] = bd.getUint16(i * 2, Endian.big);
    }
    return FinsWriteOutcome.ok();
  }

  @override
  FinsReadOutcome readBits(int areaCode, int wordAddress, int bitOffset, int count) {
    final wordCode = finsWordAreaForBitArea(areaCode);
    final bank = wordCode == null ? null : _areas[wordCode];
    if (bank == null) {
      return FinsReadOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 || bitOffset < 0 || bitOffset > 15 || count < 0) {
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    final startBit = wordAddress * 16 + bitOffset;
    if (startBit + count > bank.length * 16) {
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      final pos = startBit + i;
      out[i] = (bank[pos >> 4] >> (pos & 15)) & 1;
    }
    return FinsReadOutcome.ok(out);
  }

  @override
  FinsWriteOutcome writeBits(int areaCode, int wordAddress, int bitOffset, Uint8List bits) {
    final wordCode = finsWordAreaForBitArea(areaCode);
    final bank = wordCode == null ? null : _areas[wordCode];
    if (bank == null) {
      return FinsWriteOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 || bitOffset < 0 || bitOffset > 15) {
      return FinsWriteOutcome.error(kFinsEndAddressRange);
    }
    final startBit = wordAddress * 16 + bitOffset;
    if (startBit + bits.length > bank.length * 16) {
      return FinsWriteOutcome.error(kFinsEndAddressRange);
    }
    for (var i = 0; i < bits.length; i++) {
      final pos = startBit + i;
      final mask = 1 << (pos & 15);
      if (bits[i] != 0x00) {
        bank[pos >> 4] |= mask;
      } else {
        bank[pos >> 4] &= ~mask & 0xFFFF;
      }
    }
    return FinsWriteOutcome.ok();
  }
}

/// A [FinsMemoryImage] backed by the project's tags via a [FinsMap] and the
/// pure area word-image (`fins_area_image.dart`). This is what the shipped
/// `FinsHost` serves: a Memory Area Read materializes the mapped tags into a
/// word image, and a Memory Area Write decodes the written words back onto the
/// tags the range covers (force- and access-aware). Both directions honour
/// the S7-proven area-image semantics: unmapped words read `0x0000`, writes to
/// gaps are discarded, a partially covered multi-word tag is not written, and a
/// forced / read-only / reserved-`System` tag refuses writes.
class FinsTagImage implements FinsMemoryImage {
  final PlcProject project;
  final FinsMap map;

  FinsTagImage(this.project, this.map);

  @override
  FinsReadOutcome readWords(int areaCode, int wordAddress, int count) {
    final area = finsAreaNameForCode(areaCode);
    if (area == null) {
      return FinsReadOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 || count < 0 || wordAddress + count > kFinsMaxAreaImageWords) {
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    if (count == 0) {
      return FinsReadOutcome.ok(Uint8List(0));
    }
    final image = readAreaImage(project, map, area, wordAddress, count);
    if (image.length != count * 2) {
      // readAreaImage only returns short for arguments this method already
      // rejected; treat any residual mismatch as an address-range error rather
      // than emit a malformed response.
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    return FinsReadOutcome.ok(image);
  }

  @override
  FinsWriteOutcome writeWords(int areaCode, int wordAddress, Uint8List data) {
    final area = finsAreaNameForCode(areaCode);
    if (area == null) {
      return FinsWriteOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 || data.length.isOdd ||
        wordAddress + (data.length ~/ 2) > kFinsMaxAreaImageWords) {
      return FinsWriteOutcome.error(kFinsEndAddressRange);
    }
    final results = applyAreaWrite(project, map, area, wordAddress, data);
    return FinsWriteOutcome(finsWriteEndCode(results));
  }

  @override
  FinsReadOutcome readBits(int areaCode, int wordAddress, int bitOffset, int count) {
    final wordCode = finsWordAreaForBitArea(areaCode);
    final area = wordCode == null ? null : finsAreaNameForCode(wordCode);
    if (area == null) {
      return FinsReadOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 || bitOffset < 0 || bitOffset > 15 || count < 0) {
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    if (count == 0) {
      return FinsReadOutcome.ok(Uint8List(0));
    }
    final lastWord = wordAddress + ((bitOffset + count - 1) >> 4);
    if (lastWord >= kFinsMaxAreaImageWords) {
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    final bits = readAreaBits(project, map, area, wordAddress, bitOffset, count);
    if (bits.length != count) {
      // readAreaBits only returns short for arguments this method already
      // rejected; treat any residual mismatch as an address-range error.
      return FinsReadOutcome.error(kFinsEndAddressRange);
    }
    return FinsReadOutcome.ok(bits);
  }

  @override
  FinsWriteOutcome writeBits(int areaCode, int wordAddress, int bitOffset, Uint8List bits) {
    final wordCode = finsWordAreaForBitArea(areaCode);
    final area = wordCode == null ? null : finsAreaNameForCode(wordCode);
    if (area == null) {
      return FinsWriteOutcome.error(kFinsEndNoArea);
    }
    if (wordAddress < 0 || bitOffset < 0 || bitOffset > 15) {
      return FinsWriteOutcome.error(kFinsEndAddressRange);
    }
    if (bits.isEmpty) {
      return FinsWriteOutcome.ok();
    }
    final lastWord = wordAddress + ((bitOffset + bits.length - 1) >> 4);
    if (lastWord >= kFinsMaxAreaImageWords) {
      return FinsWriteOutcome.error(kFinsEndAddressRange);
    }
    final results = applyAreaBitWrite(project, map, area, wordAddress, bitOffset, bits);
    return FinsWriteOutcome(finsWriteEndCode(results));
  }
}

/// Collapses the per-tag outcomes [applyAreaWrite] reported for one Memory Area
/// Write into that write's single FINS end code, mirroring S7's
/// `s7WriteReturnCode`.
///
/// An EMPTY [results] list means the range covered no map entry at all — a
/// write into a gap, DISCARDED silently by design and reported as success,
/// exactly as a real controller reports a write into an unused word.
///
/// A refusal wins over everything else so a client is never told a write it was
/// denied succeeded: a `ReadOnly` entry, a FORCED root tag, or the write-time
/// hard backstop all yield [kFinsEndNotWritable]. A partially covered
/// multi-word tag yields [kFinsEndAddressRange]; a tag with no v1 FINS
/// representation also yields [kFinsEndAddressRange] (only if nothing was
/// refused).
int finsWriteEndCode(List<FinsWriteResult> results) {
  var code = kFinsEndNormal;
  for (final r in results) {
    switch (r.status) {
      case FinsWriteStatus.written:
        break;
      case FinsWriteStatus.refusedReadOnly:
      case FinsWriteStatus.refusedForced:
      case FinsWriteStatus.refusedNotExternallyWritable:
        return kFinsEndNotWritable;
      case FinsWriteStatus.partiallyCovered:
        code = kFinsEndAddressRange;
        break;
      case FinsWriteStatus.unsupported:
        if (code == kFinsEndNormal) {
          code = kFinsEndAddressRange;
        }
        break;
    }
  }
  return code;
}

/// Dispatches one raw FINS command [datagram] against [image], returning the
/// complete FINS response datagram bytes — or `null` when the datagram is not
/// a served command (malformed/short frame, unparseable item, or a command
/// code this task does not serve), in which case the caller drops it without
/// replying.
///
/// This never throws: [parseFinsCommand] and [parseMemAreaReadItem] both
/// return `null` rather than throwing on hostile input, and
/// [FinsMemoryImage.readWords] reports every failure as an end code.
Uint8List? dispatchFinsDatagram(Uint8List datagram, FinsMemoryImage image) {
  final frame = parseFinsCommand(datagram);
  if (frame == null) {
    return null;
  }
  switch (frame.commandCode) {
    case kFinsCmdMemAreaRead:
      final item = parseMemAreaReadItem(frame.text);
      if (item == null) {
        return null;
      }
      // A BIT-area read addresses bits (1 byte each in the response); a
      // word-area read addresses words (2 bytes each). Same 6-byte item spec.
      final outcome = isFinsBitArea(item.areaCode)
          ? image.readBits(item.areaCode, item.wordAddress, item.bitOffset, item.count)
          : image.readWords(item.areaCode, item.wordAddress, item.count);
      return buildFinsResponse(
        requestHeader: frame.header,
        commandCode: frame.commandCode,
        endCode: outcome.endCode,
        data: buildMemReadResponseData(outcome.words),
      );
    case kFinsCmdMemAreaWrite:
      // Peek the 6-byte item spec first: a BIT-area write carries ONE byte
      // per item after the spec, a word-area write TWO — the two layouts
      // must be parsed differently (Ignition's Omron FINS driver writes
      // Booleans via the bit layout; see fins_memory.dart's AREA CODES note).
      final spec = parseMemAreaReadItem(frame.text);
      if (spec == null) {
        return null;
      }
      if (isFinsBitArea(spec.areaCode)) {
        final parsed = parseMemAreaWriteBitItem(frame.text);
        if (parsed == null) {
          return null;
        }
        final outcome = image.writeBits(
          parsed.item.areaCode,
          parsed.item.wordAddress,
          parsed.item.bitOffset,
          parsed.writeData,
        );
        // A Memory Area Write response carries only the end code (no data).
        return buildFinsResponse(
          requestHeader: frame.header,
          commandCode: frame.commandCode,
          endCode: outcome.endCode,
        );
      }
      final parsed = parseMemAreaWriteItem(frame.text);
      if (parsed == null) {
        return null;
      }
      final outcome = image.writeWords(
        parsed.item.areaCode,
        parsed.item.wordAddress,
        parsed.writeData,
      );
      // A Memory Area Write response carries only the end code (no data).
      return buildFinsResponse(
        requestHeader: frame.header,
        commandCode: frame.commandCode,
        endCode: outcome.endCode,
      );
    default:
      // Any other command is not served; drop it here (no reply).
      return null;
  }
}
