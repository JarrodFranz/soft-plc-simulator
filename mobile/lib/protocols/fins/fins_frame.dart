// Omron FINS command/response frame codec — pure Dart, no dart:io / Flutter
// imports. This is the bottom layer of the FINS stack: the 10-byte header
// plus the command/response envelope that rides directly inside a UDP
// datagram (the UDP host is a later task and is not referenced here).
// Implemented from public FINS specification material.
//
// *** ENDIANNESS WARNING ***
// FINS multi-byte fields are BIG-ENDIAN. The most recently added protocol in
// this repo (EtherNet/IP, protocols/enip/) is little-endian, and Modbus
// mixes conventions elsewhere in this codebase — do not pattern-match either
// one into this file. Every multi-byte field here (`commandCode`, `endCode`)
// is read/written with `Endian.big`.
//
// *** WIRE LAYOUT (all BIG-ENDIAN) ***
// 10-byte header: `ICF`(0), `RSV`(1, 0x00), `GCT`(2, gateway count 0x02),
// `DNA`(3, dest network), `DA1`(4, dest node), `DA2`(5, dest unit),
// `SNA`(6, src network), `SA1`(7, src node), `SA2`(8, src unit),
// `SID`(9, service id) — then `commandCode` u16, then `text` (the remainder
// of the buffer for a command; `endCode` u16 + `data` for a response).
//
// `ICF`: bit 6 (mask 0x40) distinguishes a command (0) from a response (1);
// bit 0 (mask 0x01) is the response-required flag, set by the requester and
// left AS-IS by this codec's response builder (this device does not
// interpret or clear it — it only sets the response bit).
//
// *** THE RESPONSE HEADER IS NOT THE REQUEST HEADER COPIED VERBATIM ***
// [buildFinsResponse] swaps DNA/DA1/DA2 (destination) with SNA/SA1/SA2
// (source), because the reply travels back to the node that sent the
// request — what was the destination becomes the source of the reply, and
// vice versa. `SID` is echoed UNCHANGED (the client correlates its reply by
// SID, not by node address). Getting the swap backwards sends every reply to
// the wrong node address; a real client would never see it.
//
// Node addressing (DNA/DA1/DA2/SNA/SA1/SA2) is accepted PERMISSIVELY: this
// codec never validates it against any notion of "this device's own
// address" — it only ever echoes it back, swapped. This is a simulator; a
// rejected node/unit mismatch would be a confusing failure with no
// diagnostic value (the same call this codebase's S7 host makes for
// rack/slot).
//
// Safety contract: [parseFinsCommand] returns `null` — and never throws —
// on malformed, truncated, or otherwise hostile input, since the UDP host (a
// later task) feeds this function arbitrary datagram bytes read straight off
// the wire.
library fins_frame;

import 'dart:typed_data';

// --- Header layout -----------------------------------------------------------

/// Length, in bytes, of the fixed FINS header: `ICF`(1) + `RSV`(1) +
/// `GCT`(1) + `DNA`(1) + `DA1`(1) + `DA2`(1) + `SNA`(1) + `SA1`(1) +
/// `SA2`(1) + `SID`(1) = 10.
const int kFinsHeaderLen = 10;

/// Fixed `RSV` (reserved) byte value emitted by this codec's response
/// builder, per the FINS wire format.
const int kFinsRsv = 0x00;

/// Fixed `GCT` (gateway count) byte value emitted by this codec's response
/// builder, per the FINS wire format.
const int kFinsGct = 0x02;

/// `ICF` bit mask distinguishing a command (bit clear) from a response (bit
/// set). [buildFinsResponse] always sets this bit on the header it emits.
const int kFinsIcfResponseBit = 0x40;

/// `ICF` bit mask for the response-required flag, set by the requester. This
/// codec never interprets or clears this bit — it is carried through as-is
/// by [buildFinsResponse].
const int kFinsIcfResponseRequiredBit = 0x01;

// --- End codes (consumers in later tasks use these) --------------------------

/// Normal completion — no error.
const int kFinsEndNormal = 0x0000;

/// The requested memory area does not exist / is not supported.
const int kFinsEndNoArea = 0x1101;

/// The requested address (or address range) is out of bounds.
const int kFinsEndAddressRange = 0x1103;

/// The requested item is not writable (used later for a refused write).
const int kFinsEndNotWritable = 0x2101;

// --- Header + frame ------------------------------------------------------------

/// A decoded (or to-be-built) 10-byte FINS header. All fields are single
/// bytes (0-255) on the wire; multi-byte fields live outside the header
/// (see [FinsFrame.commandCode] and the `endCode`/`data` of a response).
class FinsHeader {
  final int icf;
  final int rsv;
  final int gct;
  final int dna;
  final int da1;
  final int da2;
  final int sna;
  final int sa1;
  final int sa2;
  final int sid;

  FinsHeader({
    required this.icf,
    required this.rsv,
    required this.gct,
    required this.dna,
    required this.da1,
    required this.da2,
    required this.sna,
    required this.sa1,
    required this.sa2,
    required this.sid,
  });

  /// True when [icf]'s response bit ([kFinsIcfResponseBit]) is set — i.e.
  /// this header describes a response rather than a command.
  bool get isResponse => (icf & kFinsIcfResponseBit) != 0;

  /// True when [icf]'s response-required bit ([kFinsIcfResponseRequiredBit])
  /// is set.
  bool get responseRequired => (icf & kFinsIcfResponseRequiredBit) != 0;
}

/// A decoded FINS command: the 10-byte [header], the BIG-ENDIAN
/// `commandCode` u16 that follows it, and the remaining [text] bytes (the
/// command's parameters/data, whatever they are — this layer does not
/// interpret them; that is a later task's job).
class FinsFrame {
  final FinsHeader header;
  final int commandCode;
  final Uint8List text;

  FinsFrame({required this.header, required this.commandCode, required this.text});
}

/// Parses a FINS command from [buffer]: the 10-byte header, then a
/// BIG-ENDIAN `commandCode` u16, then the remainder of [buffer] as [text].
///
/// Returns `null` — and NEVER throws — if [buffer] is shorter than
/// `kFinsHeaderLen + 2` (10-byte header + 2-byte command code), since the
/// UDP host feeds this function arbitrary datagram bytes off the wire and
/// must not crash on malformed or truncated input.
FinsFrame? parseFinsCommand(Uint8List buffer) {
  if (buffer.length < kFinsHeaderLen + 2) {
    return null;
  }

  final header = FinsHeader(
    icf: buffer[0],
    rsv: buffer[1],
    gct: buffer[2],
    dna: buffer[3],
    da1: buffer[4],
    da2: buffer[5],
    sna: buffer[6],
    sa1: buffer[7],
    sa2: buffer[8],
    sid: buffer[9],
  );
  final commandCode = ByteData.sublistView(buffer, kFinsHeaderLen, kFinsHeaderLen + 2).getUint16(0, Endian.big);
  final text = Uint8List.fromList(buffer.sublist(kFinsHeaderLen + 2));

  return FinsFrame(header: header, commandCode: commandCode, text: text);
}

/// Builds a complete FINS response datagram from [requestHeader]: a 10-byte
/// header with DNA/DA1/DA2 (destination) and SNA/SA1/SA2 (source) SWAPPED
/// from [requestHeader] — the reply travels back to the node that sent the
/// request, so what was the destination becomes the source of the reply,
/// and vice versa — `SID` echoed UNCHANGED, `RSV`/`GCT` set to the fixed
/// wire values ([kFinsRsv]/[kFinsGct]), and the response bit
/// ([kFinsIcfResponseBit]) set in `ICF` (every other `ICF` bit, including
/// the response-required flag, is carried through from [requestHeader]
/// as-is). Node addressing is accepted PERMISSIVELY and never validated —
/// this codec only ever echoes it back, swapped.
///
/// After the header: BIG-ENDIAN `commandCode` u16, then BIG-ENDIAN
/// [endCode] u16, then [data] (empty by default).
Uint8List buildFinsResponse({
  required FinsHeader requestHeader,
  required int commandCode,
  required int endCode,
  Uint8List? data,
}) {
  final effectiveData = data ?? Uint8List(0);
  final out = Uint8List(kFinsHeaderLen + 2 + 2 + effectiveData.length);

  out[0] = (requestHeader.icf | kFinsIcfResponseBit) & 0xFF;
  out[1] = kFinsRsv;
  out[2] = kFinsGct;
  out[3] = requestHeader.sna & 0xFF; // DNA <- request's SNA
  out[4] = requestHeader.sa1 & 0xFF; // DA1 <- request's SA1
  out[5] = requestHeader.sa2 & 0xFF; // DA2 <- request's SA2
  out[6] = requestHeader.dna & 0xFF; // SNA <- request's DNA
  out[7] = requestHeader.da1 & 0xFF; // SA1 <- request's DA1
  out[8] = requestHeader.da2 & 0xFF; // SA2 <- request's DA2
  out[9] = requestHeader.sid & 0xFF; // SID echoed unchanged

  ByteData.sublistView(out, kFinsHeaderLen, kFinsHeaderLen + 2).setUint16(0, commandCode & 0xFFFF, Endian.big);
  ByteData.sublistView(out, kFinsHeaderLen + 2, kFinsHeaderLen + 4).setUint16(0, endCode & 0xFFFF, Endian.big);
  out.setRange(kFinsHeaderLen + 4, kFinsHeaderLen + 4 + effectiveData.length, effectiveData);

  return out;
}
