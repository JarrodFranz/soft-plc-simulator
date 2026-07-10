# SCADA Interop Validation Guide

A practical checklist for validating the app's four in-app protocol hosts against real SCADA clients. All four run **in-process** on the device/desktop running the app — no companion service. Hosting is **native-only** (Android/iOS/desktop); a web build compiles but cannot bind sockets.

> **Step 0 — rebuild first.** Build/reinstall the app from the current `main`. Fixes and new protocols only exist in a fresh build. Find the device's LAN IP (`<app-ip>` below); the client and the app must be on the same network.

Each protocol is enabled per-project from **Outbound Protocols**. Toggling a protocol's enable switch **off** now also stops its host.

---

## 1. OPC UA — `opc.tcp://<app-ip>:4840`

**Config:** Outbound Protocols → OPC UA → enable, Start hosting. Namespace is `urn:softplc:<project-id>` (namespace index 1). Default port 4840.

**Steps & expected results:**
1. Point an OPC UA client (Ignition, UAExpert) at `opc.tcp://<app-ip>:4840`. **Discovery should now work** — no hardcoded endpoint needed (the server advertises the host you dialed).
2. **Browse from the top.** Root → Objects → your tags should appear. The client resolves namespace 1 = `urn:softplc:<project-id>` via the now-served `NamespaceArray` node.
3. **Read** a tag — value matches the app. **Force** a tag in the app → the OPC UA read reflects the forced value.
4. **Write** a writable tag from the client → the app tag changes (unless forced, which is rejected with `Bad_UserAccessDenied`).

**Verified in-repo by:** the Rust `opcua` client E2E (`tool/opcua_e2e.sh`).

---

## 2. Modbus TCP — `modbus-tcp://<app-ip>:502`

**Config:** Outbound Protocols → Modbus TCP → enable, Start hosting. Default port 502. Point map is auto-generated; editable rows let you hand-map tags (incl. struct members like `Motor.Speed`).

**Point mapping** (auto-generated, per-type 0-based addresses; note Ignition Modbus is 1-based, so `C1` = coil address 0):
- RW `BOOL` → **Coils**; RO `BOOL` (SimulatedOutput) → **Discrete Inputs**
- RW numeric → **Holding Registers**; RO numeric → **Input Registers** (INT16=1 reg, INT32=2, FLOAT64=4; big-endian, hi-word first)

**Steps & expected results:**
1. In the motor project, coil 0 = `Start_PB`. **Force `Start_PB` true** → your master reads coil 0 = **true** (this was the bug; forcing now propagates to Modbus and to the ladder logic).
2. **Write** a coil/register from the master → the app tag changes (forced tags silently reject + echo unchanged).
3. Use the **map editor** to add a register for a tag (e.g. map `Motor.Speed` to a holding register) → the master reads it with the correct width.

**Verified in-repo by:** the Rust `tokio-modbus` client E2E (`tool/modbus_e2e.sh`).

---

## 3. MQTT + Sparkplug B — broker you provide

The app is a **publisher (client)** — it connects **out** to a broker. You need a broker (Mosquitto/HiveMQ/EMQX, or Ignition's MQTT Distributor); the SCADA subscribes there.

**Config:** Outbound Protocols → MQTT → enable, set broker **host/port** (1883, or 8883 + TLS), **format** (`json` or `sparkplug`), enter the broker **password** if any (in-memory only, never saved), Connect. Remote writes are **off** by default — enable "Allow remote writes" to test writes.

**Steps & expected results:**
- **JSON:** subscribe any MQTT client to `softplc/#`. Expect retained `softplc/<controller>/status` = `ONLINE`, and `softplc/<controller>/tags/<name>` payloads `{"value","quality","timestamp","forced"}` (changed tags publish on change; all republish each heartbeat). A forced tag publishes its forced value.
- **Sparkplug B:** Ignition's **MQTT Engine** (Cirrus Link) auto-discovers the edge node under `spBv1.0/SoftPLC/…`, with your tags as metrics carrying live values (NBIRTH then NDATA). `bdSeq` increments each reconnect.
- **Remote write:** with writes enabled, publish `softplc/<controller>/tags/<name>/set` (JSON) or an NCMD (Sparkplug) → the app tag changes (forced tags win).

**Verified in-repo by:** a real `rumqttd` broker + `rumqttc` subscriber + `prost`-decoded Sparkplug E2E (`tool/mqtt_e2e.sh`).

---

## 4. DNP3 Outstation — `dnp3://<app-ip>:20000`

**Config:** Outbound Protocols → DNP3 → enable, Start hosting. Default port 20000, **outstation link address 1024**, **master link address 1** (both editable — set your master to match). Point map auto-generated + editable.

**Point mapping:** RO `BOOL` → Binary Input; RW `BOOL` → Binary Output (CROB control); RO numeric → Analog Input; RW numeric → Analog Output. Integer tags use the 32-bit variation, FLOAT64 the float variation.

**Steps & expected results:**
1. Configure your DNP3 master: outstation address **1024**, master address **1**, TCP `<app-ip>:20000`.
2. Run a **Class 0 / integrity poll** → all Binary/Analog Input & Output points read live tag values (forced tags read their forced value).
3. **Control** a Binary Output (CROB LATCH_ON/OFF, DIRECT_OPERATE or SELECT-then-OPERATE) → the app BOOL flips. Control an Analog Output (analog output block) → the numeric changes.
4. **Force** an output tag, then operate it → the operate is **rejected** (`NOT_AUTHORIZED` / `BadStatus`), tag unchanged.

**v1 scope note:** static polling + control only. Events (Class 1/2/3), unsolicited responses, and counters are deferred. Link service is unconfirmed.

**Verified in-repo by:** the reference Step Function I/O `dnp3` master E2E (`tool/dnp3_e2e.sh`) — accepted the outstation with no wire-format issues.

---

## If something fails

For any step that doesn't behave as above, capture:
- **Which protocol + which step**, and what you observed vs expected.
- **The client's log line** (Ignition connection/console log, broker log, DNP3 master error). DNP3/OPC UA masters usually name the exact object/status that failed.
- The app's **Outbound Protocols status/endpoint/last-error** for that card.

That's enough to diagnose and, if it's a real bug, fix it through the same brainstorm → spec → plan → subagent pipeline the protocol interop fixes used.
