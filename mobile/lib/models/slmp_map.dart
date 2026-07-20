// Pure Dart Mitsubishi SLMP (MELSEC) tag<->device/address map model (SLMP
// workstream).
//
// Mirrors the Omron FINS area map (fins_map.dart), which solves the same
// named-tag <-> numeric-address problem, with one difference: SLMP addresses a
// DEVICE (D/M/W/R) by a device NUMBER (the "address"), not a memory-area name by
// word offset. A real MC client issues Batch Reads by device code + device
// number ("D100, 20 words" in one request), so tags are packed into a WORD image
// — see protocols/slmp/slmp_device_image.dart, which consumes this map.
//
// Word devices supported in v1: `'D'` (data register), `'M'` (internal relay),
// `'W'` (link register) and `'R'` (file register) — the word devices a client
// polling word data addresses. (These are the device NAMES; the on-the-wire
// device CODES live in protocols/slmp/slmp_commands.dart.)
//
// Type mapping (see slmp_device_image.dart for the encoding itself; all
// LITTLE-ENDIAN, the EXACT INVERSE of FINS/S7):
//   BOOL    -> 1 bit inside a word (16 bits per word, bit 0..15)
//   INT16   -> 1 word
//   INT32   -> 2 words — LOW WORD FIRST (at the lower device address),
//              little-endian within each word. PROVISIONAL pending Task 5's real
//              `pymcprotocol` read-back E2E, which settles the 32-bit word order
//              (see slmp_device_image.dart's header).
//   INT64   -> 4 words
//   FLOAT64 -> REAL, 2 words — a NARROWING conversion to IEEE-754 single
//              precision. The app stores doubles; SLMP REAL is 32-bit, so a
//              value read back over SLMP is the float32 approximation of the
//              tag's value, not the double itself.
//   STRING  -> SKIPPED by [SlmpMap.autoGenerate], exactly as the FINS map
//              defers STRING. A STRING can still be mapped by hand, but the
//              device image refuses to encode or decode it.
//
// No Flutter dependency and no dart:io — this file must stay pure Dart so it
// can be used from services and widgets alike.

import 'project_model.dart';
import 'tag_resolver.dart';
import 'tag_write_gate.dart';

/// Data register (D) device name.
const String kSlmpDeviceNameD = 'D';

/// Internal relay (M) device name.
const String kSlmpDeviceNameM = 'M';

/// Link register (W) device name.
const String kSlmpDeviceNameW = 'W';

/// File register (R) device name.
const String kSlmpDeviceNameR = 'R';

/// Every device name this version supports.
const List<String> kSlmpDeviceNames = [
  kSlmpDeviceNameD,
  kSlmpDeviceNameM,
  kSlmpDeviceNameW,
  kSlmpDeviceNameR,
];

/// One SLMP map entry, binding a project tag (by its dotted/indexed leaf path)
/// to a `device` + `address` (+ `bitOffset` for BOOLs).
///
/// `device` is one of [kSlmpDeviceNames]. `address` is the device number (the
/// starting word). `bitOffset` (0..15) is only meaningful for `BOOL` tags and is
/// 0 otherwise. `access` is either `'ReadOnly'` or `'ReadWrite'`.
class SlmpMapEntry {
  String tag;
  String device;
  int address;
  int bitOffset;
  String access;

  SlmpMapEntry({
    required this.tag,
    required this.device,
    required this.address,
    this.bitOffset = 0,
    this.access = 'ReadWrite',
  });

  factory SlmpMapEntry.fromJson(Map<String, dynamic> json) => SlmpMapEntry(
        tag: json['tag']?.toString() ?? '',
        device: json['device']?.toString() ?? kSlmpDeviceNameD,
        address: (json['address'] as num?)?.toInt() ?? 0,
        bitOffset: (json['bit_offset'] as num?)?.toInt() ?? 0,
        access: json['access']?.toString() ?? 'ReadWrite',
      );

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'device': device,
        'address': address,
        'bit_offset': bitOffset,
        'access': access,
      };
}

/// The editable SLMP device map for a project: the list of tag<->address
/// bindings across the supported word devices.
class SlmpMap {
  List<SlmpMapEntry> entries;

  SlmpMap({List<SlmpMapEntry>? entries}) : entries = entries ?? [];

  /// Tolerant of a missing or non-list `entries` key so an older project JSON
  /// with no `slmp` section loads cleanly (additive persistence).
  factory SlmpMap.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return SlmpMap(
      entries: (rawEntries is List)
          ? rawEntries
              .whereType<Map>()
              .map((e) => SlmpMapEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <SlmpMapEntry>[],
    );
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// Width in WORDS a scalar data type occupies in an SLMP device image, or
  /// `null` if the type has no v1 SLMP representation (`STRING`, and anything
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
        return 4;
      default:
        return null;
    }
  }

  /// Builds a default map from a project's scalar leaf tags ([scalarLeaves]):
  /// composite/array tags are expanded into one entry per scalar leaf. Every
  /// entry is packed into the `D` device sequentially by WORD, in leaf order.
  ///
  /// `BOOL` leaves are bit-packed: consecutive BOOLs share a word, filling
  /// bits 0..15 before advancing. The first non-BOOL leaf after a BOOL closes
  /// the partially used word and advances to the next whole word.
  ///
  /// `STRING` leaves are SKIPPED entirely (see the file header), as is any
  /// other type with no [widthWordsForType].
  ///
  /// Access is inherited from the ROOT tag via [defaultsExternallyWritable],
  /// exactly as the FINS/S7/Modbus/CIP maps do: a `SimulatedOutput` tag, an
  /// explicit tag `access` of `'ReadOnly'`, or the reserved `System` tag
  /// (checked by NAME) yields `'ReadOnly'`; everything else yields
  /// `'ReadWrite'`.
  static SlmpMap autoGenerate(PlcProject p) {
    final entries = <SlmpMapEntry>[];
    var nextWord = 0;
    var nextBit = 0;
    for (final leaf in scalarLeaves(p)) {
      final width = widthWordsForType(leaf.dataType);
      if (width == null) {
        continue;
      }
      final rw = defaultsExternallyWritable(p, leaf.path);
      final access = rw ? 'ReadWrite' : 'ReadOnly';

      int address;
      int bitOffset;
      if (leaf.dataType == 'BOOL') {
        address = nextWord;
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
        address = nextWord;
        bitOffset = 0;
        nextWord += width;
      }

      entries.add(SlmpMapEntry(
        tag: leaf.path,
        device: kSlmpDeviceNameD,
        address: address,
        bitOffset: bitOffset,
        access: access,
      ));
    }
    return SlmpMap(entries: entries);
  }
}
