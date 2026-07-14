# Sparkplug B NDEATH on Graceful Disconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On an intentional MQTT stop, the SoftPLC publishes its own Sparkplug B NDEATH (current session `bdSeq`) before the MQTT DISCONNECT, so a host (Chariot/Ignition) marks the edge node Offline promptly instead of showing it Online forever.

**Architecture:** Add a pure `MqttPublisher.deathMessage(project, nowMs)` that builds the NDEATH from the CURRENT `bdSeq` (no advance). `MqttHost.disconnect()` publishes it (best-effort, only when connected) before sending the DISCONNECT. The error/reconnect path is untouched — the registered Will still covers ungraceful drops.

**Tech Stack:** pure Dart (`mobile/lib/protocols/mqtt/**`), `dart:io` socket host (`mobile/lib/services/mqtt_host.dart`), the Sparkplug codec, `flutter_test`, Rust `rumqttc` E2E.

## Global Constraints

- No vendor branding; Sparkplug B / MQTT terms fine.
- `mobile/lib/protocols/mqtt/**` stays PURE Dart (no `dart:io`); only `services/mqtt_host.dart` uses sockets.
- **`bdSeq` correlation is the crux:** the disconnect NDEATH uses the CURRENT session `bdSeq` (`publisher.bdSeq` == `_bdSeq.value`, NO `.next()`); `willMessage` remains the ONLY place `_bdSeq` advances. The clean-shutdown NDEATH must not perturb the connect/reconnect bdSeq sequence.
- Best-effort: a failed death publish (socket already broken) must NOT throw out of `disconnect()` — teardown still completes and status becomes Stopped.
- Only `disconnect()` publishes the explicit NDEATH; `_dropAndReconnect` (ungraceful) does NOT (the broker fires the Will there).
- Zero `flutter analyze` warnings; braces on all control flow.

**Commands** (from `mobile/`): `flutter test test/<path>_test.dart`; full `flutter test`; `flutter analyze` (expect **No issues found!**).

---

## Phase A — Publisher `deathMessage`

### Task 1: `MqttPublisher.deathMessage`

**Files:**
- Modify: `mobile/lib/protocols/mqtt/mqtt_publisher.dart`
- Test: `mobile/test/mqtt_publisher_test.dart` (extend — find it; if a separate file is cleaner, `mobile/test/mqtt_death_test.dart`)

**Interfaces:**
- Consumes: existing `_isJson`, `_statusTopic`, `_ndeathTopic`, `_bdSeq` (`SparkplugBdSeq`, `.value` = current, `.next()` = advance), `SparkplugPayload`/`SparkplugMetric`/`SparkplugDatatype`, `encodePayload`, `MqttPublishDescriptor`, `bdSeq` getter (`_bdSeq.value`).
- Produces: `MqttPublishDescriptor? deathMessage(PlcProject project, int nowMs)` — the death certificate for the CURRENT session (does NOT advance `_bdSeq`).

- [ ] **Step 1: Write the failing test**

Read the existing `mqtt_publisher_test.dart` for the harness (how it builds a project with MQTT config in sparkplug vs json mode and decodes a `MqttPublishDescriptor`/`SparkplugPayload`). Add:

```dart
// Sparkplug mode:
// 1. Build a project with MQTT format 'sparkplug'.
// 2. final pub = MqttPublisher();
// 3. pub.willMessage(project);          // advances _bdSeq to N (e.g. 0 -> the first value)
// 4. final n = pub.bdSeq;               // current session bdSeq
// 5. final death = pub.deathMessage(project, 12345)!;
//    - death.topic == the NDEATH topic (same as willMessage's sparkplug topic)
//    - death.retain == false, death.qos == cfg.qos
//    - decode death.payload as SparkplugPayload: seq == 0, timestampMs == 12345,
//      exactly one metric 'bdSeq' (UInt64) whose value == n
// 6. pub.bdSeq == n STILL (deathMessage did NOT advance).
//
// JSON mode: format 'json' -> deathMessage returns a retained 'OFFLINE' descriptor
//   on the status topic (same topic willMessage uses in json mode), retain == true.
//
// No MQTT config -> deathMessage returns null.
```

Write the concrete decode+expect using the existing publisher test's helpers (mirror how `willMessage`/`birthMessages` are asserted). The key assertion is #6 (bdSeq NOT advanced) and #5's `value == n`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/mqtt_publisher_test.dart`
Expected: FAIL — `deathMessage` not defined.

- [ ] **Step 3: Implement**

Add to `mqtt_publisher.dart` (mirror `willMessage`, but use `_bdSeq.value` and a real `nowMs`; do NOT call `_bdSeq.next()`):

```dart
/// The death certificate to publish on an INTENTIONAL disconnect, using the
/// CURRENT session `bdSeq` (the one the active NBIRTH used) — it does NOT
/// advance `_bdSeq` (that is `willMessage`'s job, once per new connection).
/// A clean MQTT DISCONNECT suppresses the registered Will, so the host would
/// otherwise never see the node die; the host publishes this explicitly
/// before disconnecting. Returns null if MQTT isn't configured.
MqttPublishDescriptor? deathMessage(PlcProject project, int nowMs) {
  final cfg = project.protocols?.mqtt;
  if (cfg == null) {
    return null;
  }
  if (_isJson(cfg)) {
    return MqttPublishDescriptor(
      topic: _statusTopic(cfg, project),
      payload: Uint8List.fromList(utf8.encode('OFFLINE')),
      qos: cfg.qos,
      retain: true,
    );
  }
  final payload = SparkplugPayload(
    timestampMs: nowMs,
    seq: 0,
    metrics: [
      SparkplugMetric(name: 'bdSeq', datatype: SparkplugDatatype.uint64, value: _bdSeq.value),
    ],
  );
  return MqttPublishDescriptor(
    topic: _ndeathTopic(cfg, project),
    payload: encodePayload(payload),
    qos: cfg.qos,
    retain: false,
  );
}
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/mqtt_publisher_test.dart` → PASS.
Run: `flutter analyze` → No issues found!

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/protocols/mqtt/mqtt_publisher.dart mobile/test/mqtt_publisher_test.dart
git commit -m "feat(mqtt): deathMessage — NDEATH for the current session bdSeq (no advance)"
```

---

## Phase B — Host publishes NDEATH on disconnect

### Task 2: `disconnect()` sends NDEATH before DISCONNECT

**Files:**
- Modify: `mobile/lib/services/mqtt_host.dart` (`disconnect()` + its doc comment)
- Test: `mobile/test/mqtt_host_test.dart` (extend)

**Interfaces:**
- Consumes: `deathMessage` (Task 1); `_publisher`, `_projectProvider`, `_connacked`, `_socket`, `_sendPublish`, `_wallNowMs`, `encodeDisconnect`.
- Produces: `disconnect()` publishes the NDEATH (best-effort, only when `_connacked` and a live socket + a project provider) BEFORE the DISCONNECT.

- [ ] **Step 1: Write the failing test**

Read `mqtt_host_test.dart` for the harness (how it drives the host to a CONNACK'd state with a fake socket that records outbound bytes, and how it decodes PUBLISH vs DISCONNECT packets). Add a test:

```
// 1. Connect the host (sparkplug) to CONNACK'd state; NBIRTH sent (bdSeq N).
// 2. Clear/snapshot the fake socket's outbound log.
// 3. await host.disconnect();
// 4. Assert the outbound sequence contains a PUBLISH to the NDEATH topic
//    (decode it: a Sparkplug payload with a bdSeq metric == N) BEFORE the
//    MQTT DISCONNECT packet.
// 5. Second case: a host that was never connected (no CONNACK) -> disconnect()
//    writes NO NDEATH PUBLISH (only tears down).
```

Use the existing fake-socket/packet-decode helpers from the current mqtt_host tests; assert ordering (NDEATH publish index < DISCONNECT index).

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/mqtt_host_test.dart`
Expected: FAIL — `disconnect()` currently sends only DISCONNECT.

- [ ] **Step 3: Implement**

Rewrite `disconnect()` to publish the NDEATH first (best-effort, gated on connected state). Replace the current body:

```dart
Future<void> disconnect() async {
  _stopping = true;
  _reconnectTimer?.cancel();
  _reconnectTimer = null;

  // Sparkplug B: a clean MQTT DISCONNECT tells the broker NOT to fire the
  // registered Will (NDEATH). So on an INTENTIONAL stop we must publish the
  // death certificate ourselves first — otherwise the host keeps the node
  // Online forever. Uses the CURRENT session bdSeq (deathMessage does not
  // advance it). Best-effort: a broken socket here must not block teardown.
  final provider = _projectProvider;
  if (_connacked && _socket != null && provider != null) {
    try {
      final project = provider();
      final death = _publisher.deathMessage(project, _wallNowMs());
      if (death != null) {
        _sendPublish(death);
        await _socket?.flush();
      }
    } catch (_) {
      // Ignore — best-effort death notice only.
    }
  }

  try {
    _socket?.add(encodeDisconnect());
    await _socket?.flush();
  } catch (_) {
    // Ignore — best-effort graceful notice only.
  }
  _teardownConnectionOnly();
  _clock.stop();
  _setStatus(MqttHostStatus.stopped);
}
```

Update the doc comment above `disconnect()` (currently says a clean shutdown does NOT re-publish the Will) to state that a clean shutdown DOES publish an explicit NDEATH first, with the Will remaining the safety net for an unexpected drop.

> Confirm `_projectProvider`'s exact name/type by reading the host (it's the `() => PlcProject` passed to `connect`). If it's stored under a different field name, use that. Do NOT publish the NDEATH in `_dropAndReconnect` (ungraceful — the Will fires).

- [ ] **Step 4: Run tests**

Run: `flutter test test/mqtt_host_test.dart` → PASS (new + existing).
Run: `flutter test test/` (mqtt publisher/host/sparkplug) + `flutter analyze` → green / no issues. Confirm connect→NBIRTH, rebirth, heartbeat, deadband/interval, and the bdSeq sequence across connect/disconnect/reconnect are unchanged.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/services/mqtt_host.dart mobile/test/mqtt_host_test.dart
git commit -m "fix(mqtt): publish NDEATH on graceful disconnect so hosts mark the node offline"
```

---

## Phase C — E2E + validation + docs + final review

### Task 3: Rust subscriber E2E + validation + docs

**Files:**
- Modify (E2E): `tool/mqtt_e2e.sh` + the Rust `rumqttc` subscriber/fixture under `gateway/` (read first)
- Modify: `docs/protocols/MQTT.md`, `ROADMAP.md`
- Test: full suite

- [ ] **Step 1: Full green gate**

From `mobile/`: `flutter test` (report count, all green); `flutter analyze` (**No issues found!**); `flutter build web --release` (compiles). Fix code-caused failures; document environmental ones honestly.

- [ ] **Step 2: Machine-proof E2E (clean-disconnect death)**

Read `tool/mqtt_e2e.sh` + the existing Rust `rumqttc` MQTT probe/fixture. Extend so: a Rust subscriber subscribes to the NDEATH topic; the Dart fixture connects (NBIRTH, bdSeq N) then performs a **clean stop** (`disconnect()`, not a killed socket); the subscriber asserts an **NDEATH with bdSeq == N arrives on the clean disconnect**. Preserve the honest build+unit fallback; run `bash tool/mqtt_e2e.sh` and report live-vs-fallback truthfully (do NOT claim a live PASS that didn't happen).

- [ ] **Step 3: Regression**

Confirm existing MQTT publisher/host/Sparkplug tests pass (NBIRTH/rebirth/heartbeat/deadband/interval unchanged; bdSeq pairing across connect/disconnect/reconnect intact). Name the files run.

- [ ] **Step 4: Docs + ROADMAP**

Update `docs/protocols/MQTT.md`: on an intentional stop the SoftPLC publishes an explicit Sparkplug B NDEATH (current session bdSeq) before the DISCONNECT, so a host marks the node Offline promptly (a clean DISCONNECT suppresses the broker Will; the Will remains the ungraceful-drop safety net). Add a ROADMAP entry. No vendor branding.

```bash
git add docs/protocols/MQTT.md ROADMAP.md
git commit -m "docs(mqtt): NDEATH-on-disconnect for prompt host offline detection"
```

- [ ] **Step 5: Final whole-branch review**

Dispatch the final code review; fix Critical/Important; finish the branch (merge `--no-ff` + push) per finishing-a-development-branch.

---

## Self-Review notes (author)

- **Spec coverage:** publisher `deathMessage` with current-bdSeq (T1); host publishes it before DISCONNECT, best-effort, gated, comment fixed, `_dropAndReconnect` untouched (T2); E2E clean-disconnect death + validation + docs (T3). All spec sections mapped.
- **Type consistency:** `deathMessage(project, nowMs)` defined in T1, consumed in T2; uses `_bdSeq.value` (current) per the crux constraint; `_sendPublish`/`_connacked`/`_projectProvider`/`_wallNowMs` are the real host members.
- **Ordering:** A(1) → B(2) → C(3). The host (T2) depends on the publisher method (T1); E2E (T3) exercises both.
