---
id: knowledge:industry/protocols/bacnet-ip
title: BACnet/IP
domain: industry/protocols
version: "2026-08"
topics: [bacnet, bacnet-ip, bvll, npdu, apdu, annex-j, readpropertymultiple, big-endian]
summary: BACnet/IP (Annex J) wire format across BVLL/NPDU/APDU layers, the object/property model, ReadPropertyMultiple's per-property error semantics, and how an in-app pure-Dart device implements and E2E-proves it against a real bacpypes3 client, including a real client-library substitution story.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/dnp3
---

# BACnet/IP

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/bacnet/bacnet_bvll.dart`,
> `bacnet_tags.dart`, `bacnet_services.dart`, `bacnet_dispatch.dart`,
> `bacnet_object_image.dart`, `mobile/lib/services/bacnet_host.dart`, and the
> real-client E2E script `tool/bacnet_e2e.sh`.
> **Read this before:** implementing or debugging a BACnet/IP device/client,
> diagnosing a ReadPropertyMultiple partial-failure question, or handling a
> datagram (UDP) protocol with a "must always answer a confirmed request"
> obligation.

---

## 1. The headline rule

**A BACnet/IP datagram is three nested layers - BVLL, NPDU, APDU, all big-endian - and any confirmed request that parses far enough to yield an invoke ID must always get an answer (ComplexAck/SimpleAck/Error/Reject/Abort), never silence; only a genuinely unparseable datagram is dropped.**

This "always answer what parses" obligation is stricter than most protocols in this family: a segmented request a device can't handle still gets an explicit `Abort`, and an unrecognized confirmed service still gets an explicit `Reject` - silence is reserved for input malformed enough that there is no invoke ID to answer against at all.

---

## 2. Wire format

### 2.1 The three layers

1. **BVLL** (BACnet Virtual Link Layer) - a 4-byte header: `type`(`0x81`), `function` (`0x0A` `Original-Unicast-NPDU` for a unicast reply, `0x0B` `Original-Broadcast-NPDU` for a broadcast, e.g. a startup I-Am announcement), `length` u16 **big-endian** - the length of the **whole datagram including this 4-byte header**. BBMD/Foreign-Device function codes (routing across a broadcast domain) are a separate, larger scope.
2. **NPDU** (Network Layer PDU) - a 2-byte minimal header: `version`(`0x01`), `control`. Bit `0x20` (destination-present) signals router-bound traffic (a destination network other than local); a non-router device drops such datagrams outright rather than parsing further. Bit `0x08` (source-present) signals extra source-network fields that must be **skipped** (never inspected) to reach the APDU, because the actual reply destination is always the UDP datagram's real source address/port regardless of what those fields claim. A minimal NPDU (no destination, no source) is exactly 2 bytes: `01 00` - what a non-routing device always replies with.
3. **APDU** (Application Layer PDU) - PDU type in byte 0's high nibble, an invoke ID for confirmed services, a service-choice byte, then service-specific tagged data.

One UDP datagram is one complete BVLL+NPDU+APDU frame - no reassembly, the same datagram-protocol shape as FINS (see [fins.md](./fins.md)).

### 2.2 Byte order

All multi-byte fields across all three layers are **big-endian**, including the Present_Value Real encoding (IEEE-754 single precision, big-endian).

### 2.3 Object/property model

The Device object is always readable at `(device, deviceInstance)` and exposes `Object_List` both as the whole array and by individual array index (index 0 = element count) - the array-index browse path **Ignition's BACnet/IP driver** depends on for incremental directory traversal rather than pulling the whole list in one request.

A numeric point's Present_Value is served as a BACnet Real - **32-bit IEEE-754 single precision**, the same class of narrowing conversion as SLMP's/S7comm's `FLOAT64 -> REAL` story: any value not exactly representable in single precision loses precision on the wire in both directions.

### 2.4 Services and the always-answer rule

Served services (a representative scope, not exhaustive of the full BACnet service set): unconfirmed **Who-Is -> I-Am** (instance-range filtered discovery), confirmed **ReadProperty -> ComplexAck or Error**, confirmed **ReadPropertyMultiple -> ComplexAck with per-property embedded values/errors**, confirmed **WriteProperty -> SimpleAck or Error**.

**ReadPropertyMultiple's per-property error semantics matter for correctness, not just convenience:** one unsupported/unreadable property inside an otherwise-valid batch must surface as an *embedded* error inside an otherwise-successful ack - never fail the whole batch for one bad property. A response that would exceed the negotiated APDU size gets an explicit `Abort (buffer-overflow)` rather than truncation or silence.

A segmented request a device doesn't support segmentation for is answered `Abort (segmentation-not-supported)`; an unrecognized confirmed service is answered `Reject (unrecognized-service)`. Only a genuinely unparseable datagram - bad BVLL/NPDU framing, an unparseable APDU envelope, or malformed per-service data - is dropped without any reply. Unconfirmed services a device doesn't serve are silently dropped (a `Reject` requires an invoke ID, which an unconfirmed request never carries - there is structurally no PDU to answer with).

---

## 3. Transport and port

UDP, the BACnet Annex J standard port **47808** - unprivileged on every platform, so no privileged-port caveat unlike a low TCP port. Being UDP with no reassembly, a malformed/hostile datagram from any peer at any time must be handled inside its own error boundary without disturbing the bind, the same requirement FINS has.

---

## 4. Addressing / map model

BACnet addresses by **object type + instance number + property**, roughly analogous to DNP3's per-point-type independent index spaces but expressed as full object identifiers rather than a bare index. A general binding model: BOOL points map to Binary Value (BV) objects, numeric points map to Analog Value (AV) objects, each object type its own independent instance-number sequence (an AV 0 and a BV 0 are unrelated objects). `Priority_Array` (the 16-slot BACnet commandable-value stack) reads as all-NULL and `Relinquish_Default` mirrors the current Present_Value when a device does not actually implement per-priority commanding - this is a documented simplification aimed at a commandable-minded client (**Ignition's BACnet/IP driver included**) reading a consistent, non-alarming picture rather than erroring on an unsupported array, not full commandable-priority support.

A WriteProperty's request commonly carries a **priority** argument (BACnet's standard commanding mechanism). **Ignition's BACnet/IP driver always writes at a configured priority (default 8)** - a device that doesn't implement a real per-priority command stack still needs to **parse** that argument off the wire (so a malformed priority never corrupts the rest of the request) even while never consulting it in the write decision - refusing any write that merely carries a priority argument would break this driver on day one, even though its device-side commanding logic is otherwise unimplemented. This means there is no "commandable" setup step required on the client side; a plain ReadWrite-mapped tag just works.

## 5. What the in-app device implements

*(app-specific - this section describes this repository's implementation, not the BACnet/IP standard itself.)*

Object types served: Device, Analog Value, Binary Value only (no Analog/Binary Input/Output, Multi-State Value, Integer Value, etc. - AV/BV cover every scalar tag type this app has, with additional object types being further type-mappings on the same pattern rather than a new mechanism). `STRING` points have no CharacterString Value representation and are skipped by auto-generation, matching the FINS/SLMP/S7comm/EtherNet-IP `STRING` story. COV subscriptions, commandable priority arrays, segmentation, BBMD/Foreign-Device/routed networks, and alarming/eventing/schedules/trend-logs/ReadRange/WritePropertyMultiple are all out of scope - a request naming one of the unimplemented services is answered `Reject (unrecognized-service)`, never silence.

A WriteProperty is refused, checked in order: the target isn't Present_Value on a known AV/BV object; the underlying mapped point doesn't resolve at all (reported as an unknown-object error, distinct from an access refusal - a read of an unresolvable point serves an inactive/zero default instead, but a write to nothing real is a different failure category than a write refused for access reasons); the map entry's own access is read-only; the write-time hard backstop refuses it (a reserved system point, or the point's own access is read-only, independent of what a mutable map entry claims); the point's root is **FORCED**. Only after all four gates pass is the incoming value decoded.

## 6. Write-gate interaction

A forced-tag WriteProperty is refused (`errorClass=property`/`errorCode=write-access-denied`-class error), with the value left unchanged - forcing is authoritative and has no bypass via a member path under a forced root.

## 7. Real-client E2E proof

Proven against a genuine third-party BACnet/IP client library, **`bacpypes3`** (v0.0.106 - an independent, actively-maintained, asyncio-native reimplementation of the BACnet/IP stack with its own APDU/tag codec). The probe drives `who_is()`/I-Am discovery, a Device-object property read seeded independently of the client, an `Object_List` browse in whole-array/count-index/single-index forms, seeded Analog Value and Binary Value Present_Value reads (the tag-encoding settler), a **ReadPropertyMultiple batch** spanning a good object, a good property, and one unsupported property - asserting the unsupported property surfaces as an embedded error inside the ack while the rest of the batch still returns real values - a WriteProperty with independent read-back, a WriteProperty carrying a priority argument (proving it's accepted, not refused, even though unused), a WriteProperty to a read-only-mapped object refused with an independent read-back proving no change, and a read of an unsupported property on an otherwise-served object (a BACnet error, not silence or a wrong value).

**A real client-library substitution, worth knowing generally:** the originally planned client library pinned a dependency (`bacpypes`, the older synchronous BACnet stack) that failed to import on a current Python interpreter because it imported a standard-library module removed in that Python version. The fix was substituting an independent, actively-maintained reimplementation of the same protocol (`bacpypes3`) rather than pinning an older interpreter - still a genuine third-party conformance check (a different codebase's own APDU/tag codec), just a different async-vs-sync API shape. Two real encoding/API disputes that substitute client's own source settled: a batch-read's parameter list is a flat alternating sequence, not a list of tuples, despite its type hint; and a top-level Error/Reject/Abort answering a single request is raised as an exception, while a per-property embedded error inside an otherwise-successful batch ack is returned as a plain value in the result tuple, never raised.

### 7.1 Connecting Ignition's BACnet/IP driver

1. **Add the device by direct IP, not discovery.** Broadcast Who-Is does not cross a Docker NAT boundary (the same reality as FINS/SLMP/S7comm/EtherNet-IP's own recipes), and this device's I-Am replies unicast to whoever asked. In Ignition's BACnet/IP device configuration, add the device by its **direct IP address and port** (e.g. `host.docker.internal:47808` when Ignition runs in Docker and the app runs on the host) rather than relying on network discovery.
2. **Local-device settings are independent.** Any BACnet Local Device Object Instance / Network Number Ignition's driver needs for itself has no bearing on this device - this device's own identity (`deviceInstance`, `Object_Name`) is set from the app's own protocol configuration screen.
3. **Writes just work.** The driver's default write priority (commonly 8) is accepted and ignored by this device's write gate (see above), so there is no "commandable" setup step required on the Ignition side.
4. **Polling works without COV.** The driver's ReadPropertyMultiple polling path is fully served (including `ALL`/`REQUIRED` expansion), so tag browsing/import via `Object_List` and steady-state polling both work without COV subscriptions.

## 8. Gotchas

- **A confirmed request that parses far enough for an invoke ID must always get an answer.** Treat "I don't support this service" and "this request is malformed" as different failure modes with different responses (`Reject`/`Abort` vs. no reply at all) - silently dropping a request your codec successfully parsed just because the service isn't implemented breaks the discoverability a real client relies on.
- **One bad property in a ReadPropertyMultiple batch must not fail the whole batch.** The correct shape is an embedded per-property error inside an otherwise-successful ComplexAck, verified by testing a batch that deliberately mixes a good object/property with an unsupported one and asserting both outcomes land in the same response.
- **Accept-and-ignore a mandatory-shaped argument (like WriteProperty's priority) rather than refusing the whole request over an unimplemented feature**, when the alternative is breaking every real client that always sends that argument regardless of whether the device-side feature exists.
- **A pinned dependency failing to import on a newer language runtime is not necessarily a dead end for an E2E proof** - an independent reimplementation of the same protocol can substitute in as an equally valid third-party conformance check, provided its own source is read carefully enough to catch real API-shape disputes (a type hint that lies about the actual expected argument shape, an exception-vs-return-value split between top-level and embedded errors) rather than assumed correct.
- **Broadcast Who-Is discovery does not cross a Docker NAT boundary.** Ignition's BACnet/IP driver must be pointed at this device's direct IP:port rather than relying on discovery when the SCADA and the device are on opposite sides of a container/NAT boundary - the device's I-Am still replies fine, it just never receives the broadcast Who-Is in the first place.

```
Wrong: fail an entire ReadPropertyMultiple response because one requested
       property, on one requested object, isn't supported.
Correct: return the unsupported property as an embedded per-property error
       INSIDE an otherwise-successful ComplexAck; every other
       object/property in the same batch still returns its real value.
```

---

## What this means practically

### "A client's batch property read comes back completely empty even though most of what it asked for is valid - why?"
Check whether one property in the batch is unsupported and whether that's being treated as a whole-batch failure instead of a per-property embedded error. The correct BACnet behavior is a mixed response: real values for supported properties, an embedded error entry only for the unsupported one.

### "A commanding-capable client's writes are all being rejected even though the target point itself should be writable"
Check whether the write handler is refusing every request that carries a priority argument, rather than accepting-and-ignoring it. A real commanding client typically always sends a priority; a device that doesn't implement a full priority-array command stack still needs to tolerate that argument on every write.

---

## Related

- [fins.md](./fins.md) - the other UDP datagram protocol (one datagram, one frame, no reassembly) in this suite.
- [dnp3.md](./dnp3.md) - a comparably strict "must respond" obligation, though DNP3 expresses it through IIN bits/CONFIRM rather than BACnet's Reject/Abort vocabulary.
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
