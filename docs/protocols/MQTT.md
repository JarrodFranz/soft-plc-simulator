# Protocol Specification: MQTT & Sparkplug B

## 📌 Overview

The MQTT protocol adapter connects the Soft PLC Simulator to cloud platforms, MQTT brokers (HiveMQ, Mosquitto, EMQX), and IIoT SCADA hosts (Ignition Cirrus Link).

---

## 📡 Topic Hierarchy

Default base topic pattern: `softplc/{controller_name}/`

### 1. Tag State Topics (Telemetry)
- **Topic**: `softplc/{controller_name}/tags/{tag_path}`
- **Payload Format (JSON)**:
  ```json
  {
    "value": true,
    "quality": "Good",
    "timestamp": "2026-07-03T11:30:00Z",
    "forced": false
  }
  ```

### 2. Tag Command Topics (Writes)
- **Topic**: `softplc/{controller_name}/tags/{tag_path}/set`
- **Payload Format**: Raw value string or JSON object `{"value": false}`.

### 3. Birth & Death Messages (LWT)
- **Birth Topic**: `softplc/{controller_name}/status` -> `"ONLINE"` (Retained)
- **Last Will & Testament (LWT)**: `softplc/{controller_name}/status` -> `"OFFLINE"` (Retained)

---

## ⚡ Future Sparkplug B Support

- **Namespace**: `spBv1.0/{group_id}/{message_type}/{edge_node_id}/{device_id}`
- Protobuf payload encoding supporting `NBIRTH`, `NDEATH`, `DBIRTH`, `DDEATH`, and `DDATA`.
