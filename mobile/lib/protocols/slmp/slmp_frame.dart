// Mitsubishi SLMP (MELSEC Communication) 3E binary command/response frame
// codec — pure Dart, no dart:io / Flutter imports. This is the bottom layer
// of the SLMP stack: the fixed routing header plus the command/subcommand
// envelope that rides directly inside a length-prefixed TCP stream (the TCP
// host is a later task and is not referenced here). Implemented from public
// SLMP specification material.
//
// *** ENDIANNESS WARNING ***
// SLMP 3E binary is LITTLE-ENDIAN throughout — length fields,
// command/subcommand, and all word data — with ONE documented exception: the
// 2-byte `subheader` is BIG-ENDIAN (0x5000 on the wire is bytes `0x50, 0x00`;
// 0xD000 is `0xD0, 0x00`). This mixed convention is not our invention — it is
// exactly what the real `pymcprotocol` client emits (`type3e.py`
// `_make_senddata`: `self.subheader.to_bytes(2, "big")`, with the literal
// comment "subheader is big endian", while every other field goes out
// `"little"`). The client is the authority (Task 3's E2E), and it settled this
// against an earlier draft that wrongly wrote the subheader little-endian.
//
// The little-endian body is still the EXACT INVERSE of the two area protocols
// that sit right next door in this repo: S7comm (protocols/s7/) and Omron FINS
// (protocols/fins/) are both BIG-ENDIAN throughout. Do NOT copy an
// `Endian.big` from either of those neighbouring files onto a body field — but
// DO keep the subheader big-endian.
//
// A pure build -> parse round trip CANNOT catch an endianness bug — it
// cancels out perfectly even when the implementation is fully broken. Tests
// for this file assert literal expected bytes against hand-built buffers,
// not only round-trips.
//
// *** WIRE LAYOUT (body LITTLE-ENDIAN, subheader BIG-ENDIAN) ***
// Request: `subheader` u16 BIG-ENDIAN (0x5000 -> `0x50, 0x00`), `network` u8,
// `pc` u8 (0xFF = host station), `destModuleIo` u16 (0x03FF),
// `destModuleStation` u8, `requestDataLength` u16 (counts the bytes that
// FOLLOW this field: monitoring timer + command + subcommand + data),
// `monitoringTimer` u16, `command` u16, `subcommand` u16, then command data.
//
// Response: `subheader` u16 BIG-ENDIAN (0xD000 -> `0xD0, 0x00`), the echoed
// routing (`network`, `pc`, `destModuleIo`, `destModuleStation`),
// `responseDataLength` u16 (counts the end code + data that follow it),
// `endCode` u16 (0x0000 = success), then data.
//
// *** THE RESPONSE IS NOT THE REQUEST ECHOED VERBATIM ***
// [buildSlmpResponse] emits the RESPONSE subheader (0xD000, not the
// request's 0x5000), the request's routing bytes (network / PC / dest
// module IO / dest module station) echoed back, and a `responseDataLength`
// that counts a DIFFERENT span than the request's `requestDataLength` (end
// code + data, vs. monitoring timer + command + subcommand + data) — the
// request and response fixed-header shapes differ (the response has no
// monitoring timer, command, or subcommand of its own). Getting
// `responseDataLength` wrong — counting the wrong span — is exactly the kind
// of framing bug a real SLMP client's length checks catch immediately.
//
// Routing (network/PC/destModuleIo/destModuleStation) is accepted
// PERMISSIVELY: this codec never validates it against any notion of "this
// device's own address" — it only ever echoes it back unvalidated. This is a
// simulator; a rejected routing mismatch would be a confusing failure with
// no diagnostic value (the same call this codebase's S7 host makes for
// rack/slot).
//
// Safety contract: [parseSlmpRequest] returns `null` — and never throws — on
// malformed, truncated, or otherwise hostile input, since the TCP host (a
// later task) feeds this function arbitrary bytes read straight off the
// wire.
library slmp_frame;

import 'dart:typed_data';

// --- Subheaders ----------------------------------------------------------

/// The 3E binary REQUEST subheader, BIG-ENDIAN on the wire (bytes
/// `0x50, 0x00`). The subheader is the one big-endian field in an otherwise
/// little-endian frame — see the ENDIANNESS WARNING at the top of this file.
const int kSlmpRequestSubheader = 0x5000;

/// The 3E binary RESPONSE subheader, BIG-ENDIAN on the wire (bytes
/// `0xD0, 0x00`). [buildSlmpResponse] always emits this — never the
/// request's [kSlmpRequestSubheader].
const int kSlmpResponseSubheader = 0xD000;

// --- Fixed layout lengths --------------------------------------------------

/// Length, in bytes, of the fixed REQUEST prefix that [parseSlmpRequest]
/// requires before any command data: `subheader`(2) + `network`(1) +
/// `pc`(1) + `destModuleIo`(2) + `destModuleStation`(1) +
/// `requestDataLength`(2) + `monitoringTimer`(2) + `command`(2) +
/// `subcommand`(2) = 15.
const int kSlmpRequestFixedLen = 15;

/// Length, in bytes, of the fixed RESPONSE prefix emitted by
/// [buildSlmpResponse] before any data: `subheader`(2) + `network`(1) +
/// `pc`(1) + `destModuleIo`(2) + `destModuleStation`(1) +
/// `responseDataLength`(2) + `endCode`(2) = 11.
const int kSlmpResponseFixedLen = 11;

// --- End codes (consumers in later tasks use these) -----------------------
//
// The exact non-zero values below are the error-path set specified for this
// task; they are confirmed against the real `pymcprotocol` client at Task 3.

/// Normal completion — no error.
const int kSlmpEndNormal = 0x0000;

/// The command/subcommand combination is not recognised or not supported.
const int kSlmpEndCommandError = 0xC059;

/// The requested device address (or address range) is out of bounds.
const int kSlmpEndAddressRange = 0xC056;

/// The requested point count is invalid (e.g. zero, or exceeds the
/// protocol's per-request limit).
const int kSlmpEndPointCount = 0xC051;

// --- Header + frame ---------------------------------------------------------

/// The routing portion of an SLMP 3E header, shared by request and response:
/// `network`, `pc`, `destModuleIo`, `destModuleStation` are the addressing
/// bytes that [buildSlmpResponse] echoes back unvalidated (see the
/// permissive-routing note at the top of this file); `monitoringTimer` is
/// request-only (present in a parsed [SlmpFrame.header], meaningless when
/// this header is reused as `requestHeader` to build a response).
class SlmpHeader {
  final int network;
  final int pc;
  final int destModuleIo;
  final int destModuleStation;
  final int monitoringTimer;

  SlmpHeader({
    required this.network,
    required this.pc,
    required this.destModuleIo,
    required this.destModuleStation,
    required this.monitoringTimer,
  });
}

/// A decoded SLMP 3E binary request: the routing [header], the
/// LITTLE-ENDIAN `command`/`subcommand` u16 pair that select the operation
/// (interpreted by a later task, not here), and the remaining [data] bytes.
class SlmpFrame {
  final SlmpHeader header;
  final int command;
  final int subcommand;
  final Uint8List data;

  SlmpFrame({
    required this.header,
    required this.command,
    required this.subcommand,
    required this.data,
  });
}

/// Parses an SLMP 3E binary request from [buffer]: `subheader` u16 (not
/// validated against [kSlmpRequestSubheader] — this codec is permissive
/// about the exact subheader value, mirroring how routing is never
/// validated either), `network` u8, `pc` u8, `destModuleIo` u16,
/// `destModuleStation` u8, `requestDataLength` u16, `monitoringTimer` u16,
/// `command` u16, `subcommand` u16, then the remainder of [buffer] as
/// [SlmpFrame.data]. All multi-byte fields are read LITTLE-ENDIAN.
///
/// DESIGN NOTE: `requestDataLength` is read off the wire but NOT
/// cross-checked against `buffer.length` — everything after the 15-byte
/// fixed prefix is taken as data verbatim. Reassembling a complete frame
/// from a TCP byte stream using `requestDataLength` is the host's job (a
/// later task); by the time a buffer reaches this function it is assumed to
/// already be exactly one complete frame. This mirrors
/// `parseFinsCommand` (`protocols/fins/fins_frame.dart`), which likewise
/// never validates an embedded length against the buffer it was given.
///
/// Returns `null` — and NEVER throws — if [buffer] is shorter than
/// [kSlmpRequestFixedLen] (the fixed header through `subcommand`), since the
/// TCP host feeds this function arbitrary bytes off the wire and must not
/// crash on malformed or truncated input.
SlmpFrame? parseSlmpRequest(Uint8List buffer) {
  if (buffer.length < kSlmpRequestFixedLen) {
    return null;
  }

  final bd = ByteData.sublistView(buffer);
  final network = buffer[2];
  final pc = buffer[3];
  final destModuleIo = bd.getUint16(4, Endian.little);
  final destModuleStation = buffer[6];
  // requestDataLength (bytes 7-8) is intentionally not read into the
  // returned frame — see the DESIGN NOTE above.
  final monitoringTimer = bd.getUint16(9, Endian.little);
  final command = bd.getUint16(11, Endian.little);
  final subcommand = bd.getUint16(13, Endian.little);
  final data = Uint8List.fromList(buffer.sublist(kSlmpRequestFixedLen));

  final header = SlmpHeader(
    network: network,
    pc: pc,
    destModuleIo: destModuleIo,
    destModuleStation: destModuleStation,
    monitoringTimer: monitoringTimer,
  );

  return SlmpFrame(header: header, command: command, subcommand: subcommand, data: data);
}

/// Builds a complete SLMP 3E binary response from [requestHeader]: the
/// RESPONSE subheader ([kSlmpResponseSubheader] = 0xD000 — NOT the
/// request's 0x5000), the routing bytes (`network`, `pc`, `destModuleIo`,
/// `destModuleStation`) echoed back from [requestHeader] UNVALIDATED (see
/// the permissive-routing note at the top of this file), a
/// `responseDataLength` u16 equal to `2 + data.length` (the byte count of
/// the end code plus [data] — NOT the request's span, which additionally
/// counted a monitoring timer, command, and subcommand that the response
/// does not have), the [endCode] u16, then [data] (empty by default). The
/// subheader is written BIG-ENDIAN (the one big-endian field — see the
/// ENDIANNESS WARNING at the top of this file); every other multi-byte field
/// is written LITTLE-ENDIAN.
Uint8List buildSlmpResponse({
  required SlmpHeader requestHeader,
  required int endCode,
  Uint8List? data,
}) {
  final effectiveData = data ?? Uint8List(0);
  final responseDataLength = 2 + effectiveData.length;
  final out = Uint8List(kSlmpResponseFixedLen + effectiveData.length);
  final bd = ByteData.sublistView(out);

  // The subheader is the one BIG-ENDIAN field (see the ENDIANNESS WARNING at
  // the top of this file): 0xD000 must go out as bytes `0xD0, 0x00`.
  bd.setUint16(0, kSlmpResponseSubheader, Endian.big);
  out[2] = requestHeader.network & 0xFF;
  out[3] = requestHeader.pc & 0xFF;
  bd.setUint16(4, requestHeader.destModuleIo & 0xFFFF, Endian.little);
  out[6] = requestHeader.destModuleStation & 0xFF;
  bd.setUint16(7, responseDataLength & 0xFFFF, Endian.little);
  bd.setUint16(9, endCode & 0xFFFF, Endian.little);
  out.setRange(kSlmpResponseFixedLen, kSlmpResponseFixedLen + effectiveData.length, effectiveData);

  return out;
}
