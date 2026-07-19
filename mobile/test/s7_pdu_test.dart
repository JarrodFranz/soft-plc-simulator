// Byte-exact fixtures for the S7 protocol PDU codec
// (mobile/lib/protocols/s7/s7_pdu.dart) — the message layer that rides
// inside a COTP data packet (mobile/lib/protocols/s7/tpkt_cotp.dart).
//
// CRITICAL #1: the S7 header is 12 BYTES on Ack_Data (rosctr 0x03) and 10
// BYTES otherwise — errorClass/errorCode are present only on Ack_Data. Every
// byte after the header shifts by 2 if this conditional is wrong, so the Job
// and Ack_Data cases are written and asserted as a PAIR below.
//
// CRITICAL #2: S7comm is BIG-ENDIAN throughout, like the transport layer
// beneath it, unlike the little-endian EtherNet/IP codec elsewhere in this
// repo. A pure build -> parse round trip cannot catch an endianness bug (it
// cancels out perfectly even when fully broken), so every fixture asserts
// literal expected bytes against hand-built buffers, and every multi-byte
// reference value below (e.g. pduReference 0x12, 0x34 -> 0x1234) has two
// bytes that differ from each other, so a little-endian implementation
// fails instead of passing.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/s7/s7_pdu.dart';

void main() {
  group('S7 header — Job (10-byte) vs Ack_Data (12-byte) pair', () {
    test('parseS7 decodes a hand-built Job (rosctr 0x01) with a 10-byte header', () {
      final bytes = Uint8List.fromList([
        0x32, // protocolId
        0x01, // rosctr = Job
        0x00, 0x00, // redundancyId
        0x12, 0x34, // pduReference = 0x1234 (bytes differ -> catches little-endian)
        0x00, 0x02, // parameterLength = 2
        0x00, 0x03, // dataLength = 3
        // -- no errorClass/errorCode for Job --
        0xAA, 0xBB, // parameter (2 bytes)
        0x01, 0x02, 0x03, // data (3 bytes)
      ]);
      expect(bytes.length, 15); // 10 (header) + 2 (parameter) + 3 (data)

      final msg = parseS7(bytes);
      expect(msg, isNotNull);
      expect(msg!.header.rosctr, kS7RosctrJob);
      expect(msg.header.pduReference, 0x1234);
      expect(msg.header.pduReference, isNot(0x3412)); // little-endian canary
      expect(msg.header.parameterLength, 2);
      expect(msg.header.dataLength, 3);
      expect(msg.header.errorClass, 0);
      expect(msg.header.errorCode, 0);
      expect(msg.parameter, equals(Uint8List.fromList([0xAA, 0xBB])));
      expect(msg.data, equals(Uint8List.fromList([0x01, 0x02, 0x03])));
    });

    test('parseS7 decodes a hand-built Ack_Data (rosctr 0x03) with a 12-byte header, '
        'exposing errorClass/errorCode and slicing parameter 2 bytes later than the Job case', () {
      final bytes = Uint8List.fromList([
        0x32, // protocolId
        0x03, // rosctr = Ack_Data
        0x00, 0x00, // redundancyId
        0x12, 0x34, // pduReference = 0x1234 (same as Job case, for direct comparison)
        0x00, 0x02, // parameterLength = 2
        0x00, 0x03, // dataLength = 3
        0x02, 0x05, // errorClass=0x02, errorCode=0x05 -- ONLY present because rosctr==0x03
        0xAA, 0xBB, // parameter (2 bytes) -- starts at offset 12, not 10
        0x01, 0x02, 0x03, // data (3 bytes)
      ]);
      expect(bytes.length, 17); // 12 (header) + 2 (parameter) + 3 (data)

      final msg = parseS7(bytes);
      expect(msg, isNotNull);
      expect(msg!.header.rosctr, kS7RosctrAckData);
      expect(msg.header.pduReference, 0x1234);
      expect(msg.header.parameterLength, 2);
      expect(msg.header.dataLength, 3);
      expect(msg.header.errorClass, 0x02);
      expect(msg.header.errorCode, 0x05);
      // The point of this pair: parameter/data land at the SAME logical
      // content but 2 bytes further into the buffer than the Job case.
      expect(msg.parameter, equals(Uint8List.fromList([0xAA, 0xBB])));
      expect(msg.data, equals(Uint8List.fromList([0x01, 0x02, 0x03])));
    });

    test('buildS7 round-trips both Job and Ack_Data, emitting errorClass/errorCode bytes '
        'ONLY for Ack_Data, and the emitted total length differs by exactly 2', () {
      final parameter = Uint8List.fromList([0xAA, 0xBB]);
      final data = Uint8List.fromList([0x01, 0x02, 0x03]);

      final job = buildS7(
        rosctr: kS7RosctrJob,
        pduReference: 0x1234,
        parameter: parameter,
        data: data,
      );
      // Literal expected bytes -- not just a round-trip -- so an endianness
      // bug shared between buildS7 and parseS7 cannot cancel out silently.
      expect(
        job,
        equals(Uint8List.fromList([
          0x32, 0x01, 0x00, 0x00, 0x12, 0x34, 0x00, 0x02, 0x00, 0x03, //
          0xAA, 0xBB, 0x01, 0x02, 0x03,
        ])),
      );
      expect(job.length, 15);

      final ackData = buildS7(
        rosctr: kS7RosctrAckData,
        pduReference: 0x1234,
        parameter: parameter,
        data: data,
        errorClass: 0x02,
        errorCode: 0x05,
      );
      expect(
        ackData,
        equals(Uint8List.fromList([
          0x32, 0x03, 0x00, 0x00, 0x12, 0x34, 0x00, 0x02, 0x00, 0x03, //
          0x02, 0x05, // errorClass, errorCode -- ONLY present here
          0xAA, 0xBB, 0x01, 0x02, 0x03,
        ])),
      );
      expect(ackData.length, 17);

      // The header-length conditional must produce EXACTLY a 2-byte
      // difference in total emitted length between the two ROSCTRs.
      expect(ackData.length - job.length, 2);

      final parsedJob = parseS7(job);
      expect(parsedJob, isNotNull);
      expect(parsedJob!.header.rosctr, kS7RosctrJob);
      expect(parsedJob.header.pduReference, 0x1234);
      expect(parsedJob.header.errorClass, 0);
      expect(parsedJob.header.errorCode, 0);
      expect(parsedJob.parameter, equals(parameter));
      expect(parsedJob.data, equals(data));

      final parsedAckData = parseS7(ackData);
      expect(parsedAckData, isNotNull);
      expect(parsedAckData!.header.rosctr, kS7RosctrAckData);
      expect(parsedAckData.header.pduReference, 0x1234);
      expect(parsedAckData.header.errorClass, 0x02);
      expect(parsedAckData.header.errorCode, 0x05);
      expect(parsedAckData.parameter, equals(parameter));
      expect(parsedAckData.data, equals(data));
    });
  });

  group('parseS7 malformed input never throws', () {
    test('returns null when the buffer is shorter than the (10-byte) common header', () {
      final bytes = Uint8List.fromList([0x32, 0x01, 0x00, 0x00, 0x12, 0x34, 0x00, 0x02, 0x00]);
      expect(bytes.length, 9);
      expect(() => parseS7(bytes), returnsNormally);
      expect(parseS7(bytes), isNull);
    });

    test('returns null when rosctr is Ack_Data but the buffer is one byte short of the 12-byte header', () {
      final bytes = Uint8List.fromList([
        0x32, 0x03, 0x00, 0x00, 0x12, 0x34, 0x00, 0x00, 0x00, 0x00, // common 10 bytes
        0x02, // only errorClass present, errorCode missing
      ]);
      expect(bytes.length, 11);
      expect(() => parseS7(bytes), returnsNormally);
      expect(parseS7(bytes), isNull);
    });

    test('returns null when protocolId != 0x32', () {
      final bytes = Uint8List.fromList([
        0x33, 0x01, 0x00, 0x00, 0x12, 0x34, 0x00, 0x00, 0x00, 0x00,
      ]);
      expect(() => parseS7(bytes), returnsNormally);
      expect(parseS7(bytes), isNull);
    });

    test('returns null when parameterLength + dataLength overruns the buffer', () {
      final bytes = Uint8List.fromList([
        0x32, 0x01, 0x00, 0x00, 0x12, 0x34, //
        0x00, 0x05, // parameterLength = 5
        0x00, 0x05, // dataLength = 5 (declares 10 bytes; only 3 actually follow)
        0xAA, 0xBB, 0xCC,
      ]);
      expect(() => parseS7(bytes), returnsNormally);
      expect(parseS7(bytes), isNull);
    });
  });

  group('Setup Communication', () {
    test('parseSetupCommunication extracts pduLength (and the AMQ fields) big-endian from a hand-built parameter', () {
      final parameter = Uint8List.fromList([
        0xF0, // function = Setup Communication
        0x00, // reserved
        0x01, 0x02, // maxAmqCalling = 0x0102 (258)
        0x03, 0x04, // maxAmqCalled = 0x0304 (772)
        0x01, 0xE0, // pduLength = 0x01E0 (480)
      ]);
      final setup = parseSetupCommunication(parameter);
      expect(setup, isNotNull);
      expect(setup!.function, kS7FunctionSetupCommunication);
      expect(setup.maxAmqCalling, 258);
      expect(setup.maxAmqCalled, 772);
      expect(setup.pduLength, 480);
      expect(setup.pduLength, isNot(0xE001)); // little-endian canary
    });

    test('parseSetupCommunication returns null on a truncated parameter', () {
      final parameter = Uint8List.fromList([0xF0, 0x00, 0x01, 0x02]);
      expect(() => parseSetupCommunication(parameter), returnsNormally);
      expect(parseSetupCommunication(parameter), isNull);
    });

    test('buildSetupCommunicationReply round-trips through parseSetupCommunication', () {
      final reply = buildSetupCommunicationReply(
        maxAmqCalling: 258,
        maxAmqCalled: 772,
        pduLength: 480,
      );
      expect(
        reply,
        equals(Uint8List.fromList([0xF0, 0x00, 0x01, 0x02, 0x03, 0x04, 0x01, 0xE0])),
      );

      final parsed = parseSetupCommunication(reply);
      expect(parsed, isNotNull);
      expect(parsed!.function, kS7FunctionSetupCommunication);
      expect(parsed.maxAmqCalling, 258);
      expect(parsed.maxAmqCalled, 772);
      expect(parsed.pduLength, 480);
    });
  });

  group('negotiatePduLength', () {
    test('a client proposal above the max is negotiated DOWN to kS7MaxPduLength', () {
      expect(negotiatePduLength(960), kS7MaxPduLength);
      expect(kS7MaxPduLength, 480);
    });

    test('a client proposal within range is accepted unchanged', () {
      expect(negotiatePduLength(240), 240);
    });

    test('a client proposal of 0 or negative is clamped to the documented floor, never 0', () {
      expect(negotiatePduLength(0), isNot(0));
      expect(negotiatePduLength(0), kS7MinPduLength);
      expect(negotiatePduLength(-5), kS7MinPduLength);
    });
  });
}
