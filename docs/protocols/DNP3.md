# Protocol Specification: DNP3 Outstation

## 📌 Overview

The DNP3 protocol adapter implements a DNP3 Outstation (slave) interface for communicating with electric utility, water, and SCADA masters over TCP/IP (port 20000).

---

## 📊 Point Type Mapping

| DNP3 Group / Variation | Point Type | Tag Data Type | Description |
|------------------------|------------|---------------|-------------|
| **Group 1 / 2** | Binary Inputs | `BOOL` (Inputs) | Status inputs with event reporting |
| **Group 10 / 12** | Binary Outputs (CROB) | `BOOL` (Outputs) | Control Relay Output Blocks |
| **Group 30 / 32** | Analog Inputs | `INT16`, `REAL` | Measurements with analog deadband events |
| **Group 40 / 41** | Analog Outputs | `REAL` | Analog setpoints |
| **Group 20 / 22** | Counters | `UINT32` | Pulse counter accumulators |

---

## ⚡ Unsolicited Responses & Events

- **Event Buffer**: Configurable buffer capacity per point class (Class 1, 2, 3).
- **Timestamps**: UTC millisecond timestamps attached to all DNP3 events directly from the Tag Database snapshot.
