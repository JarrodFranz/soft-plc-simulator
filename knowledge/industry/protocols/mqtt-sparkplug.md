---
id: knowledge:industry/protocols/mqtt-sparkplug
title: MQTT + Sparkplug B
domain: industry/protocols
version: "2026-08"
topics: [mqtt, sparkplug-b, protobuf, publisher, bdseq, ndeath, report-by-exception, qos]
summary: MQTT 3.1.1 control-packet wire format, the Sparkplug B protobuf payload convention, the birth/death (bdSeq) sequencing contract, and how an in-app pure-Dart publisher implements and E2E-proves both JSON and Sparkplug B against a real embedded broker + subscriber, including the intentional-disconnect NDEATH gap that a bare MQTT Will structurally cannot cover.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/opc-ua
---

# MQTT + Sparkplug B

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/mqtt/mqtt_codec.dart`,
> `mqtt_publisher.dart`, `mqtt_sparkplug.dart`, `mobile/lib/services/
> mqtt_host.dart`, and the real-client E2E script `tool/mqtt_e2e.sh`.
> **Read this before:** implementing or debugging an MQTT publisher/broker
> interaction, a Sparkplug B birth/death sequencing question, or an
> intentional-vs-ungraceful disconnect notification gap.

---

## 1. The headline rule

**MQTT's registered Will only fires on an ungraceful disconnect (keep-alive timeout, TCP reset) - a clean `DISCONNECT` packet tells the broker to SUPPRESS the Will entirely (MQTT 3.1.1 §3.1.2.5), so an intentional stop must publish its own death/offline message BEFORE the graceful disconnect, or a downstream subscriber has no way to learn the client stopped on purpose.**

This is a protocol-level gap every MQTT-based birth/death convention (Sparkplug B's NBIRTH/NDEATH pairing included) has to design around explicitly - it is not an edge case, it is the *majority* path for a well-behaved client that shuts down normally rather than crashing.

---

## 2. Wire format

### 2.1 MQTT 3.1.1 control-packet framing

A fixed header byte is `(packetType << 4) | flags`, followed by **Remaining Length**: a 1-4 byte variable-length integer where each byte holds 7 data bits (least-significant group first) with the high bit signaling "more bytes follow" - a self-describing length encoding, unlike a protocol with a fixed-width length field.

CONNECT's variable header is protocol name `"MQTT"` (as an MQTT string), protocol level `0x04`, a connect-flags byte, and a **big-endian** u16 keep-alive; the payload is client id, then (if present) will topic + will payload, then username, then password - each as MQTT strings/length-prefixed binary data. PUBLISH's variable header is a topic string, then - only when QoS > 0 - a **big-endian** u16 packet id; everything after is the application payload. Multi-byte integer fields in the control-packet layer (keep-alive, packet id) are big-endian, per the OASIS spec.

### 2.2 The Will/death-notification gap

A **registered Will** (set at CONNECT time) is the broker's promise to publish a specified message *if* it detects the connection died ungracefully. A clean `DISCONNECT` packet explicitly **suppresses** that Will - the broker will never publish it for a connection that disconnected cleanly. A birth/death convention that relies solely on the registered Will therefore has a real gap: an intentional, graceful stop leaves subscribers believing the client is still alive/birthed indefinitely, since the very mechanism meant to announce "this client is now offline" is the one the graceful path silently disarms.

The fix pattern: on an intentional stop, publish the same death/offline message the Will *would* have carried, explicitly and best-effort, **before** sending the graceful `DISCONNECT` - a broken socket at this point must not block teardown. This covers exactly the path the registered Will structurally cannot: the registered Will remains the safety net for a genuinely ungraceful drop (crash, lost network, killed process); the explicit pre-disconnect publish covers the graceful stop.

### 2.3 Sparkplug B: protobuf payload over MQTT topics

Sparkplug B layers a compact binary payload (a `Payload`/`Metric` protobuf message pair, per the Eclipse Tahu `sparkplug_b.proto` convention) on top of plain MQTT publish/subscribe - MQTT itself carries no protobuf awareness; the payload bytes are opaque to the broker. A metric carries `name`/`alias`/`datatype` plus exactly one scalar value field appropriate to that datatype.

**Topic convention:**

| Purpose | Topic |
|---|---|
| Birth (retained) | `spBv1.0/{group_id}/NBIRTH/{edge_node_id}` |
| Will/death (retained) | `spBv1.0/{group_id}/NDEATH/{edge_node_id}` |
| Telemetry | `spBv1.0/{group_id}/NDATA/{edge_node_id}` |
| Remote write | `spBv1.0/{group_id}/NCMD/{edge_node_id}` |

**NBIRTH** carries one aliased metric per exposed point (both `name` and `alias`, so a subscriber can build its own alias table) and resets the message **sequence counter** (`seq`) to `0`. **NDATA** carries alias-only metrics (no `name`, saving bytes on every subsequent publish) and advances `seq` by one each time, wrapping back to `0`.

**`bdSeq` (birth/death sequence)** is the pairing mechanism a Sparkplug-aware subscriber uses to tell a stale NDEATH from the current session's: a monotonically increasing counter that never resets for the client's lifetime, not even across reconnects. Each (re)connect's Will (registered at CONNECT time, before any session traffic) carries an NDEATH with `bdSeq` advanced by one from the previous connection's value, and the NBIRTH that follows reads that *same* value - so a subscriber can match a death notification to the exact session it announces the end of. An intentional-stop's explicit death publish (see §2.2) must carry `bdSeq` at its **current** session value (not advanced again) - only the Will-registration path advances `bdSeq`, exactly once per new connection.

### 2.4 Report-by-exception + heartbeat

A publisher commonly runs two independent telemetry mechanisms against the same "last published" baseline (reseeded at every birth): **report-by-exception** publishes only points whose value changed since the last publish, on a fast tick; a **heartbeat** republishes the *entire* mapped set on a slower, fixed cadence regardless of change, giving a subscriber a way to detect a missed report-by-exception publish or simply poll on a fixed schedule. An **analog deadband** can additionally suppress a report-by-exception publish while a numeric value stays within a configured tolerance of the last value actually published - with the suppressed baseline pinned at that last-published value (not drifting), so several small sub-deadband moves don't silently accumulate into an unreported large change.

---

## 3. Transport and port

TCP, conventional port **1883** (plain) or **8883** (TLS) - both unprivileged. Unlike every other protocol in this family, the app is the **client** here, dialing out to a broker it does not host - the direction of connection establishment is inverted relative to a Modbus/OPC UA/EtherNet-IP/S7comm/FINS/SLMP/DNP3/BACnet server that waits for inbound connections.

---

## 4. Addressing / map model

MQTT/Sparkplug addresses by **topic** (JSON mode) or **metric alias** (Sparkplug mode) rather than a register/byte-offset/object-instance scheme - closer to OPC UA/EtherNet-IP's name-addressed model than to an area-image protocol. A general binding model: each exposed point gets a metric name/alias (Sparkplug) or a topic suffix (JSON), with a composite (struct/array) source value never published as one aggregate - each scalar leaf becomes its own metric/topic, keyed by a dotted/indexed path, the same leaf-keying convention this family's other name-addressed protocols (OPC UA, EtherNet-IP) share. `STRING`-typed leaves are directly representable in both JSON (a plain string value) and Sparkplug (`string_value`).

## 5. What the in-app publisher implements

*(app-specific - this section describes this repository's implementation, not the MQTT/Sparkplug B standard itself.)*

MQTT 3.1.1 CONNECT/PUBLISH/SUBSCRIBE/PINGREQ/DISCONNECT over plain TCP or TLS; JSON and Sparkplug B (Node-level only, no `DBIRTH`/`DDATA`/`DDEATH` device sub-tree) payload formats; retained birth/will; report-by-exception + heartbeat telemetry; opt-in, force-aware remote writes. QoS 0/1 only (no QoS 2's four-way handshake). MQTT 5.0 and WebSocket transport are not implemented. The broker **password** is supplied fresh per connection attempt and held only in memory for that attempt's lifetime - never written into a persisted configuration, so it never ends up in a saved/exported/backed-up config file.

## 6. Write-gate interaction

Remote writes are commonly **opt-in, default off** - while off, the client never subscribes to the write/command topic at all (not "subscribes but ignores" - no SUBSCRIBE packet sent), so nothing published on that topic can reach a write path regardless of content. When enabled, an inbound write to a **forced** point is **silently dropped** - no response channel exists over MQTT to report a refusal, unlike a request/response protocol (OPC UA's `Bad_UserAccessDenied`, DNP3's `NOT_AUTHORIZED`) - but the forcing engineer's value still always wins; the difference from those protocols is only that the write's originator gets no error signal.

## 7. Real-client E2E proof

Proven against a genuine embedded broker (`rumqttd` 0.20) and a genuine subscriber client (`rumqttc` 0.25, Rust). **JSON**: a retained `ONLINE` birth (proven retained via a second, freshly-subscribing client, since MQTT correctly clears the RETAIN flag on live delivery to an already-subscribed client per spec); a forced-tag telemetry publish reflecting the forced value even though the live value differs; a telemetry publish reflecting a value the fixture mutates server-side on its own timer (the live-not-frozen proof); a remote-write publish followed by the *next* telemetry publish reflecting the written value. **Sparkplug B**: a retained NBIRTH decoded against an independent protobuf-message implementation, asserting the exact metrics/aliases/`bdSeq`; an NDATA reflecting the same server-side mutation at its Sparkplug alias; an NCMD write followed by the next NDATA reflecting it at its alias. **NDEATH on a clean disconnect**: a fresh client connects and births normally, then self-initiates a clean stop mirroring the documented pattern exactly - publish NDEATH (current session `bdSeq`), flush, **then** send the MQTT `DISCONNECT`, then exit - and the probe asserts an NDEATH carrying that same `bdSeq` arrives, proof the app-level death publish (not the registered Will, which a clean DISCONNECT suppresses) is what put it there.

## 8. Gotchas

- **A registered Will alone is not a complete birth/death story.** It covers ungraceful disconnects only; a graceful stop needs its own explicit death-message publish before the clean DISCONNECT, or well-behaved shutdowns are invisible to subscribers.
- **`bdSeq` advances exactly once per new connection (at Will-registration time), never on the explicit graceful-stop death publish.** Advancing it twice for the same session (once at connect, again at intentional disconnect) breaks the birth/death pairing convention a Sparkplug-aware subscriber relies on to match an NDEATH to the NBIRTH it terminates.
- **Retained-message proof needs a *fresh* subscriber, not the primary session's live view.** MQTT correctly clears the RETAIN flag on a message delivered live to an already-subscribed client, so asserting retention against the same connection that triggered the publish is not a valid test - only a newly-subscribing client demonstrates the broker actually retained it.
- **A forced-point write refusal has no response channel in plain MQTT.** Don't assume a client publishing a write will ever learn it was refused; the only externally-observable signal is that the point's subsequent telemetry never reflects the attempted value - document this asymmetry rather than silently designing as if MQTT could report a refusal like a request/response protocol.
- **QoS 0/1-only is a real interop boundary**, not just an implementation-effort shortcut - a broker/subscriber pairing that assumes QoS 2 semantics (exactly-once delivery via the four-way PUBREC/PUBREL/PUBCOMP handshake) will not get the guarantee it expects.

```
Wrong: rely solely on the registered MQTT Will to notify subscribers that a
       client has gone offline, including for an intentional/graceful stop.
Correct: on an intentional stop, publish the death/offline message
       EXPLICITLY, before sending the clean DISCONNECT packet - the Will
       remains the safety net for an ungraceful drop only, since a clean
       DISCONNECT suppresses it per spec.
```

---

## What this means practically

### "Subscribers still see my client as ONLINE for a long time after I stopped it cleanly - why?"
Because a clean `DISCONNECT` suppresses the registered Will entirely, per MQTT 3.1.1 §3.1.2.5 - the death/offline notification that would normally fire never gets sent for a graceful stop. The fix is publishing the death/offline message yourself, explicitly, immediately before the clean disconnect.

### "How do I prove a retained message is actually retained, not just delivered live?"
Subscribe a **second, freshly-connecting** client after the publish, not the original publishing/subscribing session - MQTT correctly clears the RETAIN flag on delivery to a client that was already subscribed when the message was published, so only a fresh subscribe demonstrates real retention.

---

## Related

- [opc-ua.md](./opc-ua.md) - the other name/alias-addressed protocol in this family, and a contrast in write-refusal visibility (a response-channel refusal vs. MQTT's silent drop).
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
