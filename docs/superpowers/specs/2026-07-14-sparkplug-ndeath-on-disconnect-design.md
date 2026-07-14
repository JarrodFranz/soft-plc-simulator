# Sparkplug B NDEATH on Graceful Disconnect — Design

**Date:** 2026-07-14
**Status:** Approved by user (chat, 2026-07-14).
**Builds on:** the in-app MQTT/Sparkplug B publisher + host (`mobile/lib/protocols/mqtt/mqtt_publisher.dart`, `mobile/lib/services/mqtt_host.dart`) and the Sparkplug codec (`mqtt_sparkplug.dart`).

## Problem

When the SoftPLC's MQTT is **Stopped/Disconnected**, a Sparkplug B host (Chariot SCADA / Ignition) keeps the edge node showing **Online** indefinitely (observed >1 hour after a clean stop). Root cause is confirmed in code: `MqttHost.disconnect()` sends a clean MQTT `DISCONNECT` (`encodeDisconnect()`) and relies solely on the registered **Will** (NDEATH) to signal death. But the MQTT broker only publishes a Will on an **ungraceful** disconnect (dropped socket / keep-alive timeout) — a clean `DISCONNECT` **suppresses the Will**. So on an intentional stop no NDEATH is ever delivered, and the host never learns the node went offline. `disconnect()`'s own comment documents this as intentional ("a clean shutdown [does not] re-publish [the Will]"), which is incorrect for Sparkplug B: an edge node that intentionally disconnects MUST publish its own NDEATH first.

(The retained `spBv1.0/STATE/<host_id>` message seen in MQTT Explorer is the primary **host** application's STATE — a separate mechanism the SoftPLC does not publish — and is unrelated to this bug.)

## Goal

On an intentional stop (`MqttHost.disconnect()`), the edge node publishes its own **NDEATH** (Sparkplug) / retained **OFFLINE** status (JSON) **before** sending the MQTT `DISCONNECT`, carrying the **current session's `bdSeq`** so the host correlates the death with the active birth. The node then shows Offline in the host promptly on a clean stop, matching Sparkplug B semantics.

## Decisions (locked with the user)

- Publish an explicit death certificate on graceful disconnect (not rely on the suppressed Will).
- Use the **current session `bdSeq`** (the one the active NBIRTH used) — do NOT advance it (advancing would break the birth/death correlation).

## Architecture

### Publisher (`mqtt_publisher.dart`) — new `deathMessage`

Add `MqttPublishDescriptor? deathMessage(PlcProject project, int nowMs)`:
- JSON mode (`_isJson(cfg)`): identical to `willMessage`'s JSON branch — retained `OFFLINE` on `_statusTopic`, `qos: cfg.qos`, `retain: true`.
- Sparkplug mode: build an NDEATH on `_ndeathTopic` with `seq: 0` and a single `bdSeq` (UInt64) metric whose value is the **current** `_bdSeq` (via the existing `bdSeq` getter — NO `_bdSeq.next()` call), `timestampMs: nowMs`, `qos: cfg.qos`, `retain: false`. (Contrast `willMessage`, which calls `_bdSeq.next()` to advance for the *next* connection's Will and stamps `timestampMs: 0` because a Will can't be timestamped at publish; `deathMessage` publishes now, so it uses the live clock and the current bdSeq.)
- Returns `null` when MQTT isn't configured.

The `bdSeq` getter already exposes the current value (the host reads `publisher.bdSeq`). This keeps the sequence correct: `connect → willMessage(advance→N) → NBIRTH(N) → … → disconnect → NDEATH(N)`; the next connect advances to `N+1`.

### Host (`mqtt_host.dart`) — publish NDEATH before DISCONNECT

In `disconnect()`, before `encodeDisconnect()`: if currently connected (`_connacked` and a live socket), fetch the project, call `_publisher.deathMessage(project, _wallNowMs())`, and if non-null `_sendPublish(...)` it and `await _socket?.flush()` — then proceed to send the `DISCONNECT`, tear down, and set status Stopped. Guard so a never-connected / already-stopped `disconnect()` skips the death publish (nothing to announce). Wrap the death publish in the same best-effort try/catch the DISCONNECT already uses (a failed death publish must not block teardown). Update the misleading doc comment to state that a clean shutdown DOES publish an explicit NDEATH first (the Will remains the safety net for an unexpected drop).

- **Only `disconnect()` publishes the explicit NDEATH.** The error/reconnect path (`_dropAndReconnect`) is an ungraceful internal drop — the broker's registered Will fires there, and the host reconnects; it must NOT publish an extra NDEATH.
- No double death: on a clean `DISCONNECT` the broker discards the registered Will (doesn't fire it), so the single explicit NDEATH is the only death delivered.

## Testing

**Publisher unit (`mqtt_publisher_test.dart` / a death test):** in Sparkplug mode, `deathMessage(project, now)` returns an NDEATH descriptor on the NDEATH topic with `retain: false`, `seq: 0`, `timestampMs == now`, and a `bdSeq` metric equal to the **current** session bdSeq — specifically, after `willMessage` (advances to N) + `birthMessages` (N), `deathMessage` reports **N** and does NOT advance (a subsequent `bdSeq` read is still N). JSON mode returns a retained `OFFLINE` status descriptor.

**Host (`mqtt_host_test.dart`):** drive the host to a connected (CONNACK'd) state, then `disconnect()`; assert an NDEATH PUBLISH is written to the socket **before** the DISCONNECT packet (inspect the ordered outbound bytes / the fake socket's write log), with the session bdSeq; and that a `disconnect()` from a never-connected/stopped state writes NO NDEATH. Confirm the existing connect→NBIRTH and rebirth behavior is unchanged (bdSeq pairing intact).

**Machine-proof E2E (`tool/mqtt_e2e.sh` + the Rust `rumqttc` subscriber):** a subscriber subscribes to the NDEATH topic (and/or observes the node state), the fixture connects (NBIRTH) then calls a clean stop, and the subscriber asserts an **NDEATH with the matching bdSeq arrives on the clean disconnect** (not just on a killed connection). Preserve the honest build+unit fallback; report live vs fallback truthfully.

**Regression:** full `flutter test`; `flutter analyze` zero; `flutter build web --release` compiles; existing MQTT publisher/host + Sparkplug tests pass (NBIRTH/rebirth/heartbeat/deadband/interval unchanged; bdSeq sequence across connect/disconnect/reconnect still correct).

## Global constraints

- No vendor branding; Sparkplug B / MQTT terms fine.
- `mobile/lib/protocols/mqtt/**` stays pure Dart (no `dart:io`); only `mqtt_host.dart` (services) uses sockets.
- `bdSeq` correlation is the crux: NDEATH-on-disconnect uses the CURRENT session bdSeq (no advance); `willMessage` still advances for the next connection. The clean-shutdown NDEATH must not perturb the connect/reconnect bdSeq sequence.
- Best-effort: a failed death publish (socket already broken) must not throw out of `disconnect()` — teardown still completes and status becomes Stopped.
- Zero `flutter analyze` warnings; braces on all control flow.

## Phasing (one spec → phased plan)

- **Phase A — Publisher `deathMessage`.** Add the method (current-bdSeq NDEATH / retained OFFLINE) + unit tests (bdSeq-not-advanced, topic/retain/seq/timestamp).
- **Phase B — Host publishes NDEATH on disconnect.** Wire `deathMessage` into `disconnect()` before the DISCONNECT, guarded on connected state + best-effort; fix the comment; host test (ordering + not-when-disconnected).
- **Phase C — E2E + validation + docs + final review.** Rust subscriber sees NDEATH on clean stop; full gates; update `docs/protocols/MQTT.md`; whole-branch review; merge.
