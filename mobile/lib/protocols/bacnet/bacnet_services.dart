// BACnet/IP APDU SERVICE codecs — pure Dart, no dart:io / Flutter imports.
// This is the top layer of the BACnet/IP stack: `bacnet_bvll.dart` frames the
// raw APDU bytes off a UDP datagram, `bacnet_tags.dart` decodes/encodes the
// ASN.1-style tagged primitive values carried inside an APDU, and THIS file
// interprets/builds the actual application services (Who-Is/I-Am,
// ReadProperty, ReadPropertyMultiple, WriteProperty, and the
// SimpleAck/Error/Reject/Abort reply PDUs) out of those primitives.
//
// *** WIRE LAYOUT (see docs/superpowers/plans/2026-07-21-bacnet-v1.md "Wire
// facts" for the authoritative numbers this file pins) ***
// APDU byte 0's high nibble is the PDU type. Confirmed-Request (0x0) also
// packs SEG(0x08)/MOR(0x04)/SA(0x02) flags in byte 0's low nibble; byte 1 is
// max-segments/max-APDU (never interpreted here — an implementation-detail
// hint for the segmentation this device doesn't do), byte 2 is the invoke
// ID, and (only if SEG is set) byte 3/4 are a sequence number / proposed
// window size this device doesn't support (segmented requests are answered
// with Abort by a higher layer, not parsed further here) before the service
// choice byte. Unconfirmed-Request (0x1) has no invoke ID: byte 1 is the
// service choice directly. SimpleAck (0x2)/ComplexAck (0x3)/Error
// (0x5)/Reject (0x6)/Abort (0x7) are built by this device, never parsed (a
// server never receives them from a client in this program's scope).
//
// Every service layout below is built from `bacnet_tags.dart`'s primitive
// encoders/decoder exactly as documented per-function; see the plan's TAG-
// STRUCTURE TRAP note (repeated in `bacnet_tags.dart`'s header) — a
// build-then-parse round trip through this SAME file's own functions proves
// nothing, which is why `test/bacnet_services_test.dart` pins literal
// hand-built octets from the plan/brief in both directions.
//
// Safety contract: every `parse*` function below returns `null` — and NEVER
// throws — on malformed, truncated, or otherwise hostile input, since the
// UDP host (a later task) feeds these functions bytes read straight off the
// wire and must not crash or wedge its bind on one bad datagram. "Always an
// answer, never silence" for anything that DOES parse is the host's
// responsibility (a later task) — this file only supplies the PDU builders
// (`buildError`/`buildReject`/`buildAbort`) it needs to do so.
library bacnet_services;

import 'dart:typed_data';

import 'bacnet_tags.dart';

// --- APDU PDU types (high nibble of byte 0) ----------------------------------

const int kBacnetPduConfirmedRequest = 0x0;
const int kBacnetPduUnconfirmedRequest = 0x1;
const int kBacnetPduSimpleAck = 0x2;
const int kBacnetPduComplexAck = 0x3;
const int kBacnetPduError = 0x5;
const int kBacnetPduReject = 0x6;
const int kBacnetPduAbort = 0x7;

// --- Confirmed-Request byte-0 flag bits (low nibble) -------------------------

/// Segmented-message flag on a Confirmed-Request's byte 0. This device does
/// not support segmentation; a request with this bit set is answered with
/// Abort (segmentation-not-supported) by a higher layer.
const int kBacnetApduFlagSegmented = 0x08;

/// More-follows flag on a Confirmed-Request's byte 0 (segmentation only).
const int kBacnetApduFlagMoreFollows = 0x04;

/// Segmented-response-accepted flag on a Confirmed-Request's byte 0.
const int kBacnetApduFlagSegmentedResponseAccepted = 0x02;

/// Server bit this device sets on outgoing Abort PDUs (byte 0, low bit).
const int kBacnetAbortServerBit = 0x01;

// --- Service choice numbers ---------------------------------------------------

const int kBacnetServiceIAm = 0;
const int kBacnetServiceReadProperty = 12;
const int kBacnetServiceReadPropertyMultiple = 14;
const int kBacnetServiceWriteProperty = 15;
const int kBacnetServiceWhoIs = 8;

// --- Property identifiers ------------------------------------------------------

const int kBacnetPropApplicationSoftwareVersion = 12;
const int kBacnetPropEventState = 36;
const int kBacnetPropFirmwareRevision = 44;
const int kBacnetPropModelName = 70;
const int kBacnetPropObjectList = 76;
const int kBacnetPropObjectIdentifier = 75;
const int kBacnetPropObjectName = 77;
const int kBacnetPropObjectType = 79;
const int kBacnetPropOutOfService = 81;
const int kBacnetPropPresentValue = 85;
const int kBacnetPropPriorityArray = 87;
const int kBacnetPropProtocolObjectTypesSupported = 96;
const int kBacnetPropProtocolServicesSupported = 97;
const int kBacnetPropProtocolVersion = 98;
const int kBacnetPropRelinquishDefault = 104;
const int kBacnetPropSegmentationSupported = 107;
const int kBacnetPropStatusFlags = 111;
const int kBacnetPropSystemStatus = 112;
const int kBacnetPropUnits = 117;
const int kBacnetPropVendorIdentifier = 120;
const int kBacnetPropVendorName = 121;
const int kBacnetPropProtocolRevision = 139;

/// ReadPropertyMultiple special "property identifier" meaning "all
/// properties of the object".
const int kBacnetPropAll = 8;

/// ReadPropertyMultiple special "property identifier" meaning "all required
/// properties of the object".
const int kBacnetPropRequired = 105;

/// ReadPropertyMultiple special "property identifier" meaning "all optional
/// properties of the object".
const int kBacnetPropOptional = 80;

// --- Object types --------------------------------------------------------------

const int kBacnetObjectAnalogValue = 2;
const int kBacnetObjectBinaryValue = 5;
const int kBacnetObjectDevice = 8;

// --- Miscellaneous enumerations ------------------------------------------------

const int kBacnetUnitsNoUnits = 95;
const int kBacnetEventStateNormal = 0;
const int kBacnetSystemStatusOperational = 0;
const int kBacnetSegmentationNoSegmentation = 3;

// --- Error classes / codes ------------------------------------------------------

const int kBacnetErrorClassObject = 1;
const int kBacnetErrorClassProperty = 2;
const int kBacnetErrorClassServices = 5;

const int kBacnetErrorCodeInvalidDataType = 9;
const int kBacnetErrorCodeUnknownObject = 31;
const int kBacnetErrorCodeUnknownProperty = 32;
const int kBacnetErrorCodeWriteAccessDenied = 40;

// --- Reject / Abort reasons -----------------------------------------------------

const int kBacnetRejectReasonUnrecognizedService = 9;

const int kBacnetAbortReasonBufferOverflow = 1;
const int kBacnetAbortReasonSegmentationNotSupported = 4;

// --- I-Am fixed device values (see buildIAm) ------------------------------------

/// Max_APDU_Length_Accepted value this device advertises in I-Am (NOT the
/// property-identifier enum [kBacnetPropProtocolVersion] et al above — this
/// is the actual value carried in the PDU).
const int kBacnetIAmMaxApduLength = 1476;

/// Vendor_Identifier value this device advertises in I-Am: 0, honestly
/// identifying this as an unregistered/no-vendor device (no impersonation).
const int kBacnetIAmVendorIdentifier = 0;

// --- Context tag numbers used by the service layouts ---------------------------

const int _kCtxObjectId = 0;
const int _kCtxPropertyId = 1;
const int _kCtxArrayIndex = 2;
const int _kCtxValue = 3;
const int _kCtxPriority = 4;

const int _kCtxRpmSpecs = 1; // RPM request: per-object property-list bracket
const int _kCtxRpmPropId = 2; // RPM ack: per-property property id
const int _kCtxRpmPropIndex = 3; // RPM ack: per-property array index
const int _kCtxRpmValue = 4; // RPM ack: per-property value bracket
const int _kCtxRpmError = 5; // RPM ack: per-property error bracket

// --- Decoded APDU envelope -------------------------------------------------------

/// A decoded APDU envelope: the PDU type, whether the Confirmed-Request
/// segmented flag was set, the invoke ID (`null` for Unconfirmed-Request,
/// which carries none), the service choice number, and the raw service data
/// bytes that follow the service choice (fed to the per-service `parse*`
/// functions below).
class BacnetApdu {
  final int pduType;
  final bool segmented;
  final int? invokeId;
  final int serviceChoice;
  final Uint8List serviceData;

  BacnetApdu({
    required this.pduType,
    required this.segmented,
    required this.invokeId,
    required this.serviceChoice,
    required this.serviceData,
  });
}

/// Parses [apdu] (the bytes `bacnet_bvll.dart`'s `parseBvllToApdu` hands
/// back) into a [BacnetApdu] envelope. Only Confirmed-Request
/// ([kBacnetPduConfirmedRequest]) and Unconfirmed-Request
/// ([kBacnetPduUnconfirmedRequest]) are recognized — the only PDU types a
/// server ever receives FROM a client in this program's scope; any other PDU
/// type, or truncated input, returns `null`. Never throws.
BacnetApdu? parseApdu(Uint8List apdu) {
  try {
    if (apdu.isEmpty) {
      return null;
    }
    final byte0 = apdu[0];
    final pduType = (byte0 >> 4) & 0x0F;

    if (pduType == kBacnetPduConfirmedRequest) {
      final segmented = (byte0 & kBacnetApduFlagSegmented) != 0;
      if (apdu.length < 4) {
        return null;
      }
      final invokeId = apdu[2];
      final int serviceChoiceIndex;
      if (segmented) {
        if (apdu.length < 6) {
          return null;
        }
        serviceChoiceIndex = 5;
      } else {
        serviceChoiceIndex = 3;
      }
      final serviceChoice = apdu[serviceChoiceIndex];
      final serviceData = Uint8List.fromList(apdu.sublist(serviceChoiceIndex + 1));
      return BacnetApdu(
        pduType: pduType,
        segmented: segmented,
        invokeId: invokeId,
        serviceChoice: serviceChoice,
        serviceData: serviceData,
      );
    }

    if (pduType == kBacnetPduUnconfirmedRequest) {
      if (apdu.length < 2) {
        return null;
      }
      final serviceChoice = apdu[1];
      final serviceData = Uint8List.fromList(apdu.sublist(2));
      return BacnetApdu(
        pduType: pduType,
        segmented: false,
        invokeId: null,
        serviceChoice: serviceChoice,
        serviceData: serviceData,
      );
    }

    return null;
  } catch (_) {
    return null;
  }
}

// --- Who-Is / I-Am ----------------------------------------------------------------

/// Parses Who-Is [serviceData] (the bytes after the service choice byte).
/// Layout: `[ctx0 low limit][ctx1 high limit]`, both optional together — an
/// empty buffer means "no range, unlimited" and returns `(null, null)`. A
/// buffer with only one of the two tags present, or any tag that fails to
/// decode, is malformed and returns `null` for the whole record (not a
/// record with a null field) — never throws.
(int? low, int? high)? parseWhoIs(Uint8List serviceData) {
  try {
    if (serviceData.isEmpty) {
      return (null, null);
    }
    final reader = BacnetTagReader(serviceData);
    final lowTag = reader.readTag();
    if (lowTag == null || !lowTag.isContext || lowTag.tagNumber != 0) {
      return null;
    }
    final low = lowTag.asUnsigned();
    if (low == null) {
      return null;
    }
    if (reader.done) {
      return null; // Who-Is range is both-or-neither; one alone is malformed.
    }
    final highTag = reader.readTag();
    if (highTag == null || !highTag.isContext || highTag.tagNumber != 1) {
      return null;
    }
    final high = highTag.asUnsigned();
    if (high == null) {
      return null;
    }
    return (low, high);
  } catch (_) {
    return null;
  }
}

/// Builds a complete Unconfirmed-Request I-Am APDU for a device of
/// [deviceInstance]. Content: app ObjectIdentifier(device, [deviceInstance])
/// + app Unsigned([kBacnetIAmMaxApduLength]) + app
/// Enumerated([kBacnetSegmentationNoSegmentation]) + app
/// Unsigned([kBacnetIAmVendorIdentifier]) — e.g. device 3056 ->
/// `0x10 0x00 0xC4 0x02 0x00 0x0B 0xF0 0x22 0x05 0xC4 0x91 0x03 0x21 0x00`.
Uint8List buildIAm({required int deviceInstance}) {
  final out = <int>[
    kBacnetPduUnconfirmedRequest << 4,
    kBacnetServiceIAm,
    ...encodeAppObjectId(kBacnetObjectDevice, deviceInstance),
    ...encodeAppUnsigned(kBacnetIAmMaxApduLength),
    ...encodeAppEnumerated(kBacnetSegmentationNoSegmentation),
    ...encodeAppUnsigned(kBacnetIAmVendorIdentifier),
  ];
  return Uint8List.fromList(out);
}

// --- ReadProperty -------------------------------------------------------------

/// A decoded ReadProperty request: the target object's [objectType] and
/// [instance], the requested [propertyId], and an optional [arrayIndex].
class RpRequest {
  final int objectType;
  final int instance;
  final int propertyId;
  final int? arrayIndex;

  RpRequest({
    required this.objectType,
    required this.instance,
    required this.propertyId,
    this.arrayIndex,
  });
}

/// Parses ReadProperty [serviceData]. Layout: `ctx0 objectId, ctx1
/// propertyId, [ctx2 arrayIndex]` — e.g. analog-value(0) present-value ->
/// `0x0C 0x00 0x80 0x00 0x00 0x19 0x55`. Returns `null` — never throws — on
/// any malformed or truncated input.
RpRequest? parseReadProperty(Uint8List serviceData) {
  try {
    final reader = BacnetTagReader(serviceData);

    final objTag = reader.readTag();
    if (objTag == null || !objTag.isContext || objTag.tagNumber != _kCtxObjectId) {
      return null;
    }
    final objId = objTag.asObjectId();
    if (objId == null) {
      return null;
    }

    final propTag = reader.readTag();
    if (propTag == null || !propTag.isContext || propTag.tagNumber != _kCtxPropertyId) {
      return null;
    }
    final propertyId = propTag.asUnsigned();
    if (propertyId == null) {
      return null;
    }

    int? arrayIndex;
    if (!reader.done) {
      final idxTag = reader.readTag();
      if (idxTag == null || !idxTag.isContext || idxTag.tagNumber != _kCtxArrayIndex) {
        return null;
      }
      arrayIndex = idxTag.asUnsigned();
      if (arrayIndex == null) {
        return null;
      }
    }

    return RpRequest(
      objectType: objId.$1,
      instance: objId.$2,
      propertyId: propertyId,
      arrayIndex: arrayIndex,
    );
  } catch (_) {
    return null;
  }
}

/// Builds a complete ComplexAck APDU answering [req] (for confirmed
/// ReadProperty, invoke ID [invokeId]), embedding [valueTags] (already
/// app-tagged value bytes, built by the caller from `bacnet_tags.dart`).
/// Layout: `0x30 <invokeId> 0x0C` (ComplexAck, ReadProperty) then the
/// request's echoed `ctx0 objectId, ctx1 propertyId, [ctx2 arrayIndex]` then
/// `ctx3-open <valueTags> ctx3-close`.
Uint8List buildReadPropertyAck({
  required int invokeId,
  required RpRequest req,
  required Uint8List valueTags,
}) {
  final out = <int>[
    kBacnetPduComplexAck << 4,
    invokeId,
    kBacnetServiceReadProperty,
    ...encodeContextObjectId(_kCtxObjectId, req.objectType, req.instance),
    ...encodeContextUnsigned(_kCtxPropertyId, req.propertyId),
  ];
  if (req.arrayIndex != null) {
    out.addAll(encodeContextUnsigned(_kCtxArrayIndex, req.arrayIndex!));
  }
  out.addAll(openingTag(_kCtxValue));
  out.addAll(valueTags);
  out.addAll(closingTag(_kCtxValue));
  return Uint8List.fromList(out);
}

// --- ReadPropertyMultiple -------------------------------------------------------

/// One requested object's property list within an RPM request: the target
/// [objectType]/[instance] and the list of `(propertyId, arrayIndex)` pairs
/// requested for it (`arrayIndex` is `null` when not present; `propertyId`
/// may be one of the RPM specials [kBacnetPropAll]/[kBacnetPropRequired]/
/// [kBacnetPropOptional]).
class RpmObjectSpec {
  final int objectType;
  final int instance;
  final List<(int propertyId, int? arrayIndex)> props;

  RpmObjectSpec({required this.objectType, required this.instance, required this.props});
}

/// A decoded ReadPropertyMultiple request: one or more [RpmObjectSpec]s.
class RpmRequest {
  final List<RpmObjectSpec> specs;

  RpmRequest({required this.specs});
}

/// Parses ReadPropertyMultiple [serviceData]. Layout: repeating `{ ctx0
/// objectId, ctx1-open, { ctx0 propertyId [ctx1 arrayIndex] }*, ctx1-close
/// }`. Note the per-property propertyId/arrayIndex tags reuse context tag
/// numbers 0/1 — they are only ever read INSIDE the ctx1-open/close bracket,
/// so there is no ambiguity with the outer ctx0 objectId. Returns `null` —
/// never throws — on any malformed/truncated input, or on an empty request
/// (no object specs, or an object spec with an empty property list).
RpmRequest? parseRpm(Uint8List serviceData) {
  try {
    var reader = BacnetTagReader(serviceData);
    final specs = <RpmObjectSpec>[];

    while (!reader.done) {
      final objTag = reader.readTag();
      if (objTag == null || !objTag.isContext || objTag.tagNumber != _kCtxObjectId) {
        return null;
      }
      final objId = objTag.asObjectId();
      if (objId == null) {
        return null;
      }

      final openTag = reader.readTag();
      if (openTag == null || !openTag.isContext || !openTag.isOpening || openTag.tagNumber != _kCtxRpmSpecs) {
        return null;
      }

      final props = <(int, int?)>[];
      while (true) {
        final tag = reader.readTag();
        if (tag == null) {
          return null;
        }
        if (tag.isContext && tag.isClosing && tag.tagNumber == _kCtxRpmSpecs) {
          break;
        }
        if (!tag.isContext || tag.isOpening || tag.tagNumber != _kCtxObjectId) {
          return null;
        }
        final propertyId = tag.asUnsigned();
        if (propertyId == null) {
          return null;
        }

        int? arrayIndex;
        final beforeLookahead = reader.position;
        final lookahead = reader.done ? null : reader.readTag();
        if (lookahead != null &&
            lookahead.isContext &&
            !lookahead.isOpening &&
            !lookahead.isClosing &&
            lookahead.tagNumber == _kCtxPropertyId) {
          arrayIndex = lookahead.asUnsigned();
          if (arrayIndex == null) {
            return null;
          }
        } else {
          // Not an array-index tag: rewind so the next loop iteration
          // re-reads it (either the ctx1-close bracket or the next prop's
          // ctx0 property id).
          reader = BacnetTagReader(serviceData, beforeLookahead);
        }
        props.add((propertyId, arrayIndex));
      }

      if (props.isEmpty) {
        return null;
      }
      specs.add(RpmObjectSpec(objectType: objId.$1, instance: objId.$2, props: props));
    }

    if (specs.isEmpty) {
      return null;
    }
    return RpmRequest(specs: specs);
  } catch (_) {
    return null;
  }
}

/// One answered property within an RPM ack: the [propertyId] and optional
/// [arrayIndex] being answered, and EITHER [valueTags] (already app-tagged
/// value bytes) on success OR [error] (`(errorClass, errorCode)`) on
/// failure — never both meaningfully populated at once (a caller supplying
/// both simply gets the error branch emitted, since it is checked first).
class RpmPropResult {
  final int propertyId;
  final int? arrayIndex;
  final Uint8List? valueTags;
  final (int errClass, int errCode)? error;

  RpmPropResult({
    required this.propertyId,
    this.arrayIndex,
    this.valueTags,
    this.error,
  });
}

/// One answered object within an RPM ack: the [objectType]/[instance] and
/// its list of [RpmPropResult]s.
class RpmResult {
  final int objectType;
  final int instance;
  final List<RpmPropResult> props;

  RpmResult({required this.objectType, required this.instance, required this.props});
}

/// Builds a complete ComplexAck APDU for confirmed ReadPropertyMultiple
/// (invoke ID [invokeId]) from [results]. Layout: `0x30 <invokeId> 0x0E`
/// (ComplexAck, RPM) then, per result, `ctx0 objectId, ctx1-open, { ctx2
/// propertyId [ctx3 arrayIndex] (ctx4-open <valueTags> ctx4-close | ctx5-open
/// app-Enumerated(errClass) app-Enumerated(errCode) ctx5-close) }*,
/// ctx1-close` — e.g. one property answered with an error `(class 2, code
/// 32)` embeds `0x5E 0x91 0x02 0x91 0x20 0x5F`.
Uint8List buildRpmAck({required int invokeId, required List<RpmResult> results}) {
  final out = <int>[
    kBacnetPduComplexAck << 4,
    invokeId,
    kBacnetServiceReadPropertyMultiple,
  ];
  for (final result in results) {
    out.addAll(encodeContextObjectId(_kCtxObjectId, result.objectType, result.instance));
    out.addAll(openingTag(_kCtxRpmSpecs));
    for (final prop in result.props) {
      out.addAll(encodeContextUnsigned(_kCtxRpmPropId, prop.propertyId));
      if (prop.arrayIndex != null) {
        out.addAll(encodeContextUnsigned(_kCtxRpmPropIndex, prop.arrayIndex!));
      }
      final error = prop.error;
      if (error != null) {
        out.addAll(openingTag(_kCtxRpmError));
        out.addAll(encodeAppEnumerated(error.$1));
        out.addAll(encodeAppEnumerated(error.$2));
        out.addAll(closingTag(_kCtxRpmError));
      } else {
        out.addAll(openingTag(_kCtxRpmValue));
        if (prop.valueTags != null) {
          out.addAll(prop.valueTags!);
        }
        out.addAll(closingTag(_kCtxRpmValue));
      }
    }
    out.addAll(closingTag(_kCtxRpmSpecs));
  }
  return Uint8List.fromList(out);
}

// --- WriteProperty ---------------------------------------------------------------

/// A decoded WriteProperty request: the target [objectType]/[instance], the
/// [propertyId] being written, an optional [arrayIndex], the raw
/// [valueTags] bytes carried inside the `ctx3-open`/`ctx3-close` bracket
/// (untouched — the caller decodes these with `bacnet_tags.dart`), and an
/// optional write [priority] (accepted but, per the plan, ignored by the
/// caller).
class WpRequest {
  final int objectType;
  final int instance;
  final int propertyId;
  final int? arrayIndex;
  final Uint8List valueTags;
  final int? priority;

  WpRequest({
    required this.objectType,
    required this.instance,
    required this.propertyId,
    this.arrayIndex,
    required this.valueTags,
    this.priority,
  });
}

/// Parses WriteProperty [serviceData]. Layout: `ctx0 objectId, ctx1
/// propertyId, [ctx2 arrayIndex], ctx3-open <value> ctx3-close, [ctx4
/// priority]` — e.g. a trailing `0x49 0x08` is a ctx4 priority of 8. Returns
/// `null` — never throws — on any malformed/truncated input.
WpRequest? parseWriteProperty(Uint8List serviceData) {
  try {
    final reader = BacnetTagReader(serviceData);

    final objTag = reader.readTag();
    if (objTag == null || !objTag.isContext || objTag.tagNumber != _kCtxObjectId) {
      return null;
    }
    final objId = objTag.asObjectId();
    if (objId == null) {
      return null;
    }

    final propTag = reader.readTag();
    if (propTag == null || !propTag.isContext || propTag.tagNumber != _kCtxPropertyId) {
      return null;
    }
    final propertyId = propTag.asUnsigned();
    if (propertyId == null) {
      return null;
    }

    var tag = reader.readTag();
    if (tag == null) {
      return null;
    }

    int? arrayIndex;
    if (tag.isContext && !tag.isOpening && !tag.isClosing && tag.tagNumber == _kCtxArrayIndex) {
      arrayIndex = tag.asUnsigned();
      if (arrayIndex == null) {
        return null;
      }
      tag = reader.readTag();
      if (tag == null) {
        return null;
      }
    }

    if (!tag.isContext || !tag.isOpening || tag.tagNumber != _kCtxValue) {
      return null;
    }

    final valueStart = reader.position;
    Uint8List? valueTags;
    while (true) {
      final beforeClose = reader.position;
      final t = reader.readTag();
      if (t == null) {
        return null;
      }
      if (t.isContext && t.isClosing && t.tagNumber == _kCtxValue) {
        valueTags = Uint8List.fromList(serviceData.sublist(valueStart, beforeClose));
        break;
      }
    }

    int? priority;
    if (!reader.done) {
      final priorityTag = reader.readTag();
      if (priorityTag == null ||
          !priorityTag.isContext ||
          priorityTag.isOpening ||
          priorityTag.isClosing ||
          priorityTag.tagNumber != _kCtxPriority) {
        return null;
      }
      priority = priorityTag.asUnsigned();
      if (priority == null) {
        return null;
      }
    }

    return WpRequest(
      objectType: objId.$1,
      instance: objId.$2,
      propertyId: propertyId,
      arrayIndex: arrayIndex,
      valueTags: valueTags,
      priority: priority,
    );
  } catch (_) {
    return null;
  }
}

// --- SimpleAck / Error / Reject / Abort --------------------------------------

/// Builds a SimpleAck APDU for [invokeId] answering confirmed [service] —
/// e.g. `buildSimpleAck(5, kBacnetServiceWriteProperty)` -> `0x20 0x05 0x0F`.
Uint8List buildSimpleAck(int invokeId, int service) {
  return Uint8List.fromList([kBacnetPduSimpleAck << 4, invokeId, service]);
}

/// Builds an Error APDU for [invokeId] answering confirmed [service] with
/// `(errClass, errCode)`. Content: app Enumerated(errClass) + app
/// Enumerated(errCode) — e.g. class 2 (property) / code 32
/// (unknown-property) -> `0x50 <invokeId> <service> 0x91 0x02 0x91 0x20`.
Uint8List buildError(int invokeId, int service, int errClass, int errCode) {
  final out = <int>[
    kBacnetPduError << 4,
    invokeId,
    service,
    ...encodeAppEnumerated(errClass),
    ...encodeAppEnumerated(errCode),
  ];
  return Uint8List.fromList(out);
}

/// Builds a Reject APDU for [invokeId] with raw [reason] byte (e.g.
/// [kBacnetRejectReasonUnrecognizedService]) — `0x60 <invokeId> <reason>`.
/// The reject reason is an unencoded raw octet, not an application-tagged
/// value.
Uint8List buildReject(int invokeId, int reason) {
  return Uint8List.fromList([kBacnetPduReject << 4, invokeId, reason]);
}

/// Builds an Abort APDU for [invokeId] with raw [reason] byte (e.g.
/// [kBacnetAbortReasonSegmentationNotSupported]) — `0x71 <invokeId>
/// <reason>` (byte 0 sets [kBacnetAbortServerBit], since this device is
/// always the "server" sending the Abort). The abort reason is an unencoded
/// raw octet, not an application-tagged value.
Uint8List buildAbort(int invokeId, int reason) {
  return Uint8List.fromList([(kBacnetPduAbort << 4) | kBacnetAbortServerBit, invokeId, reason]);
}
