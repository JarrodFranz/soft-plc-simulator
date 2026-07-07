// OPC UA SubscriptionManager — subscription / monitored-item lifecycle
// services — pure Dart, no dart:io / Flutter imports, no Timer. Implements
// the seven non-Publish subscription services (CreateSubscription,
// ModifySubscription, SetPublishingMode, DeleteSubscriptions,
// CreateMonitoredItems, ModifyMonitoredItems, DeleteMonitoredItems);
// Publish/Republish are routed but answered with a Bad_ServiceUnsupported
// placeholder fault in this task (Task 2 replaces them with the real
// publish-cycle implementation — see onTick, currently a no-op stub).
//
// Every encoding id / struct layout / StatusCode / AttributeId used here is
// cross-checked against the Rust `opcua` crate (v0.12.0), vendored locally
// at:
//   C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/
// Specific files cited inline next to each constant/decision.
library opcua_subscriptions;

import 'dart:typed_data';

import 'opcua_binary.dart';

/// One MSG response to frame: [requestId] is the transport requestId to echo
/// in buildMsgChunk; [body] is the full encoded response body (type NodeId +
/// ResponseHeader + fields), ready to MSG-wrap.
class PublishOut {
  final int requestId;
  final Uint8List body;

  const PublishOut({required this.requestId, required this.body});
}

/// Service DefaultBinary encoding ids (types/node_ids.rs) — verified exact
/// against the vendored Rust source (grep of node_ids.rs `ObjectId` enum,
/// `*_Encoding_DefaultBinary` variants).
class _Ids {
  static const createSubscriptionRequest = 787; // node_ids.rs:1782
  static const createSubscriptionResponse = 790; // node_ids.rs:1783
  static const modifySubscriptionRequest = 793; // node_ids.rs:1784
  static const modifySubscriptionResponse = 796; // node_ids.rs:1785
  static const setPublishingModeRequest = 799; // node_ids.rs:1786
  static const setPublishingModeResponse = 802; // node_ids.rs:1787
  static const deleteSubscriptionsRequest = 847; // node_ids.rs:1800
  static const deleteSubscriptionsResponse = 850; // node_ids.rs:1801
  static const createMonitoredItemsRequest = 751; // node_ids.rs:1770
  static const createMonitoredItemsResponse = 754; // node_ids.rs:1771
  static const modifyMonitoredItemsRequest = 763; // node_ids.rs:1774
  static const modifyMonitoredItemsResponse = 766; // node_ids.rs:1775
  static const deleteMonitoredItemsRequest = 781; // node_ids.rs:1780
  static const deleteMonitoredItemsResponse = 784; // node_ids.rs:1781
  static const publishRequest = 826; // node_ids.rs:1793
  static const republishRequest = 832; // node_ids.rs:1795
  static const serviceFault = 397; // node_ids.rs:1662 (opcua_session.dart's _Ids.serviceFault)
  static const dataChangeFilter = 722; // node_ids.rs:217
}

/// StatusCodes used by this file. Verified one-by-one against
/// types/status_codes.rs.
class SubscriptionStatusCodes {
  static const good = 0;
  static const badServiceUnsupported = 0x800B0000; // status_codes.rs:96
  static const badNothingToDo = 0x800F0000; // status_codes.rs:100
  static const badSubscriptionIdInvalid = 0x80280000; // status_codes.rs:125
  static const badNodeIdUnknown = 0x80340000; // status_codes.rs:132
  static const badAttributeIdInvalid = 0x80350000; // status_codes.rs:133
  static const badIndexRangeInvalid = 0x80360000; // status_codes.rs:134
  static const badMonitoredItemIdInvalid = 0x80420000; // status_codes.rs:146
  static const badMonitoredItemFilterUnsupported = 0x80440000; // status_codes.rs:148
  static const badTooManySubscriptions = 0x80770000; // status_codes.rs:198
  static const badDeadbandFilterInvalid = 0x808E0000; // status_codes.rs:221
  static const badTooManyMonitoredItems = 0x80DB0000; // status_codes.rs:275
}

/// AttributeId.Value (types/attribute.rs:36) — the only attribute a
/// MonitoredItem may target (v1 scope: no Event monitoring, no other
/// attribute monitoring).
const int _attributeIdValue = 13;

/// DataChangeTrigger (service_types/enums.rs:1360-1364): Status = 0,
/// StatusValue = 1, StatusValueTimestamp = 2. Trigger 0 => status-only
/// notifications, 1/2 => status+value (v1 does not distinguish timestamp
/// inclusion beyond that — TimestampsToReturn is accepted+ignored, see brief
/// simplification #2).
const int _triggerStatusOnly = 0;

/// deadbandType (data_change_filter.rs field, plain u32 — not its own enum
/// in the Rust source, but the OPC UA spec's DeadbandType enumeration):
/// None = 0, Absolute = 1, Percent = 2.
const int _deadbandNone = 0;
const int _deadbandAbsolute = 1;
const int _deadbandPercent = 2;

/// MonitoringMode (service_types/enums.rs:1329-1333): Disabled = 0,
/// Sampling = 1, Reporting = 2.
const int _monitoringModeDisabled = 0;

/// Subscription revision caps/grids (v1 simplification — documented in the
/// task brief's "Global Constraints" / revision-rule list; not derived from
/// the Rust reference's runtime config since this server has no
/// configurable server-wide timer rate in v1).
const double _defaultPublishingIntervalMs = 500;
const double _publishingIntervalGridMs = 50;
const double _publishingIntervalFloorMs = 100;
const int _defaultMaxKeepAliveCount = 10;
const int _maxSubscriptions = 10;
const int _maxMonitoredItemsPerSubscription = 500;

double _reviseSamplingOrPublishingInterval(double requested) {
  if (requested.isNaN || !requested.isFinite || requested <= 0) {
    return _defaultPublishingIntervalMs;
  }
  // Round UP to the nearest 50ms grid multiple (60 -> 100, 125 -> 150), then
  // enforce the 100ms floor (brief's revision-rule list: 60ms -> 100ms).
  final gridCount = (requested / _publishingIntervalGridMs).ceil();
  final grid = gridCount * _publishingIntervalGridMs;
  return grid < _publishingIntervalFloorMs ? _publishingIntervalFloorMs : grid;
}

int _reviseKeepAliveCount(int requested) {
  return requested <= 0 ? _defaultMaxKeepAliveCount : requested;
}

int _reviseLifetimeCount(int requested, int revisedKeepAliveCount) {
  final minLifetime = revisedKeepAliveCount * 3;
  return requested < minLifetime ? minLifetime : requested;
}

int _reviseQueueSize(int requested) {
  return requested <= 0 ? 1 : requested;
}

/// One monitored item inside a [_Subscription]. The initial sample (and,
/// eventually in Task 2, subsequent samples) is queued here as a simple
/// list; Task 2's onTick consumes/publishes it.
class _MonitoredItem {
  final int id;
  final OpcNodeId nodeId;
  final int attributeId;
  int clientHandle;
  double samplingIntervalMs;
  int queueSize;
  bool discardOldest;
  int monitoringMode;
  int trigger;
  final int createdAtMs;
  final List<OpcDataValue> queue = [];

  _MonitoredItem({
    required this.id,
    required this.nodeId,
    required this.attributeId,
    required this.clientHandle,
    required this.samplingIntervalMs,
    required this.queueSize,
    required this.discardOldest,
    required this.monitoringMode,
    required this.trigger,
    required this.createdAtMs,
  });
}

class _Subscription {
  final int id;
  double publishingIntervalMs;
  int lifetimeCount;
  int maxKeepAliveCount;
  int maxNotificationsPerPublish;
  bool publishingEnabled;
  int priority;
  final int createdAtMs;
  final Map<int, _MonitoredItem> items = {};

  _Subscription({
    required this.id,
    required this.publishingIntervalMs,
    required this.lifetimeCount,
    required this.maxKeepAliveCount,
    required this.maxNotificationsPerPublish,
    required this.publishingEnabled,
    required this.priority,
    required this.createdAtMs,
  });
}

/// The result of decoding+validating a DataChangeFilter (or the absence of
/// a filter). [statusOnly] mirrors the DataChangeTrigger: false when the
/// notification should carry status+value (trigger 1/2), true for
/// status-only (trigger 0).
class _FilterOutcome {
  final bool ok;
  final int? errorStatus;
  final bool statusOnly;

  const _FilterOutcome.good({required this.statusOnly})
      : ok = true,
        errorStatus = null;

  const _FilterOutcome.error(this.errorStatus)
      : ok = false,
        statusOnly = false;
}

/// Handles the nine subscription services (Publish/Republish are Task 2
/// placeholders in this task). Builds its OWN ResponseHeaders/ServiceFaults
/// (timestamp `DateTime.now().toUtc()`, echoing `header.requestHandle`;
/// ServiceFault type id 397) — does not use the session's ResponseBuilder.
/// Never throws out of [handleService].
class SubscriptionManager {
  final OpcDataValue Function(OpcNodeId) sampler;

  /// The nine subscription-related service request DefaultBinary encoding
  /// ids this manager handles (see class doc / `_Ids` for citations).
  static const serviceIds = {
    _Ids.createSubscriptionRequest,
    _Ids.modifySubscriptionRequest,
    _Ids.setPublishingModeRequest,
    _Ids.deleteSubscriptionsRequest,
    _Ids.createMonitoredItemsRequest,
    _Ids.modifyMonitoredItemsRequest,
    _Ids.deleteMonitoredItemsRequest,
    _Ids.publishRequest,
    _Ids.republishRequest,
  };

  final Map<int, _Subscription> _subscriptions = {};
  int _nextSubscriptionId = 1;
  int _nextMonitoredItemId = 1;

  SubscriptionManager({required this.sampler});

  int get subscriptionCount => _subscriptions.length;

  int get monitoredItemCount =>
      _subscriptions.values.fold(0, (sum, s) => sum + s.items.length);

  /// Handles any of the nine subscription services. [body] is positioned
  /// after the RequestHeader (session already consumed type id + header).
  /// Returns response bodies to send NOW (usually one; empty when a
  /// PublishRequest was parked — not applicable this task). Never throws.
  List<PublishOut> handleService(
    int requestTypeId,
    OpcUaReader body,
    RequestHeader header,
    int requestId,
    int nowMs,
  ) {
    try {
      final responseBody = _dispatch(requestTypeId, body, header, nowMs);
      if (responseBody == null) {
        return [
          PublishOut(
            requestId: requestId,
            body: _fault(header, SubscriptionStatusCodes.badServiceUnsupported),
          ),
        ];
      }
      return [PublishOut(requestId: requestId, body: responseBody)];
    } catch (_) {
      // Never throw out of the public API: degrade to an encoded
      // ServiceFault, and if even that fails, a minimal fault body.
      Uint8List faultBody;
      try {
        faultBody = _fault(header, SubscriptionStatusCodes.badServiceUnsupported);
      } catch (_) {
        faultBody = _minimalFault(header);
      }
      return [PublishOut(requestId: requestId, body: faultBody)];
    }
  }

  /// Clock tick (Task 2 scope): sampling, publish cycles, keep-alives,
  /// lifetimes. This task does not implement publishing; onTick is a no-op
  /// placeholder so the public interface exists for Task 2/3 to build on.
  List<PublishOut> onTick(int nowMs) => const [];

  Uint8List? _dispatch(
    int requestTypeId,
    OpcUaReader body,
    RequestHeader header,
    int nowMs,
  ) {
    switch (requestTypeId) {
      case _Ids.createSubscriptionRequest:
        return _handleCreateSubscription(body, header, nowMs);
      case _Ids.modifySubscriptionRequest:
        return _handleModifySubscription(body, header);
      case _Ids.setPublishingModeRequest:
        return _handleSetPublishingMode(body, header);
      case _Ids.deleteSubscriptionsRequest:
        return _handleDeleteSubscriptions(body, header);
      case _Ids.createMonitoredItemsRequest:
        return _handleCreateMonitoredItems(body, header, nowMs);
      case _Ids.modifyMonitoredItemsRequest:
        return _handleModifyMonitoredItems(body, header);
      case _Ids.deleteMonitoredItemsRequest:
        return _handleDeleteMonitoredItems(body, header);
      case _Ids.publishRequest:
      case _Ids.republishRequest:
        // Task 2 scope: replace this placeholder with the real Publish
        // cycle / Republish-from-retransmission-queue behavior. For now,
        // both are routed here (so they don't fall through to the
        // session's generic Bad_ServiceUnsupported path with a different
        // shape) but explicitly answered unsupported.
        return null;
      default:
        return null;
    }
  }

  ResponseHeader _respond(RequestHeader header, {int serviceResult = SubscriptionStatusCodes.good}) {
    return ResponseHeader(
      timestamp: DateTime.now().toUtc(),
      requestHandle: header.requestHandle,
      serviceResult: serviceResult,
    );
  }

  Uint8List _fault(RequestHeader header, int serviceResult) {
    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.serviceFault));
    w.responseHeader(_respond(header, serviceResult: serviceResult));
    return w.take();
  }

  /// Absolute last resort if even building a normal fault throws (e.g. a
  /// pathological RequestHeader) — a minimal, always-encodable fault body
  /// with a zero requestHandle rather than crashing the caller.
  Uint8List _minimalFault(RequestHeader header) {
    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.serviceFault));
    w.responseHeader(ResponseHeader(
      timestamp: DateTime.now().toUtc(),
      requestHandle: 0,
      serviceResult: SubscriptionStatusCodes.badServiceUnsupported,
    ));
    return w.take();
  }

  // --- CreateSubscription ---------------------------------------------------

  /// CreateSubscriptionRequest (create_subscription_request.rs):
  /// requestHeader(consumed by session), requestedPublishingInterval f64,
  /// requestedLifetimeCount u32, requestedMaxKeepAliveCount u32,
  /// maxNotificationsPerPublish u32, publishingEnabled bool, priority u8.
  /// CreateSubscriptionResponse (create_subscription_response.rs):
  /// responseHeader, subscriptionId u32, revisedPublishingInterval f64,
  /// revisedLifetimeCount u32, revisedMaxKeepAliveCount u32.
  Uint8List _handleCreateSubscription(OpcUaReader body, RequestHeader header, int nowMs) {
    final requestedPublishingInterval = body.float64();
    final requestedLifetimeCount = body.uint32();
    final requestedMaxKeepAliveCount = body.uint32();
    final maxNotificationsPerPublish = body.uint32();
    final publishingEnabled = body.boolean();
    final priority = body.uint8();

    if (_subscriptions.length >= _maxSubscriptions) {
      return _fault(header, SubscriptionStatusCodes.badTooManySubscriptions);
    }

    final revisedPublishingInterval =
        _reviseSamplingOrPublishingInterval(requestedPublishingInterval);
    final revisedKeepAlive = _reviseKeepAliveCount(requestedMaxKeepAliveCount);
    final revisedLifetime = _reviseLifetimeCount(requestedLifetimeCount, revisedKeepAlive);

    final subscriptionId = _nextSubscriptionId++;
    _subscriptions[subscriptionId] = _Subscription(
      id: subscriptionId,
      publishingIntervalMs: revisedPublishingInterval,
      lifetimeCount: revisedLifetime,
      maxKeepAliveCount: revisedKeepAlive,
      maxNotificationsPerPublish: maxNotificationsPerPublish,
      publishingEnabled: publishingEnabled,
      priority: priority, // ignored beyond storage — v1 has no priority scheduling.
      createdAtMs: nowMs,
    );

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.createSubscriptionResponse));
    w.responseHeader(_respond(header));
    w.uint32(subscriptionId);
    w.float64(revisedPublishingInterval);
    w.uint32(revisedLifetime);
    w.uint32(revisedKeepAlive);
    return w.take();
  }

  // --- ModifySubscription ----------------------------------------------------

  /// ModifySubscriptionRequest (modify_subscription_request.rs):
  /// requestHeader(consumed), subscriptionId u32,
  /// requestedPublishingInterval f64, requestedLifetimeCount u32,
  /// requestedMaxKeepAliveCount u32, maxNotificationsPerPublish u32,
  /// priority u8.
  /// ModifySubscriptionResponse (modify_subscription_response.rs):
  /// responseHeader, revisedPublishingInterval f64, revisedLifetimeCount
  /// u32, revisedMaxKeepAliveCount u32.
  Uint8List _handleModifySubscription(OpcUaReader body, RequestHeader header) {
    final subscriptionId = body.uint32();
    final requestedPublishingInterval = body.float64();
    final requestedLifetimeCount = body.uint32();
    final requestedMaxKeepAliveCount = body.uint32();
    final maxNotificationsPerPublish = body.uint32();
    final priority = body.uint8();

    final sub = _subscriptions[subscriptionId];
    if (sub == null) {
      return _fault(header, SubscriptionStatusCodes.badSubscriptionIdInvalid);
    }

    final revisedPublishingInterval =
        _reviseSamplingOrPublishingInterval(requestedPublishingInterval);
    final revisedKeepAlive = _reviseKeepAliveCount(requestedMaxKeepAliveCount);
    final revisedLifetime = _reviseLifetimeCount(requestedLifetimeCount, revisedKeepAlive);

    sub.publishingIntervalMs = revisedPublishingInterval;
    sub.lifetimeCount = revisedLifetime;
    sub.maxKeepAliveCount = revisedKeepAlive;
    sub.maxNotificationsPerPublish = maxNotificationsPerPublish;
    sub.priority = priority;

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.modifySubscriptionResponse));
    w.responseHeader(_respond(header));
    w.float64(revisedPublishingInterval);
    w.uint32(revisedLifetime);
    w.uint32(revisedKeepAlive);
    return w.take();
  }

  // --- SetPublishingMode -----------------------------------------------------

  /// SetPublishingModeRequest (set_publishing_mode_request.rs):
  /// requestHeader(consumed), publishingEnabled bool, subscriptionIds
  /// Option<Vec<u32>> (Int32 length, -1/0 => null/empty => Bad_NothingToDo).
  /// SetPublishingModeResponse (set_publishing_mode_response.rs):
  /// responseHeader, results Option<Vec<StatusCode>>, diagnosticInfos
  /// Option<Vec<DiagnosticInfo>> (always null array here).
  Uint8List _handleSetPublishingMode(OpcUaReader body, RequestHeader header) {
    final publishingEnabled = body.boolean();
    final ids = _readUInt32Array(body);

    if (ids == null || ids.isEmpty) {
      return _fault(header, SubscriptionStatusCodes.badNothingToDo);
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.setPublishingModeResponse));
    w.responseHeader(_respond(header));
    w.int32(ids.length);
    for (final id in ids) {
      final sub = _subscriptions[id];
      if (sub == null) {
        w.statusCode(SubscriptionStatusCodes.badSubscriptionIdInvalid);
        continue;
      }
      sub.publishingEnabled = publishingEnabled;
      w.statusCode(SubscriptionStatusCodes.good);
    }
    w.int32(-1); // diagnosticInfos: null array
    return w.take();
  }

  // --- DeleteSubscriptions ---------------------------------------------------

  /// DeleteSubscriptionsRequest (delete_subscriptions_request.rs):
  /// requestHeader(consumed), subscriptionIds Option<Vec<u32>>.
  /// DeleteSubscriptionsResponse (delete_subscriptions_response.rs):
  /// responseHeader, results Option<Vec<StatusCode>>, diagnosticInfos.
  Uint8List _handleDeleteSubscriptions(OpcUaReader body, RequestHeader header) {
    final ids = _readUInt32Array(body);

    if (ids == null || ids.isEmpty) {
      return _fault(header, SubscriptionStatusCodes.badNothingToDo);
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.deleteSubscriptionsResponse));
    w.responseHeader(_respond(header));
    w.int32(ids.length);
    for (final id in ids) {
      if (_subscriptions.remove(id) != null) {
        w.statusCode(SubscriptionStatusCodes.good);
      } else {
        w.statusCode(SubscriptionStatusCodes.badSubscriptionIdInvalid);
      }
    }
    w.int32(-1); // diagnosticInfos: null array
    return w.take();
  }

  // --- CreateMonitoredItems ---------------------------------------------------

  /// CreateMonitoredItemsRequest (create_monitored_items_request.rs):
  /// requestHeader(consumed), subscriptionId u32, timestampsToReturn Int32
  /// enum (accepted + ignored, brief simplification #2), itemsToCreate
  /// Option<Vec<MonitoredItemCreateRequest>>.
  /// MonitoredItemCreateRequest (monitored_item_create_request.rs):
  /// itemToMonitor ReadValueId{nodeId, attributeId u32, indexRange String,
  /// dataEncoding QualifiedName}, monitoringMode Int32 enum,
  /// requestedParameters MonitoringParameters{clientHandle u32,
  /// samplingInterval f64, filter ExtensionObject, queueSize u32,
  /// discardOldest bool}.
  /// CreateMonitoredItemsResponse (create_monitored_items_response.rs):
  /// responseHeader, results Option<Vec<MonitoredItemCreateResult>>,
  /// diagnosticInfos.
  /// MonitoredItemCreateResult (monitored_item_create_result.rs):
  /// statusCode, monitoredItemId u32, revisedSamplingInterval f64,
  /// revisedQueueSize u32, filterResult ExtensionObject (always empty here
  /// — v1 does not report AggregateFilterResult/etc.).
  Uint8List _handleCreateMonitoredItems(OpcUaReader body, RequestHeader header, int nowMs) {
    final subscriptionId = body.uint32();
    body.int32(); // timestampsToReturn — accepted + ignored (brief #2).

    final sub = _subscriptions[subscriptionId];
    if (sub == null) {
      return _fault(header, SubscriptionStatusCodes.badSubscriptionIdInvalid);
    }

    final count = body.int32();
    if (count <= 0) {
      return _fault(header, SubscriptionStatusCodes.badNothingToDo);
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.createMonitoredItemsResponse));
    w.responseHeader(_respond(header));
    w.int32(count);
    for (var i = 0; i < count; i++) {
      final nodeId = body.nodeId();
      final attributeId = body.uint32();
      final indexRange = body.string();
      body.qualifiedName(); // dataEncoding — v1 always answers default encoding.
      final monitoringMode = body.int32();
      final clientHandle = body.uint32();
      final requestedSamplingInterval = body.float64();
      final filterTypeId = body.extensionObjectHeader();
      Uint8List? filterBody;
      if (body.lastExtensionObjectHasBody) {
        filterBody = Uint8List.fromList(body.byteString() ?? const []);
      }
      final queueSize = body.uint32();
      final discardOldest = body.boolean();

      if (attributeId != _attributeIdValue) {
        w.statusCode(SubscriptionStatusCodes.badAttributeIdInvalid);
        continue;
      }
      if (indexRange != null) {
        w.statusCode(SubscriptionStatusCodes.badIndexRangeInvalid);
        continue;
      }

      final filterOutcome = _decodeFilter(filterTypeId, filterBody);
      if (!filterOutcome.ok) {
        w.statusCode(filterOutcome.errorStatus!);
        continue;
      }

      // Probe the node ONCE; reuse the sample as the initial queued value.
      final sample = sampler(nodeId);
      if (sample.status == SubscriptionStatusCodes.badNodeIdUnknown) {
        w.statusCode(SubscriptionStatusCodes.badNodeIdUnknown);
        continue;
      }

      if (sub.items.length >= _maxMonitoredItemsPerSubscription) {
        w.statusCode(SubscriptionStatusCodes.badTooManyMonitoredItems);
        continue;
      }

      final revisedSampling = requestedSamplingInterval < 0
          ? sub.publishingIntervalMs
          : _reviseSamplingOrPublishingInterval(requestedSamplingInterval);
      final revisedQueueSize = _reviseQueueSize(queueSize);

      final itemId = _nextMonitoredItemId++;
      final item = _MonitoredItem(
        id: itemId,
        nodeId: nodeId,
        attributeId: attributeId,
        clientHandle: clientHandle,
        samplingIntervalMs: revisedSampling,
        queueSize: revisedQueueSize,
        discardOldest: discardOldest,
        monitoringMode: monitoringMode,
        trigger: filterOutcome.statusOnly ? _triggerStatusOnly : 1,
        createdAtMs: nowMs,
      );
      if (monitoringMode != _monitoringModeDisabled) {
        item.queue.add(sample);
      }
      sub.items[itemId] = item;

      w.statusCode(SubscriptionStatusCodes.good);
      w.uint32(itemId);
      w.float64(revisedSampling);
      w.uint32(revisedQueueSize);
      w.extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false); // filterResult: empty
    }
    w.int32(-1); // diagnosticInfos: null array
    return w.take();
  }

  // --- ModifyMonitoredItems ---------------------------------------------------

  /// ModifyMonitoredItemsRequest (modify_monitored_items_request.rs):
  /// requestHeader(consumed), subscriptionId u32, timestampsToReturn Int32
  /// enum (ignored), itemsToModify Option<Vec<MonitoredItemModifyRequest>>.
  /// MonitoredItemModifyRequest (monitored_item_modify_request.rs):
  /// monitoredItemId u32, requestedParameters MonitoringParameters.
  /// ModifyMonitoredItemsResponse (modify_monitored_items_response.rs):
  /// responseHeader, results Option<Vec<MonitoredItemModifyResult>>,
  /// diagnosticInfos.
  /// MonitoredItemModifyResult (monitored_item_modify_result.rs):
  /// statusCode, revisedSamplingInterval f64, revisedQueueSize u32,
  /// filterResult ExtensionObject.
  Uint8List _handleModifyMonitoredItems(OpcUaReader body, RequestHeader header) {
    final subscriptionId = body.uint32();
    body.int32(); // timestampsToReturn — accepted + ignored.

    final sub = _subscriptions[subscriptionId];
    if (sub == null) {
      return _fault(header, SubscriptionStatusCodes.badSubscriptionIdInvalid);
    }

    final count = body.int32();
    if (count <= 0) {
      return _fault(header, SubscriptionStatusCodes.badNothingToDo);
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.modifyMonitoredItemsResponse));
    w.responseHeader(_respond(header));
    w.int32(count);
    for (var i = 0; i < count; i++) {
      final monitoredItemId = body.uint32();
      final clientHandle = body.uint32();
      final requestedSamplingInterval = body.float64();
      final filterTypeId = body.extensionObjectHeader();
      Uint8List? filterBody;
      if (body.lastExtensionObjectHasBody) {
        filterBody = Uint8List.fromList(body.byteString() ?? const []);
      }
      final queueSize = body.uint32();
      final discardOldest = body.boolean();

      final item = sub.items[monitoredItemId];
      if (item == null) {
        w.statusCode(SubscriptionStatusCodes.badMonitoredItemIdInvalid);
        continue;
      }

      final filterOutcome = _decodeFilter(filterTypeId, filterBody);
      if (!filterOutcome.ok) {
        w.statusCode(filterOutcome.errorStatus!);
        continue;
      }

      final revisedSampling = requestedSamplingInterval < 0
          ? sub.publishingIntervalMs
          : _reviseSamplingOrPublishingInterval(requestedSamplingInterval);
      final revisedQueueSize = _reviseQueueSize(queueSize);

      item.clientHandle = clientHandle;
      item.samplingIntervalMs = revisedSampling;
      item.queueSize = revisedQueueSize;
      item.discardOldest = discardOldest;
      item.trigger = filterOutcome.statusOnly ? _triggerStatusOnly : 1;

      w.statusCode(SubscriptionStatusCodes.good);
      w.float64(revisedSampling);
      w.uint32(revisedQueueSize);
      w.extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false); // filterResult: empty
    }
    w.int32(-1); // diagnosticInfos: null array
    return w.take();
  }

  // --- DeleteMonitoredItems ---------------------------------------------------

  /// DeleteMonitoredItemsRequest (delete_monitored_items_request.rs):
  /// requestHeader(consumed), subscriptionId u32, monitoredItemIds
  /// Option<Vec<u32>>.
  /// DeleteMonitoredItemsResponse (delete_monitored_items_response.rs):
  /// responseHeader, results Option<Vec<StatusCode>>, diagnosticInfos.
  Uint8List _handleDeleteMonitoredItems(OpcUaReader body, RequestHeader header) {
    final subscriptionId = body.uint32();
    final sub = _subscriptions[subscriptionId];
    if (sub == null) {
      return _fault(header, SubscriptionStatusCodes.badSubscriptionIdInvalid);
    }

    final ids = _readUInt32Array(body);
    if (ids == null || ids.isEmpty) {
      return _fault(header, SubscriptionStatusCodes.badNothingToDo);
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.deleteMonitoredItemsResponse));
    w.responseHeader(_respond(header));
    w.int32(ids.length);
    for (final id in ids) {
      // Removing drops that item's queued notifications with it (the
      // _MonitoredItem, and its `queue` field, is simply discarded).
      if (sub.items.remove(id) != null) {
        w.statusCode(SubscriptionStatusCodes.good);
      } else {
        w.statusCode(SubscriptionStatusCodes.badMonitoredItemIdInvalid);
      }
    }
    w.int32(-1); // diagnosticInfos: null array
    return w.take();
  }

  // --- Shared helpers ---------------------------------------------------------

  /// Reads an `Option<Vec<u32>>` array (encoding.rs `read_array`: Int32
  /// length, -1 => null, 0 => empty, >0 => that many UInt32 elements).
  List<int>? _readUInt32Array(OpcUaReader body) {
    final len = body.int32();
    if (len < 0) return null;
    final ids = <int>[];
    for (var i = 0; i < len; i++) {
      ids.add(body.uint32());
    }
    return ids;
  }

  /// Decodes+validates a monitoring filter ExtensionObject per the brief:
  /// empty (typeId ns0/i=0, no body) => no filter (statusOnly = false,
  /// i.e. status+value — the OPC UA default absent an explicit
  /// DataChangeTrigger of Status-only); typeId 722 (DataChangeFilter) +
  /// body => decode deadbandType/deadbandValue/trigger; any other typeId
  /// with a body => Bad_MonitoredItemFilterUnsupported.
  _FilterOutcome _decodeFilter(OpcNodeId typeId, Uint8List? filterBody) {
    final isEmptyFilter = filterBody == null &&
        typeId.isNumeric &&
        typeId.namespace == 0 &&
        typeId.numericId == 0;
    if (isEmptyFilter) {
      return const _FilterOutcome.good(statusOnly: false);
    }
    if (filterBody == null) {
      // A non-empty typeId but no body: nothing to decode, and not the
      // DataChangeFilter shape either — treat as unsupported rather than
      // silently accepting.
      return const _FilterOutcome.error(
          SubscriptionStatusCodes.badMonitoredItemFilterUnsupported);
    }
    if (!typeId.isNumeric || typeId.numericId != _Ids.dataChangeFilter) {
      return const _FilterOutcome.error(
          SubscriptionStatusCodes.badMonitoredItemFilterUnsupported);
    }

    // DataChangeFilter (data_change_filter.rs): trigger Int32 enum,
    // deadbandType u32, deadbandValue f64.
    final reader = OpcUaReader(filterBody);
    final trigger = reader.int32();
    final deadbandType = reader.uint32();
    final deadbandValue = reader.float64();

    switch (deadbandType) {
      case _deadbandNone:
        return _FilterOutcome.good(statusOnly: trigger == _triggerStatusOnly);
      case _deadbandAbsolute:
        if (deadbandValue < 0 || !deadbandValue.isFinite) {
          return const _FilterOutcome.error(
              SubscriptionStatusCodes.badDeadbandFilterInvalid);
        }
        return _FilterOutcome.good(statusOnly: trigger == _triggerStatusOnly);
      case _deadbandPercent:
        return const _FilterOutcome.error(
            SubscriptionStatusCodes.badMonitoredItemFilterUnsupported);
      default:
        return const _FilterOutcome.error(
            SubscriptionStatusCodes.badMonitoredItemFilterUnsupported);
    }
  }
}
