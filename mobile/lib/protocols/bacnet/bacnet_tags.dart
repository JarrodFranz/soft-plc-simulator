// BACnet primitive application/context TAG codec — pure Dart, no dart:io /
// Flutter imports (this file uses `dart:convert`'s `utf8` in addition to
// `dart:typed_data`, both pure-Dart). This is the second-bottom layer of the
// BACnet/IP stack, sitting on top of `bacnet_bvll.dart`'s framing: every
// APDU service (a later task, `bacnet_services.dart`) is built out of these
// tagged primitive values.
//
// *** THE TAG-STRUCTURE TRAP — READ THIS BEFORE TOUCHING ANYTHING HERE ***
// BACnet's APDU payloads are ASN.1-style TAGGED values, not fixed layouts:
// application tags vs. context tags (same numeric tag-number range, but
// context tags carry a class bit and their meaning depends entirely on
// which service field they appear in), opening/closing tags for constructed
// (nested) data, and extended length forms. This — NOT byte order — is
// where real BACnet implementations break. Multi-byte PRIMITIVE CONTENT
// (Unsigned/Signed/Real/ObjectIdentifier numeric values) is consistently
// BIG-ENDIAN, but the tag byte itself packs its fields "backwards" from a
// naive reading: `tagNumber<<4 | classBit<<3 | lengthValueType`. A
// build-then-parse round trip through this SAME file's encoder/reader
// proves NOTHING — a symmetric bug (e.g. swapped nibbles, an off-by-one in
// the extended-length form) cancels out perfectly and passes silently. That
// is why every fixture in `test/bacnet_tags_test.dart` pins LITERAL
// hand-built octets in both directions instead of only round-tripping.
//
// One tag shape is a genuine special case, not a bug: the APPLICATION-tagged
// Boolean stores its value (0 or 1) directly IN the length/value/type (LVT)
// field of the tag byte — it has NO content bytes at all on the wire. Every
// other primitive uses LVT as an actual length (0-4 direct, 5 = extended
// length byte(s) follow). [BacnetTagReader.readTag] special-cases
// application Boolean for exactly this reason; context-tagged Booleans (rare
// in this codebase's services) use the normal length-prefixed form.
//
// Opening/closing tags ([openingTag]/[closingTag]) are context tags whose
// LVT is fixed at 6 (opening) or 7 (closing) and which never carry content
// of their own — they bracket a run of other tags.
//
// Safety contract: [BacnetTagReader.readTag] and every typed helper on
// [BacnetDecodedTag] return `null` — and NEVER throw — on malformed,
// truncated, or otherwise hostile input, since the UDP host (a later task)
// feeds decoded APDU bytes read straight off the wire.
library bacnet_tags;

import 'dart:convert';
import 'dart:typed_data';

// --- Application tag numbers (low nibble class bit clear) --------------------

const int kBacnetTagNull = 0;
const int kBacnetTagBoolean = 1;
const int kBacnetTagUnsigned = 2;
const int kBacnetTagSigned = 3;
const int kBacnetTagReal = 4;
const int kBacnetTagCharString = 7;
const int kBacnetTagBitString = 8;
const int kBacnetTagEnumerated = 9;
const int kBacnetTagObjectId = 12;

// --- Tag-byte structural constants -------------------------------------------

/// Tag-byte bit distinguishing context tags (set) from application tags
/// (clear). Packed at bit 3 of the tag byte: `tagNumber<<4 | classBit | lvt`.
const int _kTagClassBitContext = 0x08;

/// Length/value/type (LVT) sentinel meaning "an extended length byte (or
/// more) follows"; values 0-4 are literal lengths, 5 means extended.
const int _kLvtExtended = 5;

/// LVT value marking a context opening tag (constructed data begins).
const int _kLvtOpening = 6;

/// LVT value marking a context closing tag (constructed data ends).
const int _kLvtClosing = 7;

/// Tag-number nibble sentinel meaning "the real tag number is in the next
/// byte" (used for tag numbers >= 15; not exercised by any tag number this
/// codebase currently emits, but handled so the reader never misparses one
/// on the wire).
const int _kTagNumberExtended = 0x0F;

/// Charset byte BACnet CharacterString always begins with; this device only
/// ever emits/reads UTF-8.
const int _kCharStringCharsetUtf8 = 0x00;

// --- Minimal-octet integer encoding helpers ----------------------------------

/// Encodes [value] (must be >= 0) as the minimal number of BIG-ENDIAN octets
/// that represent it, per BACnet's Unsigned/Enumerated encoding rule (at
/// least 1 octet, even for 0).
Uint8List _minimalUnsignedBytes(int value) {
  if (value <= 0) {
    return Uint8List.fromList([0]);
  }
  final bytes = <int>[];
  var v = value;
  while (v > 0) {
    bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  return Uint8List.fromList(bytes);
}

/// Encodes [value] as the minimal number of BIG-ENDIAN two's-complement
/// octets that represent it, per BACnet's Signed encoding rule (ASN.1-style
/// minimal signed integer: the smallest N such that value fits in N bytes of
/// two's complement).
Uint8List _minimalSignedBytes(int value) {
  var n = 1;
  while (true) {
    final min = -(1 << (8 * n - 1));
    final max = (1 << (8 * n - 1)) - 1;
    if (value >= min && value <= max) {
      break;
    }
    n++;
  }
  final bytes = Uint8List(n);
  var v = value;
  for (var i = n - 1; i >= 0; i--) {
    bytes[i] = v & 0xFF;
    v >>= 8;
  }
  return bytes;
}

// --- Generic tag builder ------------------------------------------------------

/// Builds a complete tag (tag byte [+ extended tag number byte] [+ extended
/// length bytes] + [content]) for [tagNumber], setting the context class bit
/// when [isContext] is true. Handles the short form (content length 0-4,
/// encoded directly in LVT) and the extended forms (LVT 5 + 1/3/5 length
/// bytes) per the BACnet tag encoding rules. This is never used for
/// application-tagged Boolean, whose LVT holds the value itself, not a
/// length — see [encodeAppBoolean].
Uint8List _buildTag(int tagNumber, {required bool isContext, required Uint8List content}) {
  final classBit = isContext ? _kTagClassBitContext : 0x00;
  final extendedTagNumber = tagNumber >= 15;
  final tagNumberField = extendedTagNumber ? _kTagNumberExtended : tagNumber;

  final len = content.length;
  int lvt;
  final lengthExtra = <int>[];
  if (len <= 4) {
    lvt = len;
  } else if (len <= 253) {
    lvt = _kLvtExtended;
    lengthExtra.add(len);
  } else if (len <= 0xFFFF) {
    lvt = _kLvtExtended;
    lengthExtra.addAll([254, (len >> 8) & 0xFF, len & 0xFF]);
  } else {
    lvt = _kLvtExtended;
    lengthExtra.addAll([255, (len >> 24) & 0xFF, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF]);
  }

  final header = <int>[(tagNumberField << 4) | classBit | lvt];
  if (extendedTagNumber) {
    header.add(tagNumber & 0xFF);
  }
  header.addAll(lengthExtra);

  final out = Uint8List(header.length + content.length);
  out.setRange(0, header.length, header);
  out.setRange(header.length, out.length, content);
  return out;
}

Uint8List _buildPrimitiveApp(int tagNumber, Uint8List content) {
  return _buildTag(tagNumber, isContext: false, content: content);
}

// --- Application tag encoders -------------------------------------------------

/// Encodes the BACnet application-tagged Null value: always the single byte
/// `0x00` (tag number [kBacnetTagNull], LVT 0, no content).
Uint8List encodeAppNull() => Uint8List.fromList([kBacnetTagNull << 4]);

/// Encodes an application-tagged Boolean. UNLIKE every other primitive tag,
/// the value (0 or 1) is stored directly in the tag byte's LVT field — there
/// is NO content byte on the wire. `false` -> `0x10`, `true` -> `0x11`.
Uint8List encodeAppBoolean(bool value) {
  return Uint8List.fromList([(kBacnetTagBoolean << 4) | (value ? 1 : 0)]);
}

/// Encodes an application-tagged Unsigned integer using the minimal number
/// of BIG-ENDIAN octets (e.g. `5` -> `0x21 0x05`; `260` -> `0x22 0x01 0x04`).
Uint8List encodeAppUnsigned(int value) {
  return _buildPrimitiveApp(kBacnetTagUnsigned, _minimalUnsignedBytes(value));
}

/// Encodes an application-tagged Signed integer using the minimal number of
/// BIG-ENDIAN two's-complement octets (e.g. `-1` -> `0x31 0xFF`).
Uint8List encodeAppSigned(int value) {
  return _buildPrimitiveApp(kBacnetTagSigned, _minimalSignedBytes(value));
}

/// Encodes an application-tagged Real (IEEE-754 single-precision float,
/// BIG-ENDIAN, always 4 content bytes — e.g. `12.5` -> `0x44 0x41 0x48 0x00
/// 0x00`).
Uint8List encodeAppReal(double value) {
  final bd = ByteData(4);
  bd.setFloat32(0, value, Endian.big);
  return _buildPrimitiveApp(kBacnetTagReal, bd.buffer.asUint8List(bd.offsetInBytes, 4));
}

/// Encodes an application-tagged CharacterString: a leading charset byte
/// (always `0x00` — UTF-8, the only charset this device emits or reads)
/// followed by the UTF-8 bytes of [value]. Content length 0-4 uses the short
/// form; length >= 5 uses the extended-length form automatically (handled by
/// [_buildTag] — e.g. `"Hi"` -> `0x73 0x00 0x48 0x69`; `"Hello"` -> `0x75
/// 0x06 0x00 ...`).
Uint8List encodeAppCharString(String value) {
  final encoded = utf8.encode(value);
  final content = Uint8List(1 + encoded.length);
  content[0] = _kCharStringCharsetUtf8;
  content.setRange(1, content.length, encoded);
  return _buildPrimitiveApp(kBacnetTagCharString, content);
}

/// Encodes an application-tagged Enumerated value using the same minimal
/// BIG-ENDIAN unsigned-octet rule as [encodeAppUnsigned] (e.g. `0` -> `0x91
/// 0x00`).
Uint8List encodeAppEnumerated(int value) {
  return _buildPrimitiveApp(kBacnetTagEnumerated, _minimalUnsignedBytes(value));
}

/// Encodes an application-tagged ObjectIdentifier: a single BIG-ENDIAN u32
/// content value packing `objectType<<22 | instance` (object type is 10
/// bits, instance is 22 bits) — e.g. analog-value(2) instance 0 -> `0xC4
/// 0x00 0x80 0x00 0x00`; device(8) instance 3056 -> `0xC4 0x02 0x00 0x0B
/// 0xF0`.
Uint8List encodeAppObjectId(int objectType, int instance) {
  final value = ((objectType & 0x3FF) << 22) | (instance & 0x3FFFFF);
  final bd = ByteData(4);
  bd.setUint32(0, value, Endian.big);
  return _buildPrimitiveApp(kBacnetTagObjectId, bd.buffer.asUint8List(bd.offsetInBytes, 4));
}

/// Encodes an application-tagged BitString of [bitCount] bits, with the bits
/// listed in [setBits] (0-indexed, bit 0 is the MSB of the first data byte)
/// set to 1 and all others 0. Content is `[unusedBitCount, ...dataBytes]`
/// where `unusedBitCount` is `byteCount*8 - bitCount` and `byteCount =
/// ceil(bitCount / 8)`. Per bit N, it lives at bit `7-(N%8)` of data byte
/// `N~/8` (MSB-first) — e.g. 4 bits, all false -> `0x82 0x04 0x00`. Bit
/// indices in [setBits] outside `[0, bitCount)` are ignored defensively.
Uint8List encodeAppBitString(int bitCount, Set<int> setBits) {
  final byteCount = (bitCount + 7) ~/ 8;
  final unused = byteCount * 8 - bitCount;
  final data = Uint8List(byteCount);
  for (final n in setBits) {
    if (n < 0 || n >= bitCount) {
      continue;
    }
    final byteIndex = n ~/ 8;
    final pos = 7 - (n % 8);
    data[byteIndex] |= (1 << pos);
  }
  final content = Uint8List(1 + byteCount);
  content[0] = unused;
  content.setRange(1, content.length, data);
  return _buildPrimitiveApp(kBacnetTagBitString, content);
}

// --- Context tag encoders ------------------------------------------------

/// Encodes a context-tagged Unsigned integer under context tag number
/// [tagNum] (e.g. context 1, value 5 -> `0x19 0x05`).
Uint8List encodeContextUnsigned(int tagNum, int value) {
  return _buildTag(tagNum, isContext: true, content: _minimalUnsignedBytes(value));
}

/// Encodes a context-tagged Enumerated value under context tag number
/// [tagNum] (same minimal-unsigned-octet content rule as
/// [encodeContextUnsigned]).
Uint8List encodeContextEnumerated(int tagNum, int value) {
  return _buildTag(tagNum, isContext: true, content: _minimalUnsignedBytes(value));
}

/// Encodes a context-tagged ObjectIdentifier under context tag number
/// [tagNum] (same u32 `objectType<<22 | instance` content rule as
/// [encodeAppObjectId] — e.g. context 0, analog-value(2) instance 0 ->
/// `0x0C 0x00 0x80 0x00 0x00`).
Uint8List encodeContextObjectId(int tagNum, int objectType, int instance) {
  final value = ((objectType & 0x3FF) << 22) | (instance & 0x3FFFFF);
  final bd = ByteData(4);
  bd.setUint32(0, value, Endian.big);
  return _buildTag(tagNum, isContext: true, content: bd.buffer.asUint8List(bd.offsetInBytes, 4));
}

/// Builds a context opening tag for context tag number [n] — LVT fixed at 6,
/// no content (brackets the start of constructed/nested data) — e.g. `n=3`
/// -> `0x3E`.
Uint8List openingTag(int n) {
  if (n < 15) {
    return Uint8List.fromList([(n << 4) | _kTagClassBitContext | _kLvtOpening]);
  }
  return Uint8List.fromList([
    (_kTagNumberExtended << 4) | _kTagClassBitContext | _kLvtOpening,
    n & 0xFF,
  ]);
}

/// Builds a context closing tag for context tag number [n] — LVT fixed at 7,
/// no content (brackets the end of constructed/nested data) — e.g. `n=3` ->
/// `0x3F`.
Uint8List closingTag(int n) {
  if (n < 15) {
    return Uint8List.fromList([(n << 4) | _kTagClassBitContext | _kLvtClosing]);
  }
  return Uint8List.fromList([
    (_kTagNumberExtended << 4) | _kTagClassBitContext | _kLvtClosing,
    n & 0xFF,
  ]);
}

// --- Decoded tag + typed helpers ----------------------------------------------

/// A single decoded BACnet tag: its [tagNumber], whether it is [isContext]
/// (vs. application), whether it is an [isOpening] or [isClosing] bracket
/// (in which case [content] is always empty), and the raw [content] bytes
/// otherwise (for application Boolean specifically, [content] is a synthetic
/// single byte holding the 0/1 value taken from the tag's LVT field, since
/// that shape carries no real content on the wire — see [asBoolean]).
class BacnetDecodedTag {
  final int tagNumber;
  final bool isContext;
  final bool isOpening;
  final bool isClosing;
  final Uint8List content;

  BacnetDecodedTag({
    required this.tagNumber,
    required this.isContext,
    required this.isOpening,
    required this.isClosing,
    required this.content,
  });

  /// Interprets [content] as a BIG-ENDIAN unsigned integer (the encoding
  /// used by Unsigned and Enumerated primitives). Returns `null` — never
  /// throws — if [content] is empty or implausibly long (> 8 bytes).
  int? asUnsigned() {
    if (content.isEmpty || content.length > 8) {
      return null;
    }
    try {
      var v = 0;
      for (final b in content) {
        v = (v << 8) | b;
      }
      return v;
    } catch (_) {
      return null;
    }
  }

  /// Interprets [content] as a BIG-ENDIAN IEEE-754 single-precision float
  /// (the Real primitive). Returns `null` — never throws — unless [content]
  /// is exactly 4 bytes.
  double? asReal() {
    if (content.length != 4) {
      return null;
    }
    try {
      return ByteData.sublistView(content).getFloat32(0, Endian.big);
    } catch (_) {
      return null;
    }
  }

  /// Interprets [content] as a BIG-ENDIAN u32 ObjectIdentifier
  /// (`objectType<<22 | instance`), returning `(type, instance)`. Returns
  /// `null` — never throws — unless [content] is exactly 4 bytes.
  (int type, int instance)? asObjectId() {
    if (content.length != 4) {
      return null;
    }
    try {
      final v = ByteData.sublistView(content).getUint32(0, Endian.big);
      final type = (v >> 22) & 0x3FF;
      final instance = v & 0x3FFFFF;
      return (type, instance);
    } catch (_) {
      return null;
    }
  }

  /// Interprets [content] as a BIG-ENDIAN unsigned integer (the Enumerated
  /// primitive uses the same minimal-unsigned-octet encoding as Unsigned).
  /// Returns `null` — never throws — under the same conditions as
  /// [asUnsigned].
  int? asEnumerated() => asUnsigned();

  /// Interprets [content] as a boolean: for an application-tagged Boolean,
  /// [BacnetTagReader.readTag] already places the LVT-encoded 0/1 value into
  /// a synthetic single-byte [content]; for a context-tagged Boolean, the
  /// single content byte holds the value directly on the wire. Either way, a
  /// single content byte of `0` is `false` and any other single byte is
  /// `true`. Returns `null` — never throws — unless [content] is exactly 1
  /// byte.
  bool? asBoolean() {
    if (content.length != 1) {
      return null;
    }
    return content[0] != 0;
  }
}

/// A cursor over a [buffer] of BACnet tags, starting at byte offset [start].
/// Call [readTag] repeatedly until [done] to walk every tag in a buffer (or
/// a sub-range of one, e.g. between an opening and matching closing tag).
class BacnetTagReader {
  final Uint8List buffer;
  int _pos;

  BacnetTagReader(this.buffer, [int start = 0]) : _pos = start;

  /// True once the cursor has consumed the entire buffer (or advanced past
  /// its end, which only happens after a malformed [readTag] call already
  /// returned `null`).
  bool get done => _pos >= buffer.length;

  /// The cursor's current byte offset into [buffer].
  int get position => _pos;

  /// Reads and decodes the next tag starting at [position], advancing the
  /// cursor past it. Returns `null` — and NEVER throws — if there is no tag
  /// byte left to read, or if the tag's declared length/extended-length
  /// fields or content would run past the end of [buffer]. On `null` the
  /// cursor position is left unchanged, so a caller may safely stop walking.
  BacnetDecodedTag? readTag() {
    try {
      if (_pos >= buffer.length) {
        return null;
      }
      final first = buffer[_pos];
      var tagNumber = (first >> 4) & 0x0F;
      final isContext = (first & _kTagClassBitContext) != 0;
      final lvt = first & 0x07;
      var cursor = _pos + 1;

      if (tagNumber == _kTagNumberExtended) {
        if (cursor >= buffer.length) {
          return null;
        }
        tagNumber = buffer[cursor];
        cursor += 1;
      }

      // Opening/closing brackets only exist as context tags and carry no
      // content of their own.
      if (isContext && lvt == _kLvtOpening) {
        _pos = cursor;
        return BacnetDecodedTag(
          tagNumber: tagNumber,
          isContext: true,
          isOpening: true,
          isClosing: false,
          content: Uint8List(0),
        );
      }
      if (isContext && lvt == _kLvtClosing) {
        _pos = cursor;
        return BacnetDecodedTag(
          tagNumber: tagNumber,
          isContext: true,
          isOpening: false,
          isClosing: true,
          content: Uint8List(0),
        );
      }

      // Application-tagged Boolean is the one shape where LVT IS the value,
      // not a length — there are no content bytes on the wire at all.
      if (!isContext && tagNumber == kBacnetTagBoolean) {
        _pos = cursor;
        return BacnetDecodedTag(
          tagNumber: tagNumber,
          isContext: false,
          isOpening: false,
          isClosing: false,
          content: Uint8List.fromList([lvt]),
        );
      }

      int length;
      if (lvt <= 4) {
        length = lvt;
      } else if (lvt == _kLvtExtended) {
        if (cursor >= buffer.length) {
          return null;
        }
        final lenByte = buffer[cursor];
        cursor += 1;
        if (lenByte == 254) {
          if (cursor + 2 > buffer.length) {
            return null;
          }
          length = ByteData.sublistView(buffer, cursor, cursor + 2).getUint16(0, Endian.big);
          cursor += 2;
        } else if (lenByte == 255) {
          if (cursor + 4 > buffer.length) {
            return null;
          }
          length = ByteData.sublistView(buffer, cursor, cursor + 4).getUint32(0, Endian.big);
          cursor += 4;
        } else {
          length = lenByte;
        }
      } else {
        // lvt is 6 or 7 but isContext was false (an application tag cannot
        // be an opening/closing bracket) — malformed.
        return null;
      }

      if (cursor + length > buffer.length || length < 0) {
        return null;
      }
      final content = Uint8List.fromList(buffer.sublist(cursor, cursor + length));
      _pos = cursor + length;
      return BacnetDecodedTag(
        tagNumber: tagNumber,
        isContext: isContext,
        isOpening: false,
        isClosing: false,
        content: content,
      );
    } catch (_) {
      return null;
    }
  }
}
