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
// each) to write.
//
// *** DEVICE CODES (v1 — word devices only) ***
// D = 0xA8, M = 0x90, W = 0xB4, R = 0xAF. These byte values are per this
// task's brief and are confirmed against `pymcprotocol`'s `DeviceConstants`
// at a later task, which is the authority.
//
// *** BIT-AREA DEVICES (deliberately NOT built here) ***
// A `BOOL` tag mapped to a single bit would need the bit subcommand
// ([kSlmpSubcmdBit] = 0x0001) and per-bit addressing distinct from the word
// devices above. The exact bit-level encoding is intentionally NOT invented
// in this file — see the note above the subcommand constants below. Pin it
// against the real `pymcprotocol` client in a later task (the tag-map/
// device-image layer), which is the authority; this file only defines the
// word device codes and the word/bit subcommand selector now.
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
/// bits rather than words. NOTE: this constant selects the subcommand value
/// only; the bit-level device addressing/packing itself is deliberately NOT
/// implemented in this file (see the BIT-AREA DEVICES note above) — that is
/// left to a later task against the real `pymcprotocol` client.
const int kSlmpSubcmdBit = 0x0001;

// --- Device codes (v1 — word devices only) --------------------------------

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
