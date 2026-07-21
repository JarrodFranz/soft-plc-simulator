// Mitsubishi SLMP (MELSEC Communication) 3E Batch Read/Write command codec —
// pure Dart, no dart:io / Flutter imports. This layer parses/builds the
// command-data payload carried inside an SlmpFrame.data (see slmp_frame.dart)
// for the Batch Read (0x0401) and Batch Write (0x1401) word commands; it does
// not touch the fixed routing header or the command/subcommand envelope
// itself — that is slmp_frame.dart's job. Implemented from public SLMP
// specification material.
//
// *** ENDIANNESS WARNING ***
// SLMP 3E binary is LITTLE-ENDIAN throughout, including the 3-byte device
// number. The two area protocols built immediately before this one in this
// repo — S7comm (protocols/s7/) and Omron FINS (protocols/fins/) — are both
// BIG-ENDIAN. Do NOT copy an `Endian.big` from either of those neighbouring
// files into this one. Every multi-byte field here (device number, point
// count, and the read/write word data) is read/written with `Endian.little`.
//
// A pure build -> parse round trip CANNOT catch an endianness bug — it
// cancels out perfectly even when the implementation is fully broken. Tests
// for this file assert literal expected bytes against hand-built buffers,
// not only round-trips.
//
// *** WIRE LAYOUT (all LITTLE-ENDIAN) ***
// Device spec (6 bytes): `device number` u24 LE (3 bytes, 0-2), `device
// code` u8 (3), `point count` u16 LE (4-5). A Batch Read command's data is
// exactly this 6-byte device spec. A Batch Write command's data is the same
// 6-byte device spec followed by `point count` little-endian words (2 bytes
// each) to write — or, under the BIT subcommand, `ceil(point count / 2)`
// NIBBLE-packed bytes (two points per byte, first point in the high nibble).
//
// *** DEVICE CODES ***
// D = 0xA8, M = 0x90, W = 0xB4, R = 0xAF. These byte values are per the
// original task brief and are confirmed against `pymcprotocol`'s
// `DeviceConstants`, which is the authority.
//
// *** BIT-UNIT ACCESS (kSlmpSubcmdBit) ***
// Deferred in v1 with the encoding deliberately left open; pinned 2026-07-21
// by a real client — Ignition's Mitsubishi driver polls bit devices (`M0`)
// with subcommand 0x0001, and the word-only dispatch dropped every poll
// (5s timeouts). The 3E BINARY encoding is nibble packing (see the
// [kSlmpSubcmdBit] doc comment and [packSlmpBitUnits]); the point count
// counts BITS and the device number counts device POINTS (M5 = number 5 =
// word 0, bit 5 of the word-addressed map).
//
// Safety contract: the parse functions in this file return `null` — and
// never throw — on malformed, truncated, or otherwise hostile input, since
// the TCP host (a later task) feeds them arbitrary command-data bytes read
// straight off the wire.
library slmp_commands;

import 'dart:typed_data';

// --- Command codes -----------------------------------------------------------

/// Batch Read (word units) command code.
const int kSlmpCmdBatchReadWord = 0x0401;

/// Batch Write (word units) command code.
const int kSlmpCmdBatchWriteWord = 0x1401;

// --- Subcommands ---------------------------------------------------------------

/// Word-units subcommand — the device spec's `point count` counts whole
/// 16-bit words.
const int kSlmpSubcmdWord = 0x0000;

/// Bit-units subcommand — the device spec's `point count` counts individual
/// bits (device points) rather than words. In 3E BINARY, bit-unit data is
/// NIBBLE-packed: TWO points per byte, the FIRST point in the HIGH nibble
/// (`0x10` = first ON / second OFF), an odd final point leaving the low
/// nibble `0`. Deferred in v1; pinned 2026-07-21 by a real client —
/// Ignition's Mitsubishi driver polls a bit device (e.g. `M0`) with this
/// subcommand, which the word-only dispatch dropped (5s poll timeouts).
/// See [packSlmpBitUnits] / [unpackSlmpBitUnits] /
/// [parseBatchWriteBitRequest] below.
const int kSlmpSubcmdBit = 0x0001;

// --- Device codes -----------------------------------------------------------

/// D (Data register) device code.
const int kSlmpDevD = 0xA8;

/// M (Internal relay) device code.
const int kSlmpDevM = 0x90;

/// W (Link register) device code.
const int kSlmpDevW = 0xB4;

/// R (File register) device code.
const int kSlmpDevR = 0xAF;

// --- Device spec length ---------------------------------------------------------

/// Length, in bytes, of the fixed device spec: `device number`(3, LE) +
/// `device code`(1) + `point count`(2, LE) = 6.
const int kSlmpDeviceSpecLen = 6;

// --- Device spec -----------------------------------------------------------------

/// A decoded (or to-be-built) SLMP device spec: which [deviceCode], which
/// [deviceNumber] (the device's starting address), and how many [pointCount]
/// points (words, or bits under the bit subcommand — see [kSlmpSubcmdBit])
/// are requested.
class SlmpDeviceSpec {
  final int deviceCode;
  final int deviceNumber;
  final int pointCount;

  SlmpDeviceSpec({
    required this.deviceCode,
    required this.deviceNumber,
    required this.pointCount,
  });
}

/// Parses a Batch Read command's [commandData] as a 6-byte device spec:
/// LITTLE-ENDIAN `device number` u24 (3 bytes), `device code` u8, then
/// LITTLE-ENDIAN `point count` u16.
///
/// Returns `null` — and NEVER throws — if [commandData] is shorter than
/// [kSlmpDeviceSpecLen] bytes, since the TCP host feeds this function
/// arbitrary command-data bytes off the wire and must not crash on malformed
/// or truncated input. Trailing bytes beyond the 6-byte device spec are
/// ignored.
SlmpDeviceSpec? parseBatchReadRequest(Uint8List commandData) {
  if (commandData.length < kSlmpDeviceSpecLen) {
    return null;
  }

  final deviceNumber = commandData[0] | (commandData[1] << 8) | (commandData[2] << 16);
  final deviceCode = commandData[3];
  final pointCount = ByteData.sublistView(commandData, 4, 6).getUint16(0, Endian.little);

  return SlmpDeviceSpec(deviceCode: deviceCode, deviceNumber: deviceNumber, pointCount: pointCount);
}

/// Parses a Batch Write command's [commandData] as the 6-byte device spec
/// (identical layout to [parseBatchReadRequest]) followed by the write words
/// themselves: `pointCount` LITTLE-ENDIAN u16 words (2 bytes each).
///
/// Returns a record of the decoded [SlmpDeviceSpec] plus the raw `writeData`
/// bytes (the write words, verbatim, still LITTLE-ENDIAN — this layer does
/// not interpret them as tag values). Returns `null` — and NEVER throws —
/// if [commandData] is shorter than [kSlmpDeviceSpecLen], or if the declared
/// `pointCount` (words) does not match the number of trailing bytes actually
/// present (`pointCount * 2` bytes). This bounds check happens BEFORE any
/// slice of the trailing write data, so a declared point count that would
/// read past the end of [commandData] returns `null` rather than throwing a
/// range error — the TCP host feeds this arbitrary, potentially hostile
/// command bytes.
({SlmpDeviceSpec spec, Uint8List writeData})? parseBatchWriteRequest(Uint8List commandData) {
  final spec = parseBatchReadRequest(commandData);
  if (spec == null) {
    return null;
  }

  final expectedWriteBytes = spec.pointCount * 2;
  final actualWriteBytes = commandData.length - kSlmpDeviceSpecLen;
  if (actualWriteBytes != expectedWriteBytes) {
    return null;
  }

  final writeData = Uint8List.fromList(
    commandData.sublist(kSlmpDeviceSpecLen, kSlmpDeviceSpecLen + expectedWriteBytes),
  );
  return (spec: spec, writeData: writeData);
}

/// Builds a Batch Read response's data payload: simply the requested
/// [words], LITTLE-ENDIAN, verbatim. This function performs no
/// interpretation or padding — the caller (a later task's tag/device-image
/// layer) is responsible for supplying exactly the bytes that belong on the
/// wire. The response's end code (see slmp_frame.dart's [buildSlmpResponse])
/// is prepended by the frame layer, not here.
Uint8List buildBatchReadResponseData(Uint8List words) {
  return Uint8List.fromList(words);
}

// --- Bit-unit nibble packing (3E binary) -------------------------------------

/// Packs per-point bit values [bits] (ONE byte per point, `0x00` = OFF /
/// anything else = ON) into the 3E BINARY bit-unit wire layout: TWO points
/// per byte, the FIRST point in the HIGH nibble, an odd final point leaving
/// the trailing low nibble `0`. `ceil(points / 2)` bytes out.
Uint8List packSlmpBitUnits(Uint8List bits) {
  final out = Uint8List((bits.length + 1) >> 1);
  for (var i = 0; i < bits.length; i++) {
    if (bits[i] != 0x00) {
      out[i >> 1] |= i.isEven ? 0x10 : 0x01;
    }
  }
  return out;
}

/// Unpacks [pointCount] per-point bit values (ONE byte per point, `0x00` /
/// `0x01`) from the 3E BINARY nibble-packed [data] (see [packSlmpBitUnits]).
///
/// Returns `null` — and NEVER throws — when [pointCount] is negative or
/// [data] is not exactly `ceil(pointCount / 2)` bytes, since the TCP host
/// ultimately feeds this arbitrary command bytes off the wire.
Uint8List? unpackSlmpBitUnits(Uint8List data, int pointCount) {
  if (pointCount < 0 || data.length != (pointCount + 1) >> 1) {
    return null;
  }
  final out = Uint8List(pointCount);
  for (var i = 0; i < pointCount; i++) {
    final nibble = i.isEven ? data[i >> 1] >> 4 : data[i >> 1] & 0x0F;
    out[i] = nibble != 0 ? 0x01 : 0x00;
  }
  return out;
}

/// Parses a BIT-units Batch Write command's [commandData]: the 6-byte device
/// spec (identical layout to [parseBatchReadRequest], `pointCount` counting
/// BITS) followed by `ceil(pointCount / 2)` nibble-packed data bytes (see
/// [packSlmpBitUnits]) — unlike the word-unit write's `pointCount * 2` bytes.
///
/// Returns the decoded [SlmpDeviceSpec] plus the UNPACKED per-point
/// `bitValues` (ONE byte per point, `0x00`/`0x01`). Returns `null` — and
/// NEVER throws — if [commandData] is shorter than [kSlmpDeviceSpecLen] or
/// the trailing data is not exactly the expected packed length.
({SlmpDeviceSpec spec, Uint8List bitValues})? parseBatchWriteBitRequest(Uint8List commandData) {
  final spec = parseBatchReadRequest(commandData);
  if (spec == null) {
    return null;
  }
  final packed = Uint8List.fromList(commandData.sublist(kSlmpDeviceSpecLen));
  final bitValues = unpackSlmpBitUnits(packed, spec.pointCount);
  if (bitValues == null) {
    return null;
  }
  return (spec: spec, bitValues: bitValues);
}
