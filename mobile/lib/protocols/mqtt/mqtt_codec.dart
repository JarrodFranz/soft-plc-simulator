// Pure MQTT 3.1.1 control-packet codec + streaming reassembler — no
// dart:io / Flutter imports, only dart:typed_data. Implements the packet
// builders/parsers needed by the (later) publisher/host tasks: CONNECT,
// PUBLISH, SUBSCRIBE, PINGREQ, DISCONNECT encoders and CONNACK/PUBACK/SUBACK/
// PUBLISH parsers, plus `MqttFrameBuffer`, a TCP-chunk-tolerant reassembler.
//
// Wire reference (OASIS MQTT Version 3.1.1, OASIS Standard): fixed header
// byte = `(packetType << 4) | flags`. Remaining Length (section 2.2.3) is a
// 1-4 byte variable-length integer: each byte holds 7 data bits (LSB group
// first) with the high bit set to signal "more bytes follow". CONNECT's
// variable header (section 3.1.2) is protocol name "MQTT" (as an MQTT
// string), protocol level 0x04, a connect-flags byte, and a big-endian u16
// keep-alive; the payload is clientId, then — if present — will topic + will
// payload, then username, then password, each as MQTT strings/binary data
// (will payload and password are raw length-prefixed bytes, not required to
// be valid UTF-8, but we accept String args here per the brief's interface
// and encode them via the same string framing since Sparkplug/gateway
// payloads here are all ASCII text). PUBLISH's variable header (section
// 3.3.2) is a topic string, then — only when QoS > 0 — a big-endian u16
// packet id; everything after is the application payload.
//
// dart2js-safety note (mirrors `modbus_pdu.dart`'s convention): every 16-bit
// field goes through `ByteData.setUint16`/`getUint16` with `Endian.big`
// rather than hand-rolled `<<`/`>>`. `getInt64`/`setInt64` are never used
// (dart2js does not implement them); this codec only ever needs 16-bit
// fields plus single "remaining length" bytes, so no 32/64-bit accessors are
// needed at all.
//
// No `dart:convert` either (kept to `dart:typed_data` only, per the task's
// pure-Dart constraint) — `_utf8Encode`/`_utf8Decode` below hand-roll UTF-8
// framing over `String.runes` (Unicode code points) / `String.fromCharCodes`,
// both plain `dart:core` members, not an extra import.
library mqtt_codec;

import 'dart:typed_data';

/// MQTT 3.1.1 control packet type values (fixed header high nibble).
class MqttPacketType {
  static const int connect = 1;
  static const int connack = 2;
  static const int publish = 3;
  static const int puback = 4;
  static const int subscribe = 8;
  static const int suback = 9;
  static const int pingreq = 12;
  static const int pingresp = 13;
  static const int disconnect = 14;
}

/// A decoded MQTT variable-length integer (used for "Remaining Length"):
/// the decoded [value] plus how many bytes were consumed to encode it.
class MqttVarInt {
  final int value;
  final int bytesConsumed;

  const MqttVarInt(this.value, this.bytesConsumed);
}

/// A topic filter + requested QoS pair for [encodeSubscribe].
class MqttTopicFilter {
  final String topic;
  final int qos;

  const MqttTopicFilter(this.topic, {this.qos = 0});
}

/// A parsed CONNACK: whether the broker reports a pre-existing session and
/// its connect return code (0 = accepted, per section 3.2.2.3).
class MqttConnack {
  final bool sessionPresent;
  final int returnCode;

  const MqttConnack(this.sessionPresent, this.returnCode);
}

/// A parsed SUBACK: the acknowledged packet id and one granted-QoS/failure
/// byte per requested topic filter, in request order.
class MqttSuback {
  final int packetId;
  final List<int> returnCodes;

  const MqttSuback(this.packetId, this.returnCodes);
}

/// An inbound PUBLISH decoded from the wire.
class MqttPublish {
  final String topic;
  final Uint8List payload;
  final int qos;
  final int? packetId;
  final bool retain;

  const MqttPublish({
    required this.topic,
    required this.payload,
    required this.qos,
    this.packetId,
    required this.retain,
  });
}

// --- Remaining-length varint -------------------------------------------------

/// Encodes [length] as an MQTT "Remaining Length" varint: 7 data bits per
/// byte (least-significant group first), high bit set on every byte except
/// the last. Valid for 0..268,435,455 (the MQTT 3.1.1 max, 4 bytes); negative
/// or absurdly large input is clamped to 0 rather than throwing.
Uint8List encodeRemainingLength(int length) {
  var value = length < 0 ? 0 : length;
  final out = BytesBuilder();
  do {
    var byte = value % 128;
    value = value ~/ 128;
    if (value > 0) {
      byte |= 0x80;
    }
    out.addByte(byte);
  } while (value > 0);
  return out.toBytes();
}

/// Decodes an MQTT Remaining Length varint starting at [offset] in [data].
/// Returns null when the bytes seen so far cannot yet resolve to a value —
/// either because fewer bytes are present than the continuation bits demand
/// ("need more"), or because 4 continuation bytes appear without a
/// terminator (malformed: not a legal MQTT varint, since the format caps out
/// at 4 bytes). Callers that need to tell the two apart (the reassembler)
/// do so by checking how many bytes are actually available.
MqttVarInt? decodeRemainingLength(Uint8List data, [int offset = 0]) {
  var multiplier = 1;
  var value = 0;
  var index = offset;
  for (var i = 0; i < 4; i++) {
    if (index >= data.length) {
      return null; // need more bytes
    }
    final byte = data[index];
    value += (byte & 0x7F) * multiplier;
    index++;
    if ((byte & 0x80) == 0) {
      return MqttVarInt(value, index - offset);
    }
    multiplier *= 128;
  }
  return null; // 4 continuation bytes without a terminator: malformed
}

// --- MQTT string / binary framing -------------------------------------------

/// Encodes [value] as an MQTT string: a big-endian u16 byte length followed
/// by its UTF-8 bytes (section 1.5.3). Also used for will-payload/password
/// "binary data" fields, which share the same 2-byte-length-prefix framing.
Uint8List encodeMqttString(String value) {
  final bytes = _utf8Encode(value);
  final out = BytesBuilder();
  out.add(_u16Bytes(bytes.length));
  out.add(bytes);
  return out.toBytes();
}

/// Length-prefixes already-raw bytes (will payload) the same way
/// [encodeMqttString] does for text, without requiring valid UTF-8.
Uint8List _encodeMqttBinary(Uint8List bytes) {
  final out = BytesBuilder();
  out.add(_u16Bytes(bytes.length));
  out.add(bytes);
  return out.toBytes();
}

class _StringResult {
  final String value;
  final int bytesConsumed;

  const _StringResult(this.value, this.bytesConsumed);
}

/// Decodes one length-prefixed MQTT string starting at [offset], bounded by
/// [limit] (exclusive). Returns null if the length prefix or its bytes don't
/// fit within [limit], or the bytes aren't valid UTF-8 — never throws.
_StringResult? _decodeMqttString(Uint8List data, int offset, int limit) {
  if (offset + 2 > limit) {
    return null;
  }
  final len = _u16(data, offset);
  final start = offset + 2;
  final end = start + len;
  if (end > limit) {
    return null;
  }
  final str = _utf8Decode(Uint8List.sublistView(data, start, end));
  if (str == null) {
    return null;
  }
  return _StringResult(str, 2 + len);
}

/// Hand-rolled UTF-8 encoder over Unicode code points (`String.runes`
/// already assembles UTF-16 surrogate pairs into single code points), so no
/// `dart:convert` import is needed for this pure-Dart codec.
Uint8List _utf8Encode(String value) {
  final out = BytesBuilder();
  for (final codePoint in value.runes) {
    if (codePoint <= 0x7F) {
      out.addByte(codePoint);
    } else if (codePoint <= 0x7FF) {
      out.addByte(0xC0 | (codePoint >> 6));
      out.addByte(0x80 | (codePoint & 0x3F));
    } else if (codePoint <= 0xFFFF) {
      out.addByte(0xE0 | (codePoint >> 12));
      out.addByte(0x80 | ((codePoint >> 6) & 0x3F));
      out.addByte(0x80 | (codePoint & 0x3F));
    } else {
      out.addByte(0xF0 | (codePoint >> 18));
      out.addByte(0x80 | ((codePoint >> 12) & 0x3F));
      out.addByte(0x80 | ((codePoint >> 6) & 0x3F));
      out.addByte(0x80 | (codePoint & 0x3F));
    }
  }
  return out.toBytes();
}

/// Hand-rolled UTF-8 decoder. Returns null (rather than throwing) on a
/// truncated multi-byte sequence or an invalid leading byte.
String? _utf8Decode(Uint8List bytes) {
  final codePoints = <int>[];
  var i = 0;
  while (i < bytes.length) {
    final b0 = bytes[i];
    if (b0 & 0x80 == 0) {
      codePoints.add(b0);
      i += 1;
    } else if (b0 & 0xE0 == 0xC0) {
      if (i + 1 >= bytes.length) {
        return null;
      }
      codePoints.add(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if (b0 & 0xF0 == 0xE0) {
      if (i + 2 >= bytes.length) {
        return null;
      }
      codePoints.add(((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
      i += 3;
    } else if (b0 & 0xF8 == 0xF0) {
      if (i + 3 >= bytes.length) {
        return null;
      }
      codePoints.add(((b0 & 0x07) << 18) |
          ((bytes[i + 1] & 0x3F) << 12) |
          ((bytes[i + 2] & 0x3F) << 6) |
          (bytes[i + 3] & 0x3F));
      i += 4;
    } else {
      return null; // invalid UTF-8 leading byte
    }
  }
  return String.fromCharCodes(codePoints);
}

// --- 16-bit big-endian helpers (ByteData-based, dart2js-safe) --------------

Uint8List _u16Bytes(int value) {
  final bd = ByteData(2)..setUint16(0, value & 0xFFFF, Endian.big);
  return bd.buffer.asUint8List();
}

int _u16(Uint8List data, int offset) {
  final bd = ByteData.sublistView(data, offset, offset + 2);
  return bd.getUint16(0, Endian.big);
}

// --- Fixed-header packet assembly -------------------------------------------

Uint8List _buildPacket(int fixedHeaderByte, Uint8List variableHeaderAndPayload) {
  final out = BytesBuilder();
  out.addByte(fixedHeaderByte & 0xFF);
  out.add(encodeRemainingLength(variableHeaderAndPayload.length));
  out.add(variableHeaderAndPayload);
  return out.toBytes();
}

/// Slices out the body (everything after the fixed header) of [packet] if
/// its type nibble matches [expectedType] and the whole packet has arrived.
/// Returns null on a type mismatch, a malformed/incomplete remaining-length,
/// or a body shorter than the remaining-length promised.
Uint8List? _bodyOf(Uint8List packet, int expectedType) {
  if (packet.isEmpty) {
    return null;
  }
  final type = (packet[0] >> 4) & 0x0F;
  if (type != expectedType) {
    return null;
  }
  final rl = decodeRemainingLength(packet, 1);
  if (rl == null) {
    return null;
  }
  final bodyStart = 1 + rl.bytesConsumed;
  final bodyEnd = bodyStart + rl.value;
  if (packet.length < bodyEnd) {
    return null;
  }
  return Uint8List.sublistView(packet, bodyStart, bodyEnd);
}

// --- Packet builders ---------------------------------------------------------

/// Builds a CONNECT packet (section 3.1). [willTopic]/[willPayload] must
/// both be provided together to set the Will flag; [willRetain]/[willQos]
/// are ignored unless a will is present.
Uint8List encodeConnect({
  required String clientId,
  int keepAliveSecs = 60,
  bool cleanSession = true,
  String? username,
  String? password,
  String? willTopic,
  Uint8List? willPayload,
  bool willRetain = false,
  int willQos = 0,
}) {
  final hasWill = willTopic != null;
  final hasUsername = username != null;
  final hasPassword = password != null;

  // Connect flags byte (section 3.1.2.3):
  //   bit7 username | bit6 password | bit5 willRetain | bits4-3 willQoS |
  //   bit2 willFlag | bit1 cleanSession | bit0 reserved(0)
  var flags = 0;
  if (hasUsername) {
    flags |= 0x80;
  }
  if (hasPassword) {
    flags |= 0x40;
  }
  if (hasWill) {
    if (willRetain) {
      flags |= 0x20;
    }
    flags |= (willQos & 0x03) << 3;
    flags |= 0x04;
  }
  if (cleanSession) {
    flags |= 0x02;
  }

  final body = BytesBuilder();
  body.add(encodeMqttString('MQTT')); // protocol name
  body.addByte(0x04); // protocol level: MQTT 3.1.1
  body.addByte(flags & 0xFF);
  body.add(_u16Bytes(keepAliveSecs));
  body.add(encodeMqttString(clientId));
  if (hasWill) {
    body.add(encodeMqttString(willTopic));
    body.add(_encodeMqttBinary(willPayload ?? Uint8List(0)));
  }
  if (hasUsername) {
    body.add(encodeMqttString(username));
  }
  if (hasPassword) {
    body.add(encodeMqttString(password));
  }
  return _buildPacket(MqttPacketType.connect << 4, body.toBytes());
}

/// Builds a PUBLISH packet (section 3.3). `packetId` is only written when
/// `qos > 0` (QoS 0 publishes carry no packet id, per spec).
Uint8List encodePublish({
  required String topic,
  required Uint8List payload,
  int qos = 0,
  bool retain = false,
  int? packetId,
}) {
  final body = BytesBuilder();
  body.add(encodeMqttString(topic));
  if (qos > 0) {
    body.add(_u16Bytes(packetId ?? 0));
  }
  body.add(payload);

  var flags = 0;
  if (retain) {
    flags |= 0x01;
  }
  flags |= (qos & 0x03) << 1;
  // DUP (bit 3) intentionally left 0 — this codec only builds fresh sends.
  return _buildPacket((MqttPacketType.publish << 4) | flags, body.toBytes());
}

/// Builds a SUBSCRIBE packet (section 3.8). The fixed-header flags nibble is
/// the fixed `0b0010` the spec reserves for SUBSCRIBE.
Uint8List encodeSubscribe({
  required int packetId,
  required List<MqttTopicFilter> topicFilters,
}) {
  final body = BytesBuilder();
  body.add(_u16Bytes(packetId));
  for (final filter in topicFilters) {
    body.add(encodeMqttString(filter.topic));
    body.addByte(filter.qos & 0x03);
  }
  return _buildPacket((MqttPacketType.subscribe << 4) | 0x02, body.toBytes());
}

/// PINGREQ (section 3.12): fixed header only, no variable header/payload.
Uint8List encodePingReq() => Uint8List.fromList([MqttPacketType.pingreq << 4, 0x00]);

/// DISCONNECT (section 3.14): fixed header only, no variable header/payload.
Uint8List encodeDisconnect() => Uint8List.fromList([MqttPacketType.disconnect << 4, 0x00]);

// --- Packet parsers (never throw — null/empty means "drop") -----------------

/// Parses a CONNACK packet (section 3.2). Returns null if the packet isn't a
/// complete, well-typed CONNACK.
MqttConnack? parseConnack(Uint8List packet) {
  final body = _bodyOf(packet, MqttPacketType.connack);
  if (body == null || body.length < 2) {
    return null;
  }
  return MqttConnack((body[0] & 0x01) != 0, body[1]);
}

/// Parses a PUBACK packet (section 3.4) and returns its packet id, or null
/// if the packet isn't a complete, well-typed PUBACK.
int? parsePuback(Uint8List packet) {
  final body = _bodyOf(packet, MqttPacketType.puback);
  if (body == null || body.length < 2) {
    return null;
  }
  return _u16(body, 0);
}

/// Parses a SUBACK packet (section 3.9), or null if the packet isn't a
/// complete, well-typed SUBACK.
MqttSuback? parseSuback(Uint8List packet) {
  final body = _bodyOf(packet, MqttPacketType.suback);
  if (body == null || body.length < 2) {
    return null;
  }
  final packetId = _u16(body, 0);
  final codes = Uint8List.sublistView(body, 2);
  return MqttSuback(packetId, codes);
}

/// Parses an inbound PUBLISH packet (section 3.3), or null on anything
/// malformed/incomplete (bad topic-string framing, a QoS>0 publish too short
/// to carry its packet id, etc).
MqttPublish? parsePublish(Uint8List packet) {
  if (packet.isEmpty) {
    return null;
  }
  final typeAndFlags = packet[0];
  final type = (typeAndFlags >> 4) & 0x0F;
  if (type != MqttPacketType.publish) {
    return null;
  }
  final rl = decodeRemainingLength(packet, 1);
  if (rl == null) {
    return null;
  }
  final bodyStart = 1 + rl.bytesConsumed;
  final bodyEnd = bodyStart + rl.value;
  if (packet.length < bodyEnd) {
    return null;
  }

  final retain = (typeAndFlags & 0x01) != 0;
  final qos = (typeAndFlags >> 1) & 0x03;

  var offset = bodyStart;
  final topicResult = _decodeMqttString(packet, offset, bodyEnd);
  if (topicResult == null) {
    return null;
  }
  offset += topicResult.bytesConsumed;

  int? packetId;
  if (qos > 0) {
    if (offset + 2 > bodyEnd) {
      return null;
    }
    packetId = _u16(packet, offset);
    offset += 2;
  }

  final payload = Uint8List.sublistView(packet, offset, bodyEnd);
  return MqttPublish(
    topic: topicResult.value,
    payload: payload,
    qos: qos,
    packetId: packetId,
    retain: retain,
  );
}

// --- Streaming reassembler ---------------------------------------------------

/// Reassembles complete MQTT packets (fixed header + remaining-length +
/// body) out of an arbitrarily-chunked TCP byte stream: a packet may arrive
/// split across multiple [add] calls, or several packets may be coalesced
/// into one. Never throws — incomplete data is held for the next [add]
/// call, and an unrecoverable remaining-length (4 continuation bytes with no
/// terminator) is treated as garbage and skipped a byte at a time so the
/// buffer can never stall forever on corrupt input.
class MqttFrameBuffer {
  Uint8List _buf = Uint8List(0);

  /// Feeds newly-arrived bytes in and returns the list of complete packets
  /// (each a standalone `Uint8List` covering fixed header + remaining-length
  /// + body) that are now available. Returns an empty list when nothing new
  /// is complete yet; leftover bytes are retained for the next call.
  List<Uint8List> add(Uint8List chunk) {
    _buf = _concat(_buf, chunk);
    final packets = <Uint8List>[];
    while (_buf.isNotEmpty) {
      final rl = decodeRemainingLength(_buf, 1);
      if (rl == null) {
        if (_buf.length >= 5) {
          // >=5 bytes means the 4-byte varint window was fully available
          // and still didn't terminate: malformed, not just short. Drop the
          // leading (fixed header) byte and resync rather than waiting on
          // bytes that will never complete it.
          _buf = Uint8List.sublistView(_buf, 1);
          continue;
        }
        break; // genuinely need more bytes for the varint itself
      }
      final headerLen = 1 + rl.bytesConsumed;
      final total = headerLen + rl.value;
      if (_buf.length < total) {
        break; // need more bytes for the body
      }
      packets.add(Uint8List.fromList(_buf.sublist(0, total)));
      _buf = Uint8List.sublistView(_buf, total);
    }
    return packets;
  }
}

Uint8List _concat(Uint8List a, Uint8List b) {
  if (a.isEmpty) {
    return b;
  }
  if (b.isEmpty) {
    return a;
  }
  final out = Uint8List(a.length + b.length);
  out.setRange(0, a.length, a);
  out.setRange(a.length, a.length + b.length, b);
  return out;
}
