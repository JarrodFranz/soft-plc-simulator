# Protocol Interop Fixes — OPC UA Discovery + Forcing + Modbus Mapping Design

**Date:** 2026-07-08
**Status:** Approved by user (chat, 2026-07-08): forced values are **authoritative everywhere** (logic + HMI + comms — real-PLC forcing semantics); one **consolidated** bugfix workstream covering all three areas (A OPC UA discovery, B forcing, C Modbus map editor), merged **before** the MQTT workstream.
**Builds on / fixes:** WS19–20 (in-app OPC UA server), WS24 (in-app Modbus TCP server), and the tag/forcing model (WS2). All three defects surfaced during live SCADA interop testing (Ignition OPC UA client + a Modbus master against the motor project).

## Motivation (three field-found defects)

1. **OPC UA — client sees no tags.** A standards-strict client (Ignition) connects but its browse tree is empty. The server never serves the standard `Server` object or its `NamespaceArray` (`i=2255`), and it only answers Browse for the Objects folder (`i=85`) — Browse of the Root folder (`i=84`) returns `Bad_NodeIdUnknown` ([opcua_services.dart:153-161](../../../mobile/lib/protocols/opcua/opcua_services.dart)). A top-down browser can't reach Objects, and a client that reads `NamespaceArray` to resolve `ns=1` gets nothing. The advertised endpoint URL is a guessed LAN IP ([opcua_host.dart:215-217](../../../mobile/lib/services/opcua_host.dart)), so discovery hands the client an address it can't reach (user had to hardcode).
2. **Forcing is display-only — the core bug.** Forcing a tag sets `isForced`/`forcedValue`, but `forcedValue` is consumed **only** by UI widgets; `readPath` returns `root.value` and never consults the force ([tag_resolver.dart:211-252](../../../mobile/lib/models/tag_resolver.dart)); the scan engines merely *skip writing* a forced tag ("forcing wins") but never push `forcedValue` into `value`. So a forced value reaches neither the logic engines nor the Modbus/OPC UA servers — only the display. Forcing `Start_PB` true (coil 0) leaves coil 0 reading false, and ladder logic never sees the force either.
3. **Modbus — no map editor, no struct-member mapping.** The Modbus card only offers **Regenerate** (`_autoGenerateModbusMap`); unlike the OPC UA card it has no editable entry rows, so a tag can't be hand-mapped. And `autoGenerate` walks only top-level scalar tags, while the handler's type/force lookups match by top-level **name** only ([modbus_pdu.dart:213-239](../../../mobile/lib/protocols/modbus/modbus_pdu.dart)) — so a dotted path like `motor.speed` can't be mapped with a correct data type or force behavior.

## Design decision: forcing is authoritative everywhere

A forced tag's **effective value** (`forcedValue`) becomes the value every non-UI reader sees, matching how a real PLC force overrides an I/O point for the whole controller. This is fixed at a single seam — `readPath` — so logic engines, the OPC UA server, and the Modbus server all observe forces with no per-consumer change.

### The seam (`readPath`)

In `readPath`, the root value that seeds the path walk becomes the forced value when the root scalar tag is forced:

```dart
// tag_resolver.dart, replacing `dynamic cur = root.value;`
dynamic cur = (root.isForced && root.value is! Map && root.value is! List)
    ? root.forcedValue
    : root.value;
```

- Applies to **scalar** forced tags only (composites — structs/arrays — are never forceable in the UI, and their `value` is a Map/List, so they keep `root.value`). This also makes a **bit read** of a forced integer (`SomeInt.3`) reflect the forced integer, since the walk now starts from `forcedValue`.
- Reads only. `writePath` and the engines' existing force-skip write guards are unchanged (a forced tag's stored `value` still isn't clobbered by logic; with the read overlay it simply also isn't *observed* until unforced).
- The protocol **write** paths (OPC UA `Bad_UserAccessDenied`, Modbus silent-skip-and-echo) already branch on `isForced` and are unaffected.
- `forcedValue` must carry a type-correct scalar (the tag inspector already seeds it from the current value on force-enable); the protocol encoders coerce via `is num`/`== true` as today.

**Consequence to verify:** logic engines now read forced inputs as forced. A forced input drives ladder/FBD/ST/SFC exactly as a real force would. Existing tests that force a tag and then assert its *unforced* stored value must be reviewed (none are expected to, but the review must confirm).

## A. OPC UA discovery correctness

Make the server discoverable and browsable by a strict top-down client, without changing the flat tag layout.

1. **Serve `NamespaceArray` (`i=2255`).** A Read of `ns=0;i=2255` returns a `String[]` Variant `["http://opcfoundation.org/UA/", <opcua.namespaceUri>]` — index 0 is the OPC UA namespace, index 1 is the project namespace the tags use (`ns=1` ⇒ `urn:softplc:<id>`). This is the node Ignition reads to resolve `ns=1`.
2. **Serve a minimal `Server` object (`i=2253`).** Enough for a Read of its `NodeClass`/`BrowseName`/`DisplayName` and for it to appear as a child of Objects; its `NamespaceArray` property (`i=2255`) is the one above.
3. **Make Root browsable.** Browse of the Root folder (`i=84`) returns the Objects folder (`i=85`) via an `Organizes` reference; Browse of Objects (`i=85`) returns the Server object **and** all tag variables (today it returns only the tags). So a client walking Root → Objects → tags reaches everything.
4. **Advertise a reachable endpoint URL.** `GetEndpoints`/`CreateSession` echo the host the client actually connected to (from the client-supplied `endpointUrl` in the Hello/GetEndpoints exchange) instead of the guessed `_bestDisplayHost()` LAN IP — so discovery no longer needs a hardcoded address. The guessed host stays only as the UI-displayed convenience endpoint.

All new standard NodeIds/attribute encodings are cross-checked against the vendored Rust `opcua` 0.12.0 source, exactly as the existing address space is.

## B. Forcing → effective value

The `readPath` seam above (design decision section). No new model fields; `isForced`/`forcedValue` already exist and persist. Purely a read-resolution change plus tests proving logic + both protocol servers now observe forces.

## C. Modbus map editor + dotted-path resolution

1. **Editable map rows in the Modbus card.** Mirror the OPC UA card's `_mapEditorCard`/`_nodeRow`: a row per `ModbusMapEntry` with a **tag picker**, a **table** dropdown (`coil`/`discrete`/`holding`/`input`), an **address** field, and an **access** dropdown (`ReadOnly`/`ReadWrite`), plus **Add entry**, delete-row, and the existing **Regenerate**. Persists via the additive `modbus.map` (unchanged schema).
2. **Dotted-path tag options.** The tag picker offers composite tags' scalar members (via `childrenOf`) so a struct member such as `motor.speed` is selectable — not just top-level tags.
3. **Handler path-aware type/force resolution.** Replace the top-level-name-only lookups in `modbus_pdu.dart` (`_tagDataType`, `_findRootTag`/`_isForcedSkip`) with resolver-based path resolution: the data type of a mapped entry is resolved from its (possibly dotted) `tag` path via the resolver, and the force check finds the **root** tag of the path (`path.split('.')/[` → root name) and honors its `isForced`. So a `motor.speed` INT/FLOAT member maps with the right register width, encodes correctly, and is skipped when its root tag is forced.

`autoGenerate` is unchanged (still top-level scalars) — hand-adding member paths is the documented way to expose struct members, consistent with the Modbus spec's v1 note.

## Architecture (files touched)

| Area | File | Change |
|---|---|---|
| B (seam) | `mobile/lib/models/tag_resolver.dart` | `readPath` root-value force overlay (scalar-only). |
| A | `mobile/lib/protocols/opcua/opcua_services.dart` | Read handler serves `NamespaceArray` (i=2255) + minimal `Server` (i=2253); Browse handler returns Objects under Root and Server under Objects. |
| A | `mobile/lib/protocols/opcua/opcua_address_space.dart` | Standard-node constants + browse/read plumbing for Root/Server/NamespaceArray (kept pure). |
| A | `mobile/lib/protocols/opcua/opcua_session.dart` + `mobile/lib/services/opcua_host.dart` | Echo client-supplied endpoint host in `GetEndpoints`/`CreateSession`. |
| C | `mobile/lib/protocols/modbus/modbus_pdu.dart` | Resolver-based dotted-path data-type + root-tag force resolution. |
| C | `mobile/lib/screens/gateway_screen.dart` | Modbus card entry-row editor (Add/edit/delete) + dotted-path tag options. |
| E2E | `gateway/examples/opcua_probe.rs`, `gateway/examples/modbus_probe.rs` (+ harness scripts) | Extend to prove the fixes (below). |

## Testing (same bar as the protocol workstreams)

1. **Forcing unit tests** (`tag_resolver_test.dart` + engine/protocol read tests): `readPath` returns `forcedValue` for a forced scalar tag (bool + numeric) and the unforced `value` otherwise; a forced integer's bit read reflects the force; a forced composite is untouched. A ladder rung reads a forced input as forced. The Modbus coil/register read and the OPC UA Read attribute both return the forced value. Force cleared ⇒ live value returns.
2. **OPC UA discovery tests** (`opcua_services_test.dart`/address-space tests): Read of `i=2255` returns `["http://opcfoundation.org/UA/", "urn:softplc:<id>"]`; Browse of `i=84` returns `i=85`; Browse of `i=85` returns the Server object + every tag; a Read of the `Server` object's standard attributes succeeds. Endpoint echo: `GetEndpoints` returns the client-dialed host.
3. **Modbus mapping tests** (`modbus_pdu_test.dart` + a widget test): a hand-added `holding` entry for a dotted `struct.member` INT32 encodes with the correct 2-register width and value; a forced root tag skips the member write and (with the seam) reads back the forced value; the map-editor widget adds/edits/deletes a row and round-trips through `modbus.map` JSON.
4. **Machine-proof E2E** (extend the existing Rust probes, still merge-gated):
   - `opcua_probe.rs`: after connect, **read `NamespaceArray`** and assert index 1 = `urn:softplc:<id>`, then **browse from Root** (`i=84` → `i=85` → tags) and assert the motor tags appear — proving a top-down client sees them.
   - `modbus_probe.rs`: **force** a coil-mapped tag true in the fixture project, then read the coil and assert **true** (falsifiable proof the force reaches Modbus); plus a dotted-member register read.
   - Both end with their existing `... PROBE PASS` gates.
5. **Regression:** full `flutter test`, `flutter analyze` ZERO, `flutter build web --release` compiles, WS6 lossless round-trip guard green (no schema change — `isForced`/`forcedValue`/`modbus.map` already persisted), `cargo build --examples` green.

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); OPC UA / Modbus / IEC terms are fine.
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400 (the new Modbus editor rows must lay out like the OPC UA rows); dark theme; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/**` stays pure Dart (no Flutter/`dart:io`); the forcing seam stays in the pure resolver.
- Forcing is authoritative for **reads** everywhere; write force-skip semantics (engines + both protocol servers) unchanged. No persistence schema change — additive guarantees and the WS6 round-trip guard stay green.
- OPC UA additions are Read/Browse-only, standards-accurate against the vendored Rust `opcua` 0.12.0; the server still never crashes on malformed input.

## Phasing (one spec → plan tasks)

1. **Forcing → effective value** — the `readPath` seam + forcing unit tests across resolver, one logic engine, and both protocol read paths. (Foundational; unblocks the Modbus/OPC UA read fixes.)
2. **OPC UA discovery** — `NamespaceArray` + minimal `Server` node + Root/Objects browse + endpoint-host echo; discovery/browse tests.
3. **Modbus map editor + dotted-path resolution** — card entry-row editor + `childrenOf` tag options + resolver-based type/force in the handler; mapping + widget tests.
4. **E2E + validation + docs + final review** — extend `opcua_probe.rs` (NamespaceArray + browse-from-Root) and `modbus_probe.rs` (force→coil + dotted member), run all gates, update `docs/protocols/opcua.md` + `modbus.md`, note the fixes in `ROADMAP.md`, whole-branch review, merge.
