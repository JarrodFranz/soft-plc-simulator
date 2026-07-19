// S7comm protocol PDU codec — pure Dart, no dart:io / Flutter imports. An S7
// message (this layer) is the payload carried inside a COTP data packet
// (mobile/lib/protocols/s7/tpkt_cotp.dart, the layer below). This file does
// NOT import tpkt_cotp.dart: an S7 message has no idea it is being carried
// over COTP/TPKT/TCP, which keeps both layers independently unit-testable.
// Implemented from public S7comm specification material.
//
// *** ENDIANNESS WARNING ***
// S7comm is BIG-ENDIAN throughout, exactly like the transport layer beneath
// it. The EtherNet/IP codec elsewhere in this repo (protocols/enip/) is
// little-endian everywhere — do not pattern-match its `Endian.little` calls
// into this file. Every multi-byte field here is read/written with
// `Endian.big`.
//
// *** THE HEADER IS 12 BYTES ON Ack_Data, 10 BYTES OTHERWISE ***
// `errorClass` (u8) and `errorCode` (u8) are present in the header ONLY when
// `rosctr == kS7RosctrAckData` (0x03). Every other ROSCTR (Job, Ack,
// Userdata) has a 10-byte header with no error fields at all. Getting this
// conditional wrong shifts every byte after the header — the `parameter`
// and `data` slices land 2 bytes off and nothing downstream works.
//
// Wire reference (all BIG-ENDIAN):
//  - Header: `protocolId` u8 (0x32), `rosctr` u8, `redundancyId` u16
//    (always 0x0000), `pduReference` u16, `parameterLength` u16,
//    `dataLength` u16 — 10 bytes so far — then, ONLY if
//    `rosctr == kS7RosctrAckData`, `errorClass` u8 + `errorCode` u8 (12
//    bytes total).
//  - ROSCTR: Job 0x01, Ack 0x02, Ack_Data 0x03, Userdata 0x07.
//  - Setup Communication parameter (function 0xF0): `function` u8,
//    `reserved` u8, `maxAmqCalling` u16, `maxAmqCalled` u16, `pduLength` u16
//    — 8 bytes, used identically for both the client's Job request and the
//    server's Ack_Data reply.
//
// Safety contract: every `parse*` function here returns `null` — and never
// throws — on malformed, truncated, or otherwise hostile input, since the
// socket host (a later task) feeds these functions raw bytes read straight
// off the wire.
library s7_pdu;

import 'dart:typed_data';

// --- S7 header constants ----------------------------------------------------

/// The fixed S7comm protocol-ID byte. Every valid S7 message starts with
/// this byte; anything else is not an S7 message.
const int kS7ProtocolId = 0x32;

/// Length, in bytes, of the common header fields present on every ROSCTR:
/// `protocolId`(1) + `rosctr`(1) + `redundancyId`(2) + `pduReference`(2) +
/// `parameterLength`(2) + `dataLength`(2) = 10.
const int kS7HeaderLenCommon = 10;

/// Length, in bytes, of the header when `rosctr == kS7RosctrAckData` —
/// [kS7HeaderLenCommon] plus `errorClass`(1) + `errorCode`(1) = 12. This is
/// the ONLY ROSCTR whose header carries error fields.
const int kS7HeaderLenAckData = 12;

// --- ROSCTR (region of service control) -------------------------------------

/// Job: a request from the client (e.g. Setup Communication, Read/Write Var).
const int kS7RosctrJob = 0x01;

/// Ack: a bare acknowledgement with no data (rare; most replies are
/// Ack_Data).
const int kS7RosctrAck = 0x02;

/// Ack_Data: a reply carrying data/parameters — the ONLY ROSCTR whose header
/// includes `errorClass`/`errorCode`, making it 12 bytes instead of 10.
const int kS7RosctrAckData = 0x03;

/// Userdata: vendor-specific / diagnostic services (not implemented by this
/// codec beyond the constant itself).
const int kS7RosctrUserdata = 0x07;

// --- Setup Communication ------------------------------------------------------

/// Setup Communication function code, used both as the parameter's leading
/// byte and to identify this parameter type when parsing.
const int kS7FunctionSetupCommunication = 0xF0;

// --- Function codes (Task 4 consumes these; not implemented here) ----------

/// Read Var function code.
const int kS7FunctionReadVar = 0x04;

/// Write Var function code.
const int kS7FunctionWriteVar = 0x05;

// --- Area codes (Task 4 consumes these; not implemented here) --------------

/// Process inputs (PE) area code.
const int kS7AreaInputs = 0x81;

/// Process outputs (PA) area code.
const int kS7AreaOutputs = 0x82;

/// Merker (MK) area code.
const int kS7AreaMerker = 0x83;

/// Data block (DB) area code.
const int kS7AreaDataBlock = 0x84;

// --- Item transport sizes (Task 4 consumes these; not implemented here) ----

/// BIT transport size.
const int kS7TransportSizeBit = 0x01;

/// BYTE transport size.
const int kS7TransportSizeByte = 0x02;

/// CHAR transport size.
const int kS7TransportSizeChar = 0x03;

/// WORD transport size.
const int kS7TransportSizeWord = 0x04;

/// INT transport size.
const int kS7TransportSizeInt = 0x05;

/// DWORD transport size.
const int kS7TransportSizeDword = 0x06;

/// DINT transport size.
const int kS7TransportSizeDint = 0x07;

/// REAL transport size.
const int kS7TransportSizeReal = 0x08;

// --- Return codes (Task 4 consumes these; not implemented here) ------------

/// Success.
const int kS7ReturnSuccess = 0xFF;

/// Object does not exist.
const int kS7ReturnObjectDoesNotExist = 0x0A;

/// Address out of range.
const int kS7ReturnAddressOutOfRange = 0x05;

/// Access denied.
const int kS7ReturnAccessDenied = 0x03;

// --- PDU length negotiation --------------------------------------------------

/// Maximum PDU length this simulator will ever agree to. `negotiatePduLength`
/// negotiates DOWN from a client's proposal to at most this value, never up.
/// Every later response built by this device must respect the AGREED size
/// (the result of `negotiatePduLength`, not the client's raw proposal).
const int kS7MaxPduLength = 480;

/// Floor PDU length: the smallest value `negotiatePduLength` will ever
/// return, regardless of how small (including 0 or negative) a client's
/// proposal is. Chosen as 240 bytes because that is the smallest PDU size
/// real S7 controllers commonly negotiate to, and it is comfortably larger
/// than the fixed S7 header (up to 12 bytes) plus a single Setup
/// Communication or item-request parameter — so downstream size math never
/// has to reason about a degenerate (zero or negative) PDU budget.
const int kS7MinPduLength = 240;

/// Negotiates the PDU length this device will use with a client, given the
/// client's proposed value (as read from a Setup Communication request).
/// This device only ever negotiates DOWN, never up: a proposal above
/// [kS7MaxPduLength] is clamped to [kS7MaxPduLength]. A proposal that is 0,
/// negative, or otherwise nonsensical is clamped up to the documented floor
/// [kS7MinPduLength] instead of being passed through — a negotiated PDU
/// length of 0 would leave no room for any subsequent message. Values
/// already within `[kS7MinPduLength, kS7MaxPduLength]` are returned
/// unchanged.
int negotiatePduLength(int clientProposal) {
  if (clientProposal < kS7MinPduLength) {
    return kS7MinPduLength;
  }
  if (clientProposal > kS7MaxPduLength) {
    return kS7MaxPduLength;
  }
  return clientProposal;
}

// --- S7 header + message -----------------------------------------------------

/// A decoded S7 message header. `errorClass`/`errorCode` are only meaningful
/// when `rosctr == kS7RosctrAckData`; for every other ROSCTR they default to
/// 0 (the header simply does not carry these fields on the wire).
class S7Header {
  final int rosctr;
  final int pduReference;
  final int parameterLength;
  final int dataLength;
  final int errorClass;
  final int errorCode;

  S7Header({
    required this.rosctr,
    required this.pduReference,
    required this.parameterLength,
    required this.dataLength,
    this.errorClass = 0,
    this.errorCode = 0,
  });
}

/// A decoded S7 message: the header plus its `parameter` and `data` byte
/// slices (each sliced to exactly the length the header declared).
class S7Message {
  final S7Header header;
  final Uint8List parameter;
  final Uint8List data;

  S7Message({required this.header, required this.parameter, required this.data});
}

/// Parses an S7 message from the front of [buffer]. The header is read
/// BIG-ENDIAN throughout, and is [kS7HeaderLenAckData] (12) bytes long when
/// `rosctr == kS7RosctrAckData` — carrying `errorClass`/`errorCode` — and
/// [kS7HeaderLenCommon] (10) bytes long for every other ROSCTR. `parameter`
/// and `data` are sliced immediately after the header, in that order, using
/// the header's own declared `parameterLength`/`dataLength`.
///
/// Returns `null` — and never throws — on any malformed input: a buffer
/// shorter than the applicable header length, `protocolId != kS7ProtocolId`,
/// or `parameterLength + dataLength` overrunning the buffer.
S7Message? parseS7(Uint8List buffer) {
  if (buffer.length < kS7HeaderLenCommon) {
    return null;
  }
  if (buffer[0] != kS7ProtocolId) {
    return null;
  }
  final rosctr = buffer[1];
  final pduReference = ByteData.sublistView(buffer, 4, 6).getUint16(0, Endian.big);
  final parameterLength = ByteData.sublistView(buffer, 6, 8).getUint16(0, Endian.big);
  final dataLength = ByteData.sublistView(buffer, 8, 10).getUint16(0, Endian.big);

  int headerLen;
  int errorClass = 0;
  int errorCode = 0;
  if (rosctr == kS7RosctrAckData) {
    if (buffer.length < kS7HeaderLenAckData) {
      return null;
    }
    headerLen = kS7HeaderLenAckData;
    errorClass = buffer[10];
    errorCode = buffer[11];
  } else {
    headerLen = kS7HeaderLenCommon;
  }

  final parameterEnd = headerLen + parameterLength;
  final dataEnd = parameterEnd + dataLength;
  if (dataEnd > buffer.length) {
    return null;
  }

  final header = S7Header(
    rosctr: rosctr,
    pduReference: pduReference,
    parameterLength: parameterLength,
    dataLength: dataLength,
    errorClass: errorClass,
    errorCode: errorCode,
  );
  final parameter = Uint8List.fromList(buffer.sublist(headerLen, parameterEnd));
  final data = Uint8List.fromList(buffer.sublist(parameterEnd, dataEnd));
  return S7Message(header: header, parameter: parameter, data: data);
}

/// Builds a complete S7 message: header + [parameter] + [data]. The header
/// is [kS7HeaderLenAckData] (12) bytes — emitting `errorClass`/`errorCode` —
/// ONLY when `rosctr == kS7RosctrAckData`; for every other ROSCTR it is
/// [kS7HeaderLenCommon] (10) bytes and [errorClass]/[errorCode] are ignored.
/// `redundancyId` is always emitted as `0x0000`. All multi-byte fields are
/// BIG-ENDIAN.
Uint8List buildS7({
  required int rosctr,
  required int pduReference,
  required Uint8List parameter,
  Uint8List? data,
  int errorClass = 0,
  int errorCode = 0,
}) {
  final effectiveData = data ?? Uint8List(0);
  final headerLen = rosctr == kS7RosctrAckData ? kS7HeaderLenAckData : kS7HeaderLenCommon;
  final out = Uint8List(headerLen + parameter.length + effectiveData.length);

  out[0] = kS7ProtocolId;
  out[1] = rosctr & 0xFF;
  ByteData.sublistView(out, 2, 4).setUint16(0, 0x0000, Endian.big); // redundancyId
  ByteData.sublistView(out, 4, 6).setUint16(0, pduReference & 0xFFFF, Endian.big);
  ByteData.sublistView(out, 6, 8).setUint16(0, parameter.length & 0xFFFF, Endian.big);
  ByteData.sublistView(out, 8, 10).setUint16(0, effectiveData.length & 0xFFFF, Endian.big);
  if (rosctr == kS7RosctrAckData) {
    out[10] = errorClass & 0xFF;
    out[11] = errorCode & 0xFF;
  }

  out.setRange(headerLen, headerLen + parameter.length, parameter);
  out.setRange(headerLen + parameter.length, headerLen + parameter.length + effectiveData.length, effectiveData);
  return out;
}

// --- Setup Communication ------------------------------------------------------

/// Length, in bytes, of a Setup Communication parameter: `function`(1) +
/// `reserved`(1) + `maxAmqCalling`(2) + `maxAmqCalled`(2) + `pduLength`(2).
const int _kSetupCommParamLen = 8;

/// A decoded Setup Communication parameter.
class SetupComm {
  final int function;
  final int maxAmqCalling;
  final int maxAmqCalled;
  final int pduLength;

  SetupComm({
    required this.function,
    required this.maxAmqCalling,
    required this.maxAmqCalled,
    required this.pduLength,
  });
}

/// Parses a Setup Communication parameter (the parameter block of an S7
/// message whose `function == kS7FunctionSetupCommunication`) from
/// [parameter]. All multi-byte fields (`maxAmqCalling`, `maxAmqCalled`,
/// `pduLength`) are BIG-ENDIAN.
///
/// Returns `null` — and never throws — if [parameter] is shorter than the
/// fixed 8-byte layout, or if its leading function byte is not
/// [kS7FunctionSetupCommunication].
SetupComm? parseSetupCommunication(Uint8List parameter) {
  if (parameter.length < _kSetupCommParamLen) {
    return null;
  }
  if (parameter[0] != kS7FunctionSetupCommunication) {
    return null;
  }
  final maxAmqCalling = ByteData.sublistView(parameter, 2, 4).getUint16(0, Endian.big);
  final maxAmqCalled = ByteData.sublistView(parameter, 4, 6).getUint16(0, Endian.big);
  final pduLength = ByteData.sublistView(parameter, 6, 8).getUint16(0, Endian.big);
  return SetupComm(
    function: parameter[0],
    maxAmqCalling: maxAmqCalling,
    maxAmqCalled: maxAmqCalled,
    pduLength: pduLength,
  );
}

/// Builds a Setup Communication reply parameter: `function`
/// ([kS7FunctionSetupCommunication]), a zero `reserved` byte, then
/// [maxAmqCalling]/[maxAmqCalled]/[pduLength], each BIG-ENDIAN. Callers
/// should pass [pduLength] the AGREED value from [negotiatePduLength], not
/// the client's raw proposal — every later response this device sends must
/// respect that agreed size.
Uint8List buildSetupCommunicationReply({
  required int maxAmqCalling,
  required int maxAmqCalled,
  required int pduLength,
}) {
  final out = Uint8List(_kSetupCommParamLen);
  out[0] = kS7FunctionSetupCommunication;
  out[1] = 0x00; // reserved
  ByteData.sublistView(out, 2, 4).setUint16(0, maxAmqCalling & 0xFFFF, Endian.big);
  ByteData.sublistView(out, 4, 6).setUint16(0, maxAmqCalled & 0xFFFF, Endian.big);
  ByteData.sublistView(out, 6, 8).setUint16(0, pduLength & 0xFFFF, Endian.big);
  return out;
}
