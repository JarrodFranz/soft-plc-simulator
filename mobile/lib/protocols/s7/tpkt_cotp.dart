// TPKT (RFC 1006) + COTP (ISO 8073, class 0) framing codec — pure Dart, no
// dart:io / Flutter imports. This is the bottom transport layer for S7comm
// on TCP 102: every S7 PDU (built in a later layer) is carried as the
// payload of a COTP DT (data) TPDU, which is in turn carried as the payload
// of a TPKT frame. Implemented from public RFC 1006 / ISO 8073 material.
//
// *** ENDIANNESS WARNING ***
// S7comm/TPKT/COTP are BIG-ENDIAN throughout. The EtherNet/IP codec next
// door (protocols/enip/enip_encap.dart) is little-endian everywhere — do
// not pattern-match its `Endian.little` calls into this file. Every
// multi-byte field here is read/written with `Endian.big`.
//
// *** TPKT LENGTH IS THE WHOLE PACKET, NOT JUST THE PAYLOAD ***
// The TPKT `length` field counts the entire packet INCLUDING the 4-byte
// TPKT header itself (`total = kTpktHeaderLen + payload.length`). This is
// the exact inverse of EtherNet/IP's encapsulation `length`, which excludes
// its own header. Getting this backwards shifts every frame boundary that a
// socket host derives from it.
//
// Wire reference:
//  - TPKT header (4 bytes): `version` u8 (0x03), `reserved` u8 (0x00),
//    `length` u16 BIG-ENDIAN (whole packet, header included).
//  - COTP header: byte 0 is the length indicator (LI) — the number of
//    header bytes that follow, EXCLUDING the LI byte itself. Byte 1 (the
//    first byte counted by LI) is the PDU type.
//     - CR (0xE0) / CC (0xD0): `dstRef` u16, `srcRef` u16, `class/option`
//       u8, then a variable-length parameter list, each entry
//       `code u8, len u8, value (len bytes)`. Known parameter codes:
//       0xC1 = source TSAP, 0xC2 = destination TSAP, 0xC0 = TPDU size.
//       Parameters may appear in any order on the wire — this codec parses
//       them by code, never by position.
//     - DT (0xF0): LI 0x02, then a single TPDU-number/EOT byte (0x80 means
//       "last data unit"), then the carried user data.
//  - v1 policy: the destination TSAP encodes rack/slot, but this is a
//    simulator — rack/slot are never validated here. `buildCotpConnectConfirm`
//    simply echoes back whatever TSAPs the caller supplies (normally the
//    client's own CR TSAPs, verbatim).
//
// Safety contract: every `parse*` function here returns `null` — and never
// throws — on malformed, truncated, or otherwise hostile input, since the
// socket host (a later task) feeds these functions arbitrary bytes read
// straight off the wire.
library tpkt_cotp;

import 'dart:typed_data';

/// Total size, in bytes, of the TPKT header. Every TPKT frame is at least
/// this long, and the header itself is included in the frame's own
/// `length` field.
const int kTpktHeaderLen = 4;

/// TPKT protocol version byte (RFC 1006 defines only version 3).
const int kTpktVersion = 0x03;

// --- COTP PDU type bytes (ISO 8073) -----------------------------------------

/// Connection Request.
const int kCotpCr = 0xE0;

/// Connection Confirm.
const int kCotpCc = 0xD0;

/// Data (the only TPDU type that carries a user-data payload in class 0).
const int kCotpDt = 0xF0;

// --- COTP variable-parameter codes (used inside CR/CC) ----------------------

/// Source TSAP parameter code.
const int kCotpParamSrcTsap = 0xC1;

/// Destination TSAP parameter code.
const int kCotpParamDstTsap = 0xC2;

/// TPDU size parameter code. Emitted by [buildCotpConnectConfirm] with value
/// [kCotpTpduSizeCode1024] — parsing this parameter's value is not currently
/// exposed by this codec (only the CR/CC's TSAPs are, via [parseCotp]).
const int kCotpParamTpduSize = 0xC0;

/// TPDU-size code value meaning "1024 octets" (ISO 8073 encodes TPDU size as
/// log2(octets), so 1024 = 2^10 -> code 10 = 0x0A). Emitted in the CC so a
/// strict client never falls back to the un-negotiated 128-octet class-0
/// default, which would be too small for a negotiated 480-byte S7 PDU
/// (Task 4's Read/Write Var replies).
const int kCotpTpduSizeCode1024 = 0x0A;

// --- TPKT --------------------------------------------------------------------

/// A decoded TPKT header. `length` is the BIG-ENDIAN on-wire value, and it
/// counts the WHOLE packet — the 4-byte TPKT header plus whatever payload
/// follows it — not just the payload.
class TpktHeader {
  final int version;
  final int length;

  TpktHeader({required this.version, required this.length});
}

/// Parses the 4-byte TPKT header from the front of [frame]. `length` is
/// read BIG-ENDIAN and represents the total packet size (header included).
/// Returns `null` (never throws) if [frame] is shorter than
/// [kTpktHeaderLen]; the version byte is exposed but not validated here (a
/// permissive simulator posture — callers that care may check it).
TpktHeader? parseTpkt(Uint8List frame) {
  if (frame.length < kTpktHeaderLen) {
    return null;
  }
  final version = frame[0];
  final length = ByteData.sublistView(frame, 2, 4).getUint16(0, Endian.big);
  return TpktHeader(version: version, length: length);
}

/// Builds a full TPKT frame (4-byte header + [payload]) from [payload].
/// The emitted `length` field is BIG-ENDIAN and equals
/// `kTpktHeaderLen + payload.length` — the TOTAL packet size, including
/// this function's own 4-byte header, per RFC 1006 (the inverse of
/// EtherNet/IP's encapsulation `length`, which excludes its header).
///
/// `length` is a u16, so a packet cannot exceed 65535 bytes on the wire. If
/// `kTpktHeaderLen + payload.length` would exceed that, [payload] is
/// truncated so the emitted frame stays self-consistent (declared `length`
/// always matches the bytes actually present) rather than throwing.
Uint8List buildTpkt(Uint8List payload) {
  const maxTotal = 0xFFFF;
  final total = kTpktHeaderLen + payload.length;
  final effectiveTotal = total > maxTotal ? maxTotal : total;
  final effectivePayloadLen = effectiveTotal - kTpktHeaderLen;
  final out = Uint8List(kTpktHeaderLen + effectivePayloadLen);
  out[0] = kTpktVersion;
  out[1] = 0x00;
  ByteData.sublistView(out, 2, 4).setUint16(0, effectiveTotal, Endian.big);
  out.setRange(kTpktHeaderLen, kTpktHeaderLen + effectivePayloadLen, payload);
  return out;
}

// --- COTP --------------------------------------------------------------------

/// A decoded COTP TPDU. `pduType` is the raw PDU-type byte (e.g. [kCotpCr],
/// [kCotpCc], [kCotpDt]). `payload` is whatever bytes follow the COTP
/// header (the carried user data for DT; normally empty for CR/CC).
/// `srcRef`/`dstRef`/`srcTsap`/`dstTsap` are populated only for CR/CC —
/// `null` otherwise (e.g. for DT).
class CotpPacket {
  final int pduType;
  final Uint8List payload;
  final int? srcRef;
  final int? dstRef;
  final int? srcTsap;
  final int? dstTsap;

  CotpPacket({
    required this.pduType,
    required this.payload,
    this.srcRef,
    this.dstRef,
    this.srcTsap,
    this.dstTsap,
  });
}

/// Folds [bytes] into a single non-negative int, treating them as an
/// unsigned BIG-ENDIAN integer (most-significant byte first). Used to
/// decode COTP variable-parameter values (e.g. TSAPs), which are not
/// fixed-width on the wire.
int _readBigEndianUint(List<int> bytes) {
  var value = 0;
  for (final b in bytes) {
    value = (value << 8) | (b & 0xFF);
  }
  return value;
}

/// Parses a single COTP TPDU from the front of [frame].
///
/// Layout: byte 0 is the length indicator (LI) — the header length
/// EXCLUDING the LI byte itself — so the header occupies bytes
/// `[0, 1 + li)`. Byte 1 is the PDU type. For CR/CC, bytes 2..5 (BIG-ENDIAN)
/// are `dstRef`/`srcRef`, byte 6 is class/option, and the variable
/// parameter list (each `code u8, len u8, value`) runs from byte 7 to the
/// end of the declared header; parameters are matched by `code`, so they
/// may appear in any order. For DT, the header is just the type byte plus a
/// single TPDU-number/EOT byte, and everything after the declared header is
/// the carried payload.
///
/// Returns `null` — and never throws — on any malformed input: an empty
/// buffer, a length indicator that overruns [frame], a CR/CC header too
/// short to hold its fixed fields, a parameter whose declared length
/// overruns the declared header, or a PDU type outside CR/CC/DT (this
/// codec's supported set). An unrecognized PDU type is real, on-wire input
/// this codec simply does not implement — per this codec's parse contract,
/// that yields `null` (not a partially-populated [CotpPacket]) so the
/// socket host can drop the frame.
CotpPacket? parseCotp(Uint8List frame) {
  if (frame.isEmpty) {
    return null;
  }
  final li = frame[0];
  final headerEnd = 1 + li; // exclusive end of the COTP header within frame
  if (headerEnd > frame.length || headerEnd < 2) {
    // headerEnd < 2 means li == 0, which cannot even hold a PDU-type byte.
    return null;
  }
  final pduType = frame[1];

  if (pduType == kCotpCr || pduType == kCotpCc) {
    // Fixed fields: type(1) + dstRef(2) + srcRef(2) + class/option(1) = 6
    // bytes after the LI byte, i.e. header must extend at least to index 7.
    if (headerEnd < 7) {
      return null;
    }
    final dstRef = ByteData.sublistView(frame, 2, 4).getUint16(0, Endian.big);
    final srcRef = ByteData.sublistView(frame, 4, 6).getUint16(0, Endian.big);
    // Byte 6 is class/option; not currently exposed by this codec.

    int? srcTsap;
    int? dstTsap;
    var pos = 7;
    while (pos < headerEnd) {
      if (pos + 2 > headerEnd) {
        return null;
      }
      final code = frame[pos];
      final len = frame[pos + 1];
      final valueStart = pos + 2;
      final valueEnd = valueStart + len;
      if (valueEnd > headerEnd) {
        return null;
      }
      if (code == kCotpParamSrcTsap) {
        srcTsap = _readBigEndianUint(frame.sublist(valueStart, valueEnd));
      } else if (code == kCotpParamDstTsap) {
        dstTsap = _readBigEndianUint(frame.sublist(valueStart, valueEnd));
      }
      pos = valueEnd;
    }
    final payload = frame.length > headerEnd ? Uint8List.fromList(frame.sublist(headerEnd)) : Uint8List(0);
    return CotpPacket(
      pduType: pduType,
      payload: payload,
      srcRef: srcRef,
      dstRef: dstRef,
      srcTsap: srcTsap,
      dstTsap: dstTsap,
    );
  }

  if (pduType == kCotpDt) {
    // Fixed fields: type(1) + TPDU-number/EOT(1) = 2 bytes after the LI
    // byte, i.e. header must extend at least to index 3.
    if (headerEnd < 3) {
      return null;
    }
    final payload = frame.length > headerEnd ? Uint8List.fromList(frame.sublist(headerEnd)) : Uint8List(0);
    return CotpPacket(pduType: pduType, payload: payload);
  }

  // Unrecognized PDU type: this codec only understands CR/CC/DT. Returning
  // null (rather than a partially-populated CotpPacket) matches this
  // codebase's parse-function convention and lets the socket host drop the
  // frame instead of acting on a PDU type it can't interpret.
  return null;
}

/// Builds a COTP Connection Confirm (CC, [kCotpCc]) TPDU. v1 is a
/// permissive simulator: it does not validate rack/slot encoded in the
/// destination TSAP, it simply echoes back whatever `srcTsap`/`dstTsap` the
/// caller supplies (normally the client's own CR TSAPs, verbatim) inside
/// the `0xC1`/`0xC2` parameters. Both TSAP values are encoded as 2-byte
/// BIG-ENDIAN fields, and refs as 2-byte BIG-ENDIAN fields, matching the
/// standard S7 TSAP width. The length indicator (byte 0) is computed to
/// match the actual header content emitted, so the result always
/// round-trips through [parseCotp].
///
/// The variable part also emits a `0xC0` TPDU-size parameter (value
/// [kCotpTpduSizeCode1024], 1024 octets). ISO 8073's class-0 default is a
/// 128-octet TPDU when the responder does not negotiate one; that is fine
/// for today's ~27-byte Setup Communication reply, but would be too small
/// once Read/Write Var replies grow to the negotiated 480-byte S7 PDU, so
/// this codec negotiates a real size up front rather than relying on the
/// un-negotiated default.
///
/// Parameter order in the variable part is `0xC0` (TPDU size), then `0xC1`
/// (source TSAP), then `0xC2` (destination TSAP) — ascending by code. ISO
/// 8073 defines the CR/CC variable part as an unordered set of `code, len,
/// value` TLVs (this codec's own [parseCotp] matches by code, never by
/// position, so a different order would still parse correctly), but real
/// controllers and lightweight drivers alike emit ascending order
/// universally, and this codec matches that practice so nothing that
/// (non-conformantly) parses a CC at fixed offsets trips over us.
Uint8List buildCotpConnectConfirm({
  required int srcRef,
  required int dstRef,
  required int srcTsap,
  required int dstTsap,
}) {
  final params = <int>[
    kCotpParamTpduSize, 0x01, kCotpTpduSizeCode1024,
    kCotpParamSrcTsap, 0x02, (srcTsap >> 8) & 0xFF, srcTsap & 0xFF,
    kCotpParamDstTsap, 0x02, (dstTsap >> 8) & 0xFF, dstTsap & 0xFF,
  ];
  const fixedFieldsLen = 1 + 2 + 2 + 1; // type + dstRef + srcRef + class/option
  final li = fixedFieldsLen + params.length;
  final out = Uint8List(1 + li);
  out[0] = li & 0xFF;
  out[1] = kCotpCc;
  ByteData.sublistView(out, 2, 4).setUint16(0, dstRef & 0xFFFF, Endian.big);
  ByteData.sublistView(out, 4, 6).setUint16(0, srcRef & 0xFFFF, Endian.big);
  out[6] = 0x00; // class 0, no extended/additional options
  out.setRange(7, 7 + params.length, params);
  return out;
}

/// Builds a COTP Data (DT, [kCotpDt]) TPDU carrying [payload]. Emits the
/// fixed 3-byte DT header — length indicator `0x02`, PDU type [kCotpDt],
/// then a TPDU-number/EOT byte of `0x80` (TPDU number 0, EOT set — this
/// codec only ever emits single-TPDU messages, never splits across
/// multiple DTs) — followed by [payload] unchanged.
Uint8List buildCotpData(Uint8List payload) {
  const eotLastDataUnit = 0x80;
  final out = Uint8List(3 + payload.length);
  out[0] = 0x02;
  out[1] = kCotpDt;
  out[2] = eotLastDataUnit;
  out.setRange(3, 3 + payload.length, payload);
  return out;
}
