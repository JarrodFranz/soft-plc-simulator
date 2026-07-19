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

  // --- Read/Write Var item specification (Task 4) --------------------------
  //
  // Layout (all multi-byte fields BIG-ENDIAN):
  //   0x12  variable specification
  //   0x0A  length of the following bytes
  //   0x10  syntax id (S7ANY)
  //   u8    transport size
  //   u16   count
  //   u16   DB number
  //   u8    area
  //   u24   address == byteOffset * 8 + bitOffset
  group('S7 item specification', () {
    test('buildS7Item emits the literal 12-byte layout with a 24-bit address', () {
      final item = buildS7Item(
        transportSize: kS7TransportSizeInt,
        count: 0x0102,
        dbNumber: 0x0304,
        area: kS7AreaDataBlock,
        byteOffset: 4,
        bitOffset: 3,
      );
      // 4 * 8 + 3 == 35 == 0x000023.
      expect(
        item,
        equals(Uint8List.fromList([
          0x12, 0x0A, 0x10,
          kS7TransportSizeInt,
          0x01, 0x02, // count, BIG-ENDIAN (bytes differ)
          0x03, 0x04, // db number, BIG-ENDIAN (bytes differ)
          kS7AreaDataBlock,
          0x00, 0x00, 0x23, // address = byteOffset * 8 + bitOffset
        ])),
      );
      expect(item.length, kS7ItemSpecLen);
    });

    test('the 24-bit address is BIG-ENDIAN across all three bytes', () {
      // byteOffset 8192 -> 8192 * 8 == 65536 == 0x010000.
      final item = buildS7Item(
        transportSize: kS7TransportSizeByte,
        count: 1,
        dbNumber: 1,
        area: kS7AreaDataBlock,
        byteOffset: 8192,
      );
      expect(item.sublist(9, 12), equals([0x01, 0x00, 0x00]));

      // byteOffset 0x1234 (4660) -> * 8 == 37280 == 0x0091A0.
      final item2 = buildS7Item(
        transportSize: kS7TransportSizeByte,
        count: 1,
        dbNumber: 1,
        area: kS7AreaDataBlock,
        byteOffset: 0x1234,
        bitOffset: 0,
      );
      expect(item2.sublist(9, 12), equals([0x00, 0x91, 0xA0]));
    });

    test('parseS7Item decodes a hand-built item, splitting the address back into byte/bit', () {
      final wire = Uint8List.fromList([
        0x12, 0x0A, 0x10,
        kS7TransportSizeBit,
        0x00, 0x01,
        0x00, 0x07, // DB 7
        kS7AreaDataBlock,
        0x00, 0x00, 0x23, // 35 -> byteOffset 4, bitOffset 3
      ]);
      final item = parseS7Item(wire);
      expect(item, isNotNull);
      expect(item!.transportSize, kS7TransportSizeBit);
      expect(item.count, 1);
      expect(item.dbNumber, 7);
      expect(item.area, kS7AreaDataBlock);
      expect(item.byteOffset, 4);
      expect(item.bitOffset, 3);
      expect(item.bitAddress, 4 * 8 + 3);
    });

    test('parseReadItem is the brief-named alias of parseS7Item', () {
      final wire = buildS7Item(
        transportSize: kS7TransportSizeWord,
        count: 2,
        dbNumber: 9,
        area: kS7AreaMerker,
        byteOffset: 10,
      );
      final item = parseReadItem(wire);
      expect(item, isNotNull);
      expect(item!.dbNumber, 9);
      expect(item.byteOffset, 10);
      expect(item.bitOffset, 0);
    });

    test('parseS7Item returns null (never throws) on malformed input', () {
      expect(parseS7Item(Uint8List(0)), isNull);
      expect(parseS7Item(Uint8List.fromList([0x12, 0x0A])), isNull);
      // Wrong specification byte.
      final bad = buildS7Item(
        transportSize: kS7TransportSizeInt, count: 1, dbNumber: 1,
        area: kS7AreaDataBlock, byteOffset: 0,
      );
      bad[0] = 0x13;
      expect(parseS7Item(bad), isNull);
      // Wrong syntax id.
      final bad2 = buildS7Item(
        transportSize: kS7TransportSizeInt, count: 1, dbNumber: 1,
        area: kS7AreaDataBlock, byteOffset: 0,
      );
      bad2[2] = 0x11;
      expect(parseS7Item(bad2), isNull);
      // Offset past the end.
      expect(parseS7Item(bad2, 40), isNull);
    });
  });

  group('S7 Read/Write Var parameter', () {
    test('buildVarParameter emits function + item count, and parseVarParameter reads items back', () {
      final items = [
        buildS7Item(
          transportSize: kS7TransportSizeByte, count: 4, dbNumber: 1,
          area: kS7AreaDataBlock, byteOffset: 0,
        ),
        buildS7Item(
          transportSize: kS7TransportSizeBit, count: 1, dbNumber: 2,
          area: kS7AreaMerker, byteOffset: 5, bitOffset: 6,
        ),
      ];
      final param = Uint8List.fromList([
        ...buildVarParameter(function: kS7FunctionReadVar, itemCount: 2),
        ...items[0],
        ...items[1],
      ]);
      expect(param[0], kS7FunctionReadVar);
      expect(param[1], 2);

      final parsed = parseVarParameter(param);
      expect(parsed, isNotNull);
      expect(parsed!.function, kS7FunctionReadVar);
      expect(parsed.items.length, 2);
      expect(parsed.items[0].dbNumber, 1);
      expect(parsed.items[1].area, kS7AreaMerker);
      expect(parsed.items[1].byteOffset, 5);
      expect(parsed.items[1].bitOffset, 6);
    });

    test('parseVarParameter returns null (never throws) on truncated input', () {
      expect(parseVarParameter(Uint8List(0)), isNull);
      expect(parseVarParameter(Uint8List.fromList([kS7FunctionReadVar])), isNull);
      // Claims 3 items but carries only one.
      final truncated = Uint8List.fromList([
        kS7FunctionWriteVar, 3,
        ...buildS7Item(
          transportSize: kS7TransportSizeByte, count: 1, dbNumber: 1,
          area: kS7AreaDataBlock, byteOffset: 0,
        ),
      ]);
      expect(parseVarParameter(truncated), isNull);
    });
  });

  group('S7 response data item', () {
    test('a BYTE/WORD (0x04) item carries its length in BITS', () {
      final item = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportByteWord,
        data: Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]),
      );
      expect(
        item,
        equals(Uint8List.fromList([
          kS7ReturnSuccess,
          kS7DataTransportByteWord,
          0x00, 0x20, // 4 bytes == 32 BITS, BIG-ENDIAN
          0xAA, 0xBB, 0xCC, 0xDD,
        ])),
      );
    });

    // *** SETTLED BY THE REAL CLIENT — DO NOT "CORRECT" THIS BACK ***
    // An earlier version declared a BIT item's length as a bit COUNT (1 for
    // a single bit). `tool/py/s7_probe.py` step 6 drove a genuine single-bit
    // read through `python-snap7`, which slices a data item's payload as
    // `declared ~/ 8`: a declared `1` gave it ZERO bytes and the bit value
    // was lost. It wants `data.length * 8`. See `buildDataItem`'s doc
    // comment for the full reasoning, including why 8 is also the safer
    // choice for a client that reads the field as a true bit count.
    test('a BIT (0x03) item declares data.length * 8, as the real client requires', () {
      final item = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportBit,
        data: Uint8List.fromList([0x01]),
      );
      expect(item[0], kS7ReturnSuccess);
      expect(item[1], kS7DataTransportBit);
      expect(item[2], 0x00);
      expect(item[3], 0x08, reason: '1 data byte * 8 == 8, BIG-ENDIAN');
      expect(item[4], 0x01);
      expect(item[5], 0x00, reason: 'pad byte');
      expect(item.length, 6);
    });

    test('BIT and BYTE/WORD both declare in BITS, and OCTET STRING in BYTES — '
        'the units must never be conflated', () {
      final bitItem = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportBit,
        data: Uint8List.fromList([0x01]),
      );
      final byteWordItem = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportByteWord,
        data: Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0]), // 8 bytes
      );
      final octetItem = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportOctetString,
        data: Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0]), // 8 bytes
      );
      final declaredBit = ByteData.sublistView(bitItem, 2, 4).getUint16(0, Endian.big);
      final declaredByteWord = ByteData.sublistView(byteWordItem, 2, 4).getUint16(0, Endian.big);
      final declaredOctet = ByteData.sublistView(octetItem, 2, 4).getUint16(0, Endian.big);
      expect(declaredBit, 8, reason: '1 byte * 8 == 8 bits');
      expect(declaredByteWord, 64, reason: '8 bytes * 8 == 64 bits for the BYTE/WORD unit');
      expect(declaredOctet, 8, reason: 'OCTET STRING counts BYTES, not bits');
    });

    test('an OCTET STRING (0x09) item carries its length in BYTES', () {
      final item = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportOctetString,
        data: Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]),
      );
      expect(
        item,
        equals(Uint8List.fromList([
          kS7ReturnSuccess,
          kS7DataTransportOctetString,
          0x00, 0x04, // 4 BYTES, BIG-ENDIAN
          0xAA, 0xBB, 0xCC, 0xDD,
        ])),
      );
    });

    test('the two length units genuinely differ for the same payload', () {
      final bits = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportByteWord,
        data: Uint8List.fromList([0x01, 0x02]),
      );
      final bytes = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportOctetString,
        data: Uint8List.fromList([0x01, 0x02]),
      );
      expect(bits[3], 0x10); // 16 bits
      expect(bytes[3], 0x02); // 2 bytes
      expect(bits[3], isNot(bytes[3]));
    });

    test('odd-length data is padded to an even byte count without changing the declared length', () {
      final item = buildDataItem(
        returnCode: kS7ReturnSuccess,
        transportSize: kS7DataTransportOctetString,
        data: Uint8List.fromList([0x01, 0x02, 0x03]),
      );
      expect(item.length, 8, reason: '4 header + 3 data + 1 pad');
      expect(item[3], 0x03, reason: 'declared length excludes the pad byte');
      expect(item[7], 0x00);
    });

    test('an error item carries its return code and no data', () {
      final item = buildDataItem(
        returnCode: kS7ReturnObjectDoesNotExist,
        transportSize: kS7DataTransportNull,
        data: Uint8List(0),
      );
      expect(item, equals(Uint8List.fromList([kS7ReturnObjectDoesNotExist, 0x00, 0x00, 0x00])));
    });
  });

  group('S7 Write Var payloads and response', () {
    test('parseWriteDataItems splits the data section into per-item payloads', () {
      final data = Uint8List.fromList([
        ...buildDataItem(
          returnCode: kS7ReturnSuccess,
          transportSize: kS7DataTransportByteWord,
          data: Uint8List.fromList([0x01, 0x02]),
        ),
        ...buildDataItem(
          returnCode: kS7ReturnSuccess,
          transportSize: kS7DataTransportBit,
          data: Uint8List.fromList([0x01]),
        ),
      ]);
      final payloads = parseWriteDataItems(data, 2);
      expect(payloads, isNotNull);
      expect(payloads!.length, 2);
      expect(payloads[0], equals([0x01, 0x02]));
      expect(payloads[1], equals([0x01]));
    });

    test('parseWriteDataItems returns null (never throws) on truncated input', () {
      expect(parseWriteDataItems(Uint8List(0), 1), isNull);
      expect(parseWriteDataItems(Uint8List.fromList([0xFF, 0x04, 0x00, 0x20, 0x01]), 1), isNull);
      expect(parseWriteDataItems(Uint8List.fromList([0xFF, 0x04, 0x00, 0x10, 0x01, 0x02]), 2), isNull);
    });

    test('the Write Var response is function 0x05, item count, then one return code per item', () {
      final param = buildVarParameter(function: kS7FunctionWriteVar, itemCount: 3);
      expect(param, equals(Uint8List.fromList([0x05, 0x03])));

      final data = buildWriteResponseData([
        kS7ReturnSuccess,
        kS7ReturnAccessDenied,
        kS7ReturnAddressOutOfRange,
      ]);
      expect(data, equals(Uint8List.fromList([0xFF, 0x03, 0x05])));
      expect(data.length, 3, reason: 'exactly one byte per item');
    });
  });

  // --- Item-spec -> data-item transport size mapping ------------------------
  //
  // The two transport-size families numerically collide: item-spec BIT is
  // 0x01, but data-item BIT is 0x03. A caller that forwards a parsed
  // S7Item.transportSize straight into buildDataItem/s7DataLengthIsInBits
  // without going through this mapping will silently mistreat BIT items.
  group('dataTransportForItemTransport — item-spec/data-item collision', () {
    test('item BIT (0x01) maps to data BIT (0x03), NOT to 0x01', () {
      final mapped = dataTransportForItemTransport(kS7TransportSizeBit);
      expect(mapped, kS7DataTransportBit);
      expect(mapped, isNot(kS7TransportSizeBit));
    });

    test('every non-BIT item-spec size maps to data BYTE/WORD (0x04)', () {
      for (final size in [
        kS7TransportSizeByte,
        kS7TransportSizeChar,
        kS7TransportSizeWord,
        kS7TransportSizeInt,
        kS7TransportSizeDword,
        kS7TransportSizeDint,
        kS7TransportSizeReal,
      ]) {
        expect(dataTransportForItemTransport(size), kS7DataTransportByteWord);
      }
    });

    test('an unrecognized item-spec size falls back to data BYTE/WORD, never throws', () {
      expect(() => dataTransportForItemTransport(0xEE), returnsNormally);
      expect(dataTransportForItemTransport(0xEE), kS7DataTransportByteWord);
    });
  });
}
