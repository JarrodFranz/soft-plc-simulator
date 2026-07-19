// Byte-exact fixtures for the EtherNet/IP encapsulation codec
// (mobile/lib/protocols/enip/enip_encap.dart): the 24-byte encapsulation
// header and the Common Packet Format (CPF) item list it carries. Verified
// against public EtherNet/IP encapsulation specification material — no
// hand-rolled server logic here, just the pure wire-format encode/decode
// helpers.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/enip/enip_encap.dart';

void main() {
  group('EnipHeader parsing', () {
    test('parseEnipHeader decodes a hand-built 24-byte header (little-endian)', () {
      final bytes = Uint8List.fromList([
        0x65, 0x00, // command = RegisterSession (0x0065), LE
        0x04, 0x00, // length = 4, LE
        0x78, 0x56, 0x34, 0x12, // sessionHandle = 0x12345678, LE
        0x01, 0x00, 0x00, 0x00, // status = 1, LE
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // senderContext (8 raw bytes)
        0xAA, 0xBB, 0xCC, 0xDD, // options = 0xDDCCBBAA, LE
      ]);
      expect(bytes.length, kEnipHeaderLen);

      final header = parseEnipHeader(bytes);
      expect(header, isNotNull);
      expect(header!.command, kEnipCommandRegisterSession);
      expect(header.length, 4);
      expect(header.sessionHandle, 0x12345678);
      expect(header.status, 1);
      expect(header.senderContext, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
      expect(header.options, 0xDDCCBBAA);
    });

    test('parseEnipHeader returns null for a buffer shorter than 24 bytes', () {
      expect(parseEnipHeader(Uint8List(0)), isNull);
      expect(parseEnipHeader(Uint8List(kEnipHeaderLen - 1)), isNull);
    });

    test('buildEnipFrame round-trips through parseEnipHeader and sets length to the data length', () {
      final context = Uint8List.fromList([9, 8, 7, 6, 5, 4, 3, 2]);
      final original = EnipHeader(
        command: kEnipCommandSendRRData,
        length: 0, // deliberately wrong — buildEnipFrame must derive it from data.
        sessionHandle: 0xCAFEBABE,
        status: 0,
        senderContext: context,
        options: 0,
      );
      final data = Uint8List.fromList([0x11, 0x22, 0x33, 0x44, 0x55]);
      final frame = buildEnipFrame(original, data);

      expect(frame.length, kEnipHeaderLen + data.length);
      expect(frame.sublist(kEnipHeaderLen), data);

      final roundTripped = parseEnipHeader(frame);
      expect(roundTripped, isNotNull);
      expect(roundTripped!.command, kEnipCommandSendRRData);
      expect(roundTripped.length, data.length);
      expect(roundTripped.sessionHandle, 0xCAFEBABE);
      expect(roundTripped.status, 0);
      expect(roundTripped.senderContext, context);
      expect(roundTripped.options, 0);
    });
  });

  group('CPF (Common Packet Format)', () {
    test('parseCpf/buildCpf round-trip a 2-item list (Null Address + Unconnected Data)', () {
      final items = [
        CpfItem(typeId: kCpfTypeNullAddress, data: Uint8List(0)),
        CpfItem(typeId: kCpfTypeUnconnectedData, data: Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])),
      ];
      final built = buildCpf(items);

      // item count (2) + [typeId(2)+len(2)+data(0)] + [typeId(2)+len(2)+data(4)]
      expect(built.length, 2 + (4 + 0) + (4 + 4));

      final parsed = parseCpf(built);
      expect(parsed, isNotNull);
      expect(parsed!.length, 2);
      expect(parsed[0].typeId, kCpfTypeNullAddress);
      expect(parsed[0].data, isEmpty);
      expect(parsed[1].typeId, kCpfTypeUnconnectedData);
      expect(parsed[1].data, [0xDE, 0xAD, 0xBE, 0xEF]);
    });

    test('parseCpf returns null on a truncated item (declared length exceeds available bytes)', () {
      // Declares 1 item, typeId=0x00B2, length=10, but supplies 0 bytes of data.
      final truncated = Uint8List.fromList([
        0x01, 0x00, // item count = 1
        0xB2, 0x00, // typeId = Unconnected Data
        0x0A, 0x00, // declared length = 10
        // no data bytes follow
      ]);
      expect(parseCpf(truncated), isNull);
    });

    test('parseCpf returns null when the item header itself is truncated', () {
      final truncated = Uint8List.fromList([0x01, 0x00, 0xB2, 0x00]); // missing length field
      expect(parseCpf(truncated), isNull);
    });

    test('parseCpf returns null on an empty buffer', () {
      expect(parseCpf(Uint8List(0)), isNull);
    });
  });

  group('RegisterSession scenario', () {
    test('a RegisterSession request body parses and the built reply echoes session handle + sender context',
        () {
      final requestContext = Uint8List.fromList([0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8]);
      final requestBody = Uint8List.fromList([
        0x01, 0x00, // protocol version = 1, LE
        0x00, 0x00, // options = 0, LE
      ]);
      final requestHeader = EnipHeader(
        command: kEnipCommandRegisterSession,
        length: 0,
        sessionHandle: 0, // client doesn't have a session yet.
        status: 0,
        senderContext: requestContext,
        options: 0,
      );
      final requestFrame = buildEnipFrame(requestHeader, requestBody);

      final parsedRequestHeader = parseEnipHeader(requestFrame);
      expect(parsedRequestHeader, isNotNull);
      expect(parsedRequestHeader!.command, kEnipCommandRegisterSession);
      expect(parsedRequestHeader.length, requestBody.length);
      expect(parsedRequestHeader.senderContext, requestContext);

      final parsedRequestBody = requestFrame.sublist(kEnipHeaderLen);
      expect(parsedRequestBody, requestBody);

      // Server assigns a session handle and echoes back the same sender
      // context and the same body layout (protocol version + options).
      const assignedSessionHandle = 42;
      final replyHeader = EnipHeader(
        command: kEnipCommandRegisterSession,
        length: 0,
        sessionHandle: assignedSessionHandle,
        status: 0,
        senderContext: parsedRequestHeader.senderContext,
        options: 0,
      );
      final replyFrame = buildEnipFrame(replyHeader, requestBody);

      final parsedReplyHeader = parseEnipHeader(replyFrame);
      expect(parsedReplyHeader, isNotNull);
      expect(parsedReplyHeader!.sessionHandle, assignedSessionHandle);
      expect(parsedReplyHeader.senderContext, requestContext);
    });
  });
}
