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
// monitoring_parameters,data_change_filter}.rs and types/node_ids.rs /
// types/status_codes.rs / types/attribute.rs / types/service_types/enums.rs.
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
const _republishRequestId = 832;
const _serviceFaultId = 397;
const _dataChangeFilterTypeId = 722;

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

    test('revision: lifetimeCount raised to 3x revised keepAliveCount when too low', () {
      final mgr = buildManager();
      // keepAlive revises to 10 (from 0); lifetime requested as 5 must be
      // raised to 3*10=30.
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
                filterTypeId: 9999, // not DataChangeFilter (722)
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

  group('Publish / Republish placeholders (Task 2 scope)', () {
    test('Publish -> ServiceFault Bad_ServiceUnsupported', () {
      final mgr = buildManager();
      final w = OpcUaWriter();
      w.int32(0); // subscriptionAcknowledgements: empty
      final body = OpcUaReader(w.take());
      final out = mgr.handleService(_publishRequestId, body, _reqHeader(), 1, 0);
      expect(out, hasLength(1));
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadServiceUnsupported);
    });

    test('Republish -> ServiceFault Bad_ServiceUnsupported', () {
      final mgr = buildManager();
      final w = OpcUaWriter();
      w.uint32(1); // subscriptionId
      w.uint32(1); // retransmitSequenceNumber
      final body = OpcUaReader(w.take());
      final out = mgr.handleService(_republishRequestId, body, _reqHeader(), 1, 0);
      expect(out, hasLength(1));
      final reader = OpcUaReader(out.single.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _serviceFaultId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusBadServiceUnsupported);
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
