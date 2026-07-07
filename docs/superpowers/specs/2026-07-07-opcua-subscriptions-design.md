# In-App OPC UA Subscriptions (v2) — Design (WS20)

**Date:** 2026-07-07
**Status:** Approved by user (chat, 2026-07-07): scope = "Core + refinements"; clock model, 50 ms tick, and status UI line approved via "proceed".
**Builds on:** `docs/superpowers/specs/2026-07-06-in-app-opcua-server-design.md` (WS19, the in-app pure-Dart OPC UA server v1) and ADR-010 (single app hosts everything; no companion process).

## Goal

Add OPC UA **Subscriptions / MonitoredItems** to the in-app pure-Dart OPC UA server, so SCADA systems and OPC UA clients receive **server-pushed data-change notifications** for exposed tags instead of polling Read. After this workstream, a real OPC UA client can create a subscription, add monitored items on tag Value attributes, and receive `DataChangeNotification`s as tag values change in the running soft PLC — proven end-to-end by the existing Rust `opcua`-client harness.

## Scope ("Core + refinements", user-selected)

**Implemented services** (all encoding ids verified against the vendored Rust `opcua` 0.12.0 reference, `types/node_ids.rs`):

| Service | Request id | Response id |
|---|---|---|
| CreateSubscription | 787 | 790 |
| ModifySubscription | 793 | 796 |
| SetPublishingMode | 799 | 802 |
| DeleteSubscriptions | 847 | 850 |
| CreateMonitoredItems | 751 | 754 |
| ModifyMonitoredItems | 763 | 766 |
| DeleteMonitoredItems | 781 | 784 |
| Publish | 826 | 829 |
| Republish | 832 | 835 |

**Notification payload ids** (`types/node_ids.rs`): NotificationMessage = 805, MonitoredItemNotification = 808, DataChangeNotification = 811, StatusChangeNotification = 820, DataChangeFilter = 724.

**Monitored items:** DataChange items on the **Value attribute (attributeId 13)** of exposed-tag variable nodes only.
- Filter: none (trigger on any value-or-status change) or **DataChangeFilter with absolute deadband** (`deadbandType` Absolute = 1: trigger when `|new − lastReported| ≥ deadbandValue`; numeric types only). `deadbandType` None = 0 behaves as no filter. Percent deadband (2) → `Bad_MonitoredItemFilterUnsupported`. Any non-DataChangeFilter filter ExtensionObject with a body → `Bad_MonitoredItemFilterUnsupported`.
- Non-Value attributes: rejected with `Bad_AttributeIdInvalid` in the per-item result (keeps scope tight; Value is the SCADA case).
- MonitoringMode (Int32 enum): Disabled = 0 (item exists but never samples or reports), Sampling = 1, Reporting = 2. Sampling is treated the same as Reporting in v2 — see Documented simplifications #1.

**Explicitly out (v3+):** event monitored items / event filters, percent deadband, TransferSubscriptions, subscription diagnostics nodes, aggregate filters, monitored items on non-Value attributes.

## Architectural change: a clock + deferred publish

v1's session is purely synchronous (`onBytes(frame) → List<Uint8List>`). Subscriptions add two things that model cannot express: responses sent **later** than their request (parked PublishRequests), and **time-driven** work (sampling, publishing intervals, keep-alives) that must run even when the PLC is not scanning.

**New session entry point:**

```dart
List<Uint8List> onClockTick(int nowMs); // frames to write, possibly empty
```

- The **host** (`OpcUaHost`, the only `dart:io` file) owns a single `Timer.periodic(Duration(milliseconds: 50))` started in `start()` and cancelled in `stop()`. Each tick reads `nowMs` from one `Stopwatch` (monotonic; immune to wall-clock jumps; keeps pure code off `DateTime.now` for scheduling) and calls `onClockTick(nowMs)` on every live connection, writing returned frames to that connection's socket — the same plumbing as `onBytes` output.
- **Idle guarantee preserved:** no timer exists unless hosting was explicitly started; when hosting stops, the timer is cancelled. The app remains byte-identical when hosting is stopped.
- `onBytes` also passes the current `nowMs` (new parameter, host-supplied) so request handling can schedule against the same clock. Signature: `List<Uint8List> onBytes(Uint8List frame, int nowMs)`; existing tests updated mechanically.
- Wall-clock timestamps in wire structs (`publishTime`, DataValue server timestamps) use `DateTime.now().toUtc()` at encode time, consistent with v1.

## Ownership & files

| Unit | File | Responsibility |
|---|---|---|
| `SubscriptionManager` + `Subscription` + `MonitoredItem` (NEW, pure) | `mobile/lib/protocols/opcua/opcua_subscriptions.dart` | All subscription state & logic for ONE session: create/modify/delete subscriptions & items, sampling + change detection + deadband, notification queues, publish cycle, keep-alive/lifetime counters, sequence numbers, retransmission buffer, Republish. Encodes response/notification bodies with `OpcUaWriter`. No `dart:io`, no Flutter, no `DateTime.now()` except wire timestamps. |
| `OpcUaServerSession` (MODIFIED) | `opcua_session.dart` | Owns one `SubscriptionManager` per connection. Routes the nine service ids to it (before the generic `services` handler). Parks PublishRequests (records `requestId` + `requestHandle`), MSG-wraps manager output on tick. Gains `onClockTick`. |
| `OpcUaProjectServices` (MODIFIED) | `opcua_services.dart` | Exposes `OpcDataValue sample(OpcNodeId nodeId)` — refactored out of the existing Read/`_readAttribute` Value path so Read and sampling produce identical values (fresh `projectProvider()` + address-space build per call, same as v1 Read). Injected into sessions as the sampler `OpcDataValue Function(OpcNodeId)`. |
| `OpcUaHost` (MODIFIED) | `mobile/lib/services/opcua_host.dart` | Owns the 50 ms `Timer.periodic` + `Stopwatch`; drives `onClockTick` across connections; passes `nowMs` into `onBytes`. Exposes live `subscriptionCount` / `monitoredItemCount` totals (ChangeNotifier). |
| Outbound Protocols UI (MODIFIED) | `mobile/lib/screens/gateway_screen.dart` | One read-only line on the OPC UA card while running: "Subscriptions: N · Monitored items: M". |
| Rust E2E probe (MODIFIED) | `gateway/examples/opcua_probe.rs`, `mobile/tool/opcua_host_probe.dart`, `tool/opcua_e2e.sh` | Extend the v1 probe: create subscription + monitored item on a tag, mutate the tag server-side, assert a received DataChangeNotification carries the new value. |

## Behavior

### Subscription parameters (revision rules)

- `revisedPublishingInterval`: clamp requested to **[100 ms, 60 000 ms]**; requested ≤ 0 or NaN → 500 ms default. Rounded up to the 50 ms tick grid.
- `revisedLifetimeCount`: clamp to [30, 10 000]; must be ≥ 3 × keep-alive count after both are revised (raise lifetime to satisfy, per Part 4).
- `revisedMaxKeepAliveCount`: clamp to [1, 3 000]; requested 0 → 10.
- `maxNotificationsPerPublish`: 0 = unlimited; otherwise honored per publish cycle (excess stays queued, `moreNotifications = true`).
- `publishingEnabled` honored at create and via SetPublishingMode; `priority` accepted, ignored (single-session scheduling).
- Caps: **max 10 subscriptions per session** — CreateSubscription beyond the cap returns ServiceFault `Bad_TooManySubscriptions` (0x80770000). **Max 500 monitored items per subscription** — each CreateMonitoredItems item beyond the cap gets per-item result `Bad_TooManyMonitoredItems` (0x80DB0000, verified at status_codes.rs:275).
- Parked PublishRequests per session: max 10; an 11th returns an immediate ServiceFault `Bad_TooManyPublishRequests` (0x80780000).

### Monitored item parameters

- `revisedSamplingInterval`: clamp to [50 ms, 60 000 ms]; ≤ 0 → inherit the subscription's publishing interval; −1 semantics (publishing-interval-linked) also yields the publishing interval. Rounded up to the 50 ms grid.
- `revisedQueueSize`: clamp to [1, 100]; requested 0 → 1. `discardOldest` honored: full queue + discardOldest=true drops the oldest (and sets the **overflow bit, 0x480** — `infobits` per Part 4 §7.7.2: statusCode |= 0x480) on the queue's oldest surviving entry; discardOldest=false drops the NEW sample and sets overflow on the newest queued entry.
- `clientHandle` echoed verbatim in every notification for that item.
- Initial value: on creation in Sampling/Reporting mode, the item immediately samples once and queues that first value (standard "initial value" semantic, so clients render current state without waiting for a change).

### Change detection

At each item's sampling due-time: `sample(nodeId)` → compare `(statusCode, value)` to last **reported** sample. No filter / deadbandType None: any difference in status or value triggers. Absolute deadband: status change always triggers; value triggers only if `|new − old| ≥ deadband` (non-numeric current/previous values: any inequality triggers, deadband inapplicable). Deadband validation at create/modify: deadbandValue < 0 or non-finite → `Bad_DeadbandFilterInvalid` (0x808E0000).

### Publish state machine (per subscription)

Each publishing-interval boundary (aligned to creation time on the tick grid):

1. If publishing disabled: nothing is drained; lifetime counter still advances (Part 4: keep-alives still flow when disabled — v2 sends keep-alives normally when disabled, it just never sends data notifications).
2. If queued notifications exist AND a parked PublishRequest is available: send a `PublishResponse` — `subscriptionId`, `availableSequenceNumbers` (retransmission buffer's sequence numbers, ascending), `moreNotifications`, `NotificationMessage{sequenceNumber, publishTime, [DataChangeNotification{monitoredItems[], diagnosticInfos: null}]}`, `results[]` (acknowledgement StatusCodes), `diagnosticInfos: null`. Sequence number increments **only** for messages carrying data (keep-alives reuse the next-expected sequence number without consuming it, per Part 4). Reset keep-alive counter; reset lifetime counter.
3. If queued notifications exist but NO parked request: mark `late`; lifetime counter++ (no request consumed).
4. If nothing queued: keepAlive counter++. When keepAlive counter ≥ maxKeepAliveCount AND a parked request is available: send keep-alive PublishResponse (empty notificationData array, next-expected sequenceNumber, not consumed); reset keep-alive counter; reset lifetime counter.
5. Lifetime: when lifetime counter ≥ lifetimeCount, the subscription is dead: if a parked request is available, send a final PublishResponse carrying `StatusChangeNotification{status: Bad_Timeout (0x800A0000), diagnosticInfo: null}`, then delete the subscription (best-effort; if no request is parked the subscription is deleted silently).

Arriving PublishRequests: acknowledgements processed first (each ack removes that sequence number from the retransmission buffer; unknown → `Bad_SequenceNumberUnknown` (0x807A0000) in `results[]`); then if any subscription is `late`, answer immediately from the longest-late subscription; else park. A PublishRequest with **no subscriptions in the session** → ServiceFault `Bad_NoSubscription` (0x80790000).

### Retransmission buffer & Republish

Every data-carrying NotificationMessage sent is retained until acknowledged, capped at the **most recent 20 per subscription** (oldest silently dropped at cap). `Republish(subscriptionId, retransmitSequenceNumber)`: hit → `RepublishResponse{notificationMessage}`; miss → ServiceFault `Bad_MessageNotAvailable` (0x807B0000); unknown subscription → ServiceFault `Bad_SubscriptionIdInvalid` (0x80280000).

### Cleanup

- `DeleteSubscriptions` / session close / connection drop: all state for that session dies with the session object (per-connection ownership makes this automatic). Parked PublishRequests are NOT drained with faults on CloseSession — v2 keeps v1's close semantics (the connection closes and takes them with it); documented simplification #4.
- `DeleteMonitoredItems`: per-item results; unknown id → `Bad_MonitoredItemIdInvalid` (0x80420000); already-queued notifications from a deleted item are dropped.
- Project switch stops the host (v1 behavior, unchanged) — all subscriptions die with their connections.

### Error codes summary (all verified in vendored `status_codes.rs`)

Good 0, Bad_Timeout 0x800A0000, Bad_SubscriptionIdInvalid 0x80280000, Bad_NotSupported 0x803D0000, Bad_MonitoredItemIdInvalid 0x80420000, Bad_MonitoredItemFilterUnsupported 0x80440000, Bad_FilterNotAllowed 0x80450000, Bad_TooManySubscriptions 0x80770000, Bad_TooManyPublishRequests 0x80780000, Bad_NoSubscription 0x80790000, Bad_SequenceNumberUnknown 0x807A0000, Bad_MessageNotAvailable 0x807B0000, Bad_DeadbandFilterInvalid 0x808E0000, Bad_TooManyMonitoredItems 0x80DB0000, plus v1's existing codes (Bad_NodeIdUnknown, Bad_AttributeIdInvalid, Bad_NothingToDo…).

## Documented simplifications (v2)

1. **Sampling mode ≈ Reporting** for delivery: v2 samples items in Sampling mode but also reports them (no triggered-item linkage exists to make Sampling meaningful). Disabled mode is fully honored (no sampling, no reporting). Recorded in code comment.
2. **TimestampsToReturn** on CreateMonitoredItems is accepted and ignored — notifications always carry a server timestamp (v1 Read behaves identically).
3. Publishing-disabled subscriptions still emit keep-alives.
4. No draining of parked PublishRequests on CloseSession (connection teardown handles it).
5. Sequence numbers are session-lifetime UInt32 starting at 1 per subscription; wraparound (4 billion messages) is out of realistic scope and not specially handled.

## Testing

1. **Pure unit tests** (`mobile/test/opcua_subscriptions_test.dart` + session-level tests in `opcua_session_test.dart` style): all state-machine behavior driven by injected `nowMs` and a fake sampler — deterministic, socketless. Must cover: parameter revision/clamping, initial-value queue, change detection (incl. deadband boundary `|Δ| == deadband` triggers), queue overflow both discardOldest polarities + overflow bit, keep-alive cadence, lifetime timeout + StatusChangeNotification, publish deferral (park → tick → delivery), ack/retransmission/Republish (hit + miss), per-service error codes, multi-subscription priority-free fairness (late-first), caps.
2. **Codec fixtures** (`opcua_binary_test.dart` pattern): every new struct encoded and byte-compared against hand-derived layouts from the vendored Rust struct files (`create_subscription_request.rs`, `notification_message.rs`, `data_change_notification.rs`, `subscription_acknowledgement.rs`, `data_change_filter.rs`, etc.).
3. **E2E machine-proof** (extend `tool/opcua_e2e.sh`): Rust `opcua` client creates a subscription (500 ms) + monitored item on `Int32` tag → probe host mutates the tag → assert the client's subscription callback receives a DataChangeNotification with the exact new value within a bounded wait → PROBE PASS. This remains the merge gate.
4. **Regression:** full `flutter test` (579+ tests), `flutter analyze` zero warnings, web build still compiles (subscriptions code is pure Dart; `Timer`/`Stopwatch` are `dart:async`/`dart:core`, web-safe).

## Global constraints (unchanged from v1)

- No vendor branding ("OpenPLC", "Beremiz", "CODESYS", "RSLogix") in any string/identifier/comment; IEC & OPC UA spec terms fine.
- Zero `flutter analyze` warnings; no RenderFlex overflows; dark mode.
- Force-aware writes untouched (subscriptions only observe values — forced values are reported as-is, like Read does).
- App byte-identical when hosting is stopped; hosting remains explicit opt-in.
- Every new wire encoding cross-checked against the vendored Rust reference with file:line citations in comments.
- No new dependencies; `dart:io` stays confined to `opcua_host.dart`.
