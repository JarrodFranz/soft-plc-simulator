// Tests for the SHARED S7comm Read/Write Var dispatch
// (`mobile/lib/protocols/s7/s7_services.dart`) — the one function both
// `services/s7_host.dart` and the E2E fixture `mobile/tool/s7_host_probe.dart`
// call, so anything proven here holds for both by construction.
//
// SCOPE: the negotiated-PDU BUDGET. A Read Var response must never exceed the
// PDU length agreed during Setup Communication — a strict driver that enforces
// the negotiated size drops an oversized frame, and the read silently fails on
// exactly the large-block-read pattern this protocol exists to serve. The
// budget must therefore charge each item's FULL on-wire cost (its 4-byte data
// item header and its odd-length pad byte), not just its payload.
//
// BIG-ENDIAN throughout — the EtherNet/IP codec next door is little-endian.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/s7_map.dart';
import 'package:soft_plc_mobile/protocols/s7/s7_pdu.dart';
import 'package:soft_plc_mobile/protocols/s7/s7_services.dart';

/// The PDU length `python-snap7` negotiates with this device, and this
/// device's documented maximum — the size every assertion below bounds a
/// response against.
const int _kPdu = 480;

/// A project with one mapped tag in DB1. Every byte of DB1 outside the tag is
/// an unmapped gap, which reads as `0x00` — that is what lets these tests ask
/// for a large block without pinning hundreds of tags.
PlcProject _project() {
  final project = PlcProject(
    id: 'proj_s7_services_test',
    name: 'S7 Services Test',
    controllerName: 'PLC_TEST',
    tags: [
      PlcTag(
        name: 'Count16',
        path: 'Internal.Count16',
        dataType: 'INT16',
        value: 0x1234,
        ioType: 'Internal',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  return project;
}

S7Map _map() {
  return S7Map(entries: [
    S7MapEntry(tag: 'Count16', area: kS7AreaNameDb, dbNumber: 1, byteOffset: 0),
  ]);
}

/// Parses a Read Var Job carrying [items] back into the `S7Message` the
/// dispatch takes, going through `buildS7`/`parseS7` so the request under test
/// is a real message rather than a hand-built struct.
S7Message _readVarRequest(List<Uint8List> items) {
  final parameter = <int>[kS7FunctionReadVar, items.length];
  for (final item in items) {
    parameter.addAll(item);
  }
  final bytes = buildS7(
    rosctr: kS7RosctrJob,
    pduReference: 0x0200,
    parameter: Uint8List.fromList(parameter),
  );
  return parseS7(bytes)!;
}

/// A BYTE-transport Read Var item addressing [count] bytes of DB1 from
/// [byteOffset].
Uint8List _byteItem(int count, {int byteOffset = 0}) {
  return buildS7Item(
    transportSize: kS7TransportSizeByte,
    count: count,
    dbNumber: 1,
    area: kS7AreaDataBlock,
    byteOffset: byteOffset,
  );
}

/// Dispatches a single-item byte read of [count] bytes at [_kPdu].
Uint8List? _readBytes(int count) {
  return dispatchS7VarJob(
    _project(),
    _map(),
    _readVarRequest([_byteItem(count)]),
    negotiatedPduLength: _kPdu,
  );
}

void main() {
  group('Read Var — the response never exceeds the negotiated PDU', () {
    test('a single read of exactly the DATA budget still fits in the PDU', () {
      // `s7MaxResponseDataBytes(480)` is 466. A naive admission check compares
      // the item's PAYLOAD against that budget and admits this read, but the
      // item that actually goes on the wire is 4 bytes larger than its
      // payload, so the message lands at 484 — over the size the device just
      // agreed to.
      final budget = s7MaxResponseDataBytes(_kPdu);
      expect(budget, 466, reason: '480 - (12-byte Ack_Data header + 2-byte parameter)');

      final reply = _readBytes(budget);
      expect(reply, isNotNull);
      expect(reply!.length, lessThanOrEqualTo(_kPdu),
          reason: 'a response larger than the negotiated PDU is dropped by a '
              'strict driver, so the read silently fails');
    });

    test('the largest EVEN payload that fits is served in full, exactly filling the PDU', () {
      // 462 payload + 4 header == the 466-byte budget, so the whole message is
      // exactly 480: the boundary is inclusive, not off by one.
      final reply = _readBytes(462);
      expect(reply, isNotNull);
      expect(reply!.length, _kPdu);
      expect(reply[kS7HeaderLenAckData + 2], kS7ReturnSuccess);
      expect(reply[kS7HeaderLenAckData + 3], kS7DataTransportByteWord);
      expect(
        ByteData.sublistView(reply, kS7HeaderLenAckData + 4, kS7HeaderLenAckData + 6)
            .getUint16(0, Endian.big),
        462 * 8,
        reason: 'BYTE/WORD declares its length in BITS',
      );
      // The mapped tag is still where it belongs, BIG-ENDIAN.
      expect(reply.sublist(kS7HeaderLenAckData + 6, kS7HeaderLenAckData + 8),
          equals([0x12, 0x34]));
    });

    test('an ODD payload is charged for its pad byte too, and still fits exactly', () {
      // 461 payload + 4 header + 1 pad == 466, so this is the largest odd read
      // that fits and the message is again exactly 480.
      final reply = _readBytes(461);
      expect(reply, isNotNull);
      expect(reply!.length, _kPdu);
      expect(reply[kS7HeaderLenAckData + 2], kS7ReturnSuccess);
    });

    test('one byte past the budget is refused with ADDRESS OUT OF RANGE, not truncated', () {
      // 463 payload + 4 header == 467, one over the budget. This is the
      // budget-exhaustion guard: the item must come back as an ERROR item with
      // a NULL transport rather than a short payload.
      final reply = _readBytes(463);
      expect(reply, isNotNull);
      expect(reply!.length, lessThanOrEqualTo(_kPdu));
      expect(reply[kS7HeaderLenAckData + 2], kS7ReturnAddressOutOfRange);
      expect(reply[kS7HeaderLenAckData + 3], kS7DataTransportNull);
      expect(
        ByteData.sublistView(reply, kS7HeaderLenAckData + 4, kS7HeaderLenAckData + 6)
            .getUint16(0, Endian.big),
        0,
        reason: 'an error item carries no data',
      );
    });

    test('a read far larger than any PDU is refused rather than answered', () {
      final reply = _readBytes(4096);
      expect(reply, isNotNull);
      expect(reply!.length, lessThanOrEqualTo(_kPdu));
      expect(reply[kS7HeaderLenAckData + 2], kS7ReturnAddressOutOfRange);
    });

    test('a smaller negotiated PDU shrinks the budget correspondingly', () {
      // The floor this device clamps to. 240 - 14 == 226 data bytes, so 222
      // payload + 4 header fits and 223 does not.
      expect(s7MaxResponseDataBytes(240), 226);

      final fits = dispatchS7VarJob(
        _project(),
        _map(),
        _readVarRequest([_byteItem(222)]),
        negotiatedPduLength: 240,
      );
      expect(fits, isNotNull);
      expect(fits!.length, 240);
      expect(fits[kS7HeaderLenAckData + 2], kS7ReturnSuccess);

      final overruns = dispatchS7VarJob(
        _project(),
        _map(),
        _readVarRequest([_byteItem(223)]),
        negotiatedPduLength: 240,
      );
      expect(overruns, isNotNull);
      expect(overruns!.length, lessThanOrEqualTo(240));
      expect(overruns[kS7HeaderLenAckData + 2], kS7ReturnAddressOutOfRange);
    });

    test('s7MaxResponseDataBytes never goes negative for an absurdly small PDU', () {
      expect(s7MaxResponseDataBytes(kS7ResponseOverheadBytes), 0);
      expect(s7MaxResponseDataBytes(0), 0);
      expect(s7MaxResponseDataBytes(-1), 0);
    });
  });

  group('Read Var — multi-item requests are bounded in AGGREGATE', () {
    test('two items that each fit alone but not together stay inside the PDU', () {
      // 200 + 262 == 462 payload, under the 466 budget on payload alone — but
      // 204 + 266 == 470 on the wire, which would overrun by 4. The second
      // item must be refused.
      final request = _readVarRequest([_byteItem(200), _byteItem(262)]);
      final reply = dispatchS7VarJob(
        _project(),
        _map(),
        request,
        negotiatedPduLength: _kPdu,
      );
      expect(reply, isNotNull);
      expect(reply!.length, lessThanOrEqualTo(_kPdu));
      expect(reply[kS7HeaderLenAckData + 1], 2, reason: 'both items are answered');
      // Item 1 is served in full: 4-byte header + 200 payload.
      expect(reply[kS7HeaderLenAckData + 2], kS7ReturnSuccess);
      // Item 2 begins right after item 1 and is the refused one.
      const item2 = kS7HeaderLenAckData + 2 + kS7DataItemHeaderLen + 200;
      expect(reply[item2], kS7ReturnAddressOutOfRange);
      expect(reply[item2 + 1], kS7DataTransportNull);
    });

    test('many small items are all served while they fit, and the total stays inside the PDU', () {
      final items = List<Uint8List>.generate(8, (i) => _byteItem(50, byteOffset: i * 50));
      final reply = dispatchS7VarJob(
        _project(),
        _map(),
        _readVarRequest(items),
        negotiatedPduLength: _kPdu,
      );
      expect(reply, isNotNull);
      expect(reply!.length, lessThanOrEqualTo(_kPdu));
      expect(reply[kS7HeaderLenAckData + 1], 8);

      // 8 * (4 + 50) == 432 <= 466, so every item is served.
      var offset = kS7HeaderLenAckData + 2;
      for (var i = 0; i < 8; i++) {
        expect(reply[offset], kS7ReturnSuccess, reason: 'item $i should fit');
        offset += kS7DataItemHeaderLen + 50;
      }
    });

    test('an error item still charges its own 4-byte header against the budget', () {
      // A refused item is not free: it occupies a 4-byte NULL data item. Two
      // items — one unservable area, then a read sized to the FULL budget —
      // must still produce a message inside the PDU.
      final badArea = buildS7Item(
        transportSize: kS7TransportSizeByte,
        count: 2,
        dbNumber: 0,
        area: 0x1D, // the timer area, which this version does not serve
        byteOffset: 0,
      );
      final reply = dispatchS7VarJob(
        _project(),
        _map(),
        _readVarRequest([badArea, _byteItem(462)]),
        negotiatedPduLength: _kPdu,
      );
      expect(reply, isNotNull);
      expect(reply!.length, lessThanOrEqualTo(_kPdu));
      expect(reply[kS7HeaderLenAckData + 2], kS7ReturnObjectDoesNotExist);
      expect(reply[kS7HeaderLenAckData + 2 + kS7DataItemHeaderLen],
          kS7ReturnAddressOutOfRange,
          reason: 'the first item consumed 4 bytes, so a full-budget read no longer fits');
    });
  });
}
