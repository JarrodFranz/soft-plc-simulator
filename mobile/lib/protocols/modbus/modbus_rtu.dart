// Modbus RTU framing — pure Dart, no dart:io / Flutter imports. Covers the
// three primitives a Modbus RTU (or "RTU over TCP") transport needs on top
// of the existing MBAP/PDU codec in `modbus_pdu.dart`:
//
//   1. CRC-16/MODBUS (`crc16Modbus`) — the two-byte frame check appended to
//      every RTU frame in place of TCP's MBAP header.
//   2. Frame build/parse (`buildRtu` / `parseRtu`) — RTU has no MBAP header
//      at all: no transactionId, no protocolId, no explicit length field.
//      The frame is simply `unitId + pdu + crc16(unitId..pdu)` with the CRC
//      stored little-endian (low byte first) on the wire. `parseRtu` returns
//      a `ModbusFrame` (the same type `parseMbap` produces) with a
//      *synthetic* `transactionId: 0` — RTU has no transaction concept, but
//      giving every parsed frame a `ModbusFrame` shape lets the shared PDU
//      handler (`ModbusServer.handle`, `Uint8List? Function(ModbusFrame)`)
//      be reused unchanged for both TCP and RTU transports.
//   3. Request-length derivation (`rtuRequestLength`) — unlike Modbus TCP,
//      where the MBAP header carries an explicit `length` field so a stream
//      reassembler always knows exactly how many more bytes to buffer, RTU
//      carries NO length field anywhere in the frame. A byte-stream
//      transport (e.g. RTU framed over a TCP socket) must therefore derive
//      the expected request length itself, purely from the function code
//      (and, for the two variable-length write-multiple function codes,
//      the byte-count field those requests carry) — that is exactly what
//      `rtuRequestLength` does, returning a tri-state result: `null` while
//      undecidable (not enough bytes buffered yet to know), a positive byte
//      count once decidable (including a fixed 4 bytes for several function
//      codes `ModbusServer` doesn't implement but whose request length is
//      still known, so they get a clean ILLEGAL FUNCTION exception rather
//      than silence), or `-1` when the length genuinely cannot be derived at
//      all (the caller must drop/resync the buffer) — see `rtuRequestLength`
//      for exactly which codes fall in each bucket.
library modbus_rtu;

import 'dart:typed_data';

import 'modbus_pdu.dart';

/// Framing-mode identifier: classic Modbus TCP (MBAP header).
const String kModbusFramingTcp = 'tcp';

/// Framing-mode identifier: Modbus RTU framing carried over a TCP byte
/// stream (no MBAP header; CRC-16 framed, function-code-derived length).
const String kModbusFramingRtuOverTcp = 'rtuOverTcp';

/// Computes the CRC-16/MODBUS check value for [bytes]: reflected CRC-16,
/// polynomial 0xA001, initial value 0xFFFF. Check value for the ASCII string
/// "123456789" is 0x4B37 (the standard CRC catalogue anchor for this
/// variant).
int crc16Modbus(Uint8List bytes) {
  var crc = 0xFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc & 0xFFFF;
}

/// Builds an RTU frame: `unitId + pdu + crc16(unitId..pdu)`, with the CRC's
/// two bytes stored low byte first (little-endian) on the wire.
Uint8List buildRtu(int unitId, Uint8List pdu) {
  final out = BytesBuilder();
  out.addByte(unitId & 0xFF);
  out.add(pdu);
  final crc = crc16Modbus(out.toBytes());
  out.addByte(crc & 0xFF);
  out.addByte((crc >> 8) & 0xFF);
  return out.toBytes();
}

/// Parses a complete RTU frame (unit id + PDU + little-endian CRC-16).
/// Returns `null` if [frame] is shorter than the minimum 4 bytes (unit id +
/// at least a 1-byte function code + 2-byte CRC) or if the recomputed CRC
/// over all but the trailing 2 bytes doesn't match the trailing little-endian
/// CRC. On success, `transactionId` is a synthetic `0` (see file header).
ModbusFrame? parseRtu(Uint8List frame) {
  if (frame.length < 4) {
    return null;
  }
  final body = frame.sublist(0, frame.length - 2);
  final expectedCrc = crc16Modbus(Uint8List.fromList(body));
  final wireCrc = frame[frame.length - 2] | (frame[frame.length - 1] << 8);
  if (expectedCrc != wireCrc) {
    return null;
  }
  return ModbusFrame(
    transactionId: 0,
    unitId: frame[0],
    pdu: frame.sublist(1, frame.length - 2),
  );
}

/// Derives the total byte length of an in-flight RTU request from its
/// function code, since RTU carries no explicit length field anywhere in
/// the frame. [buf] is the bytes buffered so far, starting at the unit id.
/// Returns:
///   - `null` if [buf] is too short to decide yet (fewer than 2 bytes, i.e.
///     the function code at `buf[1]` isn't buffered yet; or, for the
///     variable-length function codes, fewer than 7 bytes, i.e. the
///     byteCount at `buf[6]` isn't buffered yet).
///   - the total expected frame length (unit + PDU + 2-byte CRC) once it can
///     be determined.
///   - `-1` if the length genuinely cannot be derived from the function code
///     alone; the caller must drop/resync the buffer, since without a known
///     length there is no way to know where this request ends and the next
///     one begins.
///
/// IMPORTANT: `-1` means "length not derivable, must resync" — it does NOT
/// mean "function code unsupported". Several function codes this project's
/// `ModbusServer` doesn't implement still have a well-known FIXED request
/// length (unit + fc + 2-byte CRC = 4 bytes, no request body at all):
/// `0x07` (Read Exception Status), `0x0B` (Get Comm Event Counter), `0x0C`
/// (Get Comm Event Log), `0x11` (Report Server ID). For those, the frame
/// length IS derivable, so this function returns `4` — the frame gets
/// framed, parsed, and handed to `ModbusServer.handle`, whose `default:`
/// case replies with a proper ILLEGAL FUNCTION exception. That is a clean,
/// spec-correct answer a master can act on immediately, versus `-1`'s
/// silence-until-timeout (which some discovery/identify tooling probes with
/// exactly these codes, and which can make a perfectly reachable device look
/// unreachable). Every OTHER unrecognized function code still returns `-1`,
/// since its request length truly cannot be derived without decoding a body
/// this project doesn't model.
int? rtuRequestLength(Uint8List buf) {
  if (buf.length < 2) {
    return null;
  }
  switch (buf[1]) {
    case 0x01:
    case 0x02:
    case 0x03:
    case 0x04:
    case 0x05:
    case 0x06:
      return 8;
    case 0x0F:
    case 0x10:
      if (buf.length < 7) {
        return null;
      }
      return 9 + buf[6];
    case 0x07: // Read Exception Status
    case 0x0B: // Get Comm Event Counter
    case 0x0C: // Get Comm Event Log
    case 0x11: // Report Server ID
      // Unsupported by `ModbusServer`, but the request is fixed-length (no
      // body beyond fc): unit(1) + fc(1) + crc(2) = 4. Derivable -> frame it
      // and let `handle` return a clean ILLEGAL FUNCTION exception instead
      // of leaving the master to time out.
      return 4;
    default:
      return -1;
  }
}
