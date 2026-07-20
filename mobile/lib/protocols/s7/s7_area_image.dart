// S7comm area byte-image — pure Dart, no dart:io / Flutter imports.
//
// This is where S7comm meets the app's tag database, and it is unlike every
// other protocol this app hosts. OPC UA and CIP address data by NAME,
// Modbus by discrete REGISTER, DNP3 by POINT. S7comm addresses a BYTE RANGE:
// a real S7 driver issues optimized block reads ("DB1 bytes 0..40" in one
// request) rather than one request per tag. So this file materializes a
// packed byte image of an area from the project's named tags, serves slices
// of it, and — in the write direction — decodes a written slice back onto
// the tags it overlaps.
//
// *** ENDIANNESS WARNING ***
// S7comm is BIG-ENDIAN throughout. Every multi-byte value encoded or decoded
// here uses `Endian.big`. The EtherNet/IP codec elsewhere in this repo
// (protocols/enip/) is little-endian everywhere — do not pattern-match its
// `Endian.little` calls into this file.
//
// Semantics (approved product decisions):
//  - **Gaps read as zero.** Unmapped bytes inside a requested range are
//    served as `0x00`. This mirrors a real controller, where a DB is a
//    fixed-size buffer whose unused bytes hold zero, and it lets a driver
//    block-read a whole DB without every byte being mapped.
//  - **Writes to gap bytes are DISCARDED**, silently and without a report —
//    there is no tag there to write.
//  - **A tag only PARTIALLY covered by a write range is NOT written**, since
//    writing half of a multi-byte value would corrupt it. Unlike a gap, this
//    IS reported ([S7WriteStatus.partiallyCovered]) so the caller can return
//    a per-item error rather than silently doing nothing.
//  - **Force-aware and access-aware writes.** A write landing on a tag whose
//    map entry is `ReadOnly`, or whose ROOT tag is forced, is refused and the
//    tag left unchanged.
//  - **FLOAT64 is encoded as a 4-byte S7 REAL** — a NARROWING conversion to
//    IEEE-754 single precision. A value read back over S7comm is the float32
//    approximation of the stored double.
//  - **STRING is not representable** in v1 (see models/s7_map.dart) and is
//    skipped on read and refused on write.
//
// Safety contract: nothing here ever throws on malformed, truncated, or
// hostile input — out-of-range offsets, absurd lengths, entries naming tags
// that do not exist, and unsupported data types all degrade to zeros or to a
// reported non-success result.
library s7_area_image;

import 'dart:typed_data';

import '../../models/project_model.dart';
import '../../models/s7_map.dart';
import '../../models/tag_resolver.dart';
import '../../models/tag_write_gate.dart';
import 's7_pdu.dart';

/// Maps an on-the-wire S7 area CODE (`kS7Area*` in `s7_pdu.dart`) to this
/// project's area NAME (`kS7AreaName*` in `models/s7_map.dart`), or `null`
/// for an area this version does not serve — notably the timer (`0x1D`) and
/// counter (`0x1C`) areas, whose S5TIME/BCD encodings have no equivalent in
/// this app's tag model. A `null` result must become a per-item error return
/// code, never an exception.
String? s7AreaNameForCode(int areaCode) {
  switch (areaCode) {
    case kS7AreaDataBlock:
      return kS7AreaNameDb;
    case kS7AreaMerker:
      return kS7AreaNameMerker;
    case kS7AreaInputs:
      return kS7AreaNameInputs;
    case kS7AreaOutputs:
      return kS7AreaNameOutputs;
    default:
      return null;
  }
}

/// Upper bound on the number of bytes [readAreaImage] will ever materialize
/// in one call. Comfortably above the largest PDU this device negotiates, so
/// a hostile or nonsensical length request cannot force a huge allocation.
const int kS7MaxAreaImageBytes = 65535;

/// Decodes a 4-byte BIG-ENDIAN IEEE-754 single-precision S7 REAL into a
/// Dart double. Returns 0.0 if [bytes] is shorter than 4 bytes (never
/// throws).
double decodeS7Real(Uint8List bytes) {
  if (bytes.length < 4) {
    return 0.0;
  }
  return ByteData.sublistView(bytes, 0, 4).getFloat32(0, Endian.big);
}

/// Encodes [value] as a 4-byte BIG-ENDIAN S7 REAL. This is a NARROWING
/// conversion: the app stores FLOAT64 doubles and S7 REAL is 32-bit, so the
/// encoded value is the float32 approximation of [value].
Uint8List encodeS7Real(double value) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setFloat32(0, value, Endian.big);
  return out;
}

/// Encodes a signed integer as [width] BIG-ENDIAN bytes (two's complement).
Uint8List _encodeInt(int value, int width) {
  final out = Uint8List(width);
  final bd = ByteData.sublistView(out);
  switch (width) {
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
  return out;
}

/// Decodes [width] BIG-ENDIAN bytes as a signed integer (two's complement).
int _decodeInt(Uint8List bytes, int width) {
  final bd = ByteData.sublistView(bytes, 0, width);
  switch (width) {
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

/// True if [entry] belongs to the area being addressed. `dbNumber` only
/// discriminates within the `DB` area — the merker and process-image areas
/// are single flat address spaces with no block number.
bool _entryMatchesArea(S7MapEntry entry, String area, int dbNumber) {
  if (entry.area != area) {
    return false;
  }
  if (area == kS7AreaNameDb) {
    return entry.dbNumber == dbNumber;
  }
  return true;
}

/// Encodes the current value of the tag named by [entry] into its wire
/// representation, or `null` if the tag does not resolve, holds an
/// unexpected runtime type, or has no v1 S7 representation.
///
/// For `BOOL` this returns a single byte that is `0x01` or `0x00`; the
/// caller is responsible for placing it into [S7MapEntry.bitOffset].
/// Everything else is BIG-ENDIAN.
Uint8List? _encodeEntryValue(PlcProject project, S7MapEntry entry) {
  final dataType = dataTypeOfPath(project, entry.tag);
  if (dataType == null) {
    return null;
  }
  final width = S7Map.widthBytesForType(dataType);
  if (width == null) {
    return null;
  }
  final value = readPath(project, entry.tag);
  if (dataType == 'BOOL') {
    return Uint8List.fromList([value == true ? 0x01 : 0x00]);
  }
  if (dataType == 'FLOAT64') {
    final d = value is num ? value.toDouble() : 0.0;
    return encodeS7Real(d);
  }
  final i = value is int ? value : 0;
  return _encodeInt(i, width);
}

/// Materializes [length] bytes of the S7 memory [area] (one of
/// [kS7AreaNames]) starting at [startByte], packing in the current value of
/// every [map] entry that intersects the requested window.
///
/// All multi-byte values are encoded BIG-ENDIAN. Bytes not covered by any
/// map entry read as `0x00` (see the file header). A tag only partially
/// inside the window contributes only its overlapping bytes — that is what a
/// real controller's flat memory image does, and a driver that asks for a
/// sub-range of a value gets exactly the bytes it asked for.
///
/// Returns an EMPTY list — and never throws — for a non-positive [length], a
/// negative [startByte], or a [length] above [kS7MaxAreaImageBytes].
Uint8List readAreaImage(
  PlcProject project,
  S7Map map,
  String area,
  int dbNumber,
  int startByte,
  int length,
) {
  if (length <= 0 || length > kS7MaxAreaImageBytes || startByte < 0) {
    return Uint8List(0);
  }
  final image = Uint8List(length);
  final endByte = startByte + length; // exclusive

  for (final entry in map.entries) {
    if (!_entryMatchesArea(entry, area, dbNumber)) {
      continue;
    }
    if (entry.byteOffset < 0 || entry.bitOffset < 0 || entry.bitOffset > 7) {
      continue;
    }
    final encoded = _encodeEntryValue(project, entry);
    if (encoded == null) {
      continue;
    }
    final dataType = dataTypeOfPath(project, entry.tag);
    if (dataType == 'BOOL') {
      if (entry.byteOffset < startByte || entry.byteOffset >= endByte) {
        continue;
      }
      if (encoded[0] != 0) {
        final idx = entry.byteOffset - startByte;
        image[idx] = image[idx] | (1 << entry.bitOffset);
      }
      continue;
    }
    // Multi-byte: copy only the portion overlapping the requested window.
    final tagStart = entry.byteOffset;
    final tagEnd = entry.byteOffset + encoded.length; // exclusive
    final overlapStart = tagStart > startByte ? tagStart : startByte;
    final overlapEnd = tagEnd < endByte ? tagEnd : endByte;
    if (overlapEnd <= overlapStart) {
      continue;
    }
    for (var b = overlapStart; b < overlapEnd; b++) {
      image[b - startByte] = encoded[b - tagStart];
    }
  }
  return image;
}

/// What happened to one tag touched by an [applyAreaWrite] call.
enum S7WriteStatus {
  /// The tag was fully covered by the write range and was written.
  written,

  /// The write range covered only PART of a multi-byte tag. Writing a
  /// fragment would corrupt the value, so nothing was written.
  partiallyCovered,

  /// The map entry is `ReadOnly`.
  refusedReadOnly,

  /// The tag's ROOT tag is forced. Forcing is authoritative: an external
  /// write must not be allowed to change the underlying value behind a
  /// force.
  refusedForced,

  /// Write-time hard backstop (protocol-hardening workstream, Task 2):
  /// `isExternallyWritable` refused the write independent of the map
  /// entry's own `access` — the ROOT tag is the reserved `System` tag, or
  /// its own `access` is `ReadOnly` (a case the per-entry `refusedReadOnly`
  /// above can miss if the entry's `access` doesn't reflect the tag's
  /// current state).
  refusedNotExternallyWritable,

  /// The tag path does not resolve, or its data type has no v1 S7
  /// representation (e.g. `STRING`).
  unsupported,
}

/// The outcome for one tag touched by an [applyAreaWrite] call.
class S7WriteResult {
  final String tag;
  final S7WriteStatus status;

  const S7WriteResult(this.tag, this.status);

  /// True only for [S7WriteStatus.written].
  bool get ok => status == S7WriteStatus.written;
}

/// Applies [data] as a write to [length] bytes of the S7 memory [area]
/// starting at [startByte], decoding it back onto every [map] entry the
/// range covers.
///
/// All multi-byte values are decoded BIG-ENDIAN. Behaviour, per the file
/// header: bytes not covered by any entry are DISCARDED and not reported; a
/// partially covered multi-byte tag is NOT written but IS reported; a
/// `ReadOnly` entry or a FORCED root tag is refused with the tag left
/// unchanged.
///
/// One refused or unsupported entry never affects any other entry — each
/// tag in range is handled independently, so a multi-item write can succeed
/// in part.
///
/// Returns an EMPTY list — and never throws — for empty [data] or a negative
/// [startByte].
List<S7WriteResult> applyAreaWrite(
  PlcProject project,
  S7Map map,
  String area,
  int dbNumber,
  int startByte,
  Uint8List data,
) {
  final results = <S7WriteResult>[];
  if (data.isEmpty || startByte < 0) {
    return results;
  }
  final endByte = startByte + data.length; // exclusive

  for (final entry in map.entries) {
    if (!_entryMatchesArea(entry, area, dbNumber)) {
      continue;
    }
    if (entry.byteOffset < 0 || entry.bitOffset < 0 || entry.bitOffset > 7) {
      continue;
    }
    final dataType = dataTypeOfPath(project, entry.tag);
    final width = dataType == null ? null : S7Map.widthBytesForType(dataType);

    // Coverage is decided on the entry's declared byte span. An entry whose
    // type is unknown/unsupported still occupies at least the byte it names,
    // so a range touching it is reported rather than silently ignored.
    final tagStart = entry.byteOffset;
    final tagEnd = entry.byteOffset + (width ?? 1); // exclusive
    if (tagEnd <= startByte || tagStart >= endByte) {
      continue; // no overlap at all — nothing to say about this entry
    }
    if (dataType == null || width == null) {
      results.add(S7WriteResult(entry.tag, S7WriteStatus.unsupported));
      continue;
    }
    if (tagStart < startByte || tagEnd > endByte) {
      // Overlapping, but not fully covered.
      results.add(S7WriteResult(entry.tag, S7WriteStatus.partiallyCovered));
      continue;
    }
    if (entry.access == 'ReadOnly') {
      results.add(S7WriteResult(entry.tag, S7WriteStatus.refusedReadOnly));
      continue;
    }

    // Write-time hard backstop (protocol-hardening workstream, Task 2): the
    // S7Map entry above is a MUTABLE map that a hand-edit could re-target at
    // the reserved System tag. `isExternallyWritable` re-checks the
    // underlying ROOT tag itself, independent of whatever this entry
    // claims — a hard, non-overridable rule, never a replacement for the
    // per-entry check above.
    if (!isExternallyWritable(project, entry.tag)) {
      results.add(S7WriteResult(entry.tag, S7WriteStatus.refusedNotExternallyWritable));
      continue;
    }

    // Force-aware write: a forced ROOT tag refuses writes to EVERY path
    // beneath it, not just to the bare root name. `rootTagOf` walks to the
    // leaf path's FIRST SEGMENT, so for `Tank.Level` it returns `Tank`.
    // There is deliberately NO `root.name == entry.tag` clause here: such a
    // comparison is false for any member path, which would SKIP this check
    // and let the write land silently — and because reads seed from
    // `forcedValue`, the corruption would only surface once the force was
    // released. See protocols/enip/cip_tags.dart for the same corrected
    // form.
    final root = rootTagOf(project, entry.tag);
    if (root != null && root.isForced) {
      results.add(S7WriteResult(entry.tag, S7WriteStatus.refusedForced));
      continue;
    }

    final slice = Uint8List.sublistView(data, tagStart - startByte, tagEnd - startByte);
    if (dataType == 'BOOL') {
      final bit = (slice[0] & (1 << entry.bitOffset)) != 0;
      writePath(project, entry.tag, bit);
    } else if (dataType == 'FLOAT64') {
      writePath(project, entry.tag, decodeS7Real(slice));
    } else {
      writePath(project, entry.tag, _decodeInt(slice, width));
    }
    results.add(S7WriteResult(entry.tag, S7WriteStatus.written));
  }
  return results;
}
