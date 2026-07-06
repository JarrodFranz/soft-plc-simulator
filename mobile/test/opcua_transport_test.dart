// Tests for the pure-Dart opc.tcp transport framing
// (mobile/lib/protocols/opcua/opcua_transport.dart).
//
// Wire layout cross-checked against the Rust `opcua` crate (v0.12.0) source:
//   core/comms/tcp_types.rs        (HEL/ACK/ERR message header + bodies)
//   core/comms/security_header.rs  (Asymmetric/Symmetric security header, sequence header)
//   core/comms/message_chunk.rs    (12-byte chunk header: 3-byte type + 1 chunk flag +
//                                    UInt32 size + UInt32 secureChannelId)
// vendored locally at:
//   C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/core/comms/
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_transport.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('MessageHeader', () {
    test('HEL/ACK/ERR/OPN/MSG/CLO all parse their 3-byte ASCII type', () {
      for (final type in ['HEL', 'ACK', 'ERR', 'OPN', 'MSG', 'CLO']) {
        final bytes = _bytes([
          ...type.codeUnits,
          'F'.codeUnitAt(0),
          8, 0, 0, 0,
        ]);
        final header = MessageHeader.parse(bytes);
        expect(header.messageType, type);
        expect(header.chunkType, 'F');
        expect(header.size, 8);
      }
    });

    test('unrecognized chunk flag byte still parses (validated by callers)', () {
      final bytes = _bytes([
        ...'MSG'.codeUnits,
        'C'.codeUnitAt(0),
        8, 0, 0, 0,
      ]);
      final header = MessageHeader.parse(bytes);
      expect(header.chunkType, 'C');
    });
  });

  group('HelloMessage', () {
    test('build then parse round-trips all fields', () {
      const hello = HelloMessage(
        protocolVersion: 0,
        receiveBufferSize: 65536,
        sendBufferSize: 65536,
        maxMessageSize: 0,
        maxChunkCount: 0,
        endpointUrl: 'opc.tcp://127.0.0.1:4840',
      );
      final frame = hello.build();
      final decoded = HelloMessage.parse(frame);
      expect(decoded.protocolVersion, 0);
      expect(decoded.receiveBufferSize, 65536);
      expect(decoded.sendBufferSize, 65536);
      expect(decoded.maxMessageSize, 0);
      expect(decoded.maxChunkCount, 0);
      expect(decoded.endpointUrl, 'opc.tcp://127.0.0.1:4840');
    });

    // FIXTURE: exact 8-byte header + body layout for a known HEL frame.
    // Derived by hand per OPC UA Part 6 and cross-checked against
    // tcp_types.rs HelloMessage::encode (message_header + 5 * u32 + endpoint_url string).
    test('known HEL frame fixture (exact bytes)', () {
      const hello = HelloMessage(
        protocolVersion: 0,
        receiveBufferSize: 65536,
        sendBufferSize: 65536,
        maxMessageSize: 0,
        maxChunkCount: 0,
        endpointUrl: 'opc.tcp://127.0.0.1:4840',
      );
      final frame = hello.build();
      expect(
        frame,
        _bytes([
          // 8-byte MessageHeader: 'H','E','L','F', size=56 LE
          0x48, 0x45, 0x4C, 0x46, 0x38, 0x00, 0x00, 0x00,
          // protocolVersion = 0
          0x00, 0x00, 0x00, 0x00,
          // receiveBufferSize = 65536
          0x00, 0x00, 0x01, 0x00,
          // sendBufferSize = 65536
          0x00, 0x00, 0x01, 0x00,
          // maxMessageSize = 0
          0x00, 0x00, 0x00, 0x00,
          // maxChunkCount = 0
          0x00, 0x00, 0x00, 0x00,
          // endpointUrl: Int32 length = 24, then UTF-8 bytes of
          // "opc.tcp://127.0.0.1:4840"
          0x18, 0x00, 0x00, 0x00,
          0x6f, 0x70, 0x63, 0x2e, 0x74, 0x63, 0x70, 0x3a,
          0x2f, 0x2f, 0x31, 0x32, 0x37, 0x2e, 0x30, 0x2e,
          0x30, 0x2e, 0x31, 0x3a, 0x34, 0x38, 0x34, 0x30,
        ]),
      );
      expect(frame.length, 56);
    });
  });

  group('AcknowledgeMessage', () {
    test('build then parse round-trips all fields', () {
      const ack = AcknowledgeMessage(
        protocolVersion: 0,
        receiveBufferSize: 65536,
        sendBufferSize: 65536,
        maxMessageSize: 1048576,
        maxChunkCount: 0,
      );
      final frame = ack.build();
      final decoded = AcknowledgeMessage.parse(frame);
      expect(decoded.protocolVersion, 0);
      expect(decoded.receiveBufferSize, 65536);
      expect(decoded.sendBufferSize, 65536);
      expect(decoded.maxMessageSize, 1048576);
      expect(decoded.maxChunkCount, 0);
    });

    test('header type is ACK and chunk flag is F', () {
      const ack = AcknowledgeMessage(
        protocolVersion: 0,
        receiveBufferSize: 8192,
        sendBufferSize: 8192,
        maxMessageSize: 0,
        maxChunkCount: 0,
      );
      final frame = ack.build();
      expect(String.fromCharCodes(frame.sublist(0, 3)), 'ACK');
      expect(String.fromCharCodes(frame.sublist(3, 4)), 'F');
    });
  });

  group('ErrorMessage', () {
    test('build then parse round-trips error code + reason', () {
      const err = ErrorMessage(error: 0x80010000, reason: 'Bad_Something');
      final frame = err.build();
      final decoded = ErrorMessage.parse(frame);
      expect(decoded.error, 0x80010000);
      expect(decoded.reason, 'Bad_Something');
    });

    test('null reason round-trips', () {
      const err = ErrorMessage(error: 0x80010000, reason: null);
      final frame = err.build();
      final decoded = ErrorMessage.parse(frame);
      expect(decoded.reason, isNull);
    });

    test('header type is ERR', () {
      const err = ErrorMessage(error: 0, reason: null);
      final frame = err.build();
      expect(String.fromCharCodes(frame.sublist(0, 3)), 'ERR');
    });
  });

  group('OPN chunk (asymmetric security header)', () {
    // FIXTURE: OPN chunk with the None policy URI, cross-checked against
    // security_header.rs AsymmetricSecurityHeader::none() (policy uri string,
    // null sender cert ByteString (-1), null receiver thumbprint ByteString (-1)).
    test('buildOpnChunk with None policy has expected header shape', () {
      final body = _bytes([0xAA, 0xBB]); // arbitrary service body for the test
      final chunk = buildOpnChunk(
        secureChannelId: 0,
        securityPolicyUri: 'http://opcfoundation.org/UA/SecurityPolicy#None',
        senderCertificate: null,
        receiverCertificateThumbprint: null,
        sequenceNumber: 1,
        requestId: 1,
        body: body,
      );

      // 12-byte chunk header: 'O','P','N', chunk flag 'F', UInt32 size, UInt32 secureChannelId(0)
      expect(String.fromCharCodes(chunk.sublist(0, 3)), 'OPN');
      expect(String.fromCharCodes(chunk.sublist(3, 4)), 'F');
      final size = ByteData.sublistView(chunk, 4, 8).getUint32(0, Endian.little);
      expect(size, chunk.length);
      final secureChannelId =
          ByteData.sublistView(chunk, 8, 12).getUint32(0, Endian.little);
      expect(secureChannelId, 0);

      // Asymmetric security header starts at byte 12: policy URI string.
      const uri = 'http://opcfoundation.org/UA/SecurityPolicy#None';
      final uriLen =
          ByteData.sublistView(chunk, 12, 16).getInt32(0, Endian.little);
      expect(uriLen, uri.length);
      final uriBytes = chunk.sublist(16, 16 + uriLen);
      expect(String.fromCharCodes(uriBytes), uri);

      // null sender certificate ByteString -> Int32 length -1
      final certLenOffset = 16 + uriLen;
      final certLen = ByteData.sublistView(chunk, certLenOffset, certLenOffset + 4)
          .getInt32(0, Endian.little);
      expect(certLen, -1);

      // null receiver thumbprint ByteString -> Int32 length -1
      final thumbOffset = certLenOffset + 4;
      final thumbLen = ByteData.sublistView(chunk, thumbOffset, thumbOffset + 4)
          .getInt32(0, Endian.little);
      expect(thumbLen, -1);
    });

    test('parseChunk decodes a built OPN chunk back to its parts', () {
      final body = _bytes([1, 2, 3, 4]);
      final chunk = buildOpnChunk(
        secureChannelId: 7,
        securityPolicyUri: 'http://opcfoundation.org/UA/SecurityPolicy#None',
        senderCertificate: null,
        receiverCertificateThumbprint: null,
        sequenceNumber: 5,
        requestId: 9,
        body: body,
      );
      final parsed = parseChunk(chunk);
      expect(parsed.messageType, 'OPN');
      expect(parsed.chunkType, 'F');
      expect(parsed.secureChannelId, 7);
      expect(parsed.sequenceNumber, 5);
      expect(parsed.requestId, 9);
      expect(parsed.body, body);
    });
  });

  group('MSG/CLO chunk (symmetric security header)', () {
    test('buildMsgChunk round-trips through parseChunk', () {
      final body = _bytes([9, 8, 7]);
      final chunk = buildMsgChunk(
        secureChannelId: 42,
        tokenId: 100,
        sequenceNumber: 2,
        requestId: 3,
        body: body,
      );
      final parsed = parseChunk(chunk);
      expect(parsed.messageType, 'MSG');
      expect(parsed.chunkType, 'F');
      expect(parsed.secureChannelId, 42);
      expect(parsed.tokenId, 100);
      expect(parsed.sequenceNumber, 2);
      expect(parsed.requestId, 3);
      expect(parsed.body, body);
    });

    test('buildCloChunk round-trips through parseChunk', () {
      final body = _bytes([1]);
      final chunk = buildCloChunk(
        secureChannelId: 42,
        tokenId: 100,
        sequenceNumber: 4,
        requestId: 5,
        body: body,
      );
      final parsed = parseChunk(chunk);
      expect(parsed.messageType, 'CLO');
      expect(parsed.secureChannelId, 42);
      expect(parsed.tokenId, 100);
      expect(parsed.body, body);
    });

    test('symmetric header token id sits right after the 12-byte chunk header', () {
      final chunk = buildMsgChunk(
        secureChannelId: 1,
        tokenId: 0xDEADBEEF,
        sequenceNumber: 1,
        requestId: 1,
        body: _bytes([0]),
      );
      final tokenId =
          ByteData.sublistView(chunk, 12, 16).getUint32(0, Endian.little);
      expect(tokenId, 0xDEADBEEF);
    });
  });

  group('Non-final chunk handling (v1 accepts only final)', () {
    test('parseChunk on a C (intermediate) chunk yields a typed non-final result, not a throw', () {
      final chunk = buildMsgChunk(
        secureChannelId: 1,
        tokenId: 1,
        sequenceNumber: 1,
        requestId: 1,
        body: _bytes([0, 1, 2]),
        chunkType: 'C',
      );
      final parsed = parseChunk(chunk);
      expect(parsed.chunkType, 'C');
      expect(parsed.isFinal, isFalse);
    });

    test('parseChunk on an A (abort) chunk yields a typed non-final result', () {
      final chunk = buildMsgChunk(
        secureChannelId: 1,
        tokenId: 1,
        sequenceNumber: 1,
        requestId: 1,
        body: _bytes([0]),
        chunkType: 'A',
      );
      final parsed = parseChunk(chunk);
      expect(parsed.chunkType, 'A');
      expect(parsed.isFinal, isFalse);
    });

    test('parseChunk on an F (final) chunk reports isFinal true', () {
      final chunk = buildMsgChunk(
        secureChannelId: 1,
        tokenId: 1,
        sequenceNumber: 1,
        requestId: 1,
        body: _bytes([0]),
      );
      final parsed = parseChunk(chunk);
      expect(parsed.isFinal, isTrue);
    });
  });

  group('Truncated / malformed input -> FormatException, never a hang', () {
    test('MessageHeader.parse on too-short buffer throws', () {
      expect(() => MessageHeader.parse(_bytes([1, 2, 3])), throwsFormatException);
    });

    test('HelloMessage.parse on truncated frame throws', () {
      final full = const HelloMessage(
        protocolVersion: 0,
        receiveBufferSize: 8192,
        sendBufferSize: 8192,
        maxMessageSize: 0,
        maxChunkCount: 0,
        endpointUrl: 'opc.tcp://x:1',
      ).build();
      final truncated = full.sublist(0, full.length - 5);
      expect(() => HelloMessage.parse(truncated), throwsFormatException);
    });

    test('parseChunk on a buffer shorter than the 12-byte chunk header throws', () {
      expect(() => parseChunk(_bytes([1, 2, 3])), throwsFormatException);
    });

    test('parseChunk on an unrecognized message type throws', () {
      final bytes = _bytes([
        ...'XYZ'.codeUnits,
        'F'.codeUnitAt(0),
        12, 0, 0, 0,
        0, 0, 0, 0,
      ]);
      expect(() => parseChunk(bytes), throwsFormatException);
    });

    test('parseChunk on a truncated OPN security header throws', () {
      final full = buildOpnChunk(
        secureChannelId: 0,
        securityPolicyUri: 'http://opcfoundation.org/UA/SecurityPolicy#None',
        senderCertificate: null,
        receiverCertificateThumbprint: null,
        sequenceNumber: 1,
        requestId: 1,
        body: _bytes([1, 2, 3]),
      );
      final truncated = full.sublist(0, 20);
      expect(() => parseChunk(truncated), throwsFormatException);
    });
  });
}
