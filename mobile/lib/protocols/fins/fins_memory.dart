// Omron FINS Memory Area Read/Write item codec — pure Dart, no dart:io /
// Flutter imports. This layer parses/builds the `text` payload carried
// inside a FinsFrame (see fins_frame.dart) for the Memory Area Read (0x0101)
// and Memory Area Write (0x0102) commands; it does not touch the 10-byte
// header or the command dispatch itself — that is fins_frame.dart's job.
// Implemented from public FINS specification material.
//
// *** ENDIANNESS WARNING ***
// FINS multi-byte fields are BIG-ENDIAN. The most recently added protocol in
// this repo (EtherNet/IP, protocols/enip/) is little-endian — do not
// pattern-match it into this file. Every multi-byte field here (`word
// address`, `number of items`, and the read/write word data) is read/written
// with `Endian.big`.
//
// *** WIRE LAYOUT (all BIG-ENDIAN) ***
// Item spec (6 bytes): `area code` u8(0), `word address` u16(1-2), `bit`
// u8(3), `number of items` u16(4-5). A Memory Area Read command's `text` is
// exactly this 6-byte item spec. A Memory Area Write command's `text` is the
// same 6-byte item spec followed by `number of items` big-endian words (2
// bytes each) to write.
//
// *** AREA CODES ***
// WORD areas: DM = 0x82, CIO = 0xB0, WR = 0xB1, HR = 0xB2 — what a driver
// polling word data sends; each item is one 16-bit word (2 bytes on the wire).
// BIT areas: DM = 0x02, CIO = 0x30, WR = 0x31, HR = 0x32 — the same memory
// addressed one BIT at a time; each item is ONE byte on the wire (0x00/0x01),
// and the item spec's `bit` field (0..15) picks the starting bit within the
// starting word. These bit-area codes were deliberately deferred in v1 and
// pinned by a real client: Ignition's Omron FINS driver writes a Boolean as a
// 19-byte Memory Area Write (6-byte item spec + ONE data byte) with the DM
// BIT area code — the word-only build dropped it as "not a served FINS
// command" (2026-07-21 in-app log).
//
// Safety contract: the parse functions in this file return `null` — and
// never throw — on malformed, truncated, or otherwise hostile input, since
// the UDP host (a later task) feeds them arbitrary datagram bytes read
// straight off the wire.
library fins_memory;

import 'dart:typed_data';

// --- Command codes -----------------------------------------------------------

/// Memory Area Read command code.
const int kFinsCmdMemAreaRead = 0x0101;

/// Memory Area Write command code.
const int kFinsCmdMemAreaWrite = 0x0102;

// --- Word-area codes ----------------------------------------------------------

/// DM (Data Memory) word area code.
const int kFinsAreaDM = 0x82;

/// CIO (Core I/O) word area code.
const int kFinsAreaCIO = 0xB0;

/// WR (Work) word area code.
const int kFinsAreaWR = 0xB1;

/// HR (Holding) word area code.
const int kFinsAreaHR = 0xB2;

// --- Bit-area codes -----------------------------------------------------------
// The same memory addressed one BIT at a time (1 byte per item on the wire).
// Deferred in v1 per the YAGNI note that used to sit here; pinned 2026-07-21
// by a real client — Ignition's Omron FINS driver writes Booleans this way
// (see the AREA CODES section of the file header).

/// DM (Data Memory) BIT area code.
const int kFinsAreaDMBit = 0x02;

/// CIO (Core I/O) BIT area code.
const int kFinsAreaCIOBit = 0x30;

/// WR (Work) BIT area code.
const int kFinsAreaWRBit = 0x31;

/// HR (Holding) BIT area code.
const int kFinsAreaHRBit = 0x32;

/// True when [areaCode] is one of the BIT area codes above — the item spec
/// then addresses bits (ONE byte each on the wire, 0x00/0x01), not words.
bool isFinsBitArea(int areaCode) =>
    areaCode == kFinsAreaDMBit ||
    areaCode == kFinsAreaCIOBit ||
    areaCode == kFinsAreaWRBit ||
    areaCode == kFinsAreaHRBit;

/// Maps a BIT area code to the WORD area code of the same memory (e.g.
/// [kFinsAreaDMBit] -> [kFinsAreaDM]), or `null` for a non-bit-area code. A
/// `null` result must become a per-request error end code, never an exception.
int? finsWordAreaForBitArea(int areaCode) {
  switch (areaCode) {
    case kFinsAreaDMBit:
      return kFinsAreaDM;
    case kFinsAreaCIOBit:
      return kFinsAreaCIO;
    case kFinsAreaWRBit:
      return kFinsAreaWR;
    case kFinsAreaHRBit:
      return kFinsAreaHR;
    default:
      return null;
  }
}

// --- Item spec length ----------------------------------------------------------

/// Length, in bytes, of the fixed Memory Area item spec: `area code`(1) +
/// `word address`(2) + `bit`(1) + `number of items`(2) = 6.
const int kFinsMemItemLen = 6;

// --- Memory item ---------------------------------------------------------------

/// A decoded (or to-be-built) Memory Area item spec: which [areaCode], which
/// [wordAddress] (and, for a bit-level access, which [bitOffset] within that
/// word), and how many [count] items (words) are requested.
class FinsMemItem {
  final int areaCode;
  final int wordAddress;
  final int bitOffset;
  final int count;

  FinsMemItem({
    required this.areaCode,
    required this.wordAddress,
    required this.bitOffset,
    required this.count,
  });
}

/// Parses a Memory Area Read command's [text] as a 6-byte item spec:
/// `area code` u8, BIG-ENDIAN `word address` u16, `bit` u8, BIG-ENDIAN
/// `number of items` u16.
///
/// Returns `null` — and NEVER throws — if [text] is shorter than
/// [kFinsMemItemLen] bytes, since the UDP host feeds this function arbitrary
/// datagram bytes off the wire and must not crash on malformed or truncated
/// input. Trailing bytes beyond the 6-byte item spec are ignored.
FinsMemItem? parseMemAreaReadItem(Uint8List text) {
  if (text.length < kFinsMemItemLen) {
    return null;
  }

  final areaCode = text[0];
  final wordAddress = ByteData.sublistView(text, 1, 3).getUint16(0, Endian.big);
  final bitOffset = text[3];
  final count = ByteData.sublistView(text, 4, 6).getUint16(0, Endian.big);

  return FinsMemItem(areaCode: areaCode, wordAddress: wordAddress, bitOffset: bitOffset, count: count);
}

/// Parses a Memory Area Write command's [text] as the 6-byte item spec
/// (identical layout to [parseMemAreaReadItem]) followed by the write words
/// themselves: `count` BIG-ENDIAN u16 words (2 bytes each).
///
/// Returns a record of the decoded [FinsMemItem] plus the raw `writeData`
/// bytes (the write words, verbatim, still BIG-ENDIAN — this layer does not
/// interpret them as tag values). Returns `null` — and NEVER throws — if
/// [text] is shorter than [kFinsMemItemLen], or if the declared `count`
/// (words) does not match the number of trailing bytes actually present
/// (`count * 2` bytes).
({FinsMemItem item, Uint8List writeData})? parseMemAreaWriteItem(Uint8List text) {
  final item = parseMemAreaReadItem(text);
  if (item == null) {
    return null;
  }

  final expectedWriteBytes = item.count * 2;
  final actualWriteBytes = text.length - kFinsMemItemLen;
  if (actualWriteBytes != expectedWriteBytes) {
    return null;
  }

  final writeData = Uint8List.fromList(text.sublist(kFinsMemItemLen, kFinsMemItemLen + expectedWriteBytes));
  return (item: item, writeData: writeData);
}

/// Parses a BIT-area Memory Area Write command's [text]: the 6-byte item spec
/// (identical layout to [parseMemAreaReadItem]) followed by `count` bit-value
/// bytes — ONE byte per bit (0x00 = clear, anything else = set), unlike the
/// word-area write's 2 bytes per item.
///
/// Returns `null` — and NEVER throws — if [text] is shorter than
/// [kFinsMemItemLen], or if the declared `count` (bits) does not match the
/// number of trailing bytes actually present (`count` bytes).
({FinsMemItem item, Uint8List writeData})? parseMemAreaWriteBitItem(Uint8List text) {
  final item = parseMemAreaReadItem(text);
  if (item == null) {
    return null;
  }

  final actualWriteBytes = text.length - kFinsMemItemLen;
  if (actualWriteBytes != item.count) {
    return null;
  }

  final writeData = Uint8List.fromList(text.sublist(kFinsMemItemLen));
  return (item: item, writeData: writeData);
}

/// Builds a Memory Area Read response's data payload: simply the requested
/// [words], BIG-ENDIAN, verbatim. This function performs no interpretation
/// or padding — the caller (a later task's tag/area-image layer) is
/// responsible for supplying exactly the bytes that belong on the wire.
Uint8List buildMemReadResponseData(Uint8List words) {
  return Uint8List.fromList(words);
}
