// Tests for the pure-Dart OPC UA SubscriptionManager (subscription /
// monitored-item lifecycle services), mobile/lib/protocols/opcua/opcua_subscriptions.dart.
//
// Every request/response is built/decoded VIA THE TASK 1 CODEC
// (opcua_binary.dart) — no hand-rolled hex, matching the wire-API style of
// opcua_services_test.dart. Struct field orders / ids / StatusCodes verified
// against the vendored Rust `opcua` 0.12.0 reference at
// C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/
// service_types/{create_subscription_request,create_subscription_response,
// modify_subscription_request,modify_subscription_response,
// set_publishing_mode_request,set_publishing_mode_response,
// delete_subscriptions_request,delete_subscriptions_response,
// create_monitored_items_request,create_monitored_items_response,
// monitored_item_create_request,monitored_item_create_result,
// monitoring_parameters,data_change_filter,publish_request,publish_response,
// republish_request,republish_response,notification_message,
// data_change_notification,monitored_item_notification,
// status_change_notification,subscription_acknowledgement}.rs and
// types/node_ids.rs / types/status_codes.rs / types/attribute.rs /
// types/service_types/enums.rs.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_subscriptions.dart';

// --- Encoding ids (DefaultBinary), verified against types/node_ids.rs -------
const _createSubscriptionRequestId = 787;
const _createSubscriptionResponseId = 790;
const _modifySubscriptionRequestId = 793;
const _modifySubscriptionResponseId = 796;
const _setPublishingModeRequestId = 799;
const _setPublishingModeResponseId = 802;
const _deleteSubscriptionsRequestId = 847;
const _deleteSubscriptionsResponseId = 850;
const _createMonitoredItemsRequestId = 751;
const _createMonitoredItemsResponseId = 754;
const _modifyMonitoredItemsRequestId = 763;
const _modifyMonitoredItemsResponseId = 766;
const _deleteMonitoredItemsRequestId = 781;
const _deleteMonitoredItemsResponseId = 784;
const _publishRequestId = 826;
const _publishResponseId = 829; // node_ids.rs:1794
const _republishRequestId = 832;
const _republishResponseId = 835; // node_ids.rs:1796
const _serviceFaultId = 397;
// DataChangeFilter wire ExtensionObject typeId MUST be the DefaultBinary
// ENCODING id, not the plain DataType NodeId. Verified against the vendored
// Rust opcua 0.12.0 reference,
// C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/node_ids.rs:1761
// `DataChangeFilter_Encoding_DefaultBinary = 724` (node_ids.rs:217's
// `DataChangeFilter = 722` is the non-encoding NodeId and must be REJECTED
// as an ExtensionObject typeId with Bad_MonitoredItemFilterUnsupported).
const _dataChangeFilterTypeId = 724;
const _dataChangeFilterNonEncodingTypeId = 722; // node_ids.rs:217 — invalid on the wire
// NotificationMessage=805, DataChangeNotification=811,
// StatusChangeNotification=820 (node_ids.rs:1788,1790,1791).
const _dataChangeNotificationTypeId = 811;
const _statusChangeNotificationTypeId = 820;

// --- StatusCodes, verified against types/status_codes.rs -------------------
const _statusGood = 0;
const _statusBadServiceUnsupported = 0x800B0000;
const _statusBadNothingToDo = 0x800F0000;
const _statusBadSubscriptionIdInvalid = 0x80280000;
const _statusBadNodeIdUnknown = 0x80340000;
const _statusBadAttributeIdInvalid = 0x80350000;
const _statusBadIndexRangeInvalid = 0x80360000;
const _statusBadMonitoredItemIdInvalid = 0x80420000;
const _statusBadMonitoredItemFilterUnsupported = 0x80440000;
const _statusBadTooManySubscriptions = 0x80770000;
const _statusBadDeadbandFilterInvalid = 0x808E0000;
const _statusBadTooManyMonitoredItems = 0x80DB0000;
const _statusBadTimeout = 0x800A0000; // status_codes.rs:95
const _statusBadTooManyPublishRequests = 0x80780000; // status_codes.rs:199
const _statusBadNoSubscription = 0x80790000; // status_codes.rs:200
const _statusBadSequenceNumberUnknown = 0x807A0000; // status_codes.rs:201
const _statusBadMessageNotAvailable = 0x807B0000; // status_codes.rs:202

// --- AttributeIds, verified against types/attribute.rs ---------------------
const _attrValue = 13;
const _attrDisplayName = 4; // not Value -> Bad_AttributeIdInvalid

RequestHeader _reqHeader({int requestHandle = 1}) {
  return RequestHeader(
    authToken: const OpcNodeId.numeric(0, 0),
    timestamp: DateTime.utc(2026, 7, 6),
    requestHandle: requestHandle,
  );
}

/// CreateSubscriptionRequest body (past requestHeader, consumed by session):
/// requestedPublishingInterval f64, requestedLifetimeCount u32,
/// requestedMaxKeepAliveCount u32, maxNotificationsPerPublish u32,
/// publishingEnabled bool, priority u8.
OpcUaReader _createSubBody({
  double publishingInterval = 1000,
  int lifetimeCount = 30,
  int maxKeepAlive = 10,
  int maxNotifications = 0,
  bool publishingEnabled = true,
  int priority = 0,
}) {
  final w = OpcUaWriter();
  w.float64(publishingInterval);
  w.uint32(lifetimeCount);
  w.uint32(maxKeepAlive);
  w.uint32(maxNotifications);
  w.boolean(publishingEnabled);
  w.uint8(priority);
  return OpcUaReader(w.take());
}

/// ModifySubscriptionRequest body: subscriptionId u32, then same fields as
/// CreateSubscriptionRequest minus publishingEnabled (priority still last).
OpcUaReader _modifySubBody({
  required int subscriptionId,
  double publishingInterval = 1000,
  int lifetimeCount = 30,
  int maxKeepAlive = 10,
  int maxNotifications = 0,
  int priority = 0,
}) {
  final w = OpcUaWriter();
  w.uint32(subscriptionId);
  w.float64(publishingInterval);
  w.uint32(lifetimeCount);
  w.uint32(maxKeepAlive);
  w.uint32(maxNotifications);
  w.uint8(priority);
  return OpcUaReader(w.take());
}

/// SetPublishingModeRequest body: publishingEnabled bool, subscriptionIds[] u32
/// (Option<Vec<u32>> -> Int32 length, -1 == null).
OpcUaReader _setPublishingModeBody({
  required bool publishingEnabled,
  List<int>? subscriptionIds,
}) {
  final w = OpcUaWriter();
  w.boolean(publishingEnabled);
  if (subscriptionIds == null) {
    w.int32(-1);
  } else {
    w.int32(subscriptionIds.length);
    for (final id in subscriptionIds) {
      w.uint32(id);
    }
  }
  return OpcUaReader(w.take());
}

/// DeleteSubscriptionsRequest body: subscriptionIds[] u32.
OpcUaReader _deleteSubsBody(List<int>? subscriptionIds) {
  final w = OpcUaWriter();
  if (subscriptionIds == null) {
    w.int32(-1);
  } else {
    w.int32(subscriptionIds.length);
    for (final id in subscriptionIds) {
      w.uint32(id);
    }
  }
  return OpcUaReader(w.take());
}

/// A single MonitoredItemCreateRequest's raw bytes (item_to_monitor
/// ReadValueId + monitoring_mode Int32 enum + requested_parameters
/// MonitoringParameters), matching monitored_item_create_request.rs.
/// ReadValueId (read_value_id.rs): nodeId, attributeId u32, indexRange
/// String, dataEncoding QualifiedName.
/// MonitoringParameters (monitoring_parameters.rs): clientHandle u32,
/// samplingInterval f64, filter ExtensionObject, queueSize u32,
/// discardOldest bool.
void _writeMonitoredItemCreateRequest(
  OpcUaWriter w, {
  required OpcNodeId nodeId,
  int attributeId = _attrValue,
  String? indexRange,
  int monitoringMode = 2, // Reporting
  int clientHandle = 1,
  double samplingInterval = 0,
  Uint8List? filterBody, // null -> empty ExtensionObject (no filter)
  int filterTypeId = _dataChangeFilterTypeId,
  int queueSize = 1,
  bool discardOldest = true,
}) {
  w.nodeId(nodeId);
  w.uint32(attributeId);
  w.string(indexRange);
  w.qualifiedName(const OpcQualifiedName(ns: 0, name: null)); // dataEncoding
  w.int32(monitoringMode);
  w.uint32(clientHandle);
  w.float64(samplingInterval);
  if (filterBody == null) {
    w.extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false);
  } else {
    w.extensionObject(OpcNodeId.numeric(0, filterTypeId), filterBody);
  }
  w.uint32(queueSize);
  w.boolean(discardOldest);
}

/// DataChangeFilter body (data_change_filter.rs): trigger Int32 enum,
/// deadbandType u32, deadbandValue f64.
Uint8List _dataChangeFilterBody({
  int trigger = 1, // StatusValue
  int deadbandType = 1, // Absolute
  double deadbandValue = 1.0,
}) {
  final w = OpcUaWriter();
  w.int32(trigger);
  w.uint32(deadbandType);
  w.float64(deadbandValue);
  return w.take();
}

/// CreateMonitoredItemsRequest body: subscriptionId u32, timestampsToReturn
/// Int32 enum, itemsToCreate[] (each written via a callback so callers can
/// customize per-item).
OpcUaReader _createMonitoredItemsBody({
  required int subscriptionId,
  int timestampsToReturn = 2, // Both
  required List<void Function(OpcUaWriter)> items,
}) {
  final w = OpcUaWriter();
  w.uint32(subscriptionId);
  w.int32(timestampsToReturn);
  w.int32(items.length);
  for (final item in items) {
    item(w);
  }
  return OpcUaReader(w.take());
}

/// ModifyMonitoredItemsRequest body: subscriptionId u32, timestampsToReturn
/// Int32 enum, itemsToModify[] (monitoredItemId u32 + MonitoringParameters).
OpcUaReader _modifyMonitoredItemsBody({
  required int subscriptionId,
  int timestampsToReturn = 2,
  required List<
      ({
        int monitoredItemId,
        int clientHandle,
        double samplingInterval,
        Uint8List? filterBody,
        int filterTypeId,
        int queueSize,
        bool discardOldest,
      })> items,
}) {
  final w = OpcUaWriter();
  w.uint32(subscriptionId);
  w.int32(timestampsToReturn);
  w.int32(items.length);
  for (final item in items) {
    w.uint32(item.monitoredItemId);
    w.uint32(item.clientHandle);
    w.float64(item.samplingInterval);
    if (item.filterBody == null) {
      w.extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false);
    } else {
      w.extensionObject(OpcNodeId.numeric(0, item.filterTypeId), item.filterBody!);
    }
    w.uint32(item.queueSize);
    w.boolean(item.discardOldest);
  }
  return OpcUaReader(w.take());
}

/// DeleteMonitoredItemsRequest body: subscriptionId u32, monitoredItemIds[] u32.
OpcUaReader _deleteMonitoredItemsBody({
  required int subscriptionId,
  required List<int> monitoredItemIds,
}) {
  final w = OpcUaWriter();
  w.uint32(subscriptionId);
  w.int32(monitoredItemIds.length);
  for (final id in monitoredItemIds) {
    w.uint32(id);
  }
  return OpcUaReader(w.take());
}

/// A sampler that returns Good for known nodes and Bad_NodeIdUnknown for
/// anything else.
OpcDataValue Function(OpcNodeId) _sampler(Set<OpcNodeId> knownNodes) {
  return (nodeId) {
    if (!knownNodes.contains(nodeId)) {
      return const OpcDataValue(status: _statusBadNodeIdUnknown);
    }
    return OpcDataValue(
      variant: const OpcVariant(typeId: 6, value: 42),
      status: _statusGood,
      sourceTs: DateTime.utc(2026, 7, 6),
      serverTs: DateTime.utc(2026, 7, 6),
    );
  };
}

/// PublishRequest body: subscriptionAcknowledgements[]
/// (SubscriptionAcknowledgement{subscriptionId u32, sequenceNumber u32}).
OpcUaReader _publishBody([List<({int subscriptionId, int sequenceNumber})> acks = const []]) {
  final w = OpcUaWriter();
  w.int32(acks.length);
  for (final ack in acks) {
    w.uint32(ack.subscriptionId);
    w.uint32(ack.sequenceNumber);
  }
  return OpcUaReader(w.take());
}

/// RepublishRequest body: subscriptionId u32, retransmitSequenceNumber u32.
OpcUaReader _republishBody({required int subscriptionId, required int seq}) {
  final w = OpcUaWriter();
  w.uint32(subscriptionId);
  w.uint32(seq);
  return OpcUaReader(w.take());
}

/// Fully decodes a PublishResponse body (past the leading NodeId typeId,
/// which the caller has already consumed via `reader.nodeId()`).
({
  ResponseHeader header,
  int subscriptionId,
  List<int> availableSeq,
  bool moreNotifications,
  int sequenceNumber,
  List<({int clientHandle, OpcDataValue value})> items,
  int? statusChangeStatus,
  List<int> results,
}) _decodePublishResponse(OpcUaReader reader) {
  final header = reader.responseHeader();
  final subscriptionId = reader.uint32();
  final availLen = reader.int32();
  final availableSeq = <int>[];
  for (var i = 0; i < availLen; i++) {
    availableSeq.add(reader.uint32());
  }
  final moreNotifications = reader.boolean();
  final sequenceNumber = reader.uint32();
  reader.dateTime(); // publishTime
  final notifLen = reader.int32();
  final items = <({int clientHandle, OpcDataValue value})>[];
  int? statusChangeStatus;
  for (var i = 0; i < notifLen; i++) {
    final typeId = reader.extensionObjectHeader();
    expect(reader.lastExtensionObjectHasBody, isTrue);
    final bodyBytes = reader.byteString()!;
    final inner = OpcUaReader(Uint8List.fromList(bodyBytes));
    if (typeId.numericId == _dataChangeNotificationTypeId) {
      final monitoredLen = inner.int32();
      for (var j = 0; j < monitoredLen; j++) {
        final clientHandle = inner.uint32();
        final value = inner.dataValue();
        items.add((clientHandle: clientHandle, value: value));
      }
      expect(inner.int32(), -1); // diagnosticInfos null
    } else if (typeId.numericId == _statusChangeNotificationTypeId) {
      statusChangeStatus = inner.statusCode();
      inner.uint8(); // empty DiagnosticInfo (0x00)
    } else {
      fail('Unexpected notificationData typeId ${typeId.numericId}');
    }
  }
  final resultsLen = reader.int32();
  final results = <int>[];
  for (var i = 0; i < resultsLen; i++) {
    results.add(reader.statusCode());
  }
  reader.int32(); // diagnosticInfos: null array (-1)
  return (
    header: header,
    subscriptionId: subscriptionId,
    availableSeq: availableSeq,
    moreNotifications: moreNotifications,
    sequenceNumber: sequenceNumber,
    items: items,
    statusChangeStatus: statusChangeStatus,
    results: results,
  );
}

void main() {
  const knownNode = OpcNodeId.string(1, 'Known');
  final knownNodes = {knownNode};

  SubscriptionManager buildManager() =>
      SubscriptionManager(sampler: _sampler(knownNodes));

  /// Calls handleService and returns the FIRST PublishOut's body reader
  /// (this task's services always emit exactly one PublishOut per call).
  OpcUaReader callAndDecode(
    SubscriptionManager mgr,
    int requestTypeId,
    OpcUaReader body, {
    RequestHeader? header,
    int requestId = 1,
    int nowMs = 0,
  }) {
    final h = header ?? _reqHeader();
    final out = mgr.handleService(requestTypeId, body, h, requestId, nowMs);
    expect(out, hasLength(1));
    return OpcUaReader(out.single.body);
  }

  group('CreateSubscription', () {
    test('happy path: response has correct type id, echoes requestHandle, revises nothing extreme', () {
      final mgr = buildManager();
      final h = _reqHeader(requestHandle: 42);
      final body = _createSubBody(publishingInterval: 1000, lifetimeCount: 30, maxKeepAlive: 10);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body, header: h);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _createSubscriptionResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(respHeader.requestHandle, 42);
      final subscriptionId = reader.uint32();
      expect(subscriptionId, 1); // per-manager counter from 1
      final revisedInterval = reader.float64();
      expect(revisedInterval, 1000);
      final revisedLifetime = reader.uint32();
      expect(revisedLifetime, 30);
      final revisedKeepAlive = reader.uint32();
      expect(revisedKeepAlive, 10);
      expect(mgr.subscriptionCount, 1);
    });

    test('revision: NaN publishing interval -> 500ms default', () {
      final mgr = buildManager();
      final body = _createSubBody(publishingInterval: double.nan, lifetimeCount: 30, maxKeepAlive: 10);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32(); // subscriptionId
      expect(reader.float64(), 500);
    });

    test('revision: 60ms publishing interval rounds up to 100ms grid', () {
      final mgr = buildManager();
      final body = _createSubBody(publishingInterval: 60, lifetimeCount: 30, maxKeepAlive: 10);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32();
      expect(reader.float64(), 100);
    });

    test('revision: 125ms publishing interval rounds up to 150ms grid', () {
      final mgr = buildManager();
      final body = _createSubBody(publishingInterval: 125, lifetimeCount: 30, maxKeepAlive: 10);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32();
      expect(reader.float64(), 150);
    });

    test('revision: publishingInterval 5000000 (way over ceiling) clamps to 60000', () {
      final mgr = buildManager();
      final body = _createSubBody(publishingInterval: 5000000, lifetimeCount: 30, maxKeepAlive: 10);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32();
      expect(reader.float64(), 60000);
    });

    test('revision: keepAlive 0 -> revised to 10', () {
      final mgr = buildManager();
      final body = _createSubBody(publishingInterval: 1000, lifetimeCount: 30, maxKeepAlive: 0);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32();
      reader.float64();
      reader.uint32(); // lifetime
      expect(reader.uint32(), 10); // keepAlive
    });

    test('revision: keepAlive 999999 (way over ceiling) clamps to 3000', () {
      final mgr = buildManager();
      final body = _createSubBody(publishingInterval: 1000, lifetimeCount: 30, maxKeepAlive: 999999);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32();
      reader.float64();
      reader.uint32(); // lifetime
      expect(reader.uint32(), 3000); // keepAlive
    });

    test('revision: lifetimeCount raised to 3x revised keepAliveCount when too low (requested 10, keepAlive 1 -> 30, NOT 10)', () {
      final mgr = buildManager();
      // keepAlive requested 1 stays 1 (within [1,3000]); lifetime requested
      // 10 clamps to [30,10000] FIRST (-> 30), which already satisfies
      // 3*1=3, so revised lifetime must be 30 (reviewer's regression
      // scenario — a naive "clamp lifetime to max(requested,3*keepAlive)"
      // without the floor-clamp-first step would wrongly yield 10 here
      // since 10 >= 3*1).
      final body = _createSubBody(publishingInterval: 1000, lifetimeCount: 10, maxKeepAlive: 1);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32();
      reader.float64();
      final revisedLifetime = reader.uint32();
      final revisedKeepAlive = reader.uint32();
      expect(revisedKeepAlive, 1);
      expect(revisedLifetime, 30);
    });

    test('revision: lifetimeCount 99999 (way over ceiling) clamps to 10000, still >= 3x keepAlive', () {
      final mgr = buildManager();
      final body = _createSubBody(publishingInterval: 1000, lifetimeCount: 99999, maxKeepAlive: 10);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32();
      reader.float64();
      final revisedLifetime = reader.uint32();
      final revisedKeepAlive = reader.uint32();
      expect(revisedKeepAlive, 10);
      expect(revisedLifetime, 10000);
      expect(revisedLifetime, greaterThanOrEqualTo(3 * revisedKeepAlive));
    });

    test('revision: lifetimeCount raised to 3x revised keepAliveCount when too low', () {
      final mgr = buildManager();
      // keepAlive revises to 10 (from 0); lifetime requested as 5 clamps to
      // the [30,10000] floor first (-> 30), which already satisfies 3*10=30.
      final body = _createSubBody(publishingInterval: 1000, lifetimeCount: 5, maxKeepAlive: 0);
      final reader = callAndDecode(mgr, _createSubscriptionRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.uint32();
      reader.float64();
      final revisedLifetime = reader.uint32();
      final revisedKeepAlive = reader.uint32();
      expect(revisedKeepAlive, 10);
      expect(revisedLifetime, 30);
    });

    test('revision: maxNotificationsPerPublish 0 (unlimited) accepted as-is', () {
      final mgr = buildManager();
      final body = _createSubBody(maxNotifications: 0);
      final out = mgr.handleService(_createSubscriptionRequestId, body, _reqHeader(), 1, 0);
      expect(out, hasLength(1));
      // No fault -> Good result path exercised; nothing further to assert on
      // maxNotifications itself (not echoed back in CreateSubscriptionResponse).
      final reader = OpcUaReader(out.single.body);
      reader.nodeId();
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
    });

    test('11th subscription -> ServiceFault Bad_TooManySubscriptions', () {
      final mgr = buildManager();
      for (var i = 0; i < 10; i++) {
        final body = _createSubBody();
        final out = mgr.handleService(_createSubscriptionRequestId, body, _reqHeader(), 1, 0);
        expect(out, hasLength(1));
        final r = OpcUaReader(out.single.body);
        final typeId = r.nodeId();
        expect(typeId.numericId, _createSubscriptionResponseId);
      }
      expect(mgr.subscriptionCount, 10);
      final body = _createSubBody();
      final out = mgr.handleService(_createSubscriptionRequestId, body, _reqHeader(), 1, 0);
      expect(out, hasLength(1));
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadTooManySubscriptions);
      expect(mgr.subscriptionCount, 10); // unchanged
    });
  });

  group('ModifySubscription', () {
    test('unknown subscription id -> ServiceFault Bad_SubscriptionIdInvalid', () {
      final mgr = buildManager();
      final body = _modifySubBody(subscriptionId: 999);
      final reader = callAndDecode(mgr, _modifySubscriptionRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadSubscriptionIdInvalid);
    });

    test('known subscription -> revised values applied and returned', () {
      final mgr = buildManager();
      final createBody = _createSubBody(publishingInterval: 1000, lifetimeCount: 30, maxKeepAlive: 10);
      final createOut = mgr.handleService(_createSubscriptionRequestId, createBody, _reqHeader(), 1, 0);
      final createReader = OpcUaReader(createOut.single.body);
      createReader.nodeId();
      createReader.responseHeader();
      final subscriptionId = createReader.uint32();

      final modifyBody = _modifySubBody(
        subscriptionId: subscriptionId,
        publishingInterval: 60, // rounds up to 100
        lifetimeCount: 30,
        maxKeepAlive: 10,
      );
      final reader = callAndDecode(mgr, _modifySubscriptionRequestId, modifyBody);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _modifySubscriptionResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.float64(), 100); // revised publishing interval
      expect(reader.uint32(), 30); // revised lifetime
      expect(reader.uint32(), 10); // revised keep alive
    });
  });

  group('SetPublishingMode', () {
    test('mixed known/unknown ids -> per-result Good/Bad_SubscriptionIdInvalid, flips publishingEnabled', () {
      final mgr = buildManager();
      final createOut = mgr.handleService(
        _createSubscriptionRequestId,
        _createSubBody(),
        _reqHeader(),
        1,
        0,
      );
      final createReader = OpcUaReader(createOut.single.body);
      createReader.nodeId();
      createReader.responseHeader();
      final subId = createReader.uint32();

      final body = _setPublishingModeBody(
        publishingEnabled: false,
        subscriptionIds: [subId, 999],
      );
      final reader = callAndDecode(mgr, _setPublishingModeRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _setPublishingModeResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      final count = reader.int32();
      expect(count, 2);
      expect(reader.statusCode(), _statusGood);
      expect(reader.statusCode(), _statusBadSubscriptionIdInvalid);
    });

    test('null subscriptionIds -> ServiceFault Bad_NothingToDo', () {
      final mgr = buildManager();
      final body = _setPublishingModeBody(publishingEnabled: true, subscriptionIds: null);
      final reader = callAndDecode(mgr, _setPublishingModeRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadNothingToDo);
    });

    test('empty subscriptionIds array -> ServiceFault Bad_NothingToDo', () {
      final mgr = buildManager();
      final body = _setPublishingModeBody(publishingEnabled: true, subscriptionIds: []);
      final reader = callAndDecode(mgr, _setPublishingModeRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadNothingToDo);
    });
  });

  group('DeleteSubscriptions', () {
    test('deletes a known subscription; subsequent modify on it -> Bad_SubscriptionIdInvalid', () {
      final mgr = buildManager();
      final createOut = mgr.handleService(
        _createSubscriptionRequestId,
        _createSubBody(),
        _reqHeader(),
        1,
        0,
      );
      final createReader = OpcUaReader(createOut.single.body);
      createReader.nodeId();
      createReader.responseHeader();
      final subId = createReader.uint32();
      expect(mgr.subscriptionCount, 1);

      final deleteBody = _deleteSubsBody([subId]);
      final reader = callAndDecode(mgr, _deleteSubscriptionsRequestId, deleteBody);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _deleteSubscriptionsResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      expect(mgr.subscriptionCount, 0);

      // Subsequent modify on the now-deleted id faults.
      final modifyBody = _modifySubBody(subscriptionId: subId);
      final modifyReader = callAndDecode(mgr, _modifySubscriptionRequestId, modifyBody);
      final modifyTypeId = modifyReader.nodeId();
      expect(modifyTypeId.numericId, _serviceFaultId);
      final modifyHeader = modifyReader.responseHeader();
      expect(modifyHeader.serviceResult, _statusBadSubscriptionIdInvalid);
    });

    test('unknown id in delete -> per-result Bad_SubscriptionIdInvalid', () {
      final mgr = buildManager();
      final deleteBody = _deleteSubsBody([999]);
      final reader = callAndDecode(mgr, _deleteSubscriptionsRequestId, deleteBody);
      reader.nodeId();
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadSubscriptionIdInvalid);
    });

    test('null subscriptionIds -> ServiceFault Bad_NothingToDo', () {
      final mgr = buildManager();
      final deleteBody = _deleteSubsBody(null);
      final reader = callAndDecode(mgr, _deleteSubscriptionsRequestId, deleteBody);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadNothingToDo);
    });
  });

  group('CreateMonitoredItems', () {
    late SubscriptionManager mgr;
    late int subId;

    setUp(() {
      mgr = buildManager();
      final createOut = mgr.handleService(
        _createSubscriptionRequestId,
        _createSubBody(),
        _reqHeader(),
        1,
        0,
      );
      final createReader = OpcUaReader(createOut.single.body);
      createReader.nodeId();
      createReader.responseHeader();
      subId = createReader.uint32();
    });

    test('unknown subscription id -> ServiceFault Bad_SubscriptionIdInvalid', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: 999,
        items: [
          (w) => _writeMonitoredItemCreateRequest(w, nodeId: knownNode),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadSubscriptionIdInvalid);
    });

    test('null/empty items -> ServiceFault Bad_NothingToDo', () {
      final body = _createMonitoredItemsBody(subscriptionId: subId, items: []);
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadNothingToDo);
    });

    test('bad attributeId (not Value) -> per-item Bad_AttributeIdInvalid', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                attributeId: _attrDisplayName,
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _createMonitoredItemsResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 1); // resultCount
      expect(reader.statusCode(), _statusBadAttributeIdInvalid);
    });

    test('unknown node -> per-item Bad_NodeIdUnknown', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: const OpcNodeId.string(1, 'DoesNotExist'),
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadNodeIdUnknown);
    });

    test('non-null indexRange -> per-item Bad_IndexRangeInvalid', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                indexRange: '0:1',
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadIndexRangeInvalid);
    });

    test('percent (2) deadband type -> per-item Bad_MonitoredItemFilterUnsupported', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                filterBody: _dataChangeFilterBody(deadbandType: 2),
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadMonitoredItemFilterUnsupported);
    });

    test('negative deadband value -> per-item Bad_DeadbandFilterInvalid', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                filterBody: _dataChangeFilterBody(deadbandType: 1, deadbandValue: -1.0),
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadDeadbandFilterInvalid);
    });

    test('non-finite (NaN) deadband value -> per-item Bad_DeadbandFilterInvalid', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                filterBody: _dataChangeFilterBody(deadbandType: 1, deadbandValue: double.nan),
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadDeadbandFilterInvalid);
    });

    test('unknown filter type id with a body -> per-item Bad_MonitoredItemFilterUnsupported', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                filterTypeId: 9999, // not DataChangeFilter (724)
                filterBody: Uint8List.fromList([1, 2, 3]),
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadMonitoredItemFilterUnsupported);
    });

    test('DataChangeFilter non-encoding NodeId (722) with a body -> per-item Bad_MonitoredItemFilterUnsupported', () {
      // node_ids.rs:217 `DataChangeFilter = 722` is the plain DataType
      // NodeId, not the DefaultBinary encoding id (724, node_ids.rs:1761).
      // A real client would never send 722 as an ExtensionObject typeId;
      // the server must reject it like any other unsupported filter type
      // rather than silently accepting it as if it were 724 (the bug this
      // test guards against).
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                filterTypeId: _dataChangeFilterNonEncodingTypeId, // 722
                filterBody: _dataChangeFilterBody(deadbandType: 1, deadbandValue: 0.5),
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadMonitoredItemFilterUnsupported);
    });

    test('valid absolute-deadband filter accepted -> Good, revised sampling/queue, monotonic item ids', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                filterBody: _dataChangeFilterBody(deadbandType: 1, deadbandValue: 0.5),
              ),
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                filterBody: null, // no filter -> also Good
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _createMonitoredItemsResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 2);

      final status1 = reader.statusCode();
      expect(status1, _statusGood);
      final itemId1 = reader.uint32();
      reader.float64(); // revised sampling interval
      reader.uint32(); // revised queue size
      reader.extensionObjectHeader(); // filterResult (empty in v1)

      final status2 = reader.statusCode();
      expect(status2, _statusGood);
      final itemId2 = reader.uint32();
      reader.float64();
      reader.uint32();
      reader.extensionObjectHeader();

      expect(itemId2, greaterThan(itemId1)); // monotonic per-manager counter
      expect(mgr.monitoredItemCount, 2);
    });

    test('zero queueSize revised to 1', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                queueSize: 0,
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusGood);
      reader.uint32(); // itemId
      reader.float64(); // sampling
      expect(reader.uint32(), 1); // revised queue size
    });

    test('negative sampling interval revised to the subscription publishing interval', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                samplingInterval: -1,
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusGood);
      reader.uint32(); // itemId
      final revisedSampling = reader.float64();
      expect(revisedSampling, 1000); // the subscription's publishing interval
    });

    test('zero sampling interval revised to the subscription publishing interval', () {
      // Spec: samplingInterval <= 0 (INCLUDING 0, not just negative) ->
      // inherit the subscription's revised publishing interval.
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                samplingInterval: 0,
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusGood);
      reader.uint32(); // itemId
      final revisedSampling = reader.float64();
      expect(revisedSampling, 1000); // the subscription's publishing interval
    });

    test('sampling interval 1e9 (way over ceiling) clamps to 60000', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                samplingInterval: 1e9,
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusGood);
      reader.uint32(); // itemId
      final revisedSampling = reader.float64();
      expect(revisedSampling, 60000);
    });

    test('queueSize 99999 (way over ceiling) clamps to 100', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                queueSize: 99999,
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusGood);
      reader.uint32(); // itemId
      reader.float64(); // sampling
      expect(reader.uint32(), 100); // revised queue size
    });

    test('501st monitored item -> per-item Bad_TooManyMonitoredItems', () {
      final items = List.generate(
        501,
        (i) => (OpcUaWriter w) => _writeMonitoredItemCreateRequest(
              w,
              nodeId: knownNode,
              clientHandle: i + 1,
              filterBody: null,
            ),
      );
      final body = _createMonitoredItemsBody(subscriptionId: subId, items: items);
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      reader.responseHeader();
      final count = reader.int32();
      expect(count, 501);
      for (var i = 0; i < 500; i++) {
        expect(reader.statusCode(), _statusGood);
        reader.uint32();
        reader.float64();
        reader.uint32();
        reader.extensionObjectHeader();
      }
      expect(reader.statusCode(), _statusBadTooManyMonitoredItems);
      expect(mgr.monitoredItemCount, 500);
    });

    test('Disabled monitoring mode -> item created but no initial sample queued (no throw either way)', () {
      final body = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(
                w,
                nodeId: knownNode,
                monitoringMode: 0, // Disabled
                filterBody: null,
              ),
        ],
      );
      final reader = callAndDecode(mgr, _createMonitoredItemsRequestId, body);
      reader.nodeId();
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      expect(mgr.monitoredItemCount, 1);
    });
  });

  group('ModifyMonitoredItems', () {
    late SubscriptionManager mgr;
    late int subId;
    late int itemId;

    setUp(() {
      mgr = buildManager();
      final createSubOut = mgr.handleService(
        _createSubscriptionRequestId,
        _createSubBody(),
        _reqHeader(),
        1,
        0,
      );
      final createSubReader = OpcUaReader(createSubOut.single.body);
      createSubReader.nodeId();
      createSubReader.responseHeader();
      subId = createSubReader.uint32();

      final createItemsBody = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(w, nodeId: knownNode, filterBody: null),
        ],
      );
      final createItemsOut = mgr.handleService(
        _createMonitoredItemsRequestId,
        createItemsBody,
        _reqHeader(),
        1,
        0,
      );
      final createItemsReader = OpcUaReader(createItemsOut.single.body);
      createItemsReader.nodeId();
      createItemsReader.responseHeader();
      createItemsReader.int32(); // resultCount
      createItemsReader.statusCode();
      itemId = createItemsReader.uint32();
    });

    test('unknown subscription id -> ServiceFault Bad_SubscriptionIdInvalid', () {
      final body = _modifyMonitoredItemsBody(subscriptionId: 999, items: [
        (
          monitoredItemId: itemId,
          clientHandle: 1,
          samplingInterval: 0,
          filterBody: null,
          filterTypeId: 0,
          queueSize: 1,
          discardOldest: true,
        ),
      ]);
      final reader = callAndDecode(mgr, _modifyMonitoredItemsRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadSubscriptionIdInvalid);
    });

    test('unknown item id -> per-item Bad_MonitoredItemIdInvalid', () {
      final body = _modifyMonitoredItemsBody(subscriptionId: subId, items: [
        (
          monitoredItemId: 999,
          clientHandle: 1,
          samplingInterval: 0,
          filterBody: null,
          filterTypeId: 0,
          queueSize: 1,
          discardOldest: true,
        ),
      ]);
      final reader = callAndDecode(mgr, _modifyMonitoredItemsRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _modifyMonitoredItemsResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadMonitoredItemIdInvalid);
    });

    test('known item -> revised values applied and returned', () {
      final body = _modifyMonitoredItemsBody(subscriptionId: subId, items: [
        (
          monitoredItemId: itemId,
          clientHandle: 5,
          samplingInterval: 0,
          filterBody: null,
          filterTypeId: 0,
          queueSize: 0, // revises to 1
          discardOldest: true,
        ),
      ]);
      final reader = callAndDecode(mgr, _modifyMonitoredItemsRequestId, body);
      reader.nodeId();
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      reader.float64(); // revised sampling
      expect(reader.uint32(), 1); // revised queue size
    });
  });

  group('DeleteMonitoredItems', () {
    late SubscriptionManager mgr;
    late int subId;
    late int itemId;

    setUp(() {
      mgr = buildManager();
      final createSubOut = mgr.handleService(
        _createSubscriptionRequestId,
        _createSubBody(),
        _reqHeader(),
        1,
        0,
      );
      final createSubReader = OpcUaReader(createSubOut.single.body);
      createSubReader.nodeId();
      createSubReader.responseHeader();
      subId = createSubReader.uint32();

      final createItemsBody = _createMonitoredItemsBody(
        subscriptionId: subId,
        items: [
          (w) => _writeMonitoredItemCreateRequest(w, nodeId: knownNode, filterBody: null),
        ],
      );
      final createItemsOut = mgr.handleService(
        _createMonitoredItemsRequestId,
        createItemsBody,
        _reqHeader(),
        1,
        0,
      );
      final createItemsReader = OpcUaReader(createItemsOut.single.body);
      createItemsReader.nodeId();
      createItemsReader.responseHeader();
      createItemsReader.int32();
      createItemsReader.statusCode();
      itemId = createItemsReader.uint32();
    });

    test('unknown subscription id -> ServiceFault Bad_SubscriptionIdInvalid', () {
      final body = _deleteMonitoredItemsBody(subscriptionId: 999, monitoredItemIds: [itemId]);
      final reader = callAndDecode(mgr, _deleteMonitoredItemsRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadSubscriptionIdInvalid);
    });

    test('known item deleted -> Good result, count decrements', () {
      expect(mgr.monitoredItemCount, 1);
      final body = _deleteMonitoredItemsBody(subscriptionId: subId, monitoredItemIds: [itemId]);
      final reader = callAndDecode(mgr, _deleteMonitoredItemsRequestId, body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _deleteMonitoredItemsResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      expect(mgr.monitoredItemCount, 0);
    });

    test('unknown item id -> per-item Bad_MonitoredItemIdInvalid', () {
      final body = _deleteMonitoredItemsBody(subscriptionId: subId, monitoredItemIds: [999]);
      final reader = callAndDecode(mgr, _deleteMonitoredItemsRequestId, body);
      reader.nodeId();
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadMonitoredItemIdInvalid);
    });
  });

  group('Publish (826) / Republish (832): sampling + publish engine (Task 2)', () {
    // A mutable "live" sampler backed by a Map the test can mutate between
    // onTick calls to simulate a changing tag. Absent nodes -> Bad_NodeIdUnknown.
    late Map<OpcNodeId, OpcDataValue> live;
    late SubscriptionManager mgr;

    void setLive(int value, {int status = _statusGood}) {
      live[knownNode] = OpcDataValue(
        variant: OpcVariant(typeId: 6, value: value),
        status: status,
        sourceTs: DateTime.utc(2026, 7, 6),
        serverTs: DateTime.utc(2026, 7, 6),
      );
    }

    setUp(() {
      live = {
        knownNode: OpcDataValue(
          variant: const OpcVariant(typeId: 6, value: 42),
          status: _statusGood,
          sourceTs: DateTime.utc(2026, 7, 6),
          serverTs: DateTime.utc(2026, 7, 6),
        ),
      };
      mgr = SubscriptionManager(
        sampler: (nodeId) =>
            live[nodeId] ?? const OpcDataValue(status: _statusBadNodeIdUnknown),
      );
    });

    /// Creates a subscription with the given (grid-aligned) parameters,
    /// returning its id.
    int createSub({
      double publishingInterval = 1000,
      int lifetimeCount = 30,
      int maxKeepAlive = 3,
      int maxNotifications = 0,
      bool publishingEnabled = true,
      int nowMs = 0,
    }) {
      final out = mgr.handleService(
        _createSubscriptionRequestId,
        _createSubBody(
          publishingInterval: publishingInterval,
          lifetimeCount: lifetimeCount,
          maxKeepAlive: maxKeepAlive,
          maxNotifications: maxNotifications,
          publishingEnabled: publishingEnabled,
        ),
        _reqHeader(),
        1,
        nowMs,
      );
      final r = OpcUaReader(out.single.body);
      r.nodeId();
      r.responseHeader();
      return r.uint32();
    }

    /// Creates one monitored item on [nodeId] (default: knownNode),
    /// returning (itemId, clientHandle).
    ({int itemId, int clientHandle}) createItem(
      int subId, {
      OpcNodeId? nodeId,
      int clientHandle = 11,
      Uint8List? filterBody,
      int queueSize = 5,
      bool discardOldest = true,
      double samplingInterval = 0,
      int monitoringMode = 2,
      int nowMs = 0,
    }) {
      final out = mgr.handleService(
        _createMonitoredItemsRequestId,
        _createMonitoredItemsBody(
          subscriptionId: subId,
          items: [
            (w) => _writeMonitoredItemCreateRequest(
                  w,
                  nodeId: nodeId ?? knownNode,
                  clientHandle: clientHandle,
                  filterBody: filterBody,
                  queueSize: queueSize,
                  discardOldest: discardOldest,
                  samplingInterval: samplingInterval,
                  monitoringMode: monitoringMode,
                ),
          ],
        ),
        _reqHeader(),
        1,
        nowMs,
      );
      final r = OpcUaReader(out.single.body);
      r.nodeId();
      r.responseHeader();
      r.int32();
      r.statusCode();
      final itemId = r.uint32();
      return (itemId: itemId, clientHandle: clientHandle);
    }

    /// Parks a PublishRequest (no acks); returns handleService's raw result
    /// (empty == parked with nothing to answer yet).
    List<PublishOut> park({int requestId = 100, int nowMs = 0}) {
      return mgr.handleService(
        _publishRequestId,
        _publishBody(),
        _reqHeader(requestHandle: requestId),
        requestId,
        nowMs,
      );
    }

    test('Publish parked before change; delivers the initial queued sample on the first cycle', () {
      final subId = createSub(publishingInterval: 1000, nowMs: 0);
      final item = createItem(subId, nowMs: 0);

      final parkOut = park(requestId: 9, nowMs: 500);
      expect(parkOut, isEmpty); // parked, nothing to answer yet (< first boundary)

      final ticked = mgr.onTick(1000); // first cycle boundary
      expect(ticked, hasLength(1));
      expect(ticked.single.requestId, 9);
      final reader = OpcUaReader(ticked.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _publishResponseId);
      final resp = _decodePublishResponse(reader);
      expect(resp.subscriptionId, subId);
      expect(resp.sequenceNumber, 1);
      expect(resp.items, hasLength(1));
      expect(resp.items.single.clientHandle, item.clientHandle);
      expect(resp.items.single.value.variant!.value, 42);
      expect(resp.moreNotifications, isFalse);
      expect(resp.availableSeq, [1]);
    });

    test('no change -> keep-alive fires at exactly maxKeepAliveCount cycles; sequence NOT consumed', () {
      createSub(publishingInterval: 1000, maxKeepAlive: 3, nowMs: 0);
      createItem(1, nowMs: 0);

      // Drain the initial sample so subsequent cycles are genuinely
      // "no change".
      park(requestId: 1, nowMs: 0);
      final first = mgr.onTick(1000);
      expect(first, hasLength(1));
      final firstResp = _decodePublishResponse(OpcUaReader(first.single.body)..nodeId());
      expect(firstResp.sequenceNumber, 1);

      park(requestId: 2, nowMs: 1000);
      final second = mgr.onTick(2000); // keepAlive=1
      expect(second, isEmpty);
      final third = mgr.onTick(3000); // keepAlive=2 (not yet >= 3)
      expect(third, isEmpty);
      final fourth = mgr.onTick(4000); // keepAlive=3 -> fires
      expect(fourth, hasLength(1));
      expect(fourth.single.requestId, 2);
      final resp = _decodePublishResponse(OpcUaReader(fourth.single.body)..nodeId());
      expect(resp.items, isEmpty);
      expect(resp.sequenceNumber, 2); // next-expected, NOT consumed

      // A subsequent data change must still use sequence 2 (proving the
      // keep-alive above did not consume it).
      setLive(100);
      park(requestId: 3, nowMs: 4000);
      final fifth = mgr.onTick(5000);
      expect(fifth, hasLength(1));
      final fifthResp = _decodePublishResponse(OpcUaReader(fifth.single.body)..nodeId());
      expect(fifthResp.sequenceNumber, 2);
      expect(fifthResp.items.single.value.variant!.value, 100);
    });

    test('value change -> DataChangeNotification carries clientHandle + new value', () {
      final subId = createSub(publishingInterval: 1000, nowMs: 0);
      final item = createItem(subId, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // drains initial sample

      park(requestId: 2, nowMs: 1000);
      setLive(55);
      final out = mgr.onTick(2000);
      expect(out, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(out.single.body)..nodeId());
      expect(resp.subscriptionId, subId);
      expect(resp.items.single.clientHandle, item.clientHandle);
      expect(resp.items.single.value.variant!.value, 55);
      expect(resp.sequenceNumber, 2);
    });

    test('deadband: |delta| < d silent, |delta| == d triggers (inclusive), status change always triggers', () {
      createSub(publishingInterval: 1000, nowMs: 0);
      createItem(
        1,
        nowMs: 0,
        filterBody: _dataChangeFilterBody(trigger: 1, deadbandType: 1, deadbandValue: 5.0),
      );
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // drains initial sample (reported baseline = 42)

      setLive(46); // |46-42| = 4 < 5 -> silent
      park(requestId: 2, nowMs: 1000);
      final silentOut = mgr.onTick(2000);
      expect(silentOut, isEmpty);

      setLive(47); // |47-42| = 5 == deadband -> triggers (inclusive)
      final out = mgr.onTick(3000);
      expect(out, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(out.single.body)..nodeId());
      expect(resp.items.single.value.variant!.value, 47);

      // Status change always triggers, even with delta 0 against the last
      // REPORTED value (47).
      park(requestId: 3, nowMs: 3000);
      setLive(47, status: 0x80000000);
      final statusOut = mgr.onTick(4000);
      expect(statusOut, hasLength(1));
      final statusResp = _decodePublishResponse(OpcUaReader(statusOut.single.body)..nodeId());
      expect(statusResp.items.single.value.status, 0x80000000);
    });

    test('trigger=Status: value-only changes ignored; status changes still trigger', () {
      createSub(publishingInterval: 1000, nowMs: 0);
      createItem(
        1,
        nowMs: 0,
        filterBody: _dataChangeFilterBody(trigger: 0, deadbandType: 0, deadbandValue: 0),
      );
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // drains initial sample

      setLive(999); // value-only change
      park(requestId: 2, nowMs: 1000);
      final out = mgr.onTick(2000);
      expect(out, isEmpty);

      setLive(999, status: 0x80000000); // status change, same value
      final out2 = mgr.onTick(3000);
      expect(out2, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(out2.single.body)..nodeId());
      expect(resp.items.single.value.status, 0x80000000);
    });

    test('queue overflow discardOldest=true: oldest dropped, overflow bit 0x480 on oldest surviving entry', () {
      createSub(publishingInterval: 1000, nowMs: 0);
      createItem(1, nowMs: 0, queueSize: 2, discardOldest: true, filterBody: null);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // drains initial sample

      // Accumulate 3 changes with NO parked request in between, so the
      // queue (cap 2) overflows.
      setLive(1);
      mgr.onTick(2000); // queue: [1]
      setLive(2);
      mgr.onTick(3000); // queue: [1, 2]
      setLive(3);
      mgr.onTick(4000); // overflow: drop oldest (1) -> [2*, 3]

      // The subscription is late (unserved queued data from past cycles), so
      // this Publish is answered IMMEDIATELY at arrival, not parked.
      final out = mgr.handleService(
        _publishRequestId,
        _publishBody(),
        _reqHeader(requestHandle: 9),
        9,
        4500,
      );
      expect(out, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(out.single.body)..nodeId());
      expect(resp.items, hasLength(2));
      expect(resp.items[0].value.variant!.value, 2);
      expect(resp.items[0].value.status! & 0x480, 0x480);
      expect(resp.items[1].value.variant!.value, 3);
      expect(resp.items[1].value.status! & 0x480, 0);
    });

    test('queue overflow discardOldest=false: newest sample dropped, overflow bit on newest queued entry', () {
      createSub(publishingInterval: 1000, nowMs: 0);
      createItem(1, nowMs: 0, queueSize: 2, discardOldest: false, filterBody: null);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // drains initial sample

      setLive(1);
      mgr.onTick(2000); // queue: [1]
      setLive(2);
      mgr.onTick(3000); // queue: [1, 2]
      setLive(3);
      mgr.onTick(4000); // overflow: new sample (3) dropped; bit set on newest queued (2)

      // The subscription is late (unserved queued data from past cycles), so
      // this Publish is answered IMMEDIATELY at arrival, not parked.
      final out = mgr.handleService(
        _publishRequestId,
        _publishBody(),
        _reqHeader(requestHandle: 9),
        9,
        4500,
      );
      expect(out, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(out.single.body)..nodeId());
      expect(resp.items, hasLength(2));
      expect(resp.items[0].value.variant!.value, 1);
      expect(resp.items[0].value.status! & 0x480, 0);
      expect(resp.items[1].value.variant!.value, 2);
      expect(resp.items[1].value.status! & 0x480, 0x480);
    });

    test('maxNotificationsPerPublish truncation + moreNotifications + follow-up drain', () {
      live[const OpcNodeId.string(1, 'A')] = OpcDataValue(
        variant: const OpcVariant(typeId: 6, value: 1),
        status: _statusGood,
        sourceTs: DateTime.utc(2026, 7, 6),
        serverTs: DateTime.utc(2026, 7, 6),
      );
      live[const OpcNodeId.string(1, 'B')] = live[const OpcNodeId.string(1, 'A')]!;
      live[const OpcNodeId.string(1, 'C')] = live[const OpcNodeId.string(1, 'A')]!;

      final subOut = mgr.handleService(
        _createSubscriptionRequestId,
        _createSubBody(publishingInterval: 1000, lifetimeCount: 30, maxKeepAlive: 50, maxNotifications: 2),
        _reqHeader(),
        1,
        0,
      );
      final subReader = OpcUaReader(subOut.single.body);
      subReader.nodeId();
      subReader.responseHeader();
      final subId = subReader.uint32();

      mgr.handleService(
        _createMonitoredItemsRequestId,
        _createMonitoredItemsBody(
          subscriptionId: subId,
          items: [
            (w) => _writeMonitoredItemCreateRequest(w,
                nodeId: const OpcNodeId.string(1, 'A'), clientHandle: 1, filterBody: null),
            (w) => _writeMonitoredItemCreateRequest(w,
                nodeId: const OpcNodeId.string(1, 'B'), clientHandle: 2, filterBody: null),
            (w) => _writeMonitoredItemCreateRequest(w,
                nodeId: const OpcNodeId.string(1, 'C'), clientHandle: 3, filterBody: null),
          ],
        ),
        _reqHeader(),
        1,
        0,
      );

      // 3 initial samples are queued (one per item at CreateMonitoredItems).
      // Only 2 of the 3 should be drained per response (maxNotifications=2).
      park(requestId: 1, nowMs: 0);
      final out = mgr.onTick(1000);
      expect(out, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(out.single.body)..nodeId());
      expect(resp.items, hasLength(2));
      expect(resp.moreNotifications, isTrue);
      expect(resp.sequenceNumber, 1);

      // Follow-up: the next parked request drains the remaining item.
      park(requestId: 2, nowMs: 1000);
      final out2 = mgr.onTick(2000);
      expect(out2, hasLength(1));
      final resp2 = _decodePublishResponse(OpcUaReader(out2.single.body)..nodeId());
      expect(resp2.items, hasLength(1));
      expect(resp2.moreNotifications, isFalse);
      expect(resp2.sequenceNumber, 2);
    });

    test('late subscription: change with no parked request is answered immediately by the next Publish', () {
      createSub(publishingInterval: 1000, nowMs: 0);
      createItem(1, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // drains initial sample

      setLive(2);
      final tickOut = mgr.onTick(2000); // no parked request -> marked late
      expect(tickOut, isEmpty);

      final immediate = mgr.handleService(
        _publishRequestId,
        _publishBody(),
        _reqHeader(requestHandle: 77),
        77,
        2500,
      );
      expect(immediate, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(immediate.single.body)..nodeId());
      expect(resp.items.single.value.variant!.value, 2);
    });

    test('acks remove sequence numbers from the retransmission buffer', () {
      final subId = createSub(publishingInterval: 1000, nowMs: 0);
      createItem(subId, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      final first = mgr.onTick(1000); // seq 1, buffer: [1]
      expect(first, hasLength(1));

      setLive(2);
      park(requestId: 2, nowMs: 1000);
      final second = mgr.onTick(2000); // seq 2, buffer: [1, 2]
      final secondResp = _decodePublishResponse(OpcUaReader(second.single.body)..nodeId());
      expect(secondResp.availableSeq, [1, 2]);

      // Ack seq 1 (removes it from the buffer); the response consuming this
      // ack may arrive immediately (if the subscription is already late) or
      // via the next tick — drive both deterministically.
      setLive(3);
      final ackOut = mgr.handleService(
        _publishRequestId,
        _publishBody([(subscriptionId: subId, sequenceNumber: 1)]),
        _reqHeader(requestHandle: 3),
        3,
        2500,
      );
      final tickOut = mgr.onTick(3000);
      final consuming = ackOut.isNotEmpty ? ackOut : tickOut;
      expect(consuming, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(consuming.single.body)..nodeId());
      expect(resp.results, [_statusGood]);
      expect(resp.availableSeq, isNot(contains(1)));
    });

    test('ack with unknown sequence number -> Bad_SequenceNumberUnknown in results', () {
      final subId = createSub(publishingInterval: 1000, nowMs: 0);
      createItem(subId, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // seq 1, buffer: [1]

      setLive(2);
      final ackOut = mgr.handleService(
        _publishRequestId,
        _publishBody([(subscriptionId: subId, sequenceNumber: 999)]),
        _reqHeader(requestHandle: 2),
        2,
        1500,
      );
      final tickOut = mgr.onTick(2000);
      final consuming = ackOut.isNotEmpty ? ackOut : tickOut;
      expect(consuming, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(consuming.single.body)..nodeId());
      expect(resp.results, [_statusBadSequenceNumberUnknown]);
    });

    test('ack with unknown subscription id -> Bad_SubscriptionIdInvalid in results', () {
      final subId = createSub(publishingInterval: 1000, nowMs: 0);
      createItem(subId, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000);

      setLive(2);
      final ackOut = mgr.handleService(
        _publishRequestId,
        _publishBody([(subscriptionId: 99999, sequenceNumber: 1)]),
        _reqHeader(requestHandle: 5),
        5,
        1500,
      );
      final tickOut = mgr.onTick(2000);
      final consuming = ackOut.isNotEmpty ? ackOut : tickOut;
      expect(consuming, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(consuming.single.body)..nodeId());
      expect(resp.results, [_statusBadSubscriptionIdInvalid]);
    });

    test('Republish hit returns the same stored NotificationMessage; miss -> Bad_MessageNotAvailable', () {
      final subId = createSub(publishingInterval: 1000, nowMs: 0);
      final item = createItem(subId, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000);

      final republishOut = mgr.handleService(
        _republishRequestId,
        _republishBody(subscriptionId: subId, seq: 1),
        _reqHeader(),
        2,
        1500,
      );
      expect(republishOut, hasLength(1));
      final reader = OpcUaReader(republishOut.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _republishResponseId);
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusGood);
      final seq = reader.uint32();
      expect(seq, 1);
      reader.dateTime(); // publishTime
      final notifLen = reader.int32();
      expect(notifLen, 1);
      final innerTypeId = reader.extensionObjectHeader();
      expect(innerTypeId.numericId, _dataChangeNotificationTypeId);
      final innerBody = reader.byteString()!;
      final innerReader = OpcUaReader(Uint8List.fromList(innerBody));
      final monLen = innerReader.int32();
      expect(monLen, 1);
      final ch = innerReader.uint32();
      expect(ch, item.clientHandle);
      final value = innerReader.dataValue();
      expect(value.variant!.value, 42);

      // Miss: sequence 999 was never sent.
      final missOut = mgr.handleService(
        _republishRequestId,
        _republishBody(subscriptionId: subId, seq: 999),
        _reqHeader(),
        3,
        1600,
      );
      expect(missOut, hasLength(1));
      final missReader = OpcUaReader(missOut.single.body);
      final missTypeId = missReader.nodeId();
      expect(missTypeId.numericId, _serviceFaultId);
      final missHeader = missReader.responseHeader();
      expect(missHeader.serviceResult, _statusBadMessageNotAvailable);
    });

    test('Republish unknown subscription -> ServiceFault Bad_SubscriptionIdInvalid', () {
      final out = mgr.handleService(
        _republishRequestId,
        _republishBody(subscriptionId: 999, seq: 1),
        _reqHeader(),
        1,
        0,
      );
      expect(out, hasLength(1));
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadSubscriptionIdInvalid);
    });

    test('retransmission buffer cap 20: oldest silently dropped', () {
      final subId = createSub(publishingInterval: 1000, maxKeepAlive: 9999, nowMs: 0);
      createItem(subId, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // seq 1

      // Generate messages seq 2..25, parking a fresh request before each
      // cycle so every cycle delivers immediately (no lateness).
      for (var i = 2; i <= 25; i++) {
        setLive(i);
        park(requestId: i, nowMs: (i - 1) * 1000 - 500);
        mgr.onTick(i * 1000);
      }

      // Buffer should now hold only the most recent 20: seq 6..25.
      setLive(999);
      park(requestId: 999, nowMs: 25500);
      final out = mgr.onTick(26000);
      final resp = _decodePublishResponse(OpcUaReader(out.single.body)..nodeId());
      expect(resp.availableSeq, List<int>.generate(20, (i) => i + 7)); // 7..26
      expect(resp.availableSeq.length, 20);
      expect(resp.subscriptionId, subId);
    });

    test('lifetime timeout with NO parked request: subscription dies silently; later Publish -> Bad_NoSubscription', () {
      createSub(publishingInterval: 1000, maxKeepAlive: 3, lifetimeCount: 30, nowMs: 0);
      createItem(1, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // drains initial sample; resets counters

      // No further parked requests at all: every subsequent cycle
      // increments lifetime (nothing delivered). After lifetimeCount (30)
      // such cycles the subscription dies (silently, since nothing is
      // parked to carry the StatusChangeNotification).
      var nowMs = 1000;
      for (var i = 0; i < 30; i++) {
        nowMs += 1000;
        mgr.onTick(nowMs);
      }
      expect(mgr.subscriptionCount, 0);

      final out = mgr.handleService(_publishRequestId, _publishBody(), _reqHeader(), 1, nowMs + 1000);
      expect(out, hasLength(1));
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadNoSubscription);
    });

    test('lifetime timeout WITH a parked request: StatusChangeNotification(Bad_Timeout) delivered, then subscription gone', () {
      createSub(publishingInterval: 1000, maxKeepAlive: 3, lifetimeCount: 30, nowMs: 0);
      createItem(1, nowMs: 0);
      park(requestId: 1, nowMs: 0);
      mgr.onTick(1000); // drains initial sample (seq 1); resets counters

      // Starve for 29 cycles: lifetime reaches 29. Keep-alive becomes
      // ELIGIBLE from cycle 3 (keepAlive >= maxKeepAliveCount=3) but never
      // fires because no request is parked during the starvation window.
      var nowMs = 1000;
      for (var i = 0; i < 29; i++) {
        nowMs += 1000;
        expect(mgr.onTick(nowMs), isEmpty);
      }
      expect(mgr.subscriptionCount, 1);

      // Park a request JUST before the death cycle. On the 30th starved
      // cycle lifetime hits 30 >= lifetimeCount; the death check runs BEFORE
      // the keep-alive send, so the parked request carries the
      // StatusChangeNotification(Bad_Timeout) instead of a keep-alive.
      park(requestId: 3, nowMs: nowMs + 500);
      final out = mgr.onTick(nowMs + 1000);
      expect(out, hasLength(1));
      expect(out.single.requestId, 3);
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _publishResponseId);
      final resp = _decodePublishResponse(reader);
      expect(resp.header.serviceResult, _statusGood);
      expect(resp.statusChangeStatus, _statusBadTimeout);
      // Sequence number = next-expected (2 — the initial data message used
      // 1), NOT consumed: StatusChange messages are not data messages.
      expect(resp.sequenceNumber, 2);
      expect(mgr.subscriptionCount, 0);
    });

    test('publishing disabled: data withheld, keep-alives still flow; re-enable delivers queued data', () {
      final subId = createSub(publishingInterval: 1000, maxKeepAlive: 2, publishingEnabled: false, nowMs: 0);
      createItem(subId, nowMs: 0);

      // The initial sample was queued at CreateMonitoredItems regardless of
      // publishingEnabled, but disabled subscriptions never send data.
      park(requestId: 1, nowMs: 0);
      final first = mgr.onTick(1000); // keepAlive=1 (data withheld)
      expect(first, isEmpty);
      park(requestId: 2, nowMs: 1000);
      final second = mgr.onTick(2000); // keepAlive=2 -> fires (>= maxKeepAlive=2)
      expect(second, hasLength(1));
      final resp = _decodePublishResponse(OpcUaReader(second.single.body)..nodeId());
      expect(resp.items, isEmpty); // keep-alive only, despite queued data

      final enableOut = mgr.handleService(
        _setPublishingModeRequestId,
        _setPublishingModeBody(publishingEnabled: true, subscriptionIds: [subId]),
        _reqHeader(),
        1,
        2500,
      );
      expect(enableOut, hasLength(1));

      park(requestId: 3, nowMs: 2600);
      final third = mgr.onTick(3000);
      expect(third, hasLength(1));
      final thirdResp = _decodePublishResponse(OpcUaReader(third.single.body)..nodeId());
      expect(thirdResp.items, hasLength(1)); // the still-queued initial sample, now delivered
      expect(thirdResp.items.single.value.variant!.value, 42);
    });

    test('11th parked Publish -> immediate ServiceFault Bad_TooManyPublishRequests', () {
      createSub(publishingInterval: 1000, maxKeepAlive: 9999, nowMs: 0);
      createItem(1, nowMs: 0);
      for (var i = 0; i < 10; i++) {
        final out = park(requestId: i + 1, nowMs: 0);
        expect(out, isEmpty);
      }
      final eleventh = mgr.handleService(
        _publishRequestId,
        _publishBody(),
        _reqHeader(requestHandle: 11),
        11,
        0,
      );
      expect(eleventh, hasLength(1));
      final reader = OpcUaReader(eleventh.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadTooManyPublishRequests);
    });

    test('Publish with no subscriptions at all -> immediate ServiceFault Bad_NoSubscription', () {
      final out = mgr.handleService(_publishRequestId, _publishBody(), _reqHeader(), 1, 0);
      expect(out, hasLength(1));
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadNoSubscription);
    });

    test('sequence numbers strictly increase 1,2,3,4,5 across successive data messages', () {
      createSub(publishingInterval: 1000, nowMs: 0);
      createItem(1, nowMs: 0);
      final seqs = <int>[];
      for (var i = 1; i <= 5; i++) {
        setLive(i);
        park(requestId: i, nowMs: (i - 1) * 1000 + 100);
        final out = mgr.onTick(i * 1000);
        expect(out, hasLength(1));
        final resp = _decodePublishResponse(OpcUaReader(out.single.body)..nodeId());
        seqs.add(resp.sequenceNumber);
      }
      expect(seqs, [1, 2, 3, 4, 5]);
    });
  });

  group('Malformed input never throws', () {
    test('a truncated CreateSubscription body -> a ServiceFault, not a throw', () {
      final mgr = buildManager();
      // Only 2 bytes: far too short for the required fields.
      final body = OpcUaReader(Uint8List.fromList([1, 2]));
      List<PublishOut> out = const [];
      expect(() {
        out = mgr.handleService(_createSubscriptionRequestId, body, _reqHeader(), 1, 0);
      }, returnsNormally);
      expect(out, hasLength(1));
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
    });

    test('an unrecognized request type id routed to the manager -> ServiceFault Bad_ServiceUnsupported', () {
      final mgr = buildManager();
      final body = OpcUaReader(Uint8List(0));
      final out = mgr.handleService(999999, body, _reqHeader(), 1, 0);
      expect(out, hasLength(1));
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadServiceUnsupported);
    });
  });

  test('serviceIds set matches the nine subscription service request ids', () {
    expect(
      SubscriptionManager.serviceIds,
      {787, 793, 799, 847, 751, 763, 781, 826, 832},
    );
  });
}
