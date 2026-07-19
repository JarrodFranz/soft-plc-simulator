// EtherNet/IP encapsulation codec — pure Dart, no dart:io / Flutter imports.
// Implements the 24-byte encapsulation header and the Common Packet Format
// (CPF) item list it carries, per public EtherNet/IP encapsulation
// specification material. This is the bottom layer only: CIP messaging
// (the actual request/response payloads carried inside SendRRData /
// SendUnitData) is built on top of this in a later layer.
//
// Wire reference: the encapsulation header is exactly 24 bytes, and every
// multi-byte field in it — and in the CPF item list that follows — is
// little-endian (unlike Modbus TCP's MBAP header, which is big-endian).
// Field layout: `command` u16, `length` u16 (the number of bytes of data
// AFTER the 24-byte header — it does NOT include the header itself),
// `sessionHandle` u32, `status` u32, `senderContext` 8 raw bytes (opaque to
// this layer — the requester sets them and the responder echoes them back
// verbatim, byte-for-byte, unchanged), `options` u32 (reserved, always 0 on
// the wire today but round-tripped as-is).
//
// CPF (Common Packet Format) is the item-list encoding used inside
// SendRRData/SendUnitData payloads: a u16 item count, followed by that many
// items, each `typeId` u16 + `length` u16 + `length` bytes of item data.
//
// dart2js-safety note: every multi-byte numeric field is read/written via
// `ByteData`'s built-in accessors (`getUint16`/`setUint32`/etc.) rather than
// hand-rolled `<<`/`>>`/`&` on values that could be large (session handles,
// status codes, and options are u32) — see `modbus_pdu.dart` for why raw
// bitwise ops on wide values are a silent-corruption trap under dart2js.
library enip_encap;

import 'dart:typed_data';

/// Total size, in bytes, of the EtherNet/IP encapsulation header. Every
/// encapsulation frame is at least this long.
const int kEnipHeaderLen = 24;

/// Number of raw bytes in the `senderContext` field — opaque to this codec.
const int kEnipSenderContextLen = 8;

// --- Encapsulation command codes --------------------------------------------

const int kEnipCommandNop = 0x00;
const int kEnipCommandListIdentity = 0x63;
const int kEnipCommandRegisterSession = 0x65;
const int kEnipCommandUnRegisterSession = 0x66;
const int kEnipCommandSendRRData = 0x6F;
const int kEnipCommandSendUnitData = 0x70;

// --- CPF (Common Packet Format) item type ids -------------------------------

const int kCpfTypeNullAddress = 0x0000;
const int kCpfTypeConnectedAddress = 0x00A1;
const int kCpfTypeConnectedData = 0x00B1;
const int kCpfTypeUnconnectedData = 0x00B2;

// --- Encapsulation header ----------------------------------------------------

/// A decoded 24-byte EtherNet/IP encapsulation header. All numeric fields are
/// plain Dart `int`s holding the little-endian value read off (or to be
/// written to) the wire; `senderContext` is the raw, opaque 8-byte payload.
class EnipHeader {
  final int command;
  final int length;
  final int sessionHandle;
  final int status;
  final Uint8List senderContext;
  final int options;

  EnipHeader({
    required this.command,
    required this.length,
    required this.sessionHandle,
    required this.status,
    required this.senderContext,
    required this.options,
  });
}

/// Parses the 24-byte encapsulation header from the front of [frame].
/// Returns `null` (never throws) if [frame] is shorter than
/// [kEnipHeaderLen] — the caller (the socket host) may pass arbitrary,
/// possibly-truncated bytes off the wire.
///
/// Note this only decodes the header; it does not check that `frame.length`
/// actually satisfies the header's own `length` field — callers that need
/// the data portion should slice `frame.sublist(kEnipHeaderLen)` themselves
/// (or use [parseCpf] on it, for commands that carry CPF payloads) and
/// validate its length against the parsed `header.length` as needed.
EnipHeader? parseEnipHeader(Uint8List frame) {
  if (frame.length < kEnipHeaderLen) {
    return null;
  }
  final bd = ByteData.sublistView(frame, 0, kEnipHeaderLen);
  final command = bd.getUint16(0, Endian.little);
  final length = bd.getUint16(2, Endian.little);
  final sessionHandle = bd.getUint32(4, Endian.little);
  final status = bd.getUint32(8, Endian.little);
  final senderContext = Uint8List.fromList(frame.sublist(12, 12 + kEnipSenderContextLen));
  final options = bd.getUint32(20, Endian.little);
  return EnipHeader(
    command: command,
    length: length,
    sessionHandle: sessionHandle,
    status: status,
    senderContext: senderContext,
    options: options,
  );
}

/// Builds a full encapsulation frame (24-byte header + [data]) from
/// [header]. The header's own `length` field is ignored on input — this
/// function always sets the on-wire `length` to the number of payload bytes
/// actually written, since that is the one value the spec requires to be
/// consistent with the actual payload.
///
/// The `length` field is a u16, so it cannot represent more than 65535
/// bytes. If [data] is longer than that, the payload is **truncated** to
/// its first 65535 bytes and `length` is set to that same truncated count —
/// the emitted frame is always self-consistent (declared `length` equals
/// the number of payload bytes actually present after the header). This
/// codec never throws, so an oversized payload is silently capped rather
/// than rejected; it does not mask the field while still appending the
/// full, uncapped payload, which would produce a frame whose length lies
/// about its own contents.
///
/// `senderContext` is copied byte-for-byte; if it is not exactly
/// [kEnipSenderContextLen] bytes it is truncated to its first 8 bytes (if
/// longer) or zero-padded on the right (if shorter) to fit (a defensive
/// fallback — well-formed callers always supply exactly 8 bytes).
Uint8List buildEnipFrame(EnipHeader header, Uint8List data) {
  final effectiveLen = data.length > 0xFFFF ? 0xFFFF : data.length;
  final out = Uint8List(kEnipHeaderLen + effectiveLen);
  final bd = ByteData.sublistView(out, 0, kEnipHeaderLen);
  bd.setUint16(0, header.command & 0xFFFF, Endian.little);
  bd.setUint16(2, effectiveLen, Endian.little);
  bd.setUint32(4, header.sessionHandle, Endian.little);
  bd.setUint32(8, header.status, Endian.little);
  final ctx = header.senderContext;
  for (var i = 0; i < kEnipSenderContextLen; i++) {
    out[12 + i] = i < ctx.length ? ctx[i] : 0;
  }
  bd.setUint32(20, header.options, Endian.little);
  out.setRange(kEnipHeaderLen, kEnipHeaderLen + effectiveLen, data);
  return out;
}

// --- CPF (Common Packet Format) ---------------------------------------------

/// A single CPF item: an address/data type id plus its raw item data.
class CpfItem {
  final int typeId;
  final Uint8List data;

  CpfItem({required this.typeId, required this.data});
}

/// Parses a CPF item list: a little-endian u16 item count, followed by that
/// many `typeId`(u16) + `length`(u16) + `length` bytes of data. Returns
/// `null` (never throws) if the buffer is too short for the declared item
/// count — a truncated item-header or an item whose declared length exceeds
/// the remaining bytes is treated as malformed, not a fatal error, since this
/// may be fed arbitrary bytes off the wire.
List<CpfItem>? parseCpf(Uint8List data) {
  if (data.length < 2) {
    return null;
  }
  final count = ByteData.sublistView(data, 0, 2).getUint16(0, Endian.little);
  final items = <CpfItem>[];
  var offset = 2;
  for (var i = 0; i < count; i++) {
    if (offset + 4 > data.length) {
      return null;
    }
    final header = ByteData.sublistView(data, offset, offset + 4);
    final typeId = header.getUint16(0, Endian.little);
    final itemLen = header.getUint16(2, Endian.little);
    offset += 4;
    if (offset + itemLen > data.length) {
      return null;
    }
    final itemData = Uint8List.fromList(data.sublist(offset, offset + itemLen));
    items.add(CpfItem(typeId: typeId, data: itemData));
    offset += itemLen;
  }
  return items;
}

/// Builds a CPF item list from [items]: a little-endian u16 item count
/// followed by each item's `typeId`(u16) + `length`(u16) + data.
///
/// Both the item count and each item's `length` are u16 fields, so each is
/// capped at 65535. Every length written is kept self-consistent with the
/// bytes actually present in the output, never masked while the full,
/// uncapped data is still written:
///  - If [items] has more than 65535 entries, only the first 65535 are
///    emitted; the excess entries are **dropped** and the item count
///    reflects only what was written.
///  - If an individual item's `data` is longer than 65535 bytes, that
///    item's data is **truncated** to its first 65535 bytes and its
///    declared `length` field is set to that same truncated count.
Uint8List buildCpf(List<CpfItem> items) {
  final effectiveItems = items.length > 0xFFFF ? items.sublist(0, 0xFFFF) : items;
  final itemLens = <int>[];
  var totalLen = 2;
  for (final item in effectiveItems) {
    final itemLen = item.data.length > 0xFFFF ? 0xFFFF : item.data.length;
    itemLens.add(itemLen);
    totalLen += 4 + itemLen;
  }
  final out = Uint8List(totalLen);
  final countView = ByteData.sublistView(out, 0, 2);
  countView.setUint16(0, effectiveItems.length, Endian.little);
  var offset = 2;
  for (var i = 0; i < effectiveItems.length; i++) {
    final item = effectiveItems[i];
    final itemLen = itemLens[i];
    final header = ByteData.sublistView(out, offset, offset + 4);
    header.setUint16(0, item.typeId & 0xFFFF, Endian.little);
    header.setUint16(2, itemLen, Endian.little);
    offset += 4;
    out.setRange(offset, offset + itemLen, item.data);
    offset += itemLen;
  }
  return out;
}
