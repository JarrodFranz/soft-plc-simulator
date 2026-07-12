// opc.tcp transport framing — pure Dart, no dart:io / Flutter imports.
// Connection-message codec (HEL/ACK/ERR) and secure-conversation chunk
// codec (OPN/MSG/CLO), per OPC UA Part 6.
//
// Wire layout cross-checked against the Rust `opcua` crate (v0.12.0),
// vendored locally at:
//   C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/core/comms/
// Specific files cited inline: tcp_types.rs (HEL/ACK/ERR), security_header.rs
// (Asymmetric/Symmetric security header + sequence header), message_chunk.rs
// (the 12-byte chunk header layout: 3-byte ASCII type + 1 chunk flag +
// UInt32 message size + UInt32 secureChannelId).
library opcua_transport;

import 'dart:convert';
import 'dart:typed_data';

/// The security policy URI for `SecurityPolicy#None` (the only policy v1
/// supports). Verified against opcua-0.12.0/src/types/mod.rs
/// `SECURITY_POLICY_NONE_URI`.
const String kSecurityPolicyNoneUri =
    'http://opcfoundation.org/UA/SecurityPolicy#None';

/// Size in bytes of the connection-message header (HEL/ACK/ERR): 3-byte
/// ASCII type + 1-byte chunk flag + UInt32 size. (tcp_types.rs `MESSAGE_HEADER_LEN`)
const int kMessageHeaderLen = 8;

/// Size in bytes of the secure-conversation chunk header (OPN/MSG/CLO):
/// 3-byte ASCII type + 1-byte chunk flag + UInt32 size + UInt32
/// secureChannelId. (message_chunk.rs `MESSAGE_CHUNK_HEADER_SIZE`)
const int kChunkHeaderLen = 12;

int _readU32LE(Uint8List data, int offset) {
  if (offset + 4 > data.length) {
    throw const FormatException('opc.tcp: truncated UInt32');
  }
  return ByteData.sublistView(data, offset, offset + 4)
      .getUint32(0, Endian.little);
}

void _writeU32LE(BytesBuilder builder, int value) {
  final b = ByteData(4)..setUint32(0, value, Endian.little);
  builder.add(b.buffer.asUint8List());
}

int _readI32LE(Uint8List data, int offset) {
  if (offset + 4 > data.length) {
    throw const FormatException('opc.tcp: truncated Int32');
  }
  return ByteData.sublistView(data, offset, offset + 4)
      .getInt32(0, Endian.little);
}

void _writeI32LE(BytesBuilder builder, int value) {
  final b = ByteData(4)..setInt32(0, value, Endian.little);
  builder.add(b.buffer.asUint8List());
}

void _writeString(BytesBuilder builder, String? value) {
  if (value == null) {
    _writeI32LE(builder, -1);
    return;
  }
  final bytes = utf8.encode(value);
  _writeI32LE(builder, bytes.length);
  builder.add(bytes);
}

String? _readString(Uint8List data, int offset, int Function(int) advance) {
  final len = _readI32LE(data, offset);
  advance(4);
  if (len == -1) return null;
  if (len < -1) {
    throw FormatException('opc.tcp: negative string length $len');
  }
  final start = offset + 4;
  if (start + len > data.length) {
    throw const FormatException('opc.tcp: truncated string body');
  }
  final bytes = data.sublist(start, start + len);
  advance(len);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('opc.tcp: string is not valid UTF-8');
  }
}

/// The 8-byte header shared by HEL/ACK/ERR (connection messages) and the
/// 3-byte type prefix used by OPN/MSG/CLO (secure-conversation chunks, which
/// have a longer 12-byte header — see [OpcChunk]).
class MessageHeader {
  final String messageType; // 'HEL' | 'ACK' | 'ERR' | 'OPN' | 'MSG' | 'CLO'
  final String chunkType; // 'F' | 'C' | 'A'
  final int size; // total message size including this header

  const MessageHeader({
    required this.messageType,
    required this.chunkType,
    required this.size,
  });

  static MessageHeader parse(Uint8List data) {
    if (data.length < kMessageHeaderLen) {
      throw const FormatException('opc.tcp: truncated message header');
    }
    final messageType = String.fromCharCodes(data.sublist(0, 3));
    final chunkType = String.fromCharCode(data[3]);
    final size = _readU32LE(data, 4);
    return MessageHeader(messageType: messageType, chunkType: chunkType, size: size);
  }

  Uint8List build() {
    final builder = BytesBuilder(copy: true);
    builder.add(ascii.encode(messageType));
    builder.add(ascii.encode(chunkType));
    _writeU32LE(builder, size);
    return builder.takeBytes();
  }
}

/// HEL — the client's opening handshake message.
class HelloMessage {
  final int protocolVersion;
  final int receiveBufferSize;
  final int sendBufferSize;
  final int maxMessageSize;
  final int maxChunkCount;
  final String endpointUrl;

  const HelloMessage({
    required this.protocolVersion,
    required this.receiveBufferSize,
    required this.sendBufferSize,
    required this.maxMessageSize,
    required this.maxChunkCount,
    required this.endpointUrl,
  });

  /// Builds the full HEL frame (8-byte header + body).
  Uint8List build() {
    final body = BytesBuilder(copy: true);
    _writeU32LE(body, protocolVersion);
    _writeU32LE(body, receiveBufferSize);
    _writeU32LE(body, sendBufferSize);
    _writeU32LE(body, maxMessageSize);
    _writeU32LE(body, maxChunkCount);
    _writeString(body, endpointUrl);
    final bodyBytes = body.takeBytes();

    final header = MessageHeader(
      messageType: 'HEL',
      chunkType: 'F',
      size: kMessageHeaderLen + bodyBytes.length,
    );
    final frame = BytesBuilder(copy: true);
    frame.add(header.build());
    frame.add(bodyBytes);
    return frame.takeBytes();
  }

  static HelloMessage parse(Uint8List frame) {
    final header = MessageHeader.parse(frame);
    if (header.messageType != 'HEL') {
      throw FormatException('opc.tcp: expected HEL, got ${header.messageType}');
    }
    if (frame.length < header.size) {
      throw const FormatException('opc.tcp: truncated HEL frame');
    }
    var offset = kMessageHeaderLen;
    int need(int n) {
      if (offset + n > frame.length) {
        throw const FormatException('opc.tcp: truncated HEL body');
      }
      final at = offset;
      offset += n;
      return at;
    }

    final protocolVersion = _readU32LE(frame, need(4));
    final receiveBufferSize = _readU32LE(frame, need(4));
    final sendBufferSize = _readU32LE(frame, need(4));
    final maxMessageSize = _readU32LE(frame, need(4));
    final maxChunkCount = _readU32LE(frame, need(4));
    final urlStart = offset;
    final endpointUrl = _readString(frame, urlStart, (n) => offset += n);
    if (endpointUrl == null) {
      throw const FormatException('opc.tcp: HEL endpointUrl must not be null');
    }
    return HelloMessage(
      protocolVersion: protocolVersion,
      receiveBufferSize: receiveBufferSize,
      sendBufferSize: sendBufferSize,
      maxMessageSize: maxMessageSize,
      maxChunkCount: maxChunkCount,
      endpointUrl: endpointUrl,
    );
  }
}

/// ACK — the server's reply to HEL, negotiating buffer sizes.
class AcknowledgeMessage {
  final int protocolVersion;
  final int receiveBufferSize;
  final int sendBufferSize;
  final int maxMessageSize;
  final int maxChunkCount;

  const AcknowledgeMessage({
    required this.protocolVersion,
    required this.receiveBufferSize,
    required this.sendBufferSize,
    required this.maxMessageSize,
    required this.maxChunkCount,
  });

  Uint8List build() {
    final body = BytesBuilder(copy: true);
    _writeU32LE(body, protocolVersion);
    _writeU32LE(body, receiveBufferSize);
    _writeU32LE(body, sendBufferSize);
    _writeU32LE(body, maxMessageSize);
    _writeU32LE(body, maxChunkCount);
    final bodyBytes = body.takeBytes();

    final header = MessageHeader(
      messageType: 'ACK',
      chunkType: 'F',
      size: kMessageHeaderLen + bodyBytes.length,
    );
    final frame = BytesBuilder(copy: true);
    frame.add(header.build());
    frame.add(bodyBytes);
    return frame.takeBytes();
  }

  static AcknowledgeMessage parse(Uint8List frame) {
    final header = MessageHeader.parse(frame);
    if (header.messageType != 'ACK') {
      throw FormatException('opc.tcp: expected ACK, got ${header.messageType}');
    }
    if (frame.length < kMessageHeaderLen + 20) {
      throw const FormatException('opc.tcp: truncated ACK frame');
    }
    var offset = kMessageHeaderLen;
    int next() {
      final at = offset;
      offset += 4;
      return at;
    }

    return AcknowledgeMessage(
      protocolVersion: _readU32LE(frame, next()),
      receiveBufferSize: _readU32LE(frame, next()),
      sendBufferSize: _readU32LE(frame, next()),
      maxMessageSize: _readU32LE(frame, next()),
      maxChunkCount: _readU32LE(frame, next()),
    );
  }
}

/// ERR — a fatal connection-level error, sent just before closing.
class ErrorMessage {
  final int error;
  final String? reason;

  const ErrorMessage({required this.error, this.reason});

  Uint8List build() {
    final body = BytesBuilder(copy: true);
    _writeU32LE(body, error);
    _writeString(body, reason);
    final bodyBytes = body.takeBytes();

    final header = MessageHeader(
      messageType: 'ERR',
      chunkType: 'F',
      size: kMessageHeaderLen + bodyBytes.length,
    );
    final frame = BytesBuilder(copy: true);
    frame.add(header.build());
    frame.add(bodyBytes);
    return frame.takeBytes();
  }

  static ErrorMessage parse(Uint8List frame) {
    final header = MessageHeader.parse(frame);
    if (header.messageType != 'ERR') {
      throw FormatException('opc.tcp: expected ERR, got ${header.messageType}');
    }
    if (frame.length < kMessageHeaderLen + 4) {
      throw const FormatException('opc.tcp: truncated ERR frame');
    }
    var offset = kMessageHeaderLen;
    final error = _readU32LE(frame, offset);
    offset += 4;
    final reason = _readString(frame, offset, (n) => offset += n);
    return ErrorMessage(error: error, reason: reason);
  }
}

/// A parsed secure-conversation chunk (OPN/MSG/CLO). For OPN,
/// [securityPolicyUri]/[senderCertificate]/[receiverCertificateThumbprint]
/// are populated and [tokenId] is null; for MSG/CLO, [tokenId] is populated
/// and the asymmetric-header fields are null.
class OpcChunk {
  final String messageType; // 'OPN' | 'MSG' | 'CLO'
  final String chunkType; // 'F' | 'C' | 'A'
  final int secureChannelId;
  final String? securityPolicyUri;
  final List<int>? senderCertificate;
  final List<int>? receiverCertificateThumbprint;
  final int? tokenId;
  final int sequenceNumber;
  final int requestId;
  final Uint8List body;

  bool get isFinal => chunkType == 'F';

  const OpcChunk({
    required this.messageType,
    required this.chunkType,
    required this.secureChannelId,
    this.securityPolicyUri,
    this.senderCertificate,
    this.receiverCertificateThumbprint,
    this.tokenId,
    required this.sequenceNumber,
    required this.requestId,
    required this.body,
  });
}

/// Parses any OPN/MSG/CLO chunk. Malformed/truncated input throws
/// [FormatException] — never hangs, never throws an unrelated exception.
/// A non-final ('C' intermediate or 'A' abort) chunk is returned as a
/// typed [OpcChunk] with `isFinal == false` rather than throwing — v1 only
/// supports single-chunk ('F') messages, so the session layer is expected to
/// reject non-final chunks cleanly using this flag.
OpcChunk parseChunk(Uint8List data) {
  if (data.length < kChunkHeaderLen) {
    throw const FormatException('opc.tcp: truncated chunk header');
  }
  final messageType = String.fromCharCodes(data.sublist(0, 3));
  if (messageType != 'OPN' && messageType != 'MSG' && messageType != 'CLO') {
    throw FormatException('opc.tcp: unrecognized chunk message type "$messageType"');
  }
  final chunkType = String.fromCharCode(data[3]);
  if (chunkType != 'F' && chunkType != 'C' && chunkType != 'A') {
    throw FormatException('opc.tcp: unrecognized chunk flag "$chunkType"');
  }
  final size = _readU32LE(data, 4);
  final secureChannelId = _readU32LE(data, 8);
  if (data.length < size) {
    throw const FormatException('opc.tcp: chunk shorter than declared size');
  }

  var offset = kChunkHeaderLen;
  int need(int n) {
    if (offset + n > data.length) {
      throw const FormatException('opc.tcp: truncated chunk security/sequence header');
    }
    final at = offset;
    offset += n;
    return at;
  }

  String? securityPolicyUri;
  List<int>? senderCertificate;
  List<int>? receiverCertificateThumbprint;
  int? tokenId;

  if (messageType == 'OPN') {
    final uriStart = offset;
    securityPolicyUri = _readString(data, uriStart, (n) => offset += n);
    final certLen = _readI32LE(data, offset);
    offset += 4;
    if (certLen == -1) {
      senderCertificate = null;
    } else if (certLen < -1) {
      throw const FormatException('opc.tcp: negative sender certificate length');
    } else {
      final start = offset;
      if (start + certLen > data.length) {
        throw const FormatException('opc.tcp: truncated sender certificate');
      }
      senderCertificate = data.sublist(start, start + certLen);
      offset += certLen;
    }

    final thumbLen = _readI32LE(data, offset);
    offset += 4;
    if (thumbLen == -1) {
      receiverCertificateThumbprint = null;
    } else if (thumbLen < -1) {
      throw const FormatException('opc.tcp: negative receiver thumbprint length');
    } else {
      final start = offset;
      if (start + thumbLen > data.length) {
        throw const FormatException('opc.tcp: truncated receiver thumbprint');
      }
      receiverCertificateThumbprint = data.sublist(start, start + thumbLen);
      offset += thumbLen;
    }
  } else {
    tokenId = _readU32LE(data, need(4));
  }

  final sequenceNumber = _readU32LE(data, need(4));
  final requestId = _readU32LE(data, need(4));

  if (offset > size) {
    throw const FormatException('opc.tcp: chunk header longer than declared size');
  }
  final body = data.sublist(offset, size);

  return OpcChunk(
    messageType: messageType,
    chunkType: chunkType,
    secureChannelId: secureChannelId,
    securityPolicyUri: securityPolicyUri,
    senderCertificate: senderCertificate,
    receiverCertificateThumbprint: receiverCertificateThumbprint,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
}

/// The plaintext chunk header + security header of an OPN/MSG/CLO chunk,
/// parsed WITHOUT touching the (possibly encrypted) sequence-header+body that
/// follows. For a secured chunk the bytes `frame[securityHeaderEnd..size]` are
/// signed+encrypted and must be handed to the secure channel to decrypt before
/// the sequence header can be read — [parseChunk] cannot be used there because
/// it assumes the remainder is plaintext.
///
/// [securityHeaderEnd] is the offset at which the (encrypted) remainder begins,
/// i.e. immediately after the asymmetric security header (OPN) or the symmetric
/// security header (MSG/CLO). The signed range used by the secure channel is
/// exactly `frame[0..securityHeaderEnd]` ++ the decrypted remainder-minus-
/// signature (mirrors `secure_channel.rs` `asymmetric_decrypt_and_verify`).
class OpcChunkHeader {
  final String messageType; // 'OPN' | 'MSG' | 'CLO'
  final String chunkType; // 'F' | 'C' | 'A'
  final int size; // total on-wire chunk size (message header `messageSize`)
  final int secureChannelId;
  final String? securityPolicyUri; // OPN only
  final List<int>? senderCertificate; // OPN only
  final List<int>? receiverCertificateThumbprint; // OPN only
  final int? tokenId; // MSG/CLO only
  final int securityHeaderEnd; // offset where the secured remainder begins

  bool get isFinal => chunkType == 'F';

  const OpcChunkHeader({
    required this.messageType,
    required this.chunkType,
    required this.size,
    required this.secureChannelId,
    this.securityPolicyUri,
    this.senderCertificate,
    this.receiverCertificateThumbprint,
    this.tokenId,
    required this.securityHeaderEnd,
  });
}

/// Parses ONLY the chunk header (12 bytes) + security header of an OPN/MSG/CLO
/// chunk — all of which are plaintext on the wire even for a secured chunk. The
/// bytes from [OpcChunkHeader.securityHeaderEnd] to `size` are the secured
/// remainder (sequence header + body + padding + signature, encrypted) which
/// the secure channel decrypts. Malformed/truncated input throws
/// [FormatException] — never hangs, never throws an unrelated exception.
OpcChunkHeader parseChunkHeader(Uint8List frame) {
  if (frame.length < kChunkHeaderLen) {
    throw const FormatException('opc.tcp: truncated chunk header');
  }
  final messageType = String.fromCharCodes(frame.sublist(0, 3));
  if (messageType != 'OPN' && messageType != 'MSG' && messageType != 'CLO') {
    throw FormatException('opc.tcp: unrecognized chunk message type "$messageType"');
  }
  final chunkType = String.fromCharCode(frame[3]);
  if (chunkType != 'F' && chunkType != 'C' && chunkType != 'A') {
    throw FormatException('opc.tcp: unrecognized chunk flag "$chunkType"');
  }
  final size = _readU32LE(frame, 4);
  final secureChannelId = _readU32LE(frame, 8);
  if (frame.length < size) {
    throw const FormatException('opc.tcp: chunk shorter than declared size');
  }

  var offset = kChunkHeaderLen;
  String? securityPolicyUri;
  List<int>? senderCertificate;
  List<int>? receiverCertificateThumbprint;
  int? tokenId;

  if (messageType == 'OPN') {
    securityPolicyUri = _readString(frame, offset, (n) => offset += n);
    final certLen = _readI32LE(frame, offset);
    offset += 4;
    if (certLen == -1) {
      senderCertificate = null;
    } else if (certLen < -1) {
      throw const FormatException('opc.tcp: negative sender certificate length');
    } else {
      final start = offset;
      if (start + certLen > frame.length) {
        throw const FormatException('opc.tcp: truncated sender certificate');
      }
      senderCertificate = frame.sublist(start, start + certLen);
      offset += certLen;
    }

    final thumbLen = _readI32LE(frame, offset);
    offset += 4;
    if (thumbLen == -1) {
      receiverCertificateThumbprint = null;
    } else if (thumbLen < -1) {
      throw const FormatException('opc.tcp: negative receiver thumbprint length');
    } else {
      final start = offset;
      if (start + thumbLen > frame.length) {
        throw const FormatException('opc.tcp: truncated receiver thumbprint');
      }
      receiverCertificateThumbprint = frame.sublist(start, start + thumbLen);
      offset += thumbLen;
    }
  } else {
    if (offset + 4 > frame.length) {
      throw const FormatException('opc.tcp: truncated symmetric security header');
    }
    tokenId = _readU32LE(frame, offset);
    offset += 4;
  }

  if (offset > size) {
    throw const FormatException('opc.tcp: security header longer than declared size');
  }

  return OpcChunkHeader(
    messageType: messageType,
    chunkType: chunkType,
    size: size,
    secureChannelId: secureChannelId,
    securityPolicyUri: securityPolicyUri,
    senderCertificate: senderCertificate,
    receiverCertificateThumbprint: receiverCertificateThumbprint,
    tokenId: tokenId,
    securityHeaderEnd: offset,
  );
}

Uint8List _buildChunk({
  required String messageType,
  required String chunkType,
  required int secureChannelId,
  required BytesBuilder securityHeader,
  required int sequenceNumber,
  required int requestId,
  required Uint8List body,
}) {
  final securityHeaderBytes = securityHeader.takeBytes();
  final sequenceHeader = BytesBuilder(copy: true);
  _writeU32LE(sequenceHeader, sequenceNumber);
  _writeU32LE(sequenceHeader, requestId);
  final sequenceHeaderBytes = sequenceHeader.takeBytes();

  final totalSize = kChunkHeaderLen +
      securityHeaderBytes.length +
      sequenceHeaderBytes.length +
      body.length;

  final frame = BytesBuilder(copy: true);
  frame.add(ascii.encode(messageType));
  frame.add(ascii.encode(chunkType));
  _writeU32LE(frame, totalSize);
  _writeU32LE(frame, secureChannelId);
  frame.add(securityHeaderBytes);
  frame.add(sequenceHeaderBytes);
  frame.add(body);
  return frame.takeBytes();
}

/// Builds an OPN (OpenSecureChannel) chunk with the asymmetric security
/// header: policy URI String + sender-certificate ByteString (null for
/// `SecurityPolicy#None`) + receiver-certificate-thumbprint ByteString
/// (also null). (security_header.rs `AsymmetricSecurityHeader::none()`)
Uint8List buildOpnChunk({
  required int secureChannelId,
  required String securityPolicyUri,
  List<int>? senderCertificate,
  List<int>? receiverCertificateThumbprint,
  required int sequenceNumber,
  required int requestId,
  required Uint8List body,
  String chunkType = 'F',
}) {
  final securityHeader = BytesBuilder(copy: true);
  _writeString(securityHeader, securityPolicyUri);
  _writeByteString(securityHeader, senderCertificate);
  _writeByteString(securityHeader, receiverCertificateThumbprint);

  return _buildChunk(
    messageType: 'OPN',
    chunkType: chunkType,
    secureChannelId: secureChannelId,
    securityHeader: securityHeader,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
}

/// Builds a MSG chunk with the symmetric security header (UInt32 tokenId).
/// (security_header.rs `SymmetricSecurityHeader`)
Uint8List buildMsgChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required Uint8List body,
  String chunkType = 'F',
}) {
  final securityHeader = BytesBuilder(copy: true);
  _writeU32LE(securityHeader, tokenId);

  return _buildChunk(
    messageType: 'MSG',
    chunkType: chunkType,
    secureChannelId: secureChannelId,
    securityHeader: securityHeader,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
}

/// Builds a CLO (CloseSecureChannel) chunk with the symmetric security
/// header (UInt32 tokenId) — same shape as MSG.
Uint8List buildCloChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required Uint8List body,
  String chunkType = 'F',
}) {
  final securityHeader = BytesBuilder(copy: true);
  _writeU32LE(securityHeader, tokenId);

  return _buildChunk(
    messageType: 'CLO',
    chunkType: chunkType,
    secureChannelId: secureChannelId,
    securityHeader: securityHeader,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
}

void _writeByteString(BytesBuilder builder, List<int>? value) {
  if (value == null) {
    _writeI32LE(builder, -1);
    return;
  }
  _writeI32LE(builder, value.length);
  builder.add(Uint8List.fromList(value));
}
