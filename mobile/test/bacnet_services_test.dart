// Byte-exact fixtures for the BACnet APDU service codecs
// (mobile/lib/protocols/bacnet/bacnet_services.dart) — Who-Is/I-Am,
// ReadProperty, ReadPropertyMultiple, WriteProperty, and the
// SimpleAck/Error/Reject/Abort reply PDUs.
//
// THE TAG-STRUCTURE TRAP (see bacnet_tags_test.dart / bacnet_tags.dart's
// header for the full note): a build -> parse round trip through our OWN
// codec proves nothing — every fixture below asserts literal hand-built
// octets, taken directly from the plan's "Wire facts" section and the task
// brief, in both directions (build-and-compare-bytes, and separately
// parse-hand-built-bytes-and-check-fields).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/bacnet/bacnet_services.dart';

void main() {
  group('parseApdu', () {
    test('Confirmed-Request, not segmented', () {
      final apdu = Uint8List.fromList([0x00, 0x05, 0x09, 0x0C, 0xAA, 0xBB]);
      final decoded = parseApdu(apdu);
      expect(decoded, isNotNull);
      expect(decoded!.pduType, equals(0x0));
      expect(decoded.segmented, isFalse);
      expect(decoded.invokeId, equals(9));
      expect(decoded.serviceChoice, equals(0x0C));
      expect(decoded.serviceData, equals(Uint8List.fromList([0xAA, 0xBB])));
    });

    test('Confirmed-Request flags segmented (byte0 0x08 bit)', () {
      final apdu = Uint8List.fromList([0x08, 0x05, 0x09, 0x00, 0x10, 0x0C, 0xAA, 0xBB]);
      final decoded = parseApdu(apdu);
      expect(decoded, isNotNull);
      expect(decoded!.segmented, isTrue);
      expect(decoded.invokeId, equals(9));
      expect(decoded.serviceChoice, equals(0x0C));
      expect(decoded.serviceData, equals(Uint8List.fromList([0xAA, 0xBB])));
    });

    test('Unconfirmed-Request has no invoke ID', () {
      final apdu = Uint8List.fromList([0x10, 0x08, 0x09, 0x0A]);
      final decoded = parseApdu(apdu);
      expect(decoded, isNotNull);
      expect(decoded!.pduType, equals(0x1));
      expect(decoded.segmented, isFalse);
      expect(decoded.invokeId, isNull);
      expect(decoded.serviceChoice, equals(0x08));
      expect(decoded.serviceData, equals(Uint8List.fromList([0x09, 0x0A])));
    });

    test('empty buffer -> null, no throw', () {
      expect(() => parseApdu(Uint8List.fromList([])), returnsNormally);
      expect(parseApdu(Uint8List.fromList([])), isNull);
    });

    test('truncated Confirmed-Request (no invoke ID byte) -> null, no throw', () {
      final apdu = Uint8List.fromList([0x00, 0x05]);
      expect(() => parseApdu(apdu), returnsNormally);
      expect(parseApdu(apdu), isNull);
    });

    test('truncated segmented Confirmed-Request (no service choice byte) -> null, no throw', () {
      final apdu = Uint8List.fromList([0x08, 0x05, 0x09, 0x00, 0x10]);
      expect(() => parseApdu(apdu), returnsNormally);
      expect(parseApdu(apdu), isNull);
    });

    test('truncated Unconfirmed-Request (no service choice byte) -> null, no throw', () {
      final apdu = Uint8List.fromList([0x10]);
      expect(() => parseApdu(apdu), returnsNormally);
      expect(parseApdu(apdu), isNull);
    });

    test('unrecognized PDU type (SimpleAck received) -> null', () {
      final apdu = Uint8List.fromList([0x20, 0x05, 0x0F]);
      expect(parseApdu(apdu), isNull);
    });
  });

  group('Who-Is', () {
    test('empty service data -> (null, null) unlimited', () {
      expect(parseWhoIs(Uint8List.fromList([])), equals((null, null)));
    });

    test('with range: ctx0 0x09 <lo> ctx1 0x19 <hi>', () {
      final data = Uint8List.fromList([0x09, 0x0A, 0x19, 0x14]);
      expect(parseWhoIs(data), equals((10, 20)));
    });

    test('only low limit present (no high) -> malformed, null record', () {
      final data = Uint8List.fromList([0x09, 0x0A]);
      expect(() => parseWhoIs(data), returnsNormally);
      expect(parseWhoIs(data), isNull);
    });

    test('truncated content -> null, no throw', () {
      final data = Uint8List.fromList([0x09]);
      expect(() => parseWhoIs(data), returnsNormally);
      expect(parseWhoIs(data), isNull);
    });
  });

  group('I-Am', () {
    test('device 3056 -> exact literal bytes', () {
      final apdu = buildIAm(deviceInstance: 3056);
      expect(
        apdu,
        equals(Uint8List.fromList([
          0x10, 0x00, // Unconfirmed-Request, service I-Am
          0xC4, 0x02, 0x00, 0x0B, 0xF0, // ObjectId device(8) instance 3056
          0x22, 0x05, 0xC4, // Unsigned 1476
          0x91, 0x03, // Enumerated 3 (no-segmentation)
          0x21, 0x00, // Unsigned 0 (vendor)
        ])),
      );
    });
  });

  group('ReadProperty request', () {
    test('analog-value(0) present-value -> 0x0C 0x00 0x80 0x00 0x00 0x19 0x55', () {
      final data = Uint8List.fromList([0x0C, 0x00, 0x80, 0x00, 0x00, 0x19, 0x55]);
      final req = parseReadProperty(data);
      expect(req, isNotNull);
      expect(req!.objectType, equals(2));
      expect(req.instance, equals(0));
      expect(req.propertyId, equals(85));
      expect(req.arrayIndex, isNull);
    });

    test('device(3056) object-list[0] -> ... 0x19 0x4C 0x29 0x00', () {
      final data = Uint8List.fromList([
        0x0C, 0x02, 0x00, 0x0B, 0xF0, // ctx0 objectId device(8) 3056
        0x19, 0x4C, // ctx1 propertyId object-list (76)
        0x29, 0x00, // ctx2 arrayIndex 0
      ]);
      final req = parseReadProperty(data);
      expect(req, isNotNull);
      expect(req!.objectType, equals(8));
      expect(req.instance, equals(3056));
      expect(req.propertyId, equals(76));
      expect(req.arrayIndex, equals(0));
    });

    test('truncated (missing propertyId tag) -> null, no throw', () {
      final data = Uint8List.fromList([0x0C, 0x00, 0x80, 0x00, 0x00]);
      expect(() => parseReadProperty(data), returnsNormally);
      expect(parseReadProperty(data), isNull);
    });

    test('empty buffer -> null, no throw', () {
      expect(() => parseReadProperty(Uint8List.fromList([])), returnsNormally);
      expect(parseReadProperty(Uint8List.fromList([])), isNull);
    });
  });

  group('ReadProperty ComplexAck', () {
    test('byte layout: 0x30 <invoke> 0x0C then echoed ctx tags then 0x3E <value> 0x3F', () {
      final req = RpRequest(objectType: 2, instance: 0, propertyId: 85);
      final valueTags = Uint8List.fromList([0x44, 0x42, 0x28, 0x00, 0x00]); // Real 42.0
      final ack = buildReadPropertyAck(invokeId: 5, req: req, valueTags: valueTags);
      expect(
        ack,
        equals(Uint8List.fromList([
          0x30, 0x05, 0x0C, // ComplexAck, invoke 5, ReadProperty
          0x0C, 0x00, 0x80, 0x00, 0x00, // ctx0 objectId echoed
          0x19, 0x55, // ctx1 propertyId echoed
          0x3E, // ctx3-open
          0x44, 0x42, 0x28, 0x00, 0x00, // value
          0x3F, // ctx3-close
        ])),
      );
    });

    test('echoes arrayIndex when present', () {
      final req = RpRequest(objectType: 8, instance: 3056, propertyId: 76, arrayIndex: 0);
      final valueTags = Uint8List.fromList([0x0C, 0x02, 0x00, 0x0B, 0xF0]); // an ObjectId value
      final ack = buildReadPropertyAck(invokeId: 1, req: req, valueTags: valueTags);
      expect(
        ack,
        equals(Uint8List.fromList([
          0x30, 0x01, 0x0C,
          0x0C, 0x02, 0x00, 0x0B, 0xF0, // ctx0 objectId
          0x19, 0x4C, // ctx1 propertyId
          0x29, 0x00, // ctx2 arrayIndex
          0x3E,
          0x0C, 0x02, 0x00, 0x0B, 0xF0,
          0x3F,
        ])),
      );
    });
  });

  group('ReadPropertyMultiple request', () {
    test('two objects, second uses the ALL special', () {
      final data = Uint8List.fromList([
        // Object 1: analog-value(2) instance 0, property present-value(85)
        0x0C, 0x00, 0x80, 0x00, 0x00,
        0x1E, // ctx1-open
        0x09, 0x55, // ctx0 propertyId 85 (present-value)
        0x1F, // ctx1-close
        // Object 2: device(8) instance 3056, property ALL(8)
        0x0C, 0x02, 0x00, 0x0B, 0xF0,
        0x1E,
        0x09, 0x08, // ctx0 propertyId 8 (ALL)
        0x1F,
      ]);
      final req = parseRpm(data);
      expect(req, isNotNull);
      expect(req!.specs.length, equals(2));
      expect(req.specs[0].objectType, equals(2));
      expect(req.specs[0].instance, equals(0));
      expect(req.specs[0].props, equals([(85, null)]));
      expect(req.specs[1].objectType, equals(8));
      expect(req.specs[1].instance, equals(3056));
      expect(req.specs[1].props, equals([(8, null)]));
    });

    test('a property with an explicit array index', () {
      final data = Uint8List.fromList([
        0x0C, 0x02, 0x00, 0x0B, 0xF0, // device(8) 3056
        0x1E,
        0x09, 0x4C, // ctx0 propertyId object-list (76)
        0x19, 0x00, // ctx1 arrayIndex 0
        0x1F,
      ]);
      final req = parseRpm(data);
      expect(req, isNotNull);
      expect(req!.specs.length, equals(1));
      expect(req.specs[0].props, equals([(76, 0)]));
    });

    test('missing ctx1-close -> null, no throw', () {
      final data = Uint8List.fromList([
        0x0C, 0x00, 0x80, 0x00, 0x00,
        0x1E,
        0x09, 0x55,
        // no closing tag
      ]);
      expect(() => parseRpm(data), returnsNormally);
      expect(parseRpm(data), isNull);
    });

    test('empty buffer -> null, no throw', () {
      expect(() => parseRpm(Uint8List.fromList([])), returnsNormally);
      expect(parseRpm(Uint8List.fromList([])), isNull);
    });
  });

  group('ReadPropertyMultiple ack', () {
    test('embeds one value and one error: 0x5E 0x91 0x02 0x91 0x20 0x5F', () {
      final result = RpmResult(
        objectType: 2,
        instance: 0,
        props: [
          RpmPropResult(
            propertyId: 85,
            valueTags: Uint8List.fromList([0x44, 0x41, 0x20, 0x00, 0x00]), // Real 10.0
          ),
          RpmPropResult(
            propertyId: 77,
            error: (2, 32),
          ),
        ],
      );
      final ack = buildRpmAck(invokeId: 7, results: [result]);
      expect(
        ack,
        equals(Uint8List.fromList([
          0x30, 0x07, 0x0E, // ComplexAck, invoke 7, RPM
          0x0C, 0x00, 0x80, 0x00, 0x00, // ctx0 objectId
          0x1E, // ctx1-open
          0x29, 0x55, // ctx2 propertyId 85
          0x4E, 0x44, 0x41, 0x20, 0x00, 0x00, 0x4F, // ctx4-open value ctx4-close
          0x29, 0x4D, // ctx2 propertyId 77
          0x5E, 0x91, 0x02, 0x91, 0x20, 0x5F, // ctx5-open error ctx5-close
          0x1F, // ctx1-close
        ])),
      );
    });
  });

  group('WriteProperty request', () {
    test('without ctx4 priority', () {
      final data = Uint8List.fromList([
        0x0C, 0x01, 0x40, 0x00, 0x01, // ctx0 objectId binary-value(5) instance 1
        0x19, 0x55, // ctx1 propertyId present-value (85)
        0x3E, 0x11, 0x3F, // ctx3-open Boolean(true) ctx3-close
      ]);
      final req = parseWriteProperty(data);
      expect(req, isNotNull);
      expect(req!.objectType, equals(5));
      expect(req.instance, equals(1));
      expect(req.propertyId, equals(85));
      expect(req.arrayIndex, isNull);
      expect(req.valueTags, equals(Uint8List.fromList([0x11])));
      expect(req.priority, isNull);
    });

    test('with ctx4 priority -> trailing 0x49 0x08', () {
      final data = Uint8List.fromList([
        0x0C, 0x01, 0x40, 0x00, 0x01,
        0x19, 0x55,
        0x3E, 0x11, 0x3F,
        0x49, 0x08, // ctx4 priority 8
      ]);
      final req = parseWriteProperty(data);
      expect(req, isNotNull);
      expect(req!.priority, equals(8));
      expect(req.valueTags, equals(Uint8List.fromList([0x11])));
    });

    test('truncated (missing value bracket close) -> null, no throw', () {
      final data = Uint8List.fromList([
        0x0C, 0x01, 0x40, 0x00, 0x01,
        0x19, 0x55,
        0x3E, 0x11,
        // no ctx3-close
      ]);
      expect(() => parseWriteProperty(data), returnsNormally);
      expect(parseWriteProperty(data), isNull);
    });

    test('empty buffer -> null, no throw', () {
      expect(() => parseWriteProperty(Uint8List.fromList([])), returnsNormally);
      expect(parseWriteProperty(Uint8List.fromList([])), isNull);
    });
  });

  group('SimpleAck / Error / Reject / Abort', () {
    test('SimpleAck -> 0x20 <invoke> 0x0F', () {
      expect(buildSimpleAck(5, kBacnetServiceWriteProperty), equals(Uint8List.fromList([0x20, 0x05, 0x0F])));
    });

    test('Error -> 0x50 <invoke> <svc> 0x91 <class> 0x91 <code>', () {
      expect(
        buildError(5, kBacnetServiceWriteProperty, kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty),
        equals(Uint8List.fromList([0x50, 0x05, 0x0F, 0x91, 0x02, 0x91, 0x20])),
      );
    });

    test('Reject -> 0x60 <invoke> 0x09', () {
      expect(
        buildReject(5, kBacnetRejectReasonUnrecognizedService),
        equals(Uint8List.fromList([0x60, 0x05, 0x09])),
      );
    });

    test('Abort -> 0x71 <invoke> 0x04', () {
      expect(
        buildAbort(5, kBacnetAbortReasonSegmentationNotSupported),
        equals(Uint8List.fromList([0x71, 0x05, 0x04])),
      );
    });
  });
}
