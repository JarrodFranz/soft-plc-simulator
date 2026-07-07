# In-App OPC UA Subscriptions v2 (WS20) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OPC UA Subscriptions/MonitoredItems in the in-app pure-Dart server: clients create subscriptions + data-change monitored items on exposed-tag Value attributes and receive server-pushed `DataChangeNotification`s — proven by the Rust `opcua`-client E2E harness.

**Architecture:** A new pure unit `mobile/lib/protocols/opcua/opcua_subscriptions.dart` (`SubscriptionManager`, one per session) owns all subscription state and encodes its own response bodies; `OpcUaServerSession` routes the nine subscription service ids to it and gains `onClockTick(nowMs)`; `OpcUaHost` (the only `dart:io` file) drives a single 50 ms `Timer.periodic` + `Stopwatch` and writes tick frames to sockets. Values are sampled through `OpcUaProjectServices.sample` (refactored from the v1 Read path so Read and sampling agree). Spec: `docs/superpowers/specs/2026-07-07-opcua-subscriptions-design.md`.

**Tech Stack:** Dart (`dart:typed_data`; `dart:async` Timer only in the host), Flutter for UI, `flutter_test`; Rust `opcua` 0.12 client (dev E2E harness via `cargo`).

## Global Constraints

- No third-party/reference-editor branding anywhere. Dark theme; `flutter analyze` ZERO warnings; no RenderFlex overflow at 360/320/1400. Braces; prefer `const`; `x.isNotEmpty`; `withValues(alpha:)`.
- `mobile/lib/protocols/opcua/*` stays PURE Dart: no Flutter imports, no `dart:io`, no `Timer` (the host owns the clock). No `DateTime.now()` for SCHEDULING (injected monotonic `nowMs` only); `DateTime.now().toUtc()` allowed ONLY for wire timestamps (`publishTime`, DataValue serverTimestamp), consistent with v1.
- The server must NEVER crash the app: malformed input → clean fault/ERR/close, never an uncaught throw. `onClockTick` wrapped in the same catch-all discipline as `onBytes`.
- App byte-identical when hosting is stopped: the timer exists only between `start()` and `stop()`. No persistence changes at all in this WS (round-trip guard must stay green untouched).
- Every wire encoding cross-checked against the vendored Rust reference `C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/` with file citations in comments — VERIFY ids against source, never memory.
- Run cargo/flutter in the FOREGROUND with bounded timeouts; never leave hanging processes. Discard plugin-registrant churn (`git checkout -- mobile/linux/flutter mobile/macos/Flutter mobile/windows/flutter`) before commits.
- Subscriptions only OBSERVE values — the force-aware write rule is untouched.

**Verified wire facts (all from the vendored reference; cite these files in code):**
- Service encoding ids (`types/node_ids.rs:1770-1801`): CreateSubscription 787/790 · ModifySubscription 793/796 · SetPublishingMode 799/802 · DeleteSubscriptions 847/850 · CreateMonitoredItems 751/754 · ModifyMonitoredItems 763/766 · DeleteMonitoredItems 781/784 · Publish 826/829 · Republish 832/835 · NotificationMessage 805 · MonitoredItemNotification 808 · DataChangeNotification 811 · StatusChangeNotification 820 · DataChangeFilter 724.
- StatusCodes (`types/status_codes.rs`): Bad_Timeout 0x800A0000 (:95) · Bad_SubscriptionIdInvalid 0x80280000 (:125) · Bad_MonitoredItemIdInvalid 0x80420000 (:146) · Bad_MonitoredItemFilterUnsupported 0x80440000 (:148) · Bad_TooManySubscriptions 0x80770000 (:198) · Bad_TooManyPublishRequests 0x80780000 (:199) · Bad_NoSubscription 0x80790000 (:200) · Bad_SequenceNumberUnknown 0x807A0000 (:201) · Bad_MessageNotAvailable 0x807B0000 (:202) · Bad_DeadbandFilterInvalid 0x808E0000 (:221) · Bad_TooManyMonitoredItems 0x80DB0000 (:275).
- Struct field orders (each `service_types/<file>.rs`, encoded in declaration order, requestHeader/responseHeader first as in v1):
  - CreateSubscriptionRequest: requestedPublishingInterval f64, requestedLifetimeCount u32, requestedMaxKeepAliveCount u32, maxNotificationsPerPublish u32, publishingEnabled bool, priority u8. Response: subscriptionId u32, revisedPublishingInterval f64, revisedLifetimeCount u32, revisedMaxKeepAliveCount u32.
  - ModifySubscriptionRequest: subscriptionId u32, then the same four requested params + priority u8 (NO publishingEnabled). Response: the three revised values.
  - SetPublishingModeRequest: publishingEnabled bool, subscriptionIds u32[]. Response: results StatusCode[], diagnosticInfos null.
  - DeleteSubscriptionsRequest: subscriptionIds u32[]. Response: results StatusCode[], diagnosticInfos null.
  - CreateMonitoredItemsRequest: subscriptionId u32, timestampsToReturn i32 enum, itemsToCreate MonitoredItemCreateRequest[]{itemToMonitor ReadValueId{nodeId, attributeId u32, indexRange String, dataEncoding QualifiedName}, monitoringMode i32 enum (Disabled 0/Sampling 1/Reporting 2), requestedParameters MonitoringParameters{clientHandle u32, samplingInterval f64, filter ExtensionObject, queueSize u32, discardOldest bool}}. Response: results MonitoredItemCreateResult[]{statusCode, monitoredItemId u32, revisedSamplingInterval f64, revisedQueueSize u32, filterResult ExtensionObject(empty)}, diagnosticInfos null.
  - ModifyMonitoredItemsRequest: subscriptionId u32, timestampsToReturn i32, itemsToModify[]{monitoredItemId u32, requestedParameters MonitoringParameters}. Response results[]{statusCode, revisedSamplingInterval, revisedQueueSize, filterResult empty ExtensionObject}, diagnosticInfos null.
  - DeleteMonitoredItemsRequest: subscriptionId u32, monitoredItemIds u32[]. Response: results StatusCode[], diagnosticInfos null.
  - PublishRequest: subscriptionAcknowledgements[]{subscriptionId u32, sequenceNumber u32}. PublishResponse: subscriptionId u32, availableSequenceNumbers u32[], moreNotifications bool, notificationMessage NotificationMessage, results StatusCode[] (one per ack), diagnosticInfos null.
  - NotificationMessage: sequenceNumber u32, publishTime DateTime, notificationData ExtensionObject[] (each = NodeId typeId + encoding byte 0x01 + ByteString body; empty array for keep-alive).
  - DataChangeNotification body: monitoredItems[]{clientHandle u32, value DataValue}, diagnosticInfos null. StatusChangeNotification body: status StatusCode, diagnosticInfo (empty DiagnosticInfo 0x00).
  - RepublishRequest: subscriptionId u32, retransmitSequenceNumber u32. Response: notificationMessage.
  - DataChangeFilter body: trigger i32 enum (Status 0/StatusValue 1/StatusValueTimestamp 2), deadbandType u32 (None 0/Absolute 1/Percent 2), deadbandValue f64.

**Spec'd parameter revision rules (implement exactly):** publishingInterval → NaN/≤0 ⇒ 500 ms else clamp [100, 60000], then round UP to the 50 ms grid. lifetimeCount → clamp [30, 10000] then raise to ≥ 3 × revisedMaxKeepAliveCount. maxKeepAliveCount → 0 ⇒ 10, clamp [1, 3000]. samplingInterval → ≤ 0 (incl. −1) ⇒ the subscription's revised publishing interval, else clamp [50, 60000], round UP to 50 ms grid. queueSize → 0 ⇒ 1, clamp [1, 100]. Caps: 10 subscriptions/session (`Bad_TooManySubscriptions` ServiceFault), 500 items/subscription (per-item `Bad_TooManyMonitoredItems`), 10 parked PublishRequests (11th ⇒ immediate ServiceFault `Bad_TooManyPublishRequests`). Retransmission buffer: most recent 20 sent data messages per subscription.

**Sequencing:** Task 1 (manager: lifecycle services) → Task 2 (sampling + publish engine) → Task 3 (session/services/host/UI integration) → Task 4 (Rust E2E + validation + docs + final review).

---

### Task 1: SubscriptionManager — subscription/item lifecycle services (pure, socketless)

**Files:**
- Create: `mobile/lib/protocols/opcua/opcua_subscriptions.dart`
- Modify: `mobile/lib/protocols/opcua/opcua_binary.dart` (ONLY if `OpcUaWriter` lacks a body-bearing extension-object writer: add `void extensionObject(OpcNodeId typeId, Uint8List body)` = nodeId + uint8(0x01) + byteString(body); and if `OpcUaReader` can't already read one via `extensionObjectHeader()` + `lastExtensionObjectHasBody` + `byteString()`, extend it the same way — check first, v1 likely has both)
- Test: `mobile/test/opcua_subscriptions_test.dart`

**Interfaces (consumed by Tasks 2-3):**
```dart
/// One PublishOut = one MSG response to frame: `requestId` is the transport
/// requestId to echo in buildMsgChunk; `body` is the full encoded response
/// body (type NodeId + ResponseHeader + fields), ready to MSG-wrap.
class PublishOut { final int requestId; final Uint8List body; }

class SubscriptionManager {
  SubscriptionManager({required OpcDataValue Function(OpcNodeId) sampler});
  static const serviceIds = { 787, 793, 799, 847, 751, 763, 781, 826, 832 }; // request ids
  int get subscriptionCount;
  int get monitoredItemCount; // sum across subscriptions
  /// Handles any of the nine subscription services. [body] is positioned
  /// after the RequestHeader (session already consumed type id + header).
  /// Returns response bodies to send NOW (usually one; empty when a
  /// PublishRequest was parked). Never throws.
  List<PublishOut> handleService(int requestTypeId, OpcUaReader body,
      RequestHeader header, int requestId, int nowMs);
  /// Clock tick (Task 2): sampling, publish cycles, keep-alives, lifetimes.
  List<PublishOut> onTick(int nowMs);
}
```
The manager builds its OWN ResponseHeaders/ServiceFaults (timestamp `DateTime.now().toUtc()`, echo `header.requestHandle`; ServiceFault type id 397) — it does not use the session's `ResponseBuilder`. Internal classes `Subscription` and `MonitoredItem` may be library-private but need enough visibility for tests (`@visibleForTesting` getters or just test via the wire API — PREFER wire-API tests: encode a request body with `OpcUaWriter`, decode the response with `OpcUaReader`, matching the WS19 opcua_services_test.dart style).

**Task 1 scope — the seven non-publish services** (Publish 826 / Republish 832 return a `Bad_ServiceUnsupported`-style fault placeholder in THIS task only; Task 2 replaces them):
- CreateSubscription: allocate `subscriptionId` (per-manager counter from 1), apply revision rules (see Global Constraints), store `publishingEnabled`/`priority`(ignored)/`maxNotificationsPerPublish`; enforce the 10-subscription cap (`Bad_TooManySubscriptions` ServiceFault). Response per struct layout.
- ModifySubscription: unknown id → ServiceFault `Bad_SubscriptionIdInvalid`; else re-revise + store, respond with revised values.
- SetPublishingMode: per-id results (`Good` / `Bad_SubscriptionIdInvalid`), flips `publishingEnabled`. Null/empty id array → ServiceFault `Bad_NothingToDo` (0x800F0000, v1 const).
- DeleteSubscriptions: per-id results, removes state. Null/empty → `Bad_NothingToDo`.
- CreateMonitoredItems: unknown subscription → ServiceFault `Bad_SubscriptionIdInvalid`; null/empty items → `Bad_NothingToDo`. Per item: attributeId != 13 (Value) → `Bad_AttributeIdInvalid`; sampler probe `sampler(nodeId)` returning status `Bad_NodeIdUnknown` → per-item `Bad_NodeIdUnknown` (probe ONCE, reuse as the initial sample); indexRange non-null → `Bad_IndexRangeInvalid`; filter ExtensionObject: empty (typeId ns0 i=0, no body) ⇒ no filter; typeId 724 + body ⇒ decode DataChangeFilter — deadbandType 0 ⇒ no deadband, 1 ⇒ absolute (deadbandValue < 0 or non-finite → `Bad_DeadbandFilterInvalid`), 2 ⇒ `Bad_MonitoredItemFilterUnsupported`; any other typeId with a body ⇒ `Bad_MonitoredItemFilterUnsupported`. Trigger: 0 ⇒ status-only, 1/2 ⇒ status+value. Item cap 500 → `Bad_TooManyMonitoredItems`. Success: monitoredItemId (per-manager counter), revised sampling/queue, store `clientHandle`, `discardOldest`, `monitoringMode`; queue the initial sample (Sampling/Reporting modes; Disabled queues nothing). TimestampsToReturn accepted + ignored (spec simplification #2).
- ModifyMonitoredItems: unknown subscription → ServiceFault `Bad_SubscriptionIdInvalid`; per item unknown id → `Bad_MonitoredItemIdInvalid`; else re-revise params + filter (same validation), respond revised values.
- DeleteMonitoredItems: unknown subscription → ServiceFault; per-item results; deletes drop that item's queued notifications.

- [ ] **Step 1: Write failing tests** (wire-API style): create → revision rules asserted exactly (NaN→500ms; 60ms→100ms; 125ms→150ms grid round-up; lifetime raised to 3×keepAlive; keepAlive 0→10; queueSize 0→1; sampling −1→publishing interval); 11th subscription → `Bad_TooManySubscriptions` fault; modify unknown → `Bad_SubscriptionIdInvalid`; setPublishingMode mixed known/unknown ids → per-result codes; delete removes (subsequent modify faults); createMonitoredItems: per-item codes for bad attribute/unknown node/percent deadband/negative deadband/unknown-filter-type; valid absolute-deadband accepted; item ids monotonic; counts (`subscriptionCount`/`monitoredItemCount`) track create/delete; a malformed body (truncated) → a fault, not a throw.
- [ ] **Step 2: Run → FAIL.** `cd mobile && flutter test test/opcua_subscriptions_test.dart` fails (file/class missing).
- [ ] **Step 3: Implement** per the interfaces + scope above. Cite reference files/lines next to every id/layout.
- [ ] **Step 4: Tests → PASS; `flutter analyze` ZERO; full `flutter test` green.**
- [ ] **Step 5: Commit** `feat(opcua): SubscriptionManager lifecycle services (create/modify/delete subscriptions + monitored items)`.

---

### Task 2: Sampling + publish engine (onTick, Publish, Republish, keep-alive, lifetime)

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_subscriptions.dart`
- Test: `mobile/test/opcua_subscriptions_test.dart` (extend)

**Interfaces:** `onTick(nowMs)` goes live; `handleService` gains real Publish (826) + Republish (832). All time from `nowMs` (int milliseconds, monotonic, injected); a subscription's publishing-cycle boundaries are `creationNowMs + k*revisedPublishingIntervalMs`; an item's sampling due-times likewise from its creation.

**Behavior (spec §Publish state machine — implement exactly):**
- **Sampling** (each `onTick`, per item in Sampling/Reporting mode whose due-time ≤ nowMs): `sampler(nodeId)` → change detection vs last REPORTED sample: trigger Status ⇒ statusCode change only; StatusValue ⇒ status change OR value change, where with absolute deadband a numeric value change triggers only if `|new − old| ≥ deadband` (equality INCLUSIVE) and non-numeric values trigger on any inequality; no filter ⇒ any status-or-value change. Triggered → enqueue `(clientHandle, DataValue)`; queue overflow per `discardOldest` with overflow bit `statusCode |= 0x480` set on the oldest surviving entry (discardOldest=true, oldest dropped) or on the newest queued entry (discardOldest=false, new sample dropped). Disabled items never sample.
- **Publish arrival** (`handleService` 826): decode acks; each ack: known subscription + sequenceNumber in its retransmission buffer ⇒ remove + `Good`; unknown subscription ⇒ `Bad_SubscriptionIdInvalid`; unknown seq ⇒ `Bad_SequenceNumberUnknown`. If the session has NO subscriptions ⇒ immediate ServiceFault `Bad_NoSubscription`. If ≥10 already parked ⇒ ServiceFault `Bad_TooManyPublishRequests`. If any subscription is LATE (has undelivered queued data from a past cycle) ⇒ answer the longest-late one immediately; else park `(requestId, requestHandle, ackResults)`. NOTE: ack results ride on the response that eventually consumes the parked request.
- **Publish cycle** (each `onTick`, per subscription at a cycle boundary): (a) queued notifications + parked request available ⇒ PublishResponse: drain up to `maxNotificationsPerPublish` (0 = all) item notifications into ONE DataChangeNotification inside ONE NotificationMessage; `moreNotifications` = queue non-empty after drain; sequenceNumber = next data-sequence (starts 1, increments only for data messages); retain the message in the retransmission buffer (cap 20, oldest dropped); `availableSequenceNumbers` = buffer's seq numbers ascending (AFTER retaining); reset keepAlive + lifetime counters. Publishing-disabled subscriptions never send data (queue keeps accumulating; overflow rules apply). (b) data queued but NO parked request ⇒ mark late, lifetime++. (c) nothing queued ⇒ keepAlive++; if keepAlive ≥ maxKeepAliveCount AND a parked request exists ⇒ keep-alive PublishResponse (empty notificationData, sequenceNumber = next-expected WITHOUT consuming it, moreNotifications false), reset keepAlive + lifetime. (d) lifetime ≥ lifetimeCount ⇒ dead: if a parked request exists send StatusChangeNotification(`Bad_Timeout`) response (sequenceNumber = next-expected, not consumed), then delete the subscription (silently if no request).
- **Republish** (832): known subscription + seq in buffer ⇒ RepublishResponse{that NotificationMessage}; unknown subscription ⇒ ServiceFault `Bad_SubscriptionIdInvalid`; miss ⇒ ServiceFault `Bad_MessageNotAvailable`.

- [ ] **Step 1: Write failing tests** — fully deterministic, fake sampler (a mutable `Map<String, OpcDataValue>` keyed by nodeId), explicit nowMs script. Cover at minimum: initial value delivered on first cycle after a Publish is parked; no change ⇒ no data (then keep-alive at exactly `maxKeepAliveCount` cycles, sequenceNumber NOT consumed — next data message uses it); value change ⇒ DataChangeNotification with clientHandle + new value; deadband: `|Δ| < d` silent, `|Δ| == d` triggers, status change triggers regardless; trigger=Status ignores value changes; queue overflow both discardOldest polarities incl. the 0x480 bit; `maxNotificationsPerPublish` truncation + `moreNotifications` + follow-up drain on the next parked request; park-then-tick ordering (Publish parked BEFORE the change: response arrives on the change's cycle, requestId echoes the parked one); late-subscription immediate answer (change happens with no parked request → next Publish answered instantly); acks remove from buffer (`availableSequenceNumbers` shrinks; unknown seq → `Bad_SequenceNumberUnknown` in results); Republish hit returns the SAME bytes-decodable message, miss → `Bad_MessageNotAvailable`; retransmission cap 20; lifetime timeout ⇒ StatusChange `Bad_Timeout` + subscription gone (`subscriptionCount` drops, later Publish → `Bad_NoSubscription` fault); publishing-disabled: data withheld, keep-alives still flow, re-enable ⇒ queued data delivered; 11th parked Publish ⇒ `Bad_TooManyPublishRequests`; sequence numbers strictly 1,2,3… across data messages.
- [ ] **Step 2: Run → FAIL. Step 3: Implement.**
- [ ] **Step 4: Tests → PASS; analyze ZERO; full suite green.**
- [ ] **Step 5: Commit** `feat(opcua): subscription sampling + publish engine (keep-alive, lifetime, republish, deadband)`.

---

### Task 3: Session routing + onClockTick + sampler + host timer + UI counts

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_session.dart`, `mobile/lib/protocols/opcua/opcua_services.dart`, `mobile/lib/services/opcua_host.dart`, `mobile/lib/screens/gateway_screen.dart`
- Test: `mobile/test/opcua_session_test.dart` (update signatures + add), `mobile/test/opcua_services_test.dart` (sample), `mobile/test/opcua_host_test.dart` (timer lifecycle), `mobile/test/gateway_screen_test.dart` (counts line)

**Interfaces:**
- `OpcUaServerSession`: constructor gains `OpcDataValue Function(OpcNodeId)? sampler` (null ⇒ subscription services fault `Bad_ServiceUnsupported`, preserving v1 behavior for tests that don't care); `onBytes(Uint8List frame, int nowMs)` (BREAKING param add — update every existing call site/test mechanically, pass `0` where time is irrelevant); NEW `List<Uint8List> onClockTick(int nowMs)` → MSG-wraps `SubscriptionManager.onTick` output (empty when no channel/session/subscriptions; NEVER throws — same catch-all as onBytes, but tick errors return `const []` and do NOT close the connection). Expose `int get subscriptionCount` / `int get monitoredItemCount` (0 when no manager).
- Routing: in `_handleMsg`'s switch default path, if `SubscriptionManager.serviceIds.contains(id)` → AFTER the existing activation guards (`_session` null/closed/authToken/activated — same faults as `_dispatchToServiceHandler`), call `manager.handleService(id, reader, header, chunk.requestId, nowMs)` and MSG-wrap each `PublishOut` (a new `_wrapMsgResponseForRequestId(int requestId, Uint8List body)` — `buildMsgChunk` with that requestId). Parked Publish ⇒ empty list from `handleService` ⇒ NO frames written (the transport stays quiet — that's the deferral).
- `OpcUaProjectServices`: NEW `OpcDataValue sample(OpcNodeId nodeId)` — exactly `_readAttribute(project, space, nodeId, 13 /*Value*/, null)` over a fresh `projectProvider()` + `OpcUaAddressSpace.build`, refactored so Read's Value branch and `sample` share one code path (extract, don't duplicate).
- `OpcUaHost`: a `Stopwatch _clock` (started in `start()`), `Timer? _tickTimer = Timer.periodic(const Duration(milliseconds: 50), ...)` created in `start()` AFTER the socket binds, cancelled FIRST in `stop()` (and `_clock` reset); each tick: for every live connection, `final frames = conn.session.onClockTick(_clock.elapsedMilliseconds); for (f in frames) conn.socket.add(f);` guarded per-connection try/catch (a tick crash drops that connection only). `onData` passes `_clock.elapsedMilliseconds` into `onBytes`. Host exposes `int get subscriptionCount` / `int get monitoredItemCount` (sums over connections; notifyListeners on the tick ONLY when counts changed since the last notify — avoid 20 Hz UI spam). Sessions get the sampler: `OpcUaProjectServices` instance's `sample` passed into each `OpcUaServerSession(sampler: services.sample, ...)`.
- `gateway_screen.dart`: on the OPC UA card, when running, one read-only line under the endpoint: `Subscriptions: N · Monitored items: M` (AnimatedBuilder/ListenableBuilder over the host, same pattern as the existing status/client-count display).

- [ ] **Step 1: Write failing tests.** Session-level (socketless, frames built with the v1 codec helpers from `opcua_session_test.dart`): full handshake → CreateSubscription through REAL frames → decode CreateSubscriptionResponse (revised values sane); CreateMonitoredItems on a fake-sampler node → Good; Publish parked (onBytes returns NO frames) → mutate fake sampler → `onClockTick(nowMs)` walked past the publishing interval → EXACTLY the parked requestId comes back as a MSG frame decoding to PublishResponse with the new value; subscription services before ActivateSession → `Bad_SessionNotActivated` fault; `sampler: null` session → `Bad_ServiceUnsupported`; onClockTick with no subscriptions → `const []`. Services: `sample()` returns live value (mutate project between calls — two different values, and identical to a Read of the same node). Host: after `start()` a subscription-bearing connection receives pushed frames WITHOUT sending more bytes (bind ephemeral port, raw Socket, drive the real handshake, park a Publish, mutate the tag, await the pushed PublishResponse with a bounded timeout — this is the in-Dart E2E); after `stop()` no timer leaks (`start`→`stop`→no notifications after a delay; test completes without pending-timer flake). Widget: counts line renders when running (fake host), absent when stopped; no overflow 320/1400.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** (mechanical `onBytes` call-site sweep included — grep `onBytes(` across `mobile/`).
- [ ] **Step 4: Tests → PASS; analyze ZERO; FULL `flutter test` green; `flutter build web --release` compiles (pure code has no Timer; host's Timer is dart:async, web-safe to compile).**
- [ ] **Step 5: Commit** `feat(opcua): session subscription routing + host clock tick + live subscription counts in UI`.

---

### Task 4: Rust E2E subscription probe + validation + docs + final review

**Files:**
- Modify: `gateway/examples/opcua_probe.rs`, `mobile/tool/opcua_host_probe.dart`, `tool/opcua_e2e.sh`, `docs/protocols/opcua.md`, `ROADMAP.md`

- [ ] **Step 1: Extend the Rust probe.** After the existing Browse/Read/Write/read-back PASS section: create a subscription (publishing interval 500 ms) + one monitored item on the Int32 node (queue 10, no filter) via the `opcua` client crate's subscription API (`Session::create_subscription` + `create_monitored_items` with a data-change callback — mirror the crate's `simple-client` subscription example under the vendored `samples/` or the client docs); collect callback values into a channel; then trigger the server-side mutation and assert a received DataChangeNotification value equals the expected new value within a 10 s bound; print `SUBSCRIPTION PASS` / exit 1 on timeout. `mobile/tool/opcua_host_probe.dart` gains a mutation trigger the probe can invoke WITHOUT stdin coupling: simplest is time-based — the host probe mutates the Int32 tag to a known second value N seconds after `READY` (e.g. at +4 s, value 7777) so the Rust side just waits for 7777; keep the existing Write-path test unaffected (mutation happens via `writePath` on the project, i.e. a server-side change, exactly what SCADA monitors). Update `tool/opcua_e2e.sh` timeout accordingly.
- [ ] **Step 2: RUN `tool/opcua_e2e.sh`** (bounded) → paste output; require both `PROBE PASS` and `SUBSCRIPTION PASS`. This is the machine-proof a real third-party client receives pushed data changes from the in-app Dart server.
- [ ] **Step 3: Gates.** `cd mobile && flutter test` ALL green · `flutter analyze` ZERO · `flutter build web --release` OK · `cd gateway && cargo build --examples` green · branding grep (`grep -riE "openplc|beremiz|codesys|rslogix" mobile/lib mobile/test gateway/examples tool/ docs/protocols/` → only allowed historical references in Source/Examples paths, none in app/probe code) · plugin churn discarded.
- [ ] **Step 4: Docs.** `docs/protocols/opcua.md`: add a Subscriptions section (v2 shipped: data-change monitored items on Value, absolute deadband, keep-alive/lifetime, Republish; caps 10/500/10/20; UAExpert: subscription tab shows live updates; Sampling≈Reporting + other spec simplifications listed). `ROADMAP.md` Phase 4: mark Subscriptions/MonitoredItems ✅ with v2 scope; leave encryption + UAExpert manual confirmation ⏳.
- [ ] **Step 5: Commit** `feat(opcua): subscription E2E probe (Rust client receives pushed data changes) + docs`, then hand the branch to the final whole-branch review (superpowers:requesting-code-review) and merge via superpowers:finishing-a-development-branch.

---

## Self-review notes
- **Spec coverage:** all nine services (T1 lifecycle, T2 publish/republish/engine), change detection incl. deadband + trigger + overflow bits (T2), clock model + deferral + host timer + idle guarantee (T3), sampler unification with Read (T3), counts UI line (T3), E2E machine-proof + docs + roadmap (T4). Simplifications 1-5 embedded where they bind (TimestampsToReturn ignored T1; Sampling≈Reporting T1/T2; disabled-still-keep-alives T2; no CloseSession draining — nothing added, v1 close path untouched; no wraparound handling).
- **Type consistency:** `PublishOut{requestId, body}` produced by T1/T2, consumed by T3's `_wrapMsgResponseForRequestId`; `sampler` type `OpcDataValue Function(OpcNodeId)` everywhere; `onBytes(frame, nowMs)` sweep called out.
- **No persistence changes** — round-trip guard untouched; no new deps; pure/`dart:io` boundary preserved (Timer only in host).
- **Verified against source:** every id/status/layout above was freshly grepped from the vendored crate this session, with file:line notes for implementers to cite.
