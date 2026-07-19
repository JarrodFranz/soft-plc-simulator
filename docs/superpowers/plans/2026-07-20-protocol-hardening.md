# Protocol Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two classes of defect two audits found in shipped protocol hosts: external-write gating that trusts a mutable map entry, and response-size overruns that ignore a negotiated limit.

**Architecture:** A shared pure write-gate predicate that all six protocols consult at write time; per-protocol response-size budgets (DNP3 multi-fragment, OPC UA fail-loud, EtherNet/IP connection-size), each mirroring the S7 budget fix already in the tree.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`, `tool/*_e2e.sh`.

## Global Constraints

- **ADR-010**: pure Dart, in-process, no companion process, no FFI.
- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/protocols/` and `mobile/lib/models/`; `dart:io` confined to `services/*_host.dart`.
- Codecs must **never throw** on malformed/hostile input.
- Deterministic: no wall clock, no randomness in codec logic.
- **Additive/backward-compatible.** No existing serialized form changes; default-projects round-trip and scan-equivalence stay green.
- **No protocol behaviour may change except where a decision below explicitly requires it.** Under-limit responses stay byte-identical; only at/over the limit does behaviour change. The three size fixes and the Modbus force-refuse are deliberate wire changes; everything else is invisible on the wire.
- **Every size/gate fix ships a test at its measured tipping point.** All four bounds had ZERO coverage — a fix without a boundary test repeats the mistake that let these ship.
- **The four third-party E2Es must still pass** (`python-snap7`, `pycomm3`, `tokio-modbus`, a real Ignition OPC UA session — the last is not scriptable here, so its probe is the build+unit fallback). They are the wire-behaviour authority.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No competitor-tooling branding; no reverse-engineering wording.

## Key facts (verified on this branch — do not re-derive)

**Tag model** (`mobile/lib/models/project_model.dart:11-40`): `PlcTag` has `String name` (:12), `String access` (:18, default `'ReadWrite'`), `String ioType` (:22 — `'SimulatedInput'|'SimulatedOutput'|'Internal'`), `bool isForced` (:23). `rootTagOf(PlcProject, String) -> PlcTag?` at `tag_resolver.dart:499` (nullable). `kSystemTagName = 'System'` at `system_tags.dart:4`. `ensureSystemTag` sets `access: 'ReadOnly'` **only at creation** (`system_tags.dart:75`); it does NOT re-assert access on an existing tag — which is exactly why five of six auto-gen functions relying on that default are fragile.

**Six auto-gen read-only rules** (note the inverted polarity — three positive, three negative):
- `cip_map.dart:99-102` — `readOnly = ioType=='SimulatedOutput' || access=='ReadOnly' || name==kSystemTagName` **(the only one checking System by name)**
- `opcua_map.dart:96-97` — `readOnly = ioType=='SimulatedOutput' || access=='ReadOnly'`
- `dnp3_map.dart:106-107` — `ro = ioType=='SimulatedOutput' || access=='ReadOnly'`
- `modbus_map.dart:113-114` — `rw = ioType!='SimulatedOutput' && access!='ReadOnly'`
- `mqtt_map.dart:87,89` — `writable = ioType!='SimulatedOutput' && access!='ReadOnly'`
- `s7_map.dart:190-191` — `rw = ioType!='SimulatedOutput' && access!='ReadOnly'`

**Seven write-time gates** (each trusts the map entry, never re-checks the tag):
- `cip_tags.dart:186` `entry.access == 'ReadOnly'`; forced check `:212` `root.isForced` (root at :211)
- `s7_area_image.dart:325` `entry.access == 'ReadOnly'`; forced `:340` (root at :339)
- `opcua_services.dart:571` `!entry.isWritable`, where `isWritable => access == 'ReadWrite'` (`opcua_address_space.dart:127`)
- `modbus_pdu.dart` write FCs: FC05 :493, FC06 :511, FC0F :552, FC10 :593 — each `entry == null || entry.access == 'ReadOnly'`; forced skip `_isForcedSkip` at :296, called at :496/:518/:559/:609
- `mqtt_publisher.dart:591` and `:659` `entry == null || !entry.writable`
- DNP3 `dnp3_outstation.dart` `_evaluateCrob` :969 / `_evaluateAnalogOut` :1005 — no access field consulted; only `_isForcedSkip` (:1056) at :993/:1010

**No existing test constructs a mismatched entry** (a `ReadWrite`/writable entry against a `SimulatedOutput` or `System` tag). So nothing breaks — but the hardened gate has NO regression coverage until this workstream adds those fixtures. That is the finding, restated.

**Modbus force-refusal**: `_isForcedSkip` (`modbus_pdu.dart:296`) causes a forced write to fall through and return a normal SUCCESS echo. Write handlers return non-nullable `Uint8List` (`_writeSingleCoil` :481, `_writeSingleRegister` :502, `_writeMultipleCoils` :529, `_writeMultipleRegisters` :566). Exception builder: `encodeExceptionResponse(int fc, int code)` at `:135`. Codes (`class ModbusEx` :41-45): `illegalFunction=1`, `illegalDataAddress=2`, `illegalDataValue=3`, `serverFailure=4`. The host **already** detects any exception PDU: `modbus_host.dart:287` `_logWriteRefusal` compares `responsePdu[0] != (fc | 0x80)`. So emitting an exception is sufficient for the host to log it — no new structured channel is strictly required.

**DNP3**: `buildAppResponse({seq, fir, fin, con, iin, objectData})` at `dnp3_app.dart:449`. **11 call sites, all `fir:true, fin:true`** in `dnp3_outstation.dart`: :206 :219 :252 :265 :289 :434 :672 :759 :773 :788 :800. Class 0 chain: `_buildClassZeroPayload` :506 → `_encodeAnalogBucket`/`_encodeBinaryBucket` → `_encodeNumericSubBucket` :570 → `_buildRuns` :618. `_handleRead` :399 emits the solicited response (:434). CONFIRM: `_confirmSolicited` :686, dispatched from `_dispatch` :233. **Transport segmentation is already correct** (`dnp3_host.dart:248` `_buildResponseFrames`, `_maxSegmentPayload=249` :44) — this task is the APPLICATION layer above it. **No application-fragment size constant exists** (grep for 2048/maxFragment: zero hits).

**OPC UA**: `negotiate(...)` local at `opcua_session.dart:395`; `recvSize`/`sendSize` computed :401-402 are **function-local, never stored**. `hello.maxMessageSize`/`maxChunkCount` parsed `opcua_transport.dart:182-183`, **zero readers**. Builders default `chunkType='F'` (:597,:623,:647); `_buildChunk` :554 writes `totalSize` (:577) with no bound check. Browse: `_writeBrowseResult` `opcua_services.dart:161`; `requestedMaxReferencesPerNode` read+discarded :112; `continuationPoint` hardcoded null :169,:175. **No `Bad_ResponseTooLarge`/`Bad_EncodingLimitsExceeded` constant exists** anywhere in the opcua tree.

**EtherNet/IP**: `forwardOpen` (`cip_connection.dart:215`) reads offsets 6/10/12/14/22/28/35 and **skips offset 26 (O→T params) and 32 (T→O params)** — the connection-size words. `CipConnection` (:162-195) stores `connectionIdTO` (:175) but **no size field**. MSP handler `_multipleServicePacket` `cip_tags.dart:239`; `cursor` accounting :297-301; u16 guard :307 `cursor > 0xFFFF`. Handler takes **no size budget**. `enip_host.dart` `_handleSendUnitData` builds the connected reply (~:433-445) with **no size check**. The S7 budget fix to mirror is `s7_services.dart` `buildReadVarResponse` (per-item header charged at admission + `remainingItems * headerLen` reservation).

**Write-path test files**: `cip_tags_test.dart`, `s7_area_image_test.dart`, `modbus_registers_test.dart` (NOT `modbus_pdu_test.dart`, which tests the raw codec), `mqtt_publisher_test.dart`, `opcua_services_test.dart`, `dnp3_outstation_test.dart`. Baseline: `flutter test` **1877 passing / 0 failing**; analyze clean.

---

### Task 1: Shared write-gate helper + six auto-generation call sites

**Files:**
- Create: `mobile/lib/models/tag_write_gate.dart`
- Modify: `cip_map.dart`, `opcua_map.dart`, `modbus_map.dart`, `dnp3_map.dart`, `mqtt_map.dart`, `s7_map.dart` (all under `mobile/lib/models/`)
- Test: `mobile/test/tag_write_gate_test.dart`, plus the six `*_map_test.dart`

**Interfaces:**
- Produces: `bool isExternallyWritable(PlcProject project, String leafPath)` — the write-time HARD backstop, and `bool defaultsExternallyWritable(PlcProject project, String leafPath)` — the auto-generation default.

**Context:**
- `defaultsExternallyWritable` = `root != null && root.name != kSystemTagName && root.ioType != 'SimulatedOutput' && root.access != 'ReadOnly'`. This is the current auto-gen rule, unified, and now checks `System` by name for **all six** (today only CIP does). Each auto-gen call site replaces its inline boolean: the three positive sites (`modbus`/`mqtt`/`s7`, which compute `rw`/`writable`) call it directly; the three negative sites (`cip`/`opcua`/`dnp3`, which compute `readOnly`/`ro`) negate it. **The generated default read-only-ness must not change for any existing tag** — only the (previously CIP-only) System-by-name check is newly applied to the other five, and today every project's System tag already has `access=='ReadOnly'`, so the generated output is identical.
- `isExternallyWritable` = `root != null && root.name != kSystemTagName && root.access != 'ReadOnly'`. **It deliberately does NOT check `ioType`** — that is what keeps a `SimulatedOutput` overridable per the approved decision (a user may set its map entry `ReadWrite` to drive a simulated field device). The hard, non-overridable rules are: the reserved `System` tag, and a tag the user declared `access=='ReadOnly'` in the tag itself. This is Task 2's backstop; define it here, consume it there.
- Pure: imports `project_model.dart`, `tag_resolver.dart`, `system_tags.dart` only. No Flutter, no `dart:io`.

- [ ] **Step 1: Write the failing tests**

`tag_write_gate_test.dart`:
- `defaultsExternallyWritable`: false for a `System` root, a `SimulatedOutput` root, and an `access=='ReadOnly'` root; true for a plain `Internal` `ReadWrite` root; false for an unknown path (null root).
- `isExternallyWritable`: **false for `System` even when the tag's access is `ReadWrite`** (the hard rule); false for an `access=='ReadOnly'` root; **true for a `SimulatedOutput` root whose access is `ReadWrite`** (the deliberate-override carve-out — this is the assertion that pins decision 1); false for a null root.
- A member path (`Tank.Level`) resolves to the root `Tank` and is judged by the root, for both helpers.

In each `*_map_test.dart`: add a case that a `System`-named tag is generated read-only (the five non-CIP maps lacked this). Confirm existing assertions still pass (the generated output is unchanged for every existing fixture).

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/tag_write_gate_test.dart`

- [ ] **Step 3: Implement** the helper and rewire the six call sites.

- [ ] **Step 4: Run — expect PASS**, then the six map tests, then the full suite (`cd mobile && flutter test`) to confirm auto-gen output is unchanged. Report the count.

- [ ] **Step 5: analyze + commit**

```bash
cd mobile && flutter analyze
git add mobile/lib/models/ mobile/test/tag_write_gate_test.dart mobile/test/*_map_test.dart
git commit -m "feat(hardening): shared write-gate helper; unify six auto-gen read-only rules"
```

---

### Task 2: Apply the write-time backstop across the seven gates

**Files:**
- Modify: `cip_tags.dart`, `s7_area_image.dart`, `opcua_services.dart`, `modbus_pdu.dart`, `mqtt_publisher.dart`, `dnp3_outstation.dart` (all under `mobile/lib/protocols/`)
- Test: the six write-path test files listed in Key Facts

**Interfaces:**
- Consumes: `isExternallyWritable(project, leafPath)` from Task 1.

**Context:**
- At each of the seven gates, refuse the write when `!isExternallyWritable(project, entry.tag)`, **in addition to** the existing per-entry `access`/`writable` and forced checks — never replacing them. Each protocol returns its own refusal status: CIP `0x0F`, S7 `0x03` access-denied, OPC UA `Bad_UserAccessDenied` (the status the forced path already uses at `opcua_services.dart`), Modbus its refusal exception (see Task 3 — for now, the same code the ReadOnly gate already returns), MQTT its silent-skip-with-log, DNP3 `notAuthorized` (the status `_isForcedSkip` already produces).
- **The tag must be left unchanged** on refusal, and the check must run BEFORE any mutation — same discipline the forced checks already follow. For a member path, the check is against the ROOT (`isExternallyWritable` already resolves via `rootTagOf`).
- This is a security backstop, so the tests are the point: they must construct the mismatch that no existing fixture creates.

- [ ] **Step 1: Write the failing tests**

For **each** of the six protocols, add:
- **The hard-System test**: a map entry deliberately set writable pointing at `System` (or a `System.*` member) is **refused** with the protocol's status, tag unchanged. (Today this write would succeed.)
- **The non-over-broad counter-test**: a map entry deliberately set writable pointing at a `SimulatedOutput` tag **succeeds** (decision 1 — the deliberate override survives), and a normal `Internal` `ReadWrite` tag still succeeds.
- Where the protocol has member paths (CIP, S7), a `System.*` member write is refused while a non-`System` composite member still succeeds.

- [ ] **Step 2: Run — expect FAIL** (the hard-System tests fail against current code; the counter-tests pass). `cd mobile && flutter test <the six files>`

- [ ] **Step 3: Implement** the seven gate additions.

- [ ] **Step 4: Run — expect PASS**, then the full suite. Then run all four E2Es (`bash tool/s7_e2e.sh && bash tool/enip_e2e.sh && bash tool/modbus_e2e.sh && bash tool/opcua_e2e.sh`) — the backstop must not break a legitimate write a real client makes. Report counts.

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/protocols/ mobile/test/
git commit -m "feat(hardening): write-time backstop refusing external writes to reserved tags"
```

---

### Task 3: Modbus visible force-refusal

**Files:**
- Modify: `mobile/lib/protocols/modbus/modbus_pdu.dart`, and `mobile/lib/services/modbus_host.dart` only if the log message needs the reason
- Test: `mobile/test/modbus_registers_test.dart`
- Docs: `docs/protocols/modbus.md`

**Context:**
- Today a write to a forced tag falls through `_isForcedSkip` (`:296`) and returns a SUCCESS echo. Change the four write handlers so a forced-tag write returns `encodeExceptionResponse(fc, <code>)` instead.
- **Choose the exception code deliberately and document it.** A forced tag is a transient refusal, not an addressing error, so `serverFailure` (0x04, "SLAVE DEVICE FAILURE") is the least-wrong classic code — but check what the existing **ReadOnly** gate returns and prefer consistency with it unless the E2E client rejects it. **The real `tokio-modbus` client is the authority**: if it maps the chosen code to a confusing error, pick the other and report it.
- The host already logs any exception PDU (`modbus_host.dart:287` `_logWriteRefusal` checks `responsePdu[0] != (fc|0x80)`), so emitting the exception is enough for the refusal to be logged. If the log message should distinguish "forced" from "read-only", thread a minimal structured hint — but do **not** pass an `AppLogger` into `modbus_pdu.dart` (it must stay pure); the host inspects the returned bytes/hint.
- This is a **deliberate wire-behaviour change**: a master that previously got SUCCESS for a swallowed write now gets an exception. Document it in `docs/protocols/modbus.md` and the commit message.
- **Supersede the spawned task** `task_89b34247` once this lands.

- [ ] **Step 1: Write the failing tests** in `modbus_registers_test.dart`: a FC06 (and FC05, FC10, FC0F) write to a forced tag returns the exception and leaves the tag unchanged; a write to a non-forced tag still succeeds (not over-broad).

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement. Step 4: Run — expect PASS**, then `bash tool/modbus_e2e.sh` (and `tool/modbus_rtu_e2e.sh` if present) — must still pass; a forced-tag step now expecting an exception is the proof.

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/protocols/modbus/ mobile/lib/services/modbus_host.dart mobile/test/modbus_registers_test.dart docs/protocols/modbus.md
git commit -m "fix(modbus): forced-tag writes refuse visibly instead of echoing success"
```

---

### Task 4: DNP3 application-fragment bound + multi-fragment (the largest task)

**Files:**
- Modify: `mobile/lib/protocols/dnp3/dnp3_outstation.dart`, possibly `dnp3_app.dart`
- Test: `mobile/test/dnp3_outstation_test.dart`

**Context:**
- Add `const int kDnpMaxAppFragment = 2048` — the `dnp3` reference crate's minimum *and* default `rx_buffer_size`, which a master cannot raise.
- **The bound**: when building a Class 0 (or event) response, charge each object/run header at admission and reserve room for the remaining mandatory headers — the S7-fix shape (see `s7_services.dart buildReadVarResponse`). The Class 0 chain is `_buildClassZeroPayload` :506 → `_encodeNumericSubBucket` :570 → `_buildRuns` :618; each run emits an `encodeObjectHeader`.
- **Multi-fragment**: today all 11 `buildAppResponse` sites pass `fir:true, fin:true`. When a Class 0 response exceeds `kDnpMaxAppFragment`, emit it across fragments: the first carries `fir:true, fin:false`, the last `fin:true`, and a **resume cursor** holds the position between fragments. The master advances the sequence by sending the appropriate CONFIRM; `_confirmSolicited` (:686) is where the next fragment is released. This is real application-layer state — keep it deterministic (no clock).
- The transport layer below (`dnp3_host.dart:248`) already segments a fragment into link frames correctly; do **not** touch it. This task bounds the fragment the transport receives.
- **YAGNI guard**: implement multi-fragment for the **read/Class-0 path** where a large database genuinely overruns. Do not retrofit fragmentation onto paths that cannot exceed the bound (a CROB response, a short WRITE ack). Keep those `fir:true, fin:true`.
- If the resume-cursor/CONFIRM state proves larger than one task, STOP and report — the spec flagged this as the one component that may split.

- [ ] **Step 1: Write the failing tests** in `dnp3_outstation_test.dart`:
- A Class 0 read of **≥408 analog points** produces a response whose every fragment is ≤ `kDnpMaxAppFragment`, and reassembling the fragments yields the full point set in order.
- The FIR/FIN bits are correct across fragments (first FIR, last FIN, middle neither).
- A CONFIRM advances to the next fragment; the cursor resumes at the right point.
- A small response (under the bound) is still a single `fir:true, fin:true` fragment — unchanged.

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement. Step 4: Run — expect PASS**, then the full suite, then `bash tool/opcua_e2e.sh` is irrelevant here but re-run the DNP3 coverage; there is no third-party DNP3 E2E in this repo, so the boundary unit test is the proof — say so in the report.

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/protocols/dnp3/ mobile/test/dnp3_outstation_test.dart
git commit -m "fix(dnp3): bound the application fragment and multi-fragment large reads"
```

---

### Task 5: OPC UA — store the negotiated size, fail loudly

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_session.dart`, `opcua_transport.dart` (a status constant), `opcua_services.dart`
- Test: `mobile/test/opcua_services_test.dart` (or `opcua_session_test.dart`)

**Context:**
- Store the negotiated **send** buffer size (`sendSize`, computed function-locally at `opcua_session.dart:402`) on the session so the response path can see it. Today it is discarded.
- Add a `Bad_ResponseTooLarge` status constant (0x80B80000) — none exists in the tree. Before emitting a response chunk, if the built message would exceed the stored `sendSize`, return a `ServiceFault` carrying `Bad_ResponseTooLarge` instead of the oversized frame. `_buildChunk` (`opcua_transport.dart:554`) is where `totalSize` is known.
- **The under-limit path stays byte-identical** — this only changes what happens when a response would exceed the negotiated buffer. A normal Browse/Read is untouched.
- The main amplifier is Browse (`_writeBrowseResult` :161, unbounded), so that is the primary test, but the check belongs at the chunk/message boundary so it also catches a large Read or Publish.
- Do **not** implement `F`/`C` chunking or Browse continuation points — deferred by decision. Fail-loud is the v1 backstop.

- [ ] **Step 1: Write the failing tests**:
- A Browse against **~1,400 root tags** with a negotiated send buffer of 65536 returns `Bad_ResponseTooLarge`, not an oversized frame. (Seed the tags via the bulk generator the audit named, or construct them directly.)
- A Browse under the limit returns a normal result — unchanged.
- Assert the emitted message length never exceeds the negotiated `sendSize`.

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement. Step 4: Run — expect PASS**, then the full suite, then `bash tool/opcua_e2e.sh` — the existing probe (small dataset) must still pass unchanged.

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/protocols/opcua/ mobile/test/
git commit -m "fix(opcua): honor the negotiated send buffer; Bad_ResponseTooLarge over the limit"
```

---

### Task 6: EtherNet/IP connection-size budget + u16 tighten, then full gate + docs + review

**Files:**
- Modify: `mobile/lib/protocols/enip/cip_connection.dart`, `cip_tags.dart`, `mobile/lib/services/enip_host.dart`
- Test: `mobile/test/cip_connection_test.dart`, `mobile/test/cip_tags_test.dart`
- Docs: `docs/protocols/ethernet-ip.md`, `docs/protocols/s7comm.md` (cross-reference the shared budget shape), `ROADMAP.md`

**Context:**
- Parse the Forward Open **connection parameters** at offsets 26 (O→T) and 32 (T→O) that `forwardOpen` (`cip_connection.dart:215`) currently skips; extract the connection size and store it on `CipConnection` (add a field beside `connectionIdTO` at :175).
- Thread the T→O connection size into `_multipleServicePacket` (`cip_tags.dart:239`) as a response budget: charge each embedded response's header at admission, reserve `remainingItems * kCipDataItemHeaderLen` for the mandatory error items — the S7-fix shape (`s7_services.dart buildReadVarResponse`). When the budget is exhausted, the remaining items get an error status rather than overrunning.
- `_handleSendUnitData` (`enip_host.dart:~433`) passes the connection (and thus its size) into the MSP dispatch.
- Tighten the u16 guard at `cip_tags.dart:307` from `cursor > 0xFFFF` to `cursor > 0xFFFF - 6` (the emitted CIP response is `cursor + 6` bytes; the current guard admits a self-inconsistent inner frame the `buildEnipFrame` truncation does not cover).
- **Unconnected (UCMM) messaging has no negotiated size** — leave it unbounded exactly as today; the budget applies only to connected sends over a Forward-Opened connection.

- [ ] **Step 1: Write the failing tests**:
- `forwardOpen` parses and stores the connection size (assert the stored value against a hand-built Forward Open with a known size word).
- An MSP over a **500-byte** connection filled with Read Tag requests returns a reply **≤ 500 bytes** (the audit measured ~792 today), with the over-budget items carrying an error status.
- The u16 tighten: a cursor at `0xFFFF - 5` is refused where before it slipped through.
- An MSP under the budget is unchanged.

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement. Step 4: Run — expect PASS**, then `bash tool/enip_e2e.sh` — the real `pycomm3` client is the authority on whether the connection-size parse and the budget are wire-correct.

- [ ] **Step 5: FULL GATE**

```bash
cd mobile && flutter analyze                 # zero warnings
cd mobile && flutter test                    # ALL pass — record the count (baseline 1877)
cd mobile && flutter build web --release
bash tool/s7_e2e.sh && bash tool/enip_e2e.sh && bash tool/modbus_e2e.sh && bash tool/opcua_e2e.sh
```

- [ ] **Step 6: Docs**
- `docs/protocols/ethernet-ip.md`: the connection-size budget and the MSP over-budget behaviour.
- `docs/protocols/modbus.md` already updated in Task 3; confirm.
- A short note in `ROADMAP.md` recording the hardening pass and the two audits behind it.
- Mention the deferred items explicitly: OPC UA send-path chunking, OPC UA inbound-memory bound, DNP3-only multi-fragment (other paths unchanged).

- [ ] **Step 7: Commit**

```bash
git add mobile/lib mobile/test docs ROADMAP.md
git commit -m "fix(enip): honor the Forward Open connection size; budget the Multiple Service Packet"
```

---

## Self-Review

**Spec coverage:** Component 1 (shared gate) → Tasks 1-2 ✓; Component 2 (Modbus refuse) → Task 3 ✓; Component 3 (DNP3) → Task 4 ✓; Component 4 (OPC UA) → Task 5 ✓; Component 5 (EtherNet/IP) → Task 6 ✓. All five approved decisions are bound to tasks and to specific tests: SimulatedOutput stays overridable (Task 1's `isExternallyWritable` carve-out test + Task 2's counter-test), Modbus visible refuse (Task 3), DNP3 real multi-fragment (Task 4), OPC UA fail-loud (Task 5), one workstream (this plan). The non-goals — OPC UA chunking, OPC UA inbound memory — appear nowhere as work and are named as deferred in Task 6's docs.

**Placeholder scan:** No TBDs. The two values left to the implementer — the Modbus exception code and whether DNP3 multi-fragment needs to split — are each assigned to a task with an instruction to decide against the real client / to escalate, not left implicit.

**Type consistency:** `isExternallyWritable` / `defaultsExternallyWritable` (Task 1) are consumed by the six auto-gen sites (Task 1) and the seven write gates (Task 2). `kDnpMaxAppFragment` and the resume cursor (Task 4), the `sendSize` session field + `Bad_ResponseTooLarge` (Task 5), and the `CipConnection` size field + MSP budget (Task 6) are each self-contained within their task. The S7 budget shape (`buildReadVarResponse`) is cited as the reference for Tasks 4 and 6 but not modified.

**Note for the executor:** the binding properties are (a) **under-limit and non-System behaviour is byte-identical** — every fix changes only what happens at/over a limit or on a reserved-tag write; (b) **`System` is the one hard, non-overridable write block**, `SimulatedOutput` stays overridable, and both facts are pinned by tests; (c) **every bound has a boundary test at its measured tipping point** (408 points, ~1,400 nodes, 500-byte connection) — the audit's core finding was zero coverage; (d) **the four third-party E2Es are the wire authority** — a boundary a real client rejects is a finding; and (e) codecs never throw, persistence is additive, `dart:io` stays in the hosts. Tasks 1-2 are the security fix and touch all six protocols; Tasks 3-6 are independent per protocol and may reorder. Task 4 (DNP3 multi-fragment) is the one that may split — escalate rather than cram.
