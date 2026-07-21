// FINS area word-image — pure Dart, no dart:io / Flutter imports.
//
// This is where FINS meets the app's tag database. A real FINS driver issues
// optimized block reads by area code + word address ("DM100, 20 words" in one
// request) rather than one request per tag. So this file materializes a packed
// WORD image of an area from the project's named tags, serves slices of it,
// and — in the write direction — decodes a written slice back onto the tags it
// overlaps. It mirrors protocols/s7/s7_area_image.dart almost exactly; the
// only difference is that FINS addresses by WORD (2 bytes), not by byte.
//
// *** ENDIANNESS + THE 32-BIT WORD-ORDER DECISION (settled by the E2E) ***
// FINS is BIG-ENDIAN within each 16-bit word. A 32-bit value (DINT/REAL) spans
// TWO consecutive words, and Omron's word order for those (which of the two
// words holds the high half) is a documented gotcha that a build->parse
// round-trip CANNOT detect. Task 4 provisionally chose HIGH-WORD-FIRST; Task
// 5's real `fins` E2E (a third-party client reading a value the fixture SEEDED
// independently) OVERTURNED that — the `fins` library serializes a multi-word
// value LOW-WORD-FIRST (it word-reverses the big-endian byte string; see
// `fins.fins_common.reverse_word_order`). The client is the authority, so the
// order here is now LOW-WORD-FIRST: the LOW word sits at the LOWER word
// address, each word still big-endian internally. Concretely, DINT 0x12345678
// occupies word N = 0x5678 (low) and word N+1 = 0x1234 (high). Implemented as
// a plain big-endian encode/decode (`ByteData.setInt32/getInt32(Endian.big)`)
// wrapped by [_reverseWordOrder], which swaps the 2-byte words. For a 1-word
// value (INT16/BOOL) the wrap is a no-op, so those paths are unchanged.
//
// Semantics (mirroring the approved S7 decisions):
//  - **Gaps read as zero.** Unmapped words inside a requested range are served
//    as `0x0000`, letting a driver block-read a whole area.
//  - **Writes to gap words are DISCARDED**, silently and without a report.
//  - **A tag only PARTIALLY covered by a write range is NOT written** (writing
//    half of a multi-word value would corrupt it) and IS reported
//    ([FinsWriteStatus.partiallyCovered]).
//  - **Force-aware and access-aware writes.** A write landing on a tag whose
//    map entry is `ReadOnly`, whose ROOT tag is forced, or that the shared
//    write-gate refuses (reserved `System`, or the tag's own `access` is
//    `ReadOnly`) is refused and the tag left unchanged.
//  - **FLOAT64 is a 4-byte FINS REAL** — a NARROWING conversion to IEEE-754
//    single precision.
//  - **STRING is not representable** in v1 and is skipped on read / refused on
//    write.
//
// Safety contract: nothing here ever throws on malformed, truncated, or
// hostile input — out-of-range offsets, absurd counts, entries naming tags
// that do not exist, and unsupported data types all degrade to zeros or to a
// reported non-success result.
library fins_area_image;

import 'dart:typed_data';

import '../../models/fins_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import '../../models/tag_write_gate.dart';
import 'fins_memory.dart';

/// Maps an on-the-wire FINS word-area CODE (`kFinsArea*` in `fins_memory.dart`)
/// to this project's area NAME (`kFinsAreaName*` in `models/fins_map.dart`), or
/// `null` for a code this version does not serve. A `null` result must become
/// a per-request error end code, never an exception.
String? finsAreaNameForCode(int areaCode) {
  switch (areaCode) {
    case kFinsAreaDM:
      return kFinsAreaNameDM;
    case kFinsAreaCIO:
      return kFinsAreaNameCIO;
    case kFinsAreaWR:
      return kFinsAreaNameWR;
    case kFinsAreaHR:
      return kFinsAreaNameHR;
    default:
      return null;
  }
}

/// Upper bound on the number of WORDS [readAreaImage] will ever materialize in
/// one call — comfortably above the largest Omron word area — so a hostile or
/// nonsensical count cannot force a huge allocation.
const int kFinsMaxAreaImageWords = 0x8000; // 32768 words

/// Reverses the 2-byte WORD order of [bytes] (whose length must be even),
/// keeping each word's own bytes big-endian. FINS lays a multi-word value out
/// LOW-WORD-FIRST (word-reversed relative to a plain big-endian dword) — the
/// LOW word at the lower address — as the real `fins` client's round-trip
/// settled (see the file header). For a single word this is a no-op, so
/// INT16/BOOL are unaffected; for DINT/LINT/REAL it swaps the words.
Uint8List _reverseWordOrder(Uint8List bytes) {
  final n = bytes.length;
  final words = n ~/ 2;
  final out = Uint8List(n);
  for (var w = 0; w < words; w++) {
    final src = w * 2;
    final dst = (words - 1 - w) * 2;
    out[dst] = bytes[src];
    out[dst + 1] = bytes[src + 1];
  }
  return out;
}

/// Decodes a 4-byte FINS REAL (IEEE-754 single precision) into a Dart double.
/// The two words are LOW-WORD-FIRST on the wire (see the file header), so they
/// are un-swapped back to big-endian before decoding. Returns 0.0 if [bytes]
/// is shorter than 4 bytes (never throws).
double decodeFinsReal(Uint8List bytes) {
  if (bytes.length < 4) {
    return 0.0;
  }
  final be = _reverseWordOrder(Uint8List.sublistView(bytes, 0, 4));
  return ByteData.sublistView(be).getFloat32(0, Endian.big);
}

/// Encodes [value] as a 4-byte FINS REAL, LOW-WORD-FIRST (see the file header).
/// This is a NARROWING conversion: the app stores FLOAT64 doubles and FINS REAL
/// is 32-bit, so the encoded value is the float32 approximation of [value].
Uint8List encodeFinsReal(double value) {
  final be = Uint8List(4);
  ByteData.sublistView(be).setFloat32(0, value, Endian.big);
  return _reverseWordOrder(be);
}

/// Encodes a signed integer as [widthBytes] bytes (two's complement), each word
/// big-endian, with the WORDS in LOW-WORD-FIRST order (see the file header's
/// word-order decision). For a 1-word (2-byte) value this is a plain big-endian
/// encode.
Uint8List _encodeInt(int value, int widthBytes) {
  final be = Uint8List(widthBytes);
  final bd = ByteData.sublistView(be);
  switch (widthBytes) {
    case 2:
      bd.setInt16(0, value.toSigned(16), Endian.big);
      break;
    case 4:
      bd.setInt32(0, value.toSigned(32), Endian.big);
      break;
    case 8:
      bd.setInt64(0, value.toSigned(64), Endian.big);
      break;
    default:
      break;
  }
  return _reverseWordOrder(be);
}

/// Decodes [widthBytes] bytes as a signed integer (two's complement). The words
/// are LOW-WORD-FIRST on the wire (see the file header), so they are un-swapped
/// back to big-endian before decoding.
int _decodeInt(Uint8List bytes, int widthBytes) {
  final be = _reverseWordOrder(Uint8List.sublistView(bytes, 0, widthBytes));
  final bd = ByteData.sublistView(be);
  switch (widthBytes) {
    case 2:
      return bd.getInt16(0, Endian.big);
    case 4:
      return bd.getInt32(0, Endian.big);
    case 8:
      return bd.getInt64(0, Endian.big);
    default:
      return 0;
  }
}

/// Encodes the current value of the tag named by [entry] into its wire
/// representation (BIG-ENDIAN, `width * 2` bytes), or `null` if the tag does
/// not resolve, holds an unexpected runtime type, or has no v1 FINS
/// representation. BOOL is handled separately by the caller (it is a single
/// bit within a word), not through this function.
Uint8List? _encodeEntryValue(PlcProject project, FinsMapEntry entry, String dataType) {
  final width = FinsMap.widthWordsForType(dataType);
  if (width == null) {
    return null;
  }
  final value = readPath(project, entry.tag);
  if (dataType == 'FLOAT64') {
    final d = value is num ? value.toDouble() : 0.0;
    return encodeFinsReal(d);
  }
  final i = value is int ? value : 0;
  return _encodeInt(i, width * 2);
}

/// Sets the bit of the big-endian [image] word that [entry] addresses. Bits
/// 0..7 live in the word's LOW byte (the second of the two big-endian bytes),
/// bits 8..15 in the HIGH byte (the first). [relWord] is the word's index
/// within the image (word address minus the read's start word).
void _setImageBit(Uint8List image, int relWord, int bitOffset) {
  final base = relWord * 2;
  if (bitOffset < 8) {
    image[base + 1] |= (1 << bitOffset); // low byte
  } else {
    image[base] |= (1 << (bitOffset - 8)); // high byte
  }
}

/// Reads the bit that [entry] addresses from the big-endian word at [relWord]
/// of [data] (same byte convention as [_setImageBit]).
bool _readDataBit(Uint8List data, int relWord, int bitOffset) {
  final base = relWord * 2;
  if (bitOffset < 8) {
    return (data[base + 1] & (1 << bitOffset)) != 0;
  }
  return (data[base] & (1 << (bitOffset - 8))) != 0;
}

/// Materializes [wordCount] words of the FINS memory [area] (one of
/// [kFinsAreaNames]) starting at [startWord], packing in the current value of
/// every [map] entry that intersects the requested window.
///
/// Each word is big-endian; a multi-word value's words are LOW-WORD-FIRST (see
/// the file header). Words not covered by any map entry read as `0x0000`. A tag
/// only partially inside the window contributes only its overlapping words.
///
/// Returns an EMPTY list — and never throws — for a non-positive [wordCount], a
/// negative [startWord], or a [wordCount] above [kFinsMaxAreaImageWords].
Uint8List readAreaImage(
  PlcProject project,
  FinsMap map,
  String area,
  int startWord,
  int wordCount,
) {
  if (wordCount <= 0 || wordCount > kFinsMaxAreaImageWords || startWord < 0) {
    return Uint8List(0);
  }
  final image = Uint8List(wordCount * 2);
  final endWord = startWord + wordCount; // exclusive

  for (final entry in map.entries) {
    if (entry.area != area) {
      continue;
    }
    if (entry.wordAddress < 0 || entry.bitOffset < 0 || entry.bitOffset > 15) {
      continue;
    }
    final dataType = dataTypeOfPath(project, entry.tag);
    if (dataType == null) {
      continue;
    }
    if (dataType == 'BOOL') {
      if (entry.wordAddress < startWord || entry.wordAddress >= endWord) {
        continue;
      }
      if (readPath(project, entry.tag) == true) {
        _setImageBit(image, entry.wordAddress - startWord, entry.bitOffset);
      }
      continue;
    }
    final encoded = _encodeEntryValue(project, entry, dataType);
    if (encoded == null) {
      continue;
    }
    // Multi-word: copy only the words overlapping the requested window.
    final width = encoded.length ~/ 2; // words
    final tagStart = entry.wordAddress;
    final tagEnd = entry.wordAddress + width; // exclusive
    final overlapStart = tagStart > startWord ? tagStart : startWord;
    final overlapEnd = tagEnd < endWord ? tagEnd : endWord;
    if (overlapEnd <= overlapStart) {
      continue;
    }
    for (var w = overlapStart; w < overlapEnd; w++) {
      final dest = (w - startWord) * 2;
      final src = (w - tagStart) * 2;
      image[dest] = encoded[src];
      image[dest + 1] = encoded[src + 1];
    }
  }
  return image;
}

/// Reads [count] consecutive BITS of [area] starting at bit [startBit]
/// (0..15) of word [startWord], returning ONE byte per bit (0x01 set / 0x00
/// clear) — the FINS bit-area read wire format. Bits run low-to-high within a
/// word and roll into the next word after bit 15.
///
/// Implemented on top of [readAreaImage] so a bit read is, by construction,
/// bit-for-bit consistent with what a word read of the same range serves:
/// a BOOL entry's bit reads its tag value, a bit inside a non-BOOL entry's
/// word reads that bit of the encoded value, and gap bits read 0.
///
/// Returns an EMPTY list — and never throws — for a non-positive [count], a
/// negative [startWord], a [startBit] outside 0..15, or a range whose last
/// word would exceed [kFinsMaxAreaImageWords].
Uint8List readAreaBits(
  PlcProject project,
  FinsMap map,
  String area,
  int startWord,
  int startBit,
  int count,
) {
  if (count <= 0 || startWord < 0 || startBit < 0 || startBit > 15) {
    return Uint8List(0);
  }
  final lastBitPos = startBit + count - 1;
  final wordCount = (lastBitPos >> 4) + 1;
  if (startWord + wordCount > kFinsMaxAreaImageWords) {
    return Uint8List(0);
  }
  final image = readAreaImage(project, map, area, startWord, wordCount);
  if (image.length != wordCount * 2) {
    return Uint8List(0);
  }
  final out = Uint8List(count);
  for (var i = 0; i < count; i++) {
    final pos = startBit + i;
    final relWord = pos >> 4;
    final bit = pos & 15;
    out[i] = _readDataBit(image, relWord, bit) ? 0x01 : 0x00;
  }
  return out;
}

/// What happened to one tag touched by an [applyAreaWrite] call. Mirrors
/// `S7WriteStatus`.
enum FinsWriteStatus {
  /// The tag was fully covered by the write range and was written.
  written,

  /// The write range covered only PART of a multi-word tag. Writing a fragment
  /// would corrupt the value, so nothing was written.
  partiallyCovered,

  /// The map entry is `ReadOnly`.
  refusedReadOnly,

  /// The tag's ROOT tag is forced. Forcing is authoritative: an external write
  /// must not change the underlying value behind a force.
  refusedForced,

  /// Write-time hard backstop: `isExternallyWritable` refused the write
  /// independent of the map entry's own `access` — the ROOT tag is the
  /// reserved `System` tag, or its own `access` is `ReadOnly`.
  refusedNotExternallyWritable,

  /// The tag path does not resolve, or its data type has no v1 FINS
  /// representation (e.g. `STRING`).
  unsupported,
}

/// The outcome for one tag touched by an [applyAreaWrite] call.
class FinsWriteResult {
  final String tag;
  final FinsWriteStatus status;

  const FinsWriteResult(this.tag, this.status);

  /// True only for [FinsWriteStatus.written].
  bool get ok => status == FinsWriteStatus.written;
}

/// Applies [data] as a write to `data.length / 2` words of the FINS memory
/// [area] starting at [startWord], decoding it back onto every [map] entry the
/// range covers.
///
/// Each word is big-endian; a multi-word value's words are LOW-WORD-FIRST (see
/// the file header). Behaviour, per the file header: words not covered by any
/// entry are DISCARDED and not
/// reported; a partially covered multi-word tag is NOT written but IS reported;
/// a `ReadOnly` entry, a FORCED root tag, or a tag the shared write-gate
/// refuses is refused with the tag left unchanged.
///
/// One refused or unsupported entry never affects any other entry — each tag
/// in range is handled independently, so a multi-item write can succeed in
/// part.
///
/// Returns an EMPTY list — and never throws — for empty [data], odd-length
/// [data] (not a whole number of words), or a negative [startWord].
List<FinsWriteResult> applyAreaWrite(
  PlcProject project,
  FinsMap map,
  String area,
  int startWord,
  Uint8List data,
) {
  final results = <FinsWriteResult>[];
  if (data.isEmpty || data.length.isOdd || startWord < 0) {
    return results;
  }
  final wordCount = data.length ~/ 2;
  final endWord = startWord + wordCount; // exclusive

  for (final entry in map.entries) {
    if (entry.area != area) {
      continue;
    }
    if (entry.wordAddress < 0 || entry.bitOffset < 0 || entry.bitOffset > 15) {
      continue;
    }
    final dataType = dataTypeOfPath(project, entry.tag);
    final width = dataType == null ? null : FinsMap.widthWordsForType(dataType);

    // Coverage is decided on the entry's declared word span. An entry whose
    // type is unknown/unsupported still occupies at least the word it names.
    final tagStart = entry.wordAddress;
    final tagEnd = entry.wordAddress + (width ?? 1); // exclusive
    if (tagEnd <= startWord || tagStart >= endWord) {
      continue; // no overlap at all — nothing to say about this entry
    }
    if (dataType == null || width == null) {
      results.add(FinsWriteResult(entry.tag, FinsWriteStatus.unsupported));
      continue;
    }
    if (tagStart < startWord || tagEnd > endWord) {
      // Overlapping, but not fully covered.
      results.add(FinsWriteResult(entry.tag, FinsWriteStatus.partiallyCovered));
      continue;
    }
    if (entry.access == 'ReadOnly') {
      results.add(FinsWriteResult(entry.tag, FinsWriteStatus.refusedReadOnly));
      continue;
    }

    // Write-time hard backstop: the FinsMap entry above is a MUTABLE map a
    // hand-edit could re-target at the reserved System tag.
    // `isExternallyWritable` re-checks the underlying ROOT tag itself,
    // independent of whatever this entry claims.
    if (!isExternallyWritable(project, entry.tag)) {
      results.add(FinsWriteResult(entry.tag, FinsWriteStatus.refusedNotExternallyWritable));
      continue;
    }

    // Force-aware write: a forced ROOT tag refuses writes to EVERY path
    // beneath it. `rootTagOf` walks to the leaf path's FIRST segment, so for
    // `Tank.Level` it returns `Tank`. There is deliberately NO
    // `root.name == entry.tag` clause: that comparison is false for any member
    // path, which would SKIP this check and let the write land silently.
    final root = rootTagOf(project, entry.tag);
    if (root != null && root.isForced) {
      results.add(FinsWriteResult(entry.tag, FinsWriteStatus.refusedForced));
      continue;
    }

    final relWord = tagStart - startWord;
    if (dataType == 'BOOL') {
      writePath(project, entry.tag, _readDataBit(data, relWord, entry.bitOffset));
    } else {
      final slice = Uint8List.sublistView(data, relWord * 2, (relWord + width) * 2);
      if (dataType == 'FLOAT64') {
        writePath(project, entry.tag, decodeFinsReal(slice));
      } else {
        writePath(project, entry.tag, _decodeInt(slice, width * 2));
      }
    }
    results.add(FinsWriteResult(entry.tag, FinsWriteStatus.written));
  }
  return results;
}

/// Applies [bits] (ONE byte per bit, 0x00 = clear / anything else = set — the
/// FINS bit-area write wire format) to [count] consecutive bits of [area]
/// starting at bit [startBit] (0..15) of word [startWord], writing each bit
/// onto the BOOL map entry addressed at exactly that (word, bit) position.
///
/// Per-bit semantics, mirroring [applyAreaWrite]'s word philosophy:
///  - A bit addressing a BOOL entry is written through the same gate chain
///    as a word write (`ReadOnly` -> refused, shared write-gate backstop ->
///    refused, FORCED root tag -> refused).
///  - A bit landing inside a NON-BOOL entry's word span is NOT written
///    (flipping one bit of an encoded INT/REAL would corrupt the value) and
///    is reported [FinsWriteStatus.partiallyCovered].
///  - A bit landing in a gap (no entry) is DISCARDED silently, like a write
///    to a gap word.
///
/// Each bit is handled independently; one refused bit never affects another.
/// Returns an EMPTY list — and never throws — for empty [bits], a negative
/// [startWord], or a [startBit] outside 0..15.
List<FinsWriteResult> applyAreaBitWrite(
  PlcProject project,
  FinsMap map,
  String area,
  int startWord,
  int startBit,
  Uint8List bits,
) {
  final results = <FinsWriteResult>[];
  if (bits.isEmpty || startWord < 0 || startBit < 0 || startBit > 15) {
    return results;
  }

  for (var i = 0; i < bits.length; i++) {
    final pos = startBit + i;
    final word = startWord + (pos >> 4);
    final bit = pos & 15;

    for (final entry in map.entries) {
      if (entry.area != area) {
        continue;
      }
      if (entry.wordAddress < 0 || entry.bitOffset < 0 || entry.bitOffset > 15) {
        continue;
      }
      final dataType = dataTypeOfPath(project, entry.tag);
      final width = dataType == null ? null : FinsMap.widthWordsForType(dataType);

      if (dataType == 'BOOL') {
        if (entry.wordAddress != word || entry.bitOffset != bit) {
          continue;
        }
      } else {
        // A non-BOOL entry occupies whole words; does this bit fall inside?
        final tagStart = entry.wordAddress;
        final tagEnd = entry.wordAddress + (width ?? 1); // exclusive
        if (word < tagStart || word >= tagEnd) {
          continue;
        }
        if (dataType == null || width == null) {
          results.add(FinsWriteResult(entry.tag, FinsWriteStatus.unsupported));
          continue;
        }
        // One bit of an encoded INT/REAL: refusing beats corrupting.
        results.add(FinsWriteResult(entry.tag, FinsWriteStatus.partiallyCovered));
        continue;
      }

      if (entry.access == 'ReadOnly') {
        results.add(FinsWriteResult(entry.tag, FinsWriteStatus.refusedReadOnly));
        continue;
      }

      // Write-time hard backstop — same rationale as [applyAreaWrite].
      if (!isExternallyWritable(project, entry.tag)) {
        results.add(FinsWriteResult(entry.tag, FinsWriteStatus.refusedNotExternallyWritable));
        continue;
      }

      // Force-aware write — same rationale as [applyAreaWrite].
      final root = rootTagOf(project, entry.tag);
      if (root != null && root.isForced) {
        results.add(FinsWriteResult(entry.tag, FinsWriteStatus.refusedForced));
        continue;
      }

      writePath(project, entry.tag, bits[i] != 0x00);
      results.add(FinsWriteResult(entry.tag, FinsWriteStatus.written));
    }
  }
  return results;
}
