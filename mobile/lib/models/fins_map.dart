// Pure Dart Omron FINS tag<->area/word map model (FINS workstream).
//
// Mirrors the S7 area map (s7_map.dart), which solves the same named-tag <->
// numeric-address problem, with one difference: FINS addresses a WORD (2
// bytes) inside a memory area, not a byte. A real FINS driver issues Memory
// Area Reads by area code + word address ("DM100, 20 words" in one request),
// so tags are packed into a WORD image — see
// protocols/fins/fins_area_image.dart, which consumes this map.
//
// Areas supported in v1: `'DM'` (data memory), `'CIO'` (core I/O), `'WR'`
// (work) and `'HR'` (holding) — the word areas a driver polling word data
// addresses.
//
// Type mapping (see fins_area_image.dart for the encoding itself):
//   BOOL    -> 1 bit inside a word (16 bits per word, bit 0..15)
//   INT16   -> INT,  1 word
//   INT32   -> DINT, 2 words — LOW WORD FIRST (at the lower word address),
//              big-endian within each word. The Task-5 real `fins` E2E settled
//              this: the client word-reverses a multi-word value, overturning
//              the provisional high-word-first choice (see fins_area_image.dart's
//              header).
//   INT64   -> LINT, 4 words
//   FLOAT64 -> REAL, 2 words — a NARROWING conversion to IEEE-754 single
//              precision. The app stores doubles; FINS REAL is 32-bit, so a
//              value read back over FINS is the float32 approximation of the
//              tag's value, not the double itself.
//   STRING  -> SKIPPED by [FinsMap.autoGenerate], exactly as the S7 map
//              defers STRING. A STRING can still be mapped by hand, but the
//              area image refuses to encode or decode it.
//
// No Flutter dependency and no dart:io — this file must stay pure Dart so it
// can be used from services and widgets alike.

import 'project_model.dart';
import 'tag_resolver.dart';
import 'tag_write_gate.dart';

/// Data Memory (DM) area name.
const String kFinsAreaNameDM = 'DM';

/// Core I/O (CIO) area name.
const String kFinsAreaNameCIO = 'CIO';

/// Work (WR) area name.
const String kFinsAreaNameWR = 'WR';

/// Holding (HR) area name.
const String kFinsAreaNameHR = 'HR';

/// Every area name this version supports.
const List<String> kFinsAreaNames = [
  kFinsAreaNameDM,
  kFinsAreaNameCIO,
  kFinsAreaNameWR,
  kFinsAreaNameHR,
];

/// One FINS map entry, binding a project tag (by its dotted/indexed leaf path)
/// to an `area` + `wordAddress` + `bitOffset` address.
///
/// `area` is one of [kFinsAreaNames]. `bitOffset` (0..15) is only meaningful
/// for `BOOL` tags and is 0 otherwise. `access` is either `'ReadOnly'` or
/// `'ReadWrite'`.
class FinsMapEntry {
  String tag;
  String area;
  int wordAddress;
  int bitOffset;
  String access;

  FinsMapEntry({
    required this.tag,
    required this.area,
    required this.wordAddress,
    this.bitOffset = 0,
    this.access = 'ReadWrite',
  });

  factory FinsMapEntry.fromJson(Map<String, dynamic> json) => FinsMapEntry(
        tag: json['tag']?.toString() ?? '',
        area: json['area']?.toString() ?? kFinsAreaNameDM,
        wordAddress: (json['word_address'] as num?)?.toInt() ?? 0,
        bitOffset: (json['bit_offset'] as num?)?.toInt() ?? 0,
        access: json['access']?.toString() ?? 'ReadWrite',
      );

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'area': area,
        'word_address': wordAddress,
        'bit_offset': bitOffset,
        'access': access,
      };
}

/// The editable FINS area map for a project: the list of tag<->address
/// bindings across the supported memory areas.
class FinsMap {
  List<FinsMapEntry> entries;

  FinsMap({List<FinsMapEntry>? entries}) : entries = entries ?? [];

  /// Tolerant of a missing or non-list `entries` key so an older project JSON
  /// with no `fins` section loads cleanly (additive persistence).
  factory FinsMap.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return FinsMap(
      entries: (rawEntries is List)
          ? rawEntries
              .whereType<Map>()
              .map((e) => FinsMapEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <FinsMapEntry>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// Width in WORDS a scalar data type occupies in a FINS area image, or
  /// `null` if the type has no v1 FINS representation (`STRING`, and anything
  /// unrecognized). `BOOL` reports 1 because it lives inside exactly one word,
  /// even though it occupies a single bit of it.
  static int? widthWordsForType(String dataType) {
    switch (dataType) {
      case 'BOOL':
        return 1;
      case 'INT16':
        return 1;
      case 'INT32':
        return 2; // DINT
      case 'FLOAT64':
        return 2; // REAL — narrowing, see the file header.
      case 'INT64':
        return 4; // LINT
      default:
        return null;
    }
  }

  /// Builds a default map from a project's scalar leaf tags ([scalarLeaves]):
  /// composite/array tags are expanded into one entry per scalar leaf. Every
  /// entry is packed into `DM` sequentially by WORD, in leaf order.
  ///
  /// `BOOL` leaves are bit-packed: consecutive BOOLs share a word, filling
  /// bits 0..15 before advancing. The first non-BOOL leaf after a BOOL closes
  /// the partially used word and advances to the next whole word.
  ///
  /// `STRING` leaves are SKIPPED entirely (see the file header), as is any
  /// other type with no [widthWordsForType].
  ///
  /// Access is inherited from the ROOT tag via [defaultsExternallyWritable],
  /// exactly as the S7/Modbus/CIP maps do: a `SimulatedOutput` tag, an
  /// explicit tag `access` of `'ReadOnly'`, or the reserved `System` tag
  /// (checked by NAME) yields `'ReadOnly'`; everything else yields
  /// `'ReadWrite'`.
  static FinsMap autoGenerate(PlcProject p) {
    final entries = <FinsMapEntry>[];
    var nextWord = 0;
    var nextBit = 0;
    for (final leaf in scalarLeaves(p)) {
      final width = widthWordsForType(leaf.dataType);
      if (width == null) {
        continue;
      }
      final rw = defaultsExternallyWritable(p, leaf.path);
      final access = rw ? 'ReadWrite' : 'ReadOnly';

      int wordAddress;
      int bitOffset;
      if (leaf.dataType == 'BOOL') {
        wordAddress = nextWord;
        bitOffset = nextBit;
        nextBit += 1;
        if (nextBit >= 16) {
          nextBit = 0;
          nextWord += 1;
        }
      } else {
        // Close any partially used bit word before taking whole words.
        if (nextBit > 0) {
          nextBit = 0;
          nextWord += 1;
        }
        wordAddress = nextWord;
        bitOffset = 0;
        nextWord += width;
      }

      entries.add(FinsMapEntry(
        tag: leaf.path,
        area: kFinsAreaNameDM,
        wordAddress: wordAddress,
        bitOffset: bitOffset,
        access: access,
      ));
    }
    return FinsMap(entries: entries);
  }
}
