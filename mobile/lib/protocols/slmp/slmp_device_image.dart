// SLMP device word-image — pure Dart, no dart:io / Flutter imports.
//
// This is where SLMP meets the app's tag database. A real MC client issues
// optimized block reads by device code + device number ("D100, 20 words" in one
// request) rather than one request per tag. So this file materializes a packed
// WORD image of a device from the project's named tags, serves slices of it,
// and — in the write direction — decodes a written slice back onto the tags it
// overlaps. It mirrors protocols/fins/fins_area_image.dart almost exactly; the
// only differences are that SLMP addresses by DEVICE (not memory-area name) and
// is LITTLE-ENDIAN (FINS is big-endian).
//
// *** ENDIANNESS + THE 32-BIT WORD-ORDER DECISION (PROVISIONAL) ***
// SLMP 3E binary word data is LITTLE-ENDIAN within each 16-bit word — the EXACT
// INVERSE of FINS/S7. A 32-bit value (DINT/REAL) spans TWO consecutive words,
// and Mitsubishi's word order for those (which of the two words holds the high
// half) is a documented gotcha that a build->parse round-trip CANNOT detect.
//
// PROVISIONAL CHOICE: LOW-WORD-FIRST — the least-significant word sits at the
// LOWER device address, each word little-endian internally. This is the natural
// SLMP little-endian layout (a plain little-endian encode of the whole value
// already places the low word first) and matches Mitsubishi's documented
// convention of storing a 32-bit value with D(n) = low word, D(n+1) = high word.
// Concretely, DINT 0x12345678 occupies word N = 0x5678 (bytes 0x78,0x56) and
// word N+1 = 0x1234 (bytes 0x34,0x12).
//
// This is PROVISIONAL pending Task 5's real `pymcprotocol` read-back E2E (an
// independent-seed read settles it), exactly as FINS flagged the identical thing
// provisional and its real client OVERTURNED the first guess. The whole decision
// is isolated to [_wordSlot] (with [_toWireWords]/[_fromWireWords]): if Task 5
// overturns the order, changing [_wordSlot] to `words - 1 - significance` flips
// every multi-word encode and decode at once. Do NOT scatter the assumption
// anywhere else.
//
// Semantics (mirroring the approved FINS/S7 decisions):
//  - **Gaps read as zero.** Unmapped words inside a requested range are served
//    as `0x0000`, letting a client block-read a whole device.
//  - **Writes to gap words are DISCARDED**, silently and without a report.
//  - **A tag only PARTIALLY covered by a write range is NOT written** (writing
//    half of a multi-word value would corrupt it) and IS reported
//    ([SlmpWriteStatus.partiallyCovered]).
//  - **Force-aware and access-aware writes.** A write landing on a tag whose
//    map entry is `ReadOnly`, whose ROOT tag is forced, or that the shared
//    write-gate refuses (reserved `System`, or the tag's own `access` is
//    `ReadOnly`) is refused and the tag left unchanged.
//  - **FLOAT64 is a 4-byte SLMP REAL** — a NARROWING conversion to IEEE-754
//    single precision.
//  - **STRING is not representable** in v1 and is skipped on read / refused on
//    write.
//
// Safety contract: nothing here ever throws on malformed, truncated, or
// hostile input — out-of-range offsets, absurd counts, entries naming tags
// that do not exist, and unsupported data types all degrade to zeros or to a
// reported non-success result.
library slmp_device_image;

import 'dart:typed_data';

import '../../models/project_model.dart';
import '../../models/slmp_map.dart';
import '../../models/tag_resolver.dart';
import '../../models/tag_write_gate.dart';

/// Upper bound on the number of WORDS [readDeviceImage] will ever materialize in
/// one call — comfortably above the largest word device — so a hostile or
/// nonsensical count cannot force a huge allocation.
const int kSlmpMaxDeviceImageWords = 0x8000; // 32768 words

/// The SLMP end code returned when a Batch Write is REFUSED by the write gate
/// (a `ReadOnly` entry, a FORCED root tag, or the reserved `System` tag). SLMP's
/// 3E abnormal-end code for "the specified device cannot be written" is in the
/// 0xC05x family; 0xC05B ("cannot read/write from/to the specified device") is
/// the closest documented fit for a policy refusal.
///
/// PROVISIONAL, pending Task 5's real `pymcprotocol` write-back E2E (which
/// exercises the write direction end-to-end for the first time, exactly as Task
/// 3's read-only E2E settled the read framing). It is defined HERE — not in
/// slmp_frame.dart with the Task-1 end codes — so this refusal semantics stays
/// isolated to the Task-4 write layer until the E2E confirms it.
const int kSlmpEndWriteProtect = 0xC05B;

/// Maps a word device's [significance] rank (0 = least-significant word) to its
/// WORD SLOT (index from the lower address) in the on-the-wire byte string,
/// given a value spanning [words] words. This ONE function is the isolated,
/// provisional 32-bit word-order decision (see the file header): LOW-WORD-FIRST
/// means the least-significant word takes the lowest slot, so slot ==
/// significance. To flip to high-word-first, return `words - 1 - significance`.
int _wordSlot(int significance, int words) => significance;

/// Reorders the words of a natural-little-endian value [le] (word 0 = least
/// significant, each word already little-endian internally) into SLMP wire word
/// order via [_wordSlot]. [le]'s length must be even. For the provisional
/// LOW-WORD-FIRST choice this preserves order; the explicit per-word placement
/// keeps the decision in [_wordSlot] alone.
Uint8List _toWireWords(Uint8List le) {
  final words = le.length ~/ 2;
  final out = Uint8List(le.length);
  for (var w = 0; w < words; w++) {
    final dst = _wordSlot(w, words) * 2;
    out[dst] = le[w * 2];
    out[dst + 1] = le[w * 2 + 1];
  }
  return out;
}

/// Inverse of [_toWireWords]: rearranges the wire word order back to a
/// natural-little-endian value (word 0 = least significant). [wire]'s length
/// must be even.
Uint8List _fromWireWords(Uint8List wire) {
  final words = wire.length ~/ 2;
  final out = Uint8List(wire.length);
  for (var w = 0; w < words; w++) {
    final src = _wordSlot(w, words) * 2;
    out[w * 2] = wire[src];
    out[w * 2 + 1] = wire[src + 1];
  }
  return out;
}

/// Decodes a 4-byte SLMP REAL (IEEE-754 single precision) into a Dart double.
/// The two words are in wire order (see the file header), so they are mapped
/// back to natural little-endian before decoding. Returns 0.0 if [bytes] is
/// shorter than 4 bytes (never throws).
double decodeSlmpReal(Uint8List bytes) {
  if (bytes.length < 4) {
    return 0.0;
  }
  final le = _fromWireWords(Uint8List.sublistView(bytes, 0, 4));
  return ByteData.sublistView(le).getFloat32(0, Endian.little);
}

/// Encodes [value] as a 4-byte SLMP REAL in wire word order (see the file
/// header). This is a NARROWING conversion: the app stores FLOAT64 doubles and
/// SLMP REAL is 32-bit, so the encoded value is the float32 approximation of
/// [value].
Uint8List encodeSlmpReal(double value) {
  final le = Uint8List(4);
  ByteData.sublistView(le).setFloat32(0, value, Endian.little);
  return _toWireWords(le);
}

/// Encodes a signed integer as [widthBytes] bytes (two's complement), each word
/// little-endian, with the WORDS in wire order (see the file header's word-order
/// decision). For a 1-word (2-byte) value this is a plain little-endian encode.
Uint8List _encodeInt(int value, int widthBytes) {
  final le = Uint8List(widthBytes);
  final bd = ByteData.sublistView(le);
  switch (widthBytes) {
    case 2:
      bd.setInt16(0, value.toSigned(16), Endian.little);
      break;
    case 4:
      bd.setInt32(0, value.toSigned(32), Endian.little);
      break;
    case 8:
      bd.setInt64(0, value.toSigned(64), Endian.little);
      break;
    default:
      break;
  }
  return _toWireWords(le);
}

/// Decodes [widthBytes] bytes as a signed integer (two's complement). The words
/// are in wire order (see the file header), so they are mapped back to natural
/// little-endian before decoding.
int _decodeInt(Uint8List bytes, int widthBytes) {
  final le = _fromWireWords(Uint8List.sublistView(bytes, 0, widthBytes));
  final bd = ByteData.sublistView(le);
  switch (widthBytes) {
    case 2:
      return bd.getInt16(0, Endian.little);
    case 4:
      return bd.getInt32(0, Endian.little);
    case 8:
      return bd.getInt64(0, Endian.little);
    default:
      return 0;
  }
}

/// Encodes the current value of the tag named by [entry] into its wire
/// representation (LITTLE-ENDIAN, `width * 2` bytes), or `null` if the tag does
/// not resolve, holds an unexpected runtime type, or has no v1 SLMP
/// representation. BOOL is handled separately by the caller (it is a single
/// bit within a word), not through this function.
Uint8List? _encodeEntryValue(PlcProject project, SlmpMapEntry entry, String dataType) {
  final width = SlmpMap.widthWordsForType(dataType);
  if (width == null) {
    return null;
  }
  final value = readPath(project, entry.tag);
  if (dataType == 'FLOAT64') {
    final d = value is num ? value.toDouble() : 0.0;
    return encodeSlmpReal(d);
  }
  final i = value is int ? value : 0;
  return _encodeInt(i, width * 2);
}

/// Sets the bit of the little-endian [image] word that [entry] addresses. Bits
/// 0..7 live in the word's LOW byte (the first of the two little-endian bytes),
/// bits 8..15 in the HIGH byte (the second). [relWord] is the word's index
/// within the image (address minus the read's start address).
void _setImageBit(Uint8List image, int relWord, int bitOffset) {
  final base = relWord * 2;
  if (bitOffset < 8) {
    image[base] |= (1 << bitOffset); // low byte
  } else {
    image[base + 1] |= (1 << (bitOffset - 8)); // high byte
  }
}

/// Reads the bit that [entry] addresses from the little-endian word at [relWord]
/// of [data] (same byte convention as [_setImageBit]).
bool _readDataBit(Uint8List data, int relWord, int bitOffset) {
  final base = relWord * 2;
  if (bitOffset < 8) {
    return (data[base] & (1 << bitOffset)) != 0;
  }
  return (data[base + 1] & (1 << (bitOffset - 8))) != 0;
}

/// Materializes [count] words of the SLMP [device] (one of [kSlmpDeviceNames])
/// starting at [startAddress], packing in the current value of every [map] entry
/// that intersects the requested window.
///
/// Each word is little-endian; a multi-word value's words are in wire order (see
/// the file header). Words not covered by any map entry read as `0x0000`. A tag
/// only partially inside the window contributes only its overlapping words.
///
/// Returns an EMPTY list — and never throws — for a non-positive [count], a
/// negative [startAddress], or a [count] above [kSlmpMaxDeviceImageWords].
Uint8List readDeviceImage(
  PlcProject project,
  SlmpMap map,
  String device,
  int startAddress,
  int count,
) {
  if (count <= 0 || count > kSlmpMaxDeviceImageWords || startAddress < 0) {
    return Uint8List(0);
  }
  final image = Uint8List(count * 2);
  final endAddress = startAddress + count; // exclusive

  for (final entry in map.entries) {
    if (entry.device != device) {
      continue;
    }
    if (entry.address < 0 || entry.bitOffset < 0 || entry.bitOffset > 15) {
      continue;
    }
    final dataType = dataTypeOfPath(project, entry.tag);
    if (dataType == null) {
      continue;
    }
    if (dataType == 'BOOL') {
      if (entry.address < startAddress || entry.address >= endAddress) {
        continue;
      }
      if (readPath(project, entry.tag) == true) {
        _setImageBit(image, entry.address - startAddress, entry.bitOffset);
      }
      continue;
    }
    final encoded = _encodeEntryValue(project, entry, dataType);
    if (encoded == null) {
      continue;
    }
    // Multi-word: copy only the words overlapping the requested window.
    final width = encoded.length ~/ 2; // words
    final tagStart = entry.address;
    final tagEnd = entry.address + width; // exclusive
    final overlapStart = tagStart > startAddress ? tagStart : startAddress;
    final overlapEnd = tagEnd < endAddress ? tagEnd : endAddress;
    if (overlapEnd <= overlapStart) {
      continue;
    }
    for (var w = overlapStart; w < overlapEnd; w++) {
      final dest = (w - startAddress) * 2;
      final src = (w - tagStart) * 2;
      image[dest] = encoded[src];
      image[dest + 1] = encoded[src + 1];
    }
  }
  return image;
}

/// Reads [count] consecutive device POINTS (bits) of [device] starting at
/// device number [startNumber], returning ONE byte per point (`0x01` ON /
/// `0x00` OFF) — the UNPACKED form of the SLMP bit-unit wire data (the
/// dispatch layer nibble-packs it via `packSlmpBitUnits`). Device number `n`
/// maps onto the word-addressed [map] as word `n >> 4`, bit `n & 15` — so
/// `M5` is map entry (address 0, bitOffset 5), consistent with how a
/// word-unit read of the same device packs 16 points per word.
///
/// Implemented on top of [readDeviceImage] so a bit-unit read is, by
/// construction, bit-for-bit consistent with what a word-unit read of the
/// same range serves: a BOOL entry's point reads its tag value, a point
/// inside a non-BOOL entry's word reads that bit of the encoded value, and
/// gap points read 0.
///
/// Returns an EMPTY list — and never throws — for a non-positive [count], a
/// negative [startNumber], or a range whose last word would exceed
/// [kSlmpMaxDeviceImageWords].
Uint8List readDeviceBits(
  PlcProject project,
  SlmpMap map,
  String device,
  int startNumber,
  int count,
) {
  if (count <= 0 || startNumber < 0) {
    return Uint8List(0);
  }
  final startWord = startNumber >> 4;
  final lastWord = (startNumber + count - 1) >> 4;
  final wordCount = lastWord - startWord + 1;
  if (lastWord >= kSlmpMaxDeviceImageWords) {
    return Uint8List(0);
  }
  final image = readDeviceImage(project, map, device, startWord, wordCount);
  if (image.length != wordCount * 2) {
    return Uint8List(0);
  }
  final out = Uint8List(count);
  for (var i = 0; i < count; i++) {
    final pos = startNumber + i;
    out[i] = _readDataBit(image, (pos >> 4) - startWord, pos & 15) ? 0x01 : 0x00;
  }
  return out;
}

/// What happened to one tag touched by an [applyDeviceWrite] call. Mirrors
/// `FinsWriteStatus`.
enum SlmpWriteStatus {
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

  /// The tag path does not resolve, or its data type has no v1 SLMP
  /// representation (e.g. `STRING`).
  unsupported,
}

/// The outcome for one tag touched by an [applyDeviceWrite] call.
class SlmpWriteResult {
  final String tag;
  final SlmpWriteStatus status;

  const SlmpWriteResult(this.tag, this.status);

  /// True only for [SlmpWriteStatus.written].
  bool get ok => status == SlmpWriteStatus.written;
}

/// Applies [data] as a write to `data.length / 2` words of the SLMP [device]
/// starting at [startAddress], decoding it back onto every [map] entry the range
/// covers.
///
/// Each word is little-endian; a multi-word value's words are in wire order (see
/// the file header). Behaviour, per the file header: words not covered by any
/// entry are DISCARDED and not reported; a partially covered multi-word tag is
/// NOT written but IS reported; a `ReadOnly` entry, a FORCED root tag, or a tag
/// the shared write-gate refuses is refused with the tag left unchanged.
///
/// One refused or unsupported entry never affects any other entry — each tag
/// in range is handled independently, so a multi-item write can succeed in
/// part.
///
/// Returns an EMPTY list — and never throws — for empty [data], odd-length
/// [data] (not a whole number of words), or a negative [startAddress].
List<SlmpWriteResult> applyDeviceWrite(
  PlcProject project,
  SlmpMap map,
  String device,
  int startAddress,
  Uint8List data,
) {
  final results = <SlmpWriteResult>[];
  if (data.isEmpty || data.length.isOdd || startAddress < 0) {
    return results;
  }
  final wordCount = data.length ~/ 2;
  final endAddress = startAddress + wordCount; // exclusive

  for (final entry in map.entries) {
    if (entry.device != device) {
      continue;
    }
    if (entry.address < 0 || entry.bitOffset < 0 || entry.bitOffset > 15) {
      continue;
    }
    final dataType = dataTypeOfPath(project, entry.tag);
    final width = dataType == null ? null : SlmpMap.widthWordsForType(dataType);

    // Coverage is decided on the entry's declared word span. An entry whose
    // type is unknown/unsupported still occupies at least the word it names.
    final tagStart = entry.address;
    final tagEnd = entry.address + (width ?? 1); // exclusive
    if (tagEnd <= startAddress || tagStart >= endAddress) {
      continue; // no overlap at all — nothing to say about this entry
    }
    if (dataType == null || width == null) {
      results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.unsupported));
      continue;
    }
    if (tagStart < startAddress || tagEnd > endAddress) {
      // Overlapping, but not fully covered.
      results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.partiallyCovered));
      continue;
    }
    if (entry.access == 'ReadOnly') {
      results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.refusedReadOnly));
      continue;
    }

    // Write-time hard backstop: the SlmpMap entry above is a MUTABLE map a
    // hand-edit could re-target at the reserved System tag.
    // `isExternallyWritable` re-checks the underlying ROOT tag itself,
    // independent of whatever this entry claims.
    if (!isExternallyWritable(project, entry.tag)) {
      results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.refusedNotExternallyWritable));
      continue;
    }

    // Force-aware write: a forced ROOT tag refuses writes to EVERY path
    // beneath it. `rootTagOf` walks to the leaf path's FIRST segment, so for
    // `Tank.Level` it returns `Tank`. There is deliberately NO
    // `root.name == entry.tag` clause: that comparison is false for any member
    // path, which would SKIP this check and let the write land silently.
    final root = rootTagOf(project, entry.tag);
    if (root != null && root.isForced) {
      results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.refusedForced));
      continue;
    }

    final relWord = tagStart - startAddress;
    if (dataType == 'BOOL') {
      writePath(project, entry.tag, _readDataBit(data, relWord, entry.bitOffset));
    } else {
      final slice = Uint8List.sublistView(data, relWord * 2, (relWord + width) * 2);
      if (dataType == 'FLOAT64') {
        writePath(project, entry.tag, decodeSlmpReal(slice));
      } else {
        writePath(project, entry.tag, _decodeInt(slice, width * 2));
      }
    }
    results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.written));
  }
  return results;
}

/// Applies [bits] (ONE byte per device point, `0x00` = OFF / anything else =
/// ON — the UNPACKED form of the SLMP bit-unit wire data) to [bits].length
/// consecutive points of [device] starting at device number [startNumber],
/// writing each point onto the BOOL map entry addressed at exactly that
/// (word `n >> 4`, bit `n & 15`) position — see [readDeviceBits] for the
/// numbering.
///
/// Per-point semantics, mirroring [applyDeviceWrite]'s word philosophy:
///  - A point addressing a BOOL entry is written through the same gate chain
///    as a word write (`ReadOnly` -> refused, shared write-gate backstop ->
///    refused, FORCED root tag -> refused).
///  - A point landing inside a NON-BOOL entry's word span is NOT written
///    (flipping one bit of an encoded INT/REAL would corrupt the value) and
///    is reported [SlmpWriteStatus.partiallyCovered].
///  - A point landing in a gap (no entry) is DISCARDED silently, like a
///    write to a gap word.
///
/// Each point is handled independently; one refused point never affects
/// another. Returns an EMPTY list — and never throws — for empty [bits] or a
/// negative [startNumber].
List<SlmpWriteResult> applyDeviceBitWrite(
  PlcProject project,
  SlmpMap map,
  String device,
  int startNumber,
  Uint8List bits,
) {
  final results = <SlmpWriteResult>[];
  if (bits.isEmpty || startNumber < 0) {
    return results;
  }

  for (var i = 0; i < bits.length; i++) {
    final pos = startNumber + i;
    final word = pos >> 4;
    final bit = pos & 15;

    for (final entry in map.entries) {
      if (entry.device != device) {
        continue;
      }
      if (entry.address < 0 || entry.bitOffset < 0 || entry.bitOffset > 15) {
        continue;
      }
      final dataType = dataTypeOfPath(project, entry.tag);
      final width = dataType == null ? null : SlmpMap.widthWordsForType(dataType);

      if (dataType == 'BOOL') {
        if (entry.address != word || entry.bitOffset != bit) {
          continue;
        }
      } else {
        // A non-BOOL entry occupies whole words; does this point fall inside?
        final tagStart = entry.address;
        final tagEnd = entry.address + (width ?? 1); // exclusive
        if (word < tagStart || word >= tagEnd) {
          continue;
        }
        if (dataType == null || width == null) {
          results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.unsupported));
          continue;
        }
        // One bit of an encoded INT/REAL: refusing beats corrupting.
        results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.partiallyCovered));
        continue;
      }

      if (entry.access == 'ReadOnly') {
        results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.refusedReadOnly));
        continue;
      }

      // Write-time hard backstop — same rationale as [applyDeviceWrite].
      if (!isExternallyWritable(project, entry.tag)) {
        results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.refusedNotExternallyWritable));
        continue;
      }

      // Force-aware write — same rationale as [applyDeviceWrite].
      final root = rootTagOf(project, entry.tag);
      if (root != null && root.isForced) {
        results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.refusedForced));
        continue;
      }

      writePath(project, entry.tag, bits[i] != 0x00);
      results.add(SlmpWriteResult(entry.tag, SlmpWriteStatus.written));
    }
  }
  return results;
}
