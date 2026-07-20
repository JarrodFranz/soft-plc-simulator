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
// *** AREA CODES (v1 — word areas only) ***
// DM = 0x82, CIO = 0xB0, WR = 0xB1, HR = 0xB2. These are the word-area codes
// a driver polling word data sends. A `BOOL` tag mapped to a single bit would
// need a bit-area variant (e.g. a CIO "bit" area code distinct from the CIO
// word area code above) — the exact value is intentionally NOT invented
// here (see the note above the area-code constants below). Pin it against
// the real `fins` Python client in a later task, which is the authority.
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

// --- Word-area codes (v1) -----------------------------------------------------

/// DM (Data Memory) word area code.
const int kFinsAreaDM = 0x82;

/// CIO (Core I/O) word area code.
const int kFinsAreaCIO = 0xB0;

/// WR (Work) word area code.
const int kFinsAreaWR = 0xB1;

/// HR (Holding) word area code.
const int kFinsAreaHR = 0xB2;

// NOTE (intentional placeholder — no constant here): bit-area codes (e.g. a
// CIO "bit" area distinct from [kFinsAreaCIO]) are deliberately NOT defined
// yet. A `BOOL` tag mapped to a single bit would need one, but this task's
// brief leaves the exact code open pending confirmation against the real
// `fins` Python client (a later task's E2E is the authority) — inventing a
// value now under this project's YAGNI discipline would risk silently
// committing to the wrong wire byte. Add the bit-area constant(s) here, with
// the same doc-comment style as the word-area codes above, once that
// confirmation lands (Task 4/5) — do not build the tag-map/area-image logic
// itself in this file.

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

/// Builds a Memory Area Read response's data payload: simply the requested
/// [words], BIG-ENDIAN, verbatim. This function performs no interpretation
/// or padding — the caller (a later task's tag/area-image layer) is
/// responsible for supplying exactly the bytes that belong on the wire.
Uint8List buildMemReadResponseData(Uint8List words) {
  return Uint8List.fromList(words);
}
