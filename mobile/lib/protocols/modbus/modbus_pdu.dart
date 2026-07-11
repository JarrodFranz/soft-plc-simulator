// Modbus TCP MBAP/PDU codec + register-file handler (WS24) — pure Dart, no
// dart:io / Flutter imports. Implements all 8 classic Modbus function codes
// (01/02/03/04/05/06/0F/10) against the project's `ModbusMap` and live tags.
//
// Wire reference (Modbus Application Protocol v1.1b3 + Modbus over TCP/IP
// spec): MBAP header is 7 bytes — transactionId(u16) protocolId(u16, must be
// 0) length(u16, = unitId + PDU byte count) unitId(u8) — followed by the PDU.
// All multi-byte fields are big-endian. Coil/discrete-input bit packing is
// LSB-first within each byte. INT32 register-file values occupy 2 registers,
// FLOAT64 occupies 4 registers, each register's bytes always big-endian.
// Register ORDER defaults to hi-word-first ("ABCD") but is configurable per
// `ModbusProtocolConfig.wordSwap` — when true, registers are reversed
// (low-word-first, "CDAB") to match masters that expect the swapped
// convention (the most common Modbus interop mismatch). Independently, the
// BYTE order within each 16-bit register defaults to big-endian but is
// configurable per `ModbusProtocolConfig.byteSwap` — when true, the two
// bytes of every register are swapped ("BADC"/"DCBA" family). Combining both
// knobs covers all four common Modbus multi-register orderings: ABCD (both
// false), CDAB (wordSwap only), BADC (byteSwap only), DCBA (both true). The
// server also only answers requests addressed to its configured `unitId`
// (default 255 = "any", matching the original permissive behavior) — see
// `ModbusServer.handle`.
//
// dart2js-safety note: every multi-byte numeric conversion here goes through
// `ByteData`'s built-in 16/32/64-bit accessors (`setInt32`/`getUint16`/etc.)
// rather than hand-rolled `<<`/`>>`/`&` on values that could exceed the
// 32-bit-signed range — see `opcua_binary.dart` for why raw bitwise ops on
// wide values are a silent-corruption trap under dart2js. `getInt64`/
// `setInt64` are never used (dart2js does not implement them at all);
// `getFloat64`/`setFloat64` are fine on both native and web.
library modbus_pdu;

import 'dart:typed_data';

import '../../models/modbus_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';

/// Modbus exception codes (used in the 2-byte exception response body:
/// `(functionCode | 0x80)` + this code).
class ModbusEx {
  static const int illegalFunction = 1;
  static const int illegalDataAddress = 2;
  static const int illegalDataValue = 3;
  static const int serverFailure = 4;
}

// --- Function codes ---------------------------------------------------------

const int _fcReadCoils = 0x01;
const int _fcReadDiscreteInputs = 0x02;
const int _fcReadHoldingRegisters = 0x03;
const int _fcReadInputRegisters = 0x04;
const int _fcWriteSingleCoil = 0x05;
const int _fcWriteSingleRegister = 0x06;
const int _fcWriteMultipleCoils = 0x0F;
const int _fcWriteMultipleRegisters = 0x10;

// --- MBAP --------------------------------------------------------------------

/// A decoded Modbus TCP frame: the MBAP transaction/unit identifiers plus the
/// raw PDU bytes (function code + data, no MBAP header).
class ModbusFrame {
  final int transactionId;
  final int unitId;
  final Uint8List pdu;

  ModbusFrame({required this.transactionId, required this.unitId, required this.pdu});
}

/// Parses a full MBAP+PDU TCP frame. Returns null on anything malformed or
/// short: fewer than the 7-byte header, a non-zero protocolId (Modbus TCP
/// requires 0), or a `length` field promising more PDU bytes than are
/// actually present.
ModbusFrame? parseMbap(Uint8List frame) {
  if (frame.length < 7) {
    return null;
  }
  final transactionId = _u16(frame, 0);
  final protocolId = _u16(frame, 2);
  if (protocolId != 0) {
    return null;
  }
  final length = _u16(frame, 4);
  if (length < 1) {
    return null;
  }
  final unitId = frame[6];
  final pduLen = length - 1;
  if (frame.length < 7 + pduLen) {
    return null;
  }
  final pdu = Uint8List.fromList(frame.sublist(7, 7 + pduLen));
  return ModbusFrame(transactionId: transactionId, unitId: unitId, pdu: pdu);
}

/// Builds a full MBAP+PDU TCP frame from a transaction id, unit id, and an
/// already-encoded PDU.
Uint8List buildMbap(int transactionId, int unitId, Uint8List pdu) {
  final out = BytesBuilder();
  out.add(_u16Bytes(transactionId));
  out.add(_u16Bytes(0)); // protocolId — always 0 for Modbus TCP.
  out.add(_u16Bytes(pdu.length + 1)); // length = unitId(1) + pdu.
  out.addByte(unitId & 0xFF);
  out.add(pdu);
  return out.toBytes();
}

// --- Low-level PDU byte encoders (exposed for fixture tests + reused below) -

/// Builds a read-coils/read-discrete-inputs response PDU: function code +
/// byte count + the bits packed LSB-first within each byte.
Uint8List encodeReadBitsResponse(int fc, List<bool> bits) {
  final packed = _packBits(bits);
  final out = BytesBuilder();
  out.addByte(fc & 0xFF);
  out.addByte(packed.length & 0xFF);
  out.add(packed);
  return out.toBytes();
}

/// Builds a read-holding/read-input-registers response PDU: function code +
/// byte count + each register as 2 big-endian bytes.
Uint8List encodeReadRegistersResponse(int fc, List<int> registers) {
  final out = BytesBuilder();
  out.addByte(fc & 0xFF);
  out.addByte((registers.length * 2) & 0xFF);
  for (final r in registers) {
    out.add(_u16Bytes(r));
  }
  return out.toBytes();
}

/// Builds a 2-byte Modbus exception response: `(fc | 0x80)` + exception code.
Uint8List encodeExceptionResponse(int fc, int exceptionCode) {
  return Uint8List.fromList([(fc | 0x80) & 0xFF, exceptionCode & 0xFF]);
}

/// Swaps the two bytes of a single big-endian 16-bit register value, e.g.
/// 0xABCD -> 0xCDAB. Plain 16-bit bit-ops only (dart2js-safe — no 64-bit
/// integer accessors involved).
int _swapRegBytes(int reg) => ((reg & 0xFF) << 8) | ((reg >> 8) & 0xFF);

/// Applies (or reverses — the operation is its own inverse) the configured
/// byte swap to every register in [regs].
List<int> _applyByteSwap(List<int> regs, bool byteSwap) {
  if (!byteSwap) {
    return regs;
  }
  return [for (final r in regs) _swapRegBytes(r)];
}

/// Encodes a signed INT32 as 2 big-endian registers. By default hi word
/// first ("ABCD" — the original/default wire behavior); when [wordSwap] is
/// true the register ORDER is reversed to low-word-first ("CDAB" — the
/// standard Modbus "word swap"/"reverse word order" convention some masters
/// require). When [byteSwap] is true, the two bytes WITHIN each 16-bit
/// register are additionally swapped ("BADC"/"DCBA" family) — applied AFTER
/// the word-order swap.
List<int> encodeInt32(int value, {bool wordSwap = false, bool byteSwap = false}) {
  final bd = ByteData(4)..setInt32(0, value, Endian.big);
  final hi = bd.getUint16(0, Endian.big);
  final lo = bd.getUint16(2, Endian.big);
  final regs = wordSwap ? [lo, hi] : [hi, lo];
  return _applyByteSwap(regs, byteSwap);
}

/// Decodes 2 registers back to a signed INT32. Set [wordSwap]/[byteSwap] to
/// match how [encodeInt32] produced [regs] — the byte swap (if any) is
/// reversed first, then the word order.
int decodeInt32(List<int> regs, {bool wordSwap = false, bool byteSwap = false}) {
  final unswapped = _applyByteSwap(regs, byteSwap);
  final hi = wordSwap ? unswapped[1] : unswapped[0];
  final lo = wordSwap ? unswapped[0] : unswapped[1];
  final bd = ByteData(4)
    ..setUint16(0, hi & 0xFFFF, Endian.big)
    ..setUint16(2, lo & 0xFFFF, Endian.big);
  return bd.getInt32(0, Endian.big);
}

/// Encodes an INT16 as a single register (big-endian bytes by default; when
/// [byteSwap] is true the register's two bytes are swapped). Word order
/// (`wordSwap`) is a no-op for a single-register type.
List<int> encodeInt16(int value, {bool byteSwap = false}) {
  final bd = ByteData(2)..setInt16(0, value, Endian.big);
  final reg = bd.getUint16(0, Endian.big);
  return [byteSwap ? _swapRegBytes(reg) : reg];
}

/// Decodes a single register back to a signed INT16. Set [byteSwap] to match
/// how [encodeInt16] produced [regs].
int decodeInt16(List<int> regs, {bool byteSwap = false}) {
  final reg = byteSwap ? _swapRegBytes(regs[0]) : regs[0];
  final bd = ByteData(2)..setUint16(0, reg & 0xFFFF, Endian.big);
  return bd.getInt16(0, Endian.big);
}

/// Encodes a FLOAT64 as 4 registers (the IEEE-754 double's 8 bytes in
/// big-endian order, 2 bytes per register). Uses `setFloat64` — allowed per
/// the dart2js-safety note (only the 64-bit *integer* accessors are
/// unsupported on web, not the float ones). When [wordSwap] is true the 4
/// registers are emitted in reverse order (standard Modbus "word swap");
/// when [byteSwap] is true the two bytes WITHIN each register are
/// additionally swapped — applied AFTER the word-order swap.
List<int> encodeFloat64(double value, {bool wordSwap = false, bool byteSwap = false}) {
  final bd = ByteData(8)..setFloat64(0, value, Endian.big);
  final regs = [
    bd.getUint16(0, Endian.big),
    bd.getUint16(2, Endian.big),
    bd.getUint16(4, Endian.big),
    bd.getUint16(6, Endian.big),
  ];
  final ordered = wordSwap ? regs.reversed.toList() : regs;
  return _applyByteSwap(ordered, byteSwap);
}

/// Decodes 4 registers back to a FLOAT64. Set [wordSwap]/[byteSwap] to match
/// how [encodeFloat64] produced [regs] — the byte swap (if any) is reversed
/// first, then the word order.
double decodeFloat64(List<int> regs, {bool wordSwap = false, bool byteSwap = false}) {
  final unswapped = _applyByteSwap(regs, byteSwap);
  final ordered = wordSwap ? unswapped.reversed.toList() : unswapped;
  final bd = ByteData(8)
    ..setUint16(0, ordered[0] & 0xFFFF, Endian.big)
    ..setUint16(2, ordered[1] & 0xFFFF, Endian.big)
    ..setUint16(4, ordered[2] & 0xFFFF, Endian.big)
    ..setUint16(6, ordered[3] & 0xFFFF, Endian.big);
  return bd.getFloat64(0, Endian.big);
}

int _u16(Uint8List data, int offset) => (data[offset] << 8) | data[offset + 1];

Uint8List _u16Bytes(int value) => Uint8List.fromList([(value >> 8) & 0xFF, value & 0xFF]);

Uint8List _packBits(List<bool> bits) {
  final byteCount = (bits.length + 7) ~/ 8;
  final out = Uint8List(byteCount);
  for (var i = 0; i < bits.length; i++) {
    if (bits[i]) {
      out[i ~/ 8] |= 1 << (i % 8);
    }
  }
  return out;
}

List<bool> _unpackBits(Uint8List data, int count) {
  final out = <bool>[];
  for (var i = 0; i < count; i++) {
    final byte = data[i ~/ 8];
    out.add(((byte >> (i % 8)) & 1) != 0);
  }
  return out;
}

// --- Register-view helpers ---------------------------------------------------

/// Number of 16-bit registers [dataType] occupies in a register table
/// (holding/input); delegates to `ModbusMap.regsForType`.
int _widthForEntry(PlcProject project, ModbusMapEntry entry) {
  if (entry.table == 'coil' || entry.table == 'discrete') {
    return 1;
  }
  final dt = _tagDataType(project, entry.tag) ?? 'INT16';
  return ModbusMap.regsForType(dt);
}

/// The data type of a mapped entry's (possibly dotted, e.g. `Motor.Speed`)
/// tag path — delegates to `tag_resolver.dart`'s field-def walk so a struct
/// member resolves to its OWN type (e.g. INT32) instead of the INT16
/// fallback a bare top-level-name lookup would produce.
String? _tagDataType(PlcProject project, String tagPath) {
  return dataTypeOfPath(project, tagPath);
}

/// The root tag of a (possibly dotted/indexed) path — mirrors the engines'
/// `_forceAwareWrite`/`_rootTagOf` root resolution (`fbd_exec.dart`,
/// `ld_exec.dart`, `sfc_exec.dart`, `st_exec.dart`): the tag name is
/// everything before the first `.` or `[`.
PlcTag? _findRootTag(PlcProject project, String path) {
  final rootName = path.split('.').first.split('[').first;
  for (final t in project.tags) {
    if (t.name == rootName) {
      return t;
    }
  }
  return null;
}

/// Force-aware write guard: mirrors the engines' `_forceAwareWrite` root
/// resolution — find the ROOT tag of the (possibly dotted) path and honor
/// its `isForced` flag, so forcing a struct tag (e.g. `Motor`) skips writes
/// to any of its members (e.g. `Motor.Speed`), not just a bare top-level
/// write — except Modbus skips SILENTLY and still answers with the normal
/// echo response (no exception), unlike the OPC UA path which refuses
/// visibly with Bad_UserAccessDenied.
bool _isForcedSkip(PlcProject project, String path) {
  final root = _findRootTag(project, path);
  return root != null && root.isForced && root.value is! Map && root.value is! List;
}

ModbusMap _mapFor(PlcProject project) {
  return project.protocols?.modbus?.map ?? ModbusMap(entries: []);
}

/// The configured word-order for multi-register values (see
/// `ModbusProtocolConfig.wordSwap`'s doc comment) — defaults to `false`
/// (hi-word-first) when Modbus isn't configured at all.
bool _wordSwapFor(PlcProject project) => project.protocols?.modbus?.wordSwap ?? false;

/// The configured byte-order within each register (see
/// `ModbusProtocolConfig.byteSwap`'s doc comment) — defaults to `false`
/// (big-endian) when Modbus isn't configured at all.
bool _byteSwapFor(PlcProject project) => project.protocols?.modbus?.byteSwap ?? false;

/// The configured unit id this server responds as (see
/// `ModbusProtocolConfig.unitId`'s doc comment) — defaults to `255` ("any")
/// when Modbus isn't configured at all.
int _unitIdFor(PlcProject project) => project.protocols?.modbus?.unitId ?? 255;

/// The map entry (if any) covering register/bit [address] in [table],
/// accounting for multi-register entries' full span.
ModbusMapEntry? _findEntry(PlcProject project, ModbusMap map, String table, int address) {
  for (final e in map.entries) {
    if (e.table != table) {
      continue;
    }
    final width = _widthForEntry(project, e);
    if (address >= e.address && address < e.address + width) {
      return e;
    }
  }
  return null;
}

List<int> _encodeRegsForType(String dataType, dynamic value,
    {bool wordSwap = false, bool byteSwap = false}) {
  switch (dataType) {
    case 'INT32':
      return encodeInt32(value is num ? value.toInt() : 0, wordSwap: wordSwap, byteSwap: byteSwap);
    case 'FLOAT64':
      return encodeFloat64(value is num ? value.toDouble() : 0.0,
          wordSwap: wordSwap, byteSwap: byteSwap);
    default: // INT16 and any other scalar fallback.
      return encodeInt16(value is num ? value.toInt() : 0, byteSwap: byteSwap);
  }
}

dynamic _decodeRegsForType(String dataType, List<int> regs,
    {bool wordSwap = false, bool byteSwap = false}) {
  switch (dataType) {
    case 'INT32':
      return decodeInt32(regs, wordSwap: wordSwap, byteSwap: byteSwap);
    case 'FLOAT64':
      return decodeFloat64(regs, wordSwap: wordSwap, byteSwap: byteSwap);
    default:
      return decodeInt16(regs, byteSwap: byteSwap);
  }
}

// --- Register-file handler ---------------------------------------------------

/// Decodes Modbus PDUs (all 8 classic function codes) against the project's
/// `ModbusMap` + live tags. Reads never fail (unmapped/out-of-range gaps
/// within a legal address range 0-fill); writes are force-aware (a forced
/// root tag silently discards the write but still echoes success) and never
/// throw — every internal error becomes a 0x04 Server Device Failure
/// exception PDU instead of an uncaught exception.
class ModbusServer {
  final PlcProject Function() projectProvider;

  ModbusServer({required this.projectProvider});

  /// Handles one decoded request PDU (function code + data, no MBAP) and
  /// returns the response PDU (also no MBAP — the host wraps it via
  /// [buildMbap]), or `null` if this server must stay silent (a configured
  /// unit id in 1-247 that doesn't match [req.unitId] — see `_unitIdFor`'s
  /// doc comment; mirrors how a real outstation ignores a request addressed
  /// to someone else on a shared TCP endpoint).
  Uint8List? handle(ModbusFrame req) {
    try {
      final project = projectProvider();
      final configuredUnitId = _unitIdFor(project);
      final filtering = configuredUnitId >= 1 && configuredUnitId <= 247;
      if (filtering && req.unitId != configuredUnitId && req.unitId != 0) {
        return null; // mismatched unit id, not broadcast -> stay silent
      }
      return _dispatch(project, req.pdu);
    } catch (_) {
      final fc = req.pdu.isNotEmpty ? req.pdu[0] : 0;
      return encodeExceptionResponse(fc, ModbusEx.serverFailure);
    }
  }

  Uint8List _dispatch(PlcProject project, Uint8List pdu) {
    if (pdu.isEmpty) {
      return encodeExceptionResponse(0, ModbusEx.serverFailure);
    }
    switch (pdu[0]) {
      case _fcReadCoils:
        return _readBits(project, pdu, 'coil');
      case _fcReadDiscreteInputs:
        return _readBits(project, pdu, 'discrete');
      case _fcReadHoldingRegisters:
        return _readRegs(project, pdu, 'holding');
      case _fcReadInputRegisters:
        return _readRegs(project, pdu, 'input');
      case _fcWriteSingleCoil:
        return _writeSingleCoil(project, pdu);
      case _fcWriteSingleRegister:
        return _writeSingleRegister(project, pdu);
      case _fcWriteMultipleCoils:
        return _writeMultipleCoils(project, pdu);
      case _fcWriteMultipleRegisters:
        return _writeMultipleRegisters(project, pdu);
      default:
        return encodeExceptionResponse(pdu[0], ModbusEx.illegalFunction);
    }
  }

  // --- Reads (FC01/02/03/04) ---

  Uint8List _readBits(PlcProject project, Uint8List pdu, String table) {
    final fc = pdu[0];
    if (pdu.length < 5) {
      return encodeExceptionResponse(fc, ModbusEx.serverFailure);
    }
    final start = _u16(pdu, 1);
    final qty = _u16(pdu, 3);
    if (qty < 1 || qty > 2000 || start + qty > 0x10000) {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
    }
    final map = _mapFor(project);
    final cache = <ModbusMapEntry, bool>{};
    final bits = <bool>[];
    for (var a = start; a < start + qty; a++) {
      final entry = _findEntry(project, map, table, a);
      if (entry == null) {
        bits.add(false);
        continue;
      }
      final value = cache.putIfAbsent(entry, () => readPath(project, entry.tag) == true);
      bits.add(value);
    }
    return encodeReadBitsResponse(fc, bits);
  }

  Uint8List _readRegs(PlcProject project, Uint8List pdu, String table) {
    final fc = pdu[0];
    if (pdu.length < 5) {
      return encodeExceptionResponse(fc, ModbusEx.serverFailure);
    }
    final start = _u16(pdu, 1);
    final qty = _u16(pdu, 3);
    if (qty < 1 || qty > 125 || start + qty > 0x10000) {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
    }
    final map = _mapFor(project);
    final wordSwap = _wordSwapFor(project);
    final byteSwap = _byteSwapFor(project);
    final cache = <ModbusMapEntry, List<int>>{};
    final regs = <int>[];
    for (var a = start; a < start + qty; a++) {
      final entry = _findEntry(project, map, table, a);
      if (entry == null) {
        regs.add(0);
        continue;
      }
      final words = cache.putIfAbsent(entry, () {
        final dt = _tagDataType(project, entry.tag) ?? 'INT16';
        final value = readPath(project, entry.tag);
        return _encodeRegsForType(dt, value, wordSwap: wordSwap, byteSwap: byteSwap);
      });
      final offset = a - entry.address;
      regs.add(offset >= 0 && offset < words.length ? words[offset] : 0);
    }
    return encodeReadRegistersResponse(fc, regs);
  }

  // --- Single writes (FC05/06) ---

  Uint8List _writeSingleCoil(PlcProject project, Uint8List pdu) {
    final fc = pdu[0];
    if (pdu.length < 5) {
      return encodeExceptionResponse(fc, ModbusEx.serverFailure);
    }
    final address = _u16(pdu, 1);
    final rawValue = _u16(pdu, 3);
    if (rawValue != 0xFF00 && rawValue != 0x0000) {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
    }
    final map = _mapFor(project);
    final entry = _findEntry(project, map, 'coil', address);
    if (entry == null || entry.access == 'ReadOnly') {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataAddress);
    }
    if (!_isForcedSkip(project, entry.tag)) {
      writePath(project, entry.tag, rawValue == 0xFF00);
    }
    return Uint8List.fromList(pdu.sublist(0, 5));
  }

  Uint8List _writeSingleRegister(PlcProject project, Uint8List pdu) {
    final fc = pdu[0];
    if (pdu.length < 5) {
      return encodeExceptionResponse(fc, ModbusEx.serverFailure);
    }
    final address = _u16(pdu, 1);
    final rawValue = _u16(pdu, 3);
    final map = _mapFor(project);
    final entry = _findEntry(project, map, 'holding', address);
    if (entry == null || entry.access == 'ReadOnly') {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataAddress);
    }
    if (_widthForEntry(project, entry) != 1) {
      // Can't half-write a multi-register (INT32/FLOAT64) tag via FC06.
      return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
    }
    if (!_isForcedSkip(project, entry.tag)) {
      final dt = _tagDataType(project, entry.tag) ?? 'INT16';
      final byteSwap = _byteSwapFor(project);
      final value = _decodeRegsForType(dt, [rawValue], byteSwap: byteSwap);
      writePath(project, entry.tag, value);
    }
    return Uint8List.fromList(pdu.sublist(0, 5));
  }

  // --- Multiple writes (FC0F/10) ---

  Uint8List _writeMultipleCoils(PlcProject project, Uint8List pdu) {
    final fc = pdu[0];
    if (pdu.length < 6) {
      return encodeExceptionResponse(fc, ModbusEx.serverFailure);
    }
    final start = _u16(pdu, 1);
    final qty = _u16(pdu, 3);
    final byteCount = pdu[5];
    if (qty < 1 || qty > 2000 || start + qty > 0x10000) {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
    }
    final expectedByteCount = (qty + 7) ~/ 8;
    if (byteCount != expectedByteCount || pdu.length < 6 + byteCount) {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
    }
    final data = pdu.sublist(6, 6 + byteCount);
    final bits = _unpackBits(data, qty);

    final map = _mapFor(project);
    final targets = <int, ModbusMapEntry>{};
    for (var i = 0; i < qty; i++) {
      final addr = start + i;
      final entry = _findEntry(project, map, 'coil', addr);
      if (entry == null || entry.access == 'ReadOnly') {
        return encodeExceptionResponse(fc, ModbusEx.illegalDataAddress);
      }
      targets[addr] = entry;
    }
    for (var i = 0; i < qty; i++) {
      final entry = targets[start + i]!;
      if (!_isForcedSkip(project, entry.tag)) {
        writePath(project, entry.tag, bits[i]);
      }
    }
    return _echoStartQty(fc, start, qty);
  }

  Uint8List _writeMultipleRegisters(PlcProject project, Uint8List pdu) {
    final fc = pdu[0];
    if (pdu.length < 6) {
      return encodeExceptionResponse(fc, ModbusEx.serverFailure);
    }
    final start = _u16(pdu, 1);
    final qty = _u16(pdu, 3);
    final byteCount = pdu[5];
    if (qty < 1 || qty > 125 || start + qty > 0x10000) {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
    }
    final expectedByteCount = qty * 2;
    if (byteCount != expectedByteCount || pdu.length < 6 + byteCount) {
      return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
    }
    final regs = <int>[];
    for (var i = 0; i < qty; i++) {
      regs.add(_u16(pdu, 6 + i * 2));
    }

    final map = _mapFor(project);
    final wordSwap = _wordSwapFor(project);
    final byteSwap = _byteSwapFor(project);
    final touched = <ModbusMapEntry>{};
    for (var i = 0; i < qty; i++) {
      final addr = start + i;
      final entry = _findEntry(project, map, 'holding', addr);
      if (entry == null || entry.access == 'ReadOnly') {
        return encodeExceptionResponse(fc, ModbusEx.illegalDataAddress);
      }
      touched.add(entry);
    }
    // Every touched entry's full register span must lie within the write
    // range — a multi-register tag can't be partially overwritten.
    for (final entry in touched) {
      final width = _widthForEntry(project, entry);
      final spanStart = entry.address;
      final spanEnd = entry.address + width;
      if (spanStart < start || spanEnd > start + qty) {
        return encodeExceptionResponse(fc, ModbusEx.illegalDataValue);
      }
    }
    for (final entry in touched) {
      if (_isForcedSkip(project, entry.tag)) {
        continue;
      }
      final width = _widthForEntry(project, entry);
      final offset = entry.address - start;
      final words = regs.sublist(offset, offset + width);
      final dt = _tagDataType(project, entry.tag) ?? 'INT16';
      writePath(
          project, entry.tag, _decodeRegsForType(dt, words, wordSwap: wordSwap, byteSwap: byteSwap));
    }
    return _echoStartQty(fc, start, qty);
  }

  Uint8List _echoStartQty(int fc, int start, int qty) {
    final out = BytesBuilder();
    out.addByte(fc & 0xFF);
    out.add(_u16Bytes(start));
    out.add(_u16Bytes(qty));
    return out.toBytes();
  }
}
