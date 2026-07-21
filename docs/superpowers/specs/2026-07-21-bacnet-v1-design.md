# BACnet/IP (device side) — Design Spec

**Workstream:** WS6 of the protocol-expansion program (the final one).
**Date:** 2026-07-21. **Status:** user-approved design, pre-plan.
**Prior art this leans on:** the S7/FINS/SLMP device+address family
(`docs/superpowers/specs/2026-07-20-fins-v1-design.md`,
`2026-07-20-slmp-v1-design.md`) and the OPC UA binary codec (the only other
protocol in the repo with comparable encoding depth).

## Goal

The Soft PLC app hosts a **BACnet/IP server device** in-process, in pure Dart
(ADR-010 — no companion service, no FFI; `dart:io` confined to
`services/bacnet_host.dart`), so BACnet clients (BMS/SCADA) can discover it
(Who-Is/I-Am), browse its Object_List, and read/write its tags as BACnet
objects over **UDP port 47808**. Service scope is chosen so that **Ignition's
BACnet/IP driver works via its polling path on day one** — discovered live
today across ENIP/FINS/SLMP that the client always demands the deferred
feature immediately.

## Reference clients — CONFIRMED BEFORE PLANNING

* **Automated authority:** the real third-party **BAC0** Python library
  (which drives **bacpypes**) in a `tool/py/bacnet_probe.py` lane —
  `tool/bacnet_e2e.sh`, pinned in `tool/py/requirements.txt`, READY
  handshake + trap teardown like the four existing lanes. BAC0/bacpypes is
  strict about tag encodings, making it a good wire authority.
* **Manual target:** Ignition's **BACnet/IP driver** (user-run confirmation
  at the end, like today's FINS/SLMP sessions). Its polling path needs:
  Who-Is/I-Am (or direct-IP addressing), ReadProperty including
  **Object_List by array index** (browse), **ReadPropertyMultiple**
  (efficient polling), and WriteProperty **carrying a priority** (the driver
  always writes at a configured priority, default 8). COV subscriptions are
  deliberately v2 — the driver falls back to polling.

**The client is the wire authority.** Every encoding decision a symmetric
build→parse round-trip could hide (tag octets, enumerations, object-id
packing, character-string encodings) is settled by literal-byte unit tests
AND an independent-seed read through BAC0, per the round-trip-trap rule that
caught FINS word order and SLMP endianness.

## Decisions taken (user-approved)

1. **Target clients:** Ignition (polling path) + BAC0 E2E. COV deferred.
2. **Object model:** **AV + BV only.** BOOL → Binary Value; every numeric
   (INT16/INT32/INT64/FLOAT64) → Analog Value with a **float32
   Present_Value** — a documented NARROWING for INT32/INT64 beyond 2^24 and
   for FLOAT64, the same class of narrowing as FLOAT64→REAL in FINS/SLMP.
   STRING is skipped by autoGenerate and refused by the image (as
   everywhere else).
3. **Writes accept a priority parameter and ignore it** (apply-through-gate;
   no priority-array command semantics). Forced by the Ignition driver:
   rejecting priority writes would break it. `Priority_Array` reads as
   all-NULL (16 Nulls), `Relinquish_Default` reads as the current value, so
   commandable-minded clients don't error.
4. **Unsegmented only**, Max_APDU 1476. An RPM response that would exceed it
   → `Abort (buffer-overflow)`; clients retry with smaller batches.
5. **No BBMD / Foreign Device / routed NPDUs** in v1. NPDUs carrying a
   destination network (router traffic) are dropped politely (logged DEBUG).
6. **Discovery reality:** broadcast Who-Is does not cross Docker NAT.
   I-Am replies go **unicast to the requester**; docs steer Ignition to
   direct-IP device addressing (`host.docker.internal`), same as FINS.

## Non-goals / YAGNI (deferred to v2, deliberate)

* COV subscriptions (SubscribeCOV / COVNotification).
* Commandable objects (real priority arrays, relinquish logic).
* Segmentation (both directions).
* BBMD, Foreign-Device registration, routed networks, BACnet/SC.
* Object types beyond Device/AV/BV (no AI/AO/BI/BO/MSV/IV; no
  CharacterString Value for STRING tags).
* Alarming/eventing (intrinsic reporting), schedules, trend logs, files.
* ReadRange, WritePropertyMultiple, DeviceCommunicationControl,
  ReinitializeDevice, TimeSynchronization (unrecognized-service Reject).

## Global Constraints

* Pure Dart, zero `flutter analyze` warnings, `dart:io` only in
  `services/bacnet_host.dart` and `mobile/tool/bacnet_host_probe.dart`.
* Additive `ProtocolSettings` — a project JSON without a `bacnet` key loads
  with BACnet disabled at defaults; the WS6 lossless round-trip suite stays
  green; the off/default path is byte-identical.
* Shared write-gate: `isExternallyWritable` + forced-root refusal +
  map-entry access, identical outcomes to the seven existing gates.
* Logging per the protocol-logging rule: `kLogSourceBacnet = 'BACnet'` in
  `app_log.dart` AND `kAllLogSources` (guard test enforces); host start/stop
  INFO, first-peer INFO, refusals DEBUG, drops WARN; per-frame TRACE via
  `logLazy`.
* One shared dispatch (`dispatchBacnetDatagram`) called by BOTH the shipped
  host and the E2E fixture host, so the BAC0 proof covers the shipped bytes
  by construction.
* Default port **47808** (0xBAC0). Above 1023 — no elevated privilege.
* Device instance default **3056**, user-editable 0–4194302 (enforced in
  the card).

## Component 1 — BVLL + NPDU framing (`protocols/bacnet/bacnet_bvll.dart`)

BACnet/IP Virtual Link Layer: `type` u8 (always 0x81 for BACnet/IP),
`function` u8, `length` u16 **BIG-ENDIAN** (whole datagram incl. the 4-byte
BVLL header). v1 serves:

* `0x0A` Original-Unicast-NPDU and `0x0B` Original-Broadcast-NPDU → carry an
  NPDU; anything else (Forwarded-NPDU, BBMD functions…) → BVLC-Result NAK
  where the spec calls for one, otherwise dropped politely (logged DEBUG).
* NPDU: `version` u8 (must be 0x01), `control` u8. Control bit 5 (0x20)
  destination-present → router traffic → not served (drop, DEBUG). Bit 3
  (0x08) source-present → parse past the source (a reply goes back to the
  UDP sender regardless). Bit 2 (0x04) expecting-reply informs nothing in
  v1. The NPDU of every reply we BUILD is minimal: version 1, control 0x00.
* Parse functions return `null` — never throw — on malformed/truncated/
  hostile input (the UDP host feeds raw datagram bytes).

## Component 2 — primitive tag codec (`protocols/bacnet/bacnet_tags.dart`)

The ASN.1-ish layer and the highest-risk unit. Application tags (class bit
0): Null(0), Boolean(1, value in the L/V/T field), UnsignedInt(2),
SignedInt(3), Real(4, IEEE-754 single **big-endian**), CharacterString(7,
UTF-8 charset byte 0x00), Enumerated(9), ObjectIdentifier(12, u32 =
`type << 22 | instance`). Context tags (class bit 1) with tag numbers per
service. Opening/closing tags (L/V/T 6/7). Extended lengths (5 → next byte;
254/255 forms) parsed but v1 payloads stay small. Every encoder/decoder is
pinned with LITERAL byte expectations from the standard's examples — never
by round-trip alone.

## Component 3 — services + dispatch + EARLY real-client probe

`protocols/bacnet/bacnet_services.dart` + `bacnet_dispatch.dart` +
`services/bacnet_host.dart` skeleton + `mobile/tool/bacnet_host_probe.dart`
+ `tool/py/bacnet_probe.py` first slice + `tool/bacnet_e2e.sh`.

APDU types served: Confirmed-Request (0x0) → SimpleAck (0x2) / ComplexAck
(0x3) / Error (0x5) / Reject (0x6) / Abort (0x7); Unconfirmed-Request (0x1)
for Who-Is (service 8) / I-Am (service 0). Invoke-ID echoed. Segmented
requests (APDU SEG bit set) → `Abort (segmentation-not-supported)`.

* **Who-Is/I-Am:** Who-Is with optional instance range (respond only when
  our instance is inside it); reply **I-Am unicast to the UDP sender**.
  I-Am also broadcast once, best-effort, on host start.
* **ReadProperty (12):** any served object/property; `Object_List` supports
  the array-index form (index 0 = count, index N = Nth object id) — the
  Ignition browse path. Unknown object → Error(object, unknown-object);
  unknown property → Error(property, unknown-property).
* **ReadPropertyMultiple (14):** list of (object, property refs incl.
  `ALL`(8) / `REQUIRED`(105) / `OPTIONAL`(80) specials); the ComplexAck
  embeds per-property values OR per-property errors, so one bad property
  never fails the batch. Response > 1476 bytes → Abort(buffer-overflow).
* **WriteProperty (15):** Present_Value only; optional priority context tag
  accepted and ignored; value decoded per object type (BV: Enumerated 0/1,
  also lenient Boolean; AV: Real, also lenient Unsigned/Signed converted);
  wrong type → Error(property, invalid-data-type); any other property →
  Error(property, write-access-denied).
* Anything else → Reject(unrecognized-service). **Always an answer, never
  silence** — BACnet clients time out badly on silence, and today's FINS/
  SLMP sessions were both diagnosed from drop logs.

**EARLY GATE (probe-early, the Task-3 discipline):** before the object
model widens, the fixture host + BAC0 must pass: discover (Who-Is → I-Am),
read Device Object_Name, read one seeded AV Present_Value. This pins BVLL/
NPDU/APDU/tag encoding against the real client while the surface is small.

## Component 4 — `BacnetMap` + object image

`models/bacnet_map.dart`: entries `tag` + `objectType` (`'AV'`/`'BV'`) +
`instance` (u22) + `access` (`ReadOnly`/`ReadWrite`).
`autoGenerate(project)`: scalar leaves in tag order; BOOL → BV instances
0..n; other numerics → AV instances 0..n; STRING skipped;
`defaultsExternallyWritable` → access. JSON round-trip lossless.

`protocols/bacnet/bacnet_object_image.dart`: resolves (objectType,
instance) → map entry → tag via `tag_resolver`, serving the property set:
Object_Identifier, Object_Name (tag path), Object_Type, Present_Value
(AV: Real float32 narrowing; BV: Enumerated inactive(0)/active(1)),
Status_Flags (all-false bitstring), Event_State (normal 0), Out_Of_Service
(false), Units (AV only: no-units 95), Priority_Array (16 Nulls),
Relinquish_Default (current value). The Device object additionally:
Object_List, Vendor_Name "Soft PLC Simulator", Vendor_Identifier 0,
Model_Name "Soft PLC Simulator", Firmware_Revision/Application_Software
version strings, Protocol_Version 1, Protocol_Revision 14,
Protocol_Services_Supported (bitstring matching exactly v1's services),
Protocol_Object_Types_Supported (device, analog-value, binary-value),
Segmentation_Supported (no-segmentation 3), Max_APDU_Length_Accepted 1476,
System_Status (operational 0). Honest identity, no vendor impersonation
(the ENIP precedent).

Writes run the full gate chain (entry access → `isExternallyWritable`
backstop → forced root) and report per-write results that collapse to one
BACnet Error class/code (refusal wins; mirrors `finsWriteEndCode`).

## Component 5 — config, UI, lifecycle, logs, docs, full E2E

* `BacnetProtocolConfig` (enabled, port=47808, deviceInstance=3056, map) on
  `ProtocolSettings`, additive, lossless.
* Outbound Protocols **BACnet/IP** tab: enable toggle, port, device
  instance, running status + peer count, endpoint line
  `bacnet-udp://<ip>:47808`, map editor (Tag | Object type | Instance |
  Access | delete) + Add entry + Regenerate — the FINS/SLMP card pattern.
* Shell lifecycle identical to FINS (start/stop with project, config edits
  restart the host, disabled by default).
* Logs: `kLogSourceBacnet` per the Global Constraints.
* `docs/protocols/bacnet.md` incl. the **Ignition recipe**: add the device
  by direct IP (`host.docker.internal`; broadcast discovery does not cross
  Docker NAT), local-device settings, write-priority note, AV narrowing
  note.
* Full E2E (`tool/bacnet_e2e.sh`): BAC0 discovers, reads Object_List whole
  AND by array index, reads independently seeded AV (the float-narrowing
  settler: a value with distinct bytes, e.g. 12.5) and BV, RPM batch read
  incl. one embedded per-property error, writes AV + BV and reads back
  independently, ReadOnly write refused with the exact error class/code,
  unknown property error, unrecognized service Reject. Prints
  "BACNET PROBE PASS".

## Data flow

Datagram → `bacnet_host.dart` (bind 0.0.0.0:47808, per-datagram try/catch,
peer tracking) → `dispatchBacnetDatagram` → BVLL/NPDU parse → APDU parse →
service codec → object image (map + tags, force-gated) → reply bytes →
`socket.send` to the datagram's source address:port. The fixture host runs
the same dispatch over a fixture project with explicitly pinned instances.

## Error handling / edge cases

* Malformed/truncated anything → parse returns null → host drops, WARN log
  with hex detail (bounded by `kLogMaxDetailChars`).
* Served-but-wrong → proper Error/Reject/Abort PDU (never silence).
* A crash in dispatch is caught per-datagram; the bind never wedges.
* Who-Is instance-range filtering; I-Am never answers our own I-Am.
* Hostile RPM (huge object lists) bounded by the 1476 response cap.
* Reads of an unmapped instance → unknown-object; a mapped tag whose path
  no longer resolves → Present_Value reads as 0/inactive (gap semantics)
  and writes report unknown-object — consistent with gaps elsewhere.

## Testing

* Literal-byte unit tests per codec layer (tags are the priority — encode
  AND decode against hand-written octets), service codecs, object image
  gates (the standard fixture: Flag/Word/Real/RoTag/Forced/System/SimOut),
  dispatch-level whole-datagram tests, map autoGenerate + JSON round-trip,
  host lifecycle tests (bind/stop/hostile datagram), config round-trip.
* Early-gate E2E then full E2E as above; both hosts share the dispatch.
* Existing suites stay green (lossless round-trip, kAllLogSources guard).

## Risks

* **Tag-encoding subtlety** (context vs application tags per service,
  extended lengths, character strings): mitigated by the early real-client
  gate and literal-byte tests; BAC0/bacpypes rejects sloppy encodings
  loudly.
* **RPM `ALL` semantics** (which properties a client expects in `ALL`):
  settled empirically by the BAC0 step; Ignition confirmation is the final
  user-run check.
* **Broadcast behaviour on Windows** (receiving broadcast Who-Is on a bound
  0.0.0.0 socket): the E2E runs unicast; broadcast is best-effort and the
  documented Ignition path is direct-IP unicast.
* **Ignition driver quirks** unknowable until the live session — same
  posture as today: the Logs + drop instrumentation make the gap visible
  in minutes.

## Decomposition (plan-time)

Five tasks, probe-early, mirroring SLMP:
1. BVLL/NPDU + primitive tag codec (literal-byte tests).
2. Service codecs (Who-Is/I-Am, RP, RPM, WP, Error/Reject/Abort).
3. UDP host skeleton + fixture host + EARLY BAC0 E2E gate (discover + read
   one AV).
4. BacnetMap + object image + write gates (device object incl. Object_List).
5. Config + card + shell lifecycle + logs + full E2E + docs + final review.
