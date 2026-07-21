// BACnet/IP request -> response dispatch — pure Dart, no dart:io / Flutter
// imports. This is the SINGLE definition of BACnet/IP datagram handling that
// BOTH the shipped UDP host (`services/bacnet_host.dart`) and the E2E fixture
// host (`mobile/tool/bacnet_host_probe.dart`) call, exactly as the FINS/SLMP
// stacks share `dispatchFinsDatagram`/`dispatchSlmpFrame`. Because the fixture
// host cannot import the shipped host (it extends `ChangeNotifier`, which
// pulls in `dart:ui`, unavailable under a plain `dart run`), sharing ONE
// dispatch is what makes the real third-party BAC0/bacpypes client's proof
// against the fixture also a proof of the shipped host — the bytes the client
// validates are, by construction rather than by diff, the bytes the app puts
// on the wire.
//
// *** SCOPE ***
// Serves: unconfirmed Who-Is -> I-Am (instance-range filtered); confirmed
// ReadProperty -> ComplexAck or Error; confirmed ReadPropertyMultiple ->
// ComplexAck with PER-PROPERTY embedded values/errors (one bad property never
// fails the whole batch), ALL/REQUIRED expanding to the object's full served
// property list ([_servedPropertiesFor], a PROTOCOL-level constant per object
// type — not something the image declares, since `BacnetObjectImage` has no
// "list my properties" member; see that function's doc), OPTIONAL expanding
// to nothing, and a reply that would exceed [kBacnetIAmMaxApduLength] (1476)
// bytes total datagram answered with Abort(buffer-overflow) instead; confirmed
// WriteProperty -> SimpleAck or Error, entirely through the caller-supplied
// [BacnetObjectImage] seam (force-gating, if any, is the IMAGE's job, not
// this dispatch's); a segmented confirmed request -> Abort
// (segmentation-not-supported); any other/unknown confirmed service choice ->
// Reject(unrecognized-service). An unconfirmed service choice this device
// does not serve is dropped (Reject requires an invoke ID, which
// Unconfirmed-Request PDUs never carry).
//
// *** ALWAYS AN ANSWER, NEVER SILENCE — for what PARSES ***
// Any confirmed request that parses far enough to yield an invoke ID gets a
// reply PDU (Ack/Error/Reject/Abort), never a drop. Only genuinely
// UNPARSEABLE input (bad BVLL/NPDU framing, an unparseable APDU envelope, or
// malformed per-service data) returns `null` — the host drops those with a
// WARN log, per `bacnet_bvll.dart`/`bacnet_services.dart`'s "never throws,
// returns null" contract, which this file also upholds throughout.
//
// Safety contract: [dispatchBacnetDatagram] returns `null` — and NEVER
// throws — on malformed, truncated, unsupported, or otherwise hostile input,
// since the UDP host feeds it arbitrary datagram bytes read straight off the
// wire and must never wedge its bind on one bad datagram.
library bacnet_dispatch;

import 'dart:typed_data';

import 'bacnet_bvll.dart';
import 'bacnet_services.dart';
import 'bacnet_tags.dart';

/// The outcome of one [BacnetObjectImage.readProperty] call: EITHER
/// [valueTags] (already app-tagged value bytes, ready to embed in a
/// ReadProperty ComplexAck) on success, OR [error] (`(errorClass,
/// errorCode)`) on failure — never both meaningfully populated (a caller
/// supplying both simply gets the error branch, since [dispatchBacnetDatagram]
/// checks [error] first).
class BacnetReadResult {
  final Uint8List? valueTags;
  final (int errClass, int errCode)? error;

  BacnetReadResult({this.valueTags, this.error});

  /// A successful read carrying the already-app-tagged [valueTags].
  factory BacnetReadResult.ok(Uint8List valueTags) =>
      BacnetReadResult(valueTags: valueTags);

  /// A failed read carrying only `(errClass, errCode)`.
  factory BacnetReadResult.error(int errClass, int errCode) =>
      BacnetReadResult(error: (errClass, errCode));
}

/// The outcome of one [BacnetObjectImage.writeProperty] call: `null` [error]
/// means the write landed (a SimpleAck is due); a non-null `(errClass,
/// errCode)` means it was refused or invalid.
class BacnetWriteResult {
  final (int errClass, int errCode)? error;

  BacnetWriteResult({this.error});

  /// A successful write.
  factory BacnetWriteResult.ok() => BacnetWriteResult();

  /// A failed/refused write carrying only `(errClass, errCode)`.
  factory BacnetWriteResult.error(int errClass, int errCode) =>
      BacnetWriteResult(error: (errClass, errCode));
}

/// The object model an incoming ReadProperty/ReadPropertyMultiple/
/// WriteProperty is served against. Deliberately abstract so the shipped host
/// (eventually) serves a tag-backed image while the E2E fixture host serves a
/// minimal hand-rolled one, both through the one [dispatchBacnetDatagram].
///
/// RPM/WP are NOT yet routed to this interface's members by
/// [dispatchBacnetDatagram] at this task (see the file header) — they are
/// declared here now so a later task can wire them through this SAME seam
/// without changing the shape either concrete image implements.
abstract class BacnetObjectImage {
  /// This device's own Device object instance number (e.g. 3056).
  int get deviceInstance;

  /// Every `(objectType, instance)` this device hosts, INCLUDING the device
  /// object itself. Order is the image's choice.
  List<(int type, int instance)> get objectList;

  /// Reads one property (optionally one array element, if [arrayIndex] is
  /// non-null) of object `(objectType, instance)`. Must NEVER throw: an
  /// unknown object/property is reported as an error [BacnetReadResult], not
  /// an exception.
  BacnetReadResult readProperty(
    int objectType,
    int instance,
    int propertyId,
    int? arrayIndex,
  );

  /// Writes [req]'s value to the target property. Must NEVER throw: a
  /// refused/invalid write is reported as an error [BacnetWriteResult].
  BacnetWriteResult writeProperty(WpRequest req);
}

/// A minimal, hand-rolled [BacnetObjectImage]: a Device object (Object_Name +
/// Object_Identifier only) plus zero or more Analog Value objects exposing
/// only Present_Value/Object_Identifier. This is NOT the tag-backed object
/// image (a later task, `BacnetTagImage`, serving the full device/AV/BV
/// property set through the shared force-gate chain) — it exists so (a) the
/// UDP host has something to serve before the map/tag-backed image lands, and
/// (b) the E2E fixture host (`mobile/tool/bacnet_host_probe.dart`) can seed a
/// device + one Analog Value independently of any project tags, which is the
/// whole point of this task's EARLY real-client gate: a client discovering and
/// reading this fixture settles the wire encodings before the real object
/// model exists at all.
class BacnetSimpleImage implements BacnetObjectImage {
  @override
  final int deviceInstance;

  /// This device's Object_Name (e.g. the fixture's "BACNET-E2E-FIXTURE").
  final String deviceName;

  /// Analog Value instance -> its (fixed) Present_Value.
  final Map<int, double> _analogValues;

  BacnetSimpleImage({
    required this.deviceInstance,
    required this.deviceName,
    Map<int, double> analogValues = const {},
  }) : _analogValues = Map.unmodifiable(analogValues);

  @override
  List<(int type, int instance)> get objectList => [
        (kBacnetObjectDevice, deviceInstance),
        for (final instance in _analogValues.keys)
          (kBacnetObjectAnalogValue, instance),
      ];

  @override
  BacnetReadResult readProperty(
    int objectType,
    int instance,
    int propertyId,
    int? arrayIndex,
  ) {
    if (objectType == kBacnetObjectDevice && instance == deviceInstance) {
      switch (propertyId) {
        case kBacnetPropObjectName:
          return BacnetReadResult.ok(encodeAppCharString(deviceName));
        case kBacnetPropObjectIdentifier:
          return BacnetReadResult.ok(
            encodeAppObjectId(kBacnetObjectDevice, deviceInstance),
          );
        default:
          return BacnetReadResult.error(
            kBacnetErrorClassProperty,
            kBacnetErrorCodeUnknownProperty,
          );
      }
    }

    if (objectType == kBacnetObjectAnalogValue &&
        _analogValues.containsKey(instance)) {
      switch (propertyId) {
        case kBacnetPropPresentValue:
          return BacnetReadResult.ok(encodeAppReal(_analogValues[instance]!));
        case kBacnetPropObjectIdentifier:
          return BacnetReadResult.ok(
            encodeAppObjectId(kBacnetObjectAnalogValue, instance),
          );
        default:
          return BacnetReadResult.error(
            kBacnetErrorClassProperty,
            kBacnetErrorCodeUnknownProperty,
          );
      }
    }

    return BacnetReadResult.error(
      kBacnetErrorClassObject,
      kBacnetErrorCodeUnknownObject,
    );
  }

  @override
  BacnetWriteResult writeProperty(WpRequest req) {
    // This minimal image serves no writable property — it exists only for
    // the E2E fixture / early host tests, which never write. Dispatch DOES
    // reach this now that WriteProperty is served for real (see
    // [_dispatchWriteProperty]); returning a refusal here is still correct
    // (never throws) since nothing in this image is writable.
    return BacnetWriteResult.error(
      kBacnetErrorClassProperty,
      kBacnetErrorCodeWriteAccessDenied,
    );
  }
}

/// Dispatches one raw BACnet/IP UDP [datagram] against [image], returning the
/// complete reply datagram bytes (BVLL+NPDU+APDU, ready to send back to the
/// sender) — or `null` when [datagram] is not servable at all (malformed
/// BVLL/NPDU framing, an unparseable APDU envelope, malformed per-service
/// data, or an unconfirmed service this device does not serve), in which case
/// the caller (the host) drops it without replying.
///
/// For anything that DOES parse into a confirmed request with a usable invoke
/// ID, this always returns a reply PDU — ComplexAck/SimpleAck, Error, Reject,
/// or Abort — never `null`. See the file header for the exact service scope
/// at this task.
///
/// Never throws: every codec function this calls already returns `null`
/// rather than throwing on hostile input, and this function's own logic adds
/// no additional failure modes beyond null-checks.
Uint8List? dispatchBacnetDatagram(Uint8List datagram, BacnetObjectImage image) {
  try {
    final apdu = parseBvllToApdu(datagram);
    if (apdu == null) {
      return null;
    }
    final parsed = parseApdu(apdu);
    if (parsed == null) {
      return null;
    }

    if (parsed.pduType == kBacnetPduUnconfirmedRequest) {
      return _dispatchUnconfirmed(parsed, image);
    }

    if (parsed.pduType == kBacnetPduConfirmedRequest) {
      return _dispatchConfirmed(parsed, image);
    }

    // parseApdu only ever returns Confirmed-Request or Unconfirmed-Request
    // (every other PDU type is one this device only ever BUILDS, never
    // receives) — this branch is unreachable but kept as a defensive drop.
    return null;
  } catch (_) {
    return null;
  }
}

/// Serves the unconfirmed services this device recognizes (Who-Is only, at
/// this task). Any other unconfirmed service choice is dropped: Reject
/// requires an invoke ID, which an Unconfirmed-Request never carries, so
/// there is no PDU to answer with.
Uint8List? _dispatchUnconfirmed(BacnetApdu parsed, BacnetObjectImage image) {
  if (parsed.serviceChoice != kBacnetServiceWhoIs) {
    return null;
  }
  final range = parseWhoIs(parsed.serviceData);
  if (range == null) {
    return null; // malformed Who-Is body: unparseable, drop.
  }
  final (low, high) = range;
  if (low != null && image.deviceInstance < low) {
    return null; // outside the requested range: no I-Am due.
  }
  if (high != null && image.deviceInstance > high) {
    return null;
  }
  final iAm = buildIAm(deviceInstance: image.deviceInstance);
  return buildBvllUnicast(iAm);
}

/// Serves the confirmed services this device recognizes (ReadProperty,
/// ReadPropertyMultiple, WriteProperty), aborts a segmented request, and
/// rejects any other/unknown service choice — always via the segmented/
/// invoke-id-bearing PDU builders, since a confirmed request that parses this
/// far always gets an answer.
Uint8List? _dispatchConfirmed(BacnetApdu parsed, BacnetObjectImage image) {
  final invokeId = parsed.invokeId;
  if (invokeId == null) {
    // parseApdu always sets an invoke ID for Confirmed-Request; defensive
    // drop only, never expected in practice.
    return null;
  }

  if (parsed.segmented) {
    return buildBvllUnicast(
      buildAbort(invokeId, kBacnetAbortReasonSegmentationNotSupported),
    );
  }

  switch (parsed.serviceChoice) {
    case kBacnetServiceReadProperty:
      return _dispatchReadProperty(invokeId, parsed.serviceData, image);
    case kBacnetServiceReadPropertyMultiple:
      return _dispatchReadPropertyMultiple(invokeId, parsed.serviceData, image);
    case kBacnetServiceWriteProperty:
      return _dispatchWriteProperty(invokeId, parsed.serviceData, image);
    default:
      return buildBvllUnicast(
        buildReject(invokeId, kBacnetRejectReasonUnrecognizedService),
      );
  }
}

Uint8List? _dispatchReadProperty(
  int invokeId,
  Uint8List serviceData,
  BacnetObjectImage image,
) {
  final req = parseReadProperty(serviceData);
  if (req == null) {
    return null; // malformed RP request body: unparseable, drop.
  }
  final result = image.readProperty(
    req.objectType,
    req.instance,
    req.propertyId,
    req.arrayIndex,
  );
  final error = result.error;
  if (error != null) {
    return buildBvllUnicast(
      buildError(invokeId, kBacnetServiceReadProperty, error.$1, error.$2),
    );
  }
  final valueTags = result.valueTags;
  if (valueTags == null) {
    // An image implementation that returns neither a value nor an error is
    // buggy, not the client's fault; report it as a property error rather
    // than silently dropping the reply.
    return buildBvllUnicast(
      buildError(
        invokeId,
        kBacnetServiceReadProperty,
        kBacnetErrorClassProperty,
        kBacnetErrorCodeUnknownProperty,
      ),
    );
  }
  return buildBvllUnicast(
    buildReadPropertyAck(invokeId: invokeId, req: req, valueTags: valueTags),
  );
}

// --- ReadPropertyMultiple -----------------------------------------------

/// The Device object's full served property list — a PROTOCOL-level constant
/// (every Device object this app ever hosts serves exactly this set),
/// independent of which concrete [BacnetObjectImage] answers the individual
/// `readProperty` calls. This lives HERE (not on the image) because
/// `BacnetObjectImage` deliberately has no "list my properties" member (see
/// the Task-3 interface) — RPM's ALL/REQUIRED expansion is dispatch-level
/// logic that works the same way for the minimal `BacnetSimpleImage` (most of
/// these come back as per-property unknown-property errors, which is fine —
/// RPM never fails as a whole for one bad property) and the full tag-backed
/// `BacnetTagImage` alike. MUST stay in sync with
/// `BacnetTagImage._readDeviceProperty`'s switch.
const List<int> kBacnetDeviceServedProperties = [
  kBacnetPropObjectIdentifier,
  kBacnetPropObjectName,
  kBacnetPropObjectType,
  kBacnetPropSystemStatus,
  kBacnetPropVendorName,
  kBacnetPropVendorIdentifier,
  kBacnetPropModelName,
  kBacnetPropFirmwareRevision,
  kBacnetPropApplicationSoftwareVersion,
  kBacnetPropProtocolVersion,
  kBacnetPropProtocolRevision,
  kBacnetPropProtocolServicesSupported,
  kBacnetPropProtocolObjectTypesSupported,
  kBacnetPropMaxApduLengthAccepted,
  kBacnetPropSegmentationSupported,
  kBacnetPropObjectList,
  kBacnetPropApduTimeout,
  kBacnetPropNumberOfApduRetries,
  kBacnetPropDatabaseRevision,
  kBacnetPropSerialNumber,
  kBacnetPropPropertyList,
];

/// The Analog Value object's full served property list — see
/// [kBacnetDeviceServedProperties]'s doc for why this lives here. MUST stay
/// in sync with `BacnetTagImage._readAvProperty`'s switch.
const List<int> kBacnetAnalogValueServedProperties = [
  kBacnetPropObjectIdentifier,
  kBacnetPropObjectName,
  kBacnetPropObjectType,
  kBacnetPropPresentValue,
  kBacnetPropStatusFlags,
  kBacnetPropEventState,
  kBacnetPropOutOfService,
  kBacnetPropUnits,
  kBacnetPropPriorityArray,
  kBacnetPropRelinquishDefault,
];

/// The Binary Value object's full served property list (no Units — BACnet
/// Binary objects don't carry engineering units) — see
/// [kBacnetDeviceServedProperties]'s doc for why this lives here. MUST stay
/// in sync with `BacnetTagImage._readBvProperty`'s switch.
const List<int> kBacnetBinaryValueServedProperties = [
  kBacnetPropObjectIdentifier,
  kBacnetPropObjectName,
  kBacnetPropObjectType,
  kBacnetPropPresentValue,
  kBacnetPropStatusFlags,
  kBacnetPropEventState,
  kBacnetPropOutOfService,
  kBacnetPropPriorityArray,
  kBacnetPropRelinquishDefault,
];

/// The full served property-id list for [objectType] (Device/AnalogValue/
/// BinaryValue) — empty for any other/unknown object type, in which case an
/// ALL/REQUIRED request against it simply isn't expanded (see
/// [_dispatchReadPropertyMultiple], which only expands for a KNOWN object;
/// an unknown object's ALL/REQUIRED property id is passed straight to
/// `readProperty`, which reports unknown-object regardless of the property
/// id asked for).
List<int> _servedPropertiesFor(int objectType) {
  switch (objectType) {
    case kBacnetObjectDevice:
      return kBacnetDeviceServedProperties;
    case kBacnetObjectAnalogValue:
      return kBacnetAnalogValueServedProperties;
    case kBacnetObjectBinaryValue:
      return kBacnetBinaryValueServedProperties;
    default:
      return const [];
  }
}

Uint8List? _dispatchReadPropertyMultiple(
  int invokeId,
  Uint8List serviceData,
  BacnetObjectImage image,
) {
  final req = parseRpm(serviceData);
  if (req == null) {
    return null; // malformed RPM request body: unparseable, drop.
  }

  final knownObjects = <(int, int)>{...image.objectList};
  final results = <RpmResult>[];
  for (final spec in req.specs) {
    final isKnown = knownObjects.contains((spec.objectType, spec.instance));

    // Expand ALL(8)/REQUIRED(105) to the object's full served list (only
    // when the object is actually known — see [_servedPropertiesFor]'s doc);
    // OPTIONAL(80) always expands to nothing (there are no optional
    // properties in this device's v1 property set); anything else is asked
    // for literally.
    final effective = <(int, int?)>[];
    for (final (propertyId, arrayIndex) in spec.props) {
      if (propertyId == kBacnetPropOptional) {
        continue;
      }
      if ((propertyId == kBacnetPropAll || propertyId == kBacnetPropRequired) && isKnown) {
        for (final servedId in _servedPropertiesFor(spec.objectType)) {
          effective.add((servedId, null));
        }
      } else {
        effective.add((propertyId, arrayIndex));
      }
    }

    final propResults = <RpmPropResult>[];
    for (final (propertyId, arrayIndex) in effective) {
      final result = image.readProperty(spec.objectType, spec.instance, propertyId, arrayIndex);
      final error = result.error;
      final valueTags = result.valueTags;
      if (error != null) {
        propResults.add(RpmPropResult(propertyId: propertyId, arrayIndex: arrayIndex, error: error));
      } else if (valueTags == null) {
        // Same defensive fallback as [_dispatchReadProperty]: a buggy image
        // that answers neither a value nor an error is reported as a
        // property error, not silently dropped from the batch.
        propResults.add(RpmPropResult(
          propertyId: propertyId,
          arrayIndex: arrayIndex,
          error: (kBacnetErrorClassProperty, kBacnetErrorCodeUnknownProperty),
        ));
      } else {
        propResults.add(RpmPropResult(propertyId: propertyId, arrayIndex: arrayIndex, valueTags: valueTags));
      }
    }
    results.add(RpmResult(objectType: spec.objectType, instance: spec.instance, props: propResults));
  }

  final datagram = buildBvllUnicast(buildRpmAck(invokeId: invokeId, results: results));
  // The reply must never exceed the device's own advertised
  // Max_APDU_Length_Accepted / I-Am max length (1476, [kBacnetIAmMaxApduLength])
  // — measured on the WHOLE reply datagram (BVLL+NPDU+APDU), not just the
  // APDU payload.
  if (datagram.length > kBacnetIAmMaxApduLength) {
    return buildBvllUnicast(buildAbort(invokeId, kBacnetAbortReasonBufferOverflow));
  }
  return datagram;
}

// --- WriteProperty --------------------------------------------------------

Uint8List? _dispatchWriteProperty(
  int invokeId,
  Uint8List serviceData,
  BacnetObjectImage image,
) {
  final req = parseWriteProperty(serviceData);
  if (req == null) {
    return null; // malformed WP request body: unparseable, drop.
  }
  final result = image.writeProperty(req);
  final error = result.error;
  if (error != null) {
    return buildBvllUnicast(
      buildError(invokeId, kBacnetServiceWriteProperty, error.$1, error.$2),
    );
  }
  return buildBvllUnicast(buildSimpleAck(invokeId, kBacnetServiceWriteProperty));
}
