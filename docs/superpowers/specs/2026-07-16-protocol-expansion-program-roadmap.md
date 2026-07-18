# Protocol Expansion Program Roadmap — Six Device-Side Protocols

**Date:** 2026-07-16
**Status:** Approved (program decomposition — NOT a single implementable spec)
**Scope:** Sequencing and shared decisions for adding six more device-side industrial protocols to the in-app pure-Dart suite, targeting the drivers Ignition ships.

> **This is a program map, not a feature spec.** Each of the six protocols is an
> independent subsystem and gets its **own** spec → plan → subagent-driven build
> cycle, exactly as OPC UA / Modbus TCP / MQTT / DNP3 each did. Do not attempt to
> implement from this document.

## Framing

The app is the **device**; Ignition (or any SCADA) is the **client**. Adding a
protocol means implementing the *device side* — the server/outstation/adapter —
faithfully enough that a driver written for real hardware accepts it. That
fidelity requirement, not the codec, is the hard part, and it is why every
protocol ships with a real third-party client E2E proof.

## The shipped anatomy (what each protocol costs)

Each protocol is five pieces, following the existing four:

1. `mobile/lib/protocols/<name>/` — the pure-Dart codec (no `dart:io`).
2. `mobile/lib/services/<name>_host.dart` — the socket host (the only place
   `dart:io` is allowed), started/stopped per project.
3. `mobile/lib/models/<name>_map.dart` — the tag ↔ protocol-address map
   (additive persistence), where the protocol needs one.
4. `ProtocolSettings` entry + an **Outbound Protocols** card (enable, port,
   status/counters), stopped on every project switch.
5. `mobile/tool/<name>_host_probe.dart` (fixture host) +
   a third-party client probe + `tool/<name>_e2e.sh` orchestrating
   start → READY → probe → teardown.

Measured cost of the shipped four (codec + host lines / tasks):

| Shipped | Lines | Tasks |
|---|---|---|
| Modbus TCP | ~920 | 4 |
| MQTT + Sparkplug B | ~2,660 | ~4 |
| DNP3 outstation | ~2,880 | ~4 |
| OPC UA server | ~7,250 | 5 (v1) + more for v2 subscriptions, v3 security |

## Sequence

Ordered cheapest-proof-first, then by Ignition value.

| # | Protocol | Transport | Est. lines | Est. tasks | Rationale |
|---|---|---|---|---|---|
| 1 | **Modbus RTU-over-TCP** | TCP | ~250 | **2** | Reuses `modbus_pdu.dart` wholesale — only framing differs (no MBAP header; CRC-16 trailer; unit id in-frame). Cheapest possible addition and a warm-up that re-validates the whole add-a-protocol path. |
| 2 | **EtherNet/IP + CIP (explicit messaging)** | TCP 44818 | ~2,200 | **5** | Ignition's most-used driver in North America. Session registration, SendRRData, CIP read/write tag services with **symbolic segment** addressing — tags are addressed *by name*, which fits the app's tag database better than any register-file mapping. May need **no map model at all**. |
| 3 | **Siemens S7comm** | TCP 102 (TPKT/COTP, RFC 1006) | ~1,500 | **4** | Ignition's Siemens driver; dominant in Europe. COTP connect → S7 setup-communication → read/write area (DB/M/I/Q), which maps onto the existing Memory Manager DB concept. |
| 4 | **Omron FINS** | UDP/TCP 9600 | ~800 | **3** | Simple header + memory-area read/write. |
| 5 | **Mitsubishi SLMP / MC** | TCP | ~800 | **3** | Simple binary framing + device codes. |
| 6 | **BACnet/IP** | UDP 47808 | ~1,800 | **4–5** | BVLL/NPDU/APDU + an object/property model, Who-Is/I-Am, ReadProperty/WriteProperty. The object model is the work. Different domain (building automation) — suits the existing HVAC demo. |

Total ≈ **21–22 tasks across six independent workstreams**.

## Decision: a Python E2E lane is added

The existing harness uses real third-party **Rust** clients (`opcua`,
`tokio-modbus`, `rumqttc`, `dnp3`). That does not carry across:

| Protocol | Reference client | Lane |
|---|---|---|
| Modbus RTU-over-TCP | `tokio-modbus` (already a dependency) | **Rust** (free) |
| EtherNet/IP | a Rust EIP/CIP crate if viable, else `pycomm3` | Rust **or** Python — decide at spec time |
| S7comm | `python-snap7` (snap7 is the de-facto reference) | **Python** |
| Omron FINS | Python FINS library | **Python** |
| Mitsubishi SLMP | `pymcprotocol` | **Python** |
| BACnet/IP | `bacpypes` / `BAC0` | **Python** |

So a **parallel Python probe lane** is added alongside the Rust one: a pinned
`requirements.txt` + venv under the existing tooling, with probes shaped exactly
like the Rust ones and driven by the same `tool/<name>_e2e.sh` contract (start
the Dart fixture host, wait for `READY`, run the probe, propagate its exit code,
kill the host unconditionally). Rust remains preferred wherever a credible crate
exists.

**Rationale:** verifying a device implementation only against your own codec
proves self-consistency, not conformance — it cannot catch a misread spec, which
is precisely what the third-party probes have caught before. Four of six
protocols would otherwise ship with materially weaker proof than the existing
four.

**Caveat:** the crate/library maturity above is from general knowledge and moves.
Each protocol's spec must confirm its reference client actually exists, is
maintained, and can drive the required operations **before** the plan is written.

## Decision: no shared-abstraction refactor first

The four shipped protocols each have a bespoke codec, host, and map, and their
address models genuinely differ — symbolic tag names (CIP), area+offset (S7),
memory area+address (FINS/SLMP), object+property (BACnet), register files
(Modbus), points (DNP3), nodes (OPC UA). A forced common "address map"
abstraction would fit none of them well.

Extracting a shared host/UI scaffold would mean refactoring four **working,
shipped, machine-verified** protocol hosts for no user-visible benefit. The
per-protocol pattern is proven and cheap to copy. **Copy the pattern; do not
abstract it.** Revisit only if a concrete third repetition of identical logic
appears (not merely similar shape).

## Global constraints (bind every workstream)

- **ADR-010**: hosted in-process, pure Dart, no companion process, no FFI.
- `dart:io` confined to `services/<name>_host.dart`; codecs stay pure and
  unit-testable.
- Deterministic: no wall clock or randomness in codec logic.
- Additive persistence: new `ProtocolSettings`/map fields default such that
  existing projects round-trip unchanged; default-projects scan-equivalence
  stays green.
- Force-aware writes: an external write to a *forced* tag must be refused
  visibly where the protocol has a status code for it (as OPC UA returns
  `Bad_UserAccessDenied`), or skipped consistently with the engines otherwise.
- Dark theme; `withValues(alpha:)`; braces on all control flow; zero
  `flutter analyze` warnings; no overflow at 320/360/1400.
- No "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding; no reverse-engineering
  wording. Protocols are implemented from public specification documents.

## Platform reality (applies to all six)

Inbound socket hosting works on Android / desktop / iOS (iOS while the app is
foreground). **Web compiles but cannot host inbound sockets** — unchanged from
the existing four. UDP-based protocols (FINS, BACnet/IP) additionally need
`RawDatagramSocket`, which is subject to the same platform limits.

## Risks

- **Fidelity, not framing, is the risk.** A driver written for real hardware may
  depend on behaviour the public spec under-specifies (as the OPC UA strict
  client did — it required the server certificate and nonce on
  `CreateSessionResponse`). Budget for a fix wave after each first live probe.
- **EtherNet/IP scope creep**: implicit (Class 1) cyclic I/O over UDP 2222 is
  explicitly **out of scope** — Ignition's driver uses explicit messaging, and
  real-time cyclic I/O is not viable on mobile.
- **BACnet object model** is the largest unknown of the six; it may deserve
  decomposition into v1 (Who-Is/I-Am + ReadProperty) and v2 (WriteProperty, COV)
  at spec time.
- **Serial variants are out of scope** for all six (Modbus RTU serial, DF1, S7
  MPI/PPI, FINS serial): they need a platform plugin, break the pure-Dart story,
  and are effectively impossible on iOS. RTU-**over-TCP** is the sanctioned
  workaround.

## Next step

Workstream 1 (**Modbus RTU-over-TCP**) proceeds immediately to its own
spec → plan → build. Each later workstream starts only when the previous one is
merged, so the pattern's cost and the Python lane's ergonomics are known before
the expensive ones (EtherNet/IP, BACnet) begin.
