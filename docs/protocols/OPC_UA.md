# Protocol Specification: OPC UA Server

## 📌 Overview

The Soft PLC Simulator includes an embedded OPC UA Server adapter (`opcua`) allowing SCADA systems (Ignition, Kepware, UAExpert, Wonderware, etc.) to browse, monitor, read, and write tags within the simulated controller.

---

## 🏗️ Namespace & Node Structure

The server exposes standard and custom OPC UA namespaces:

- **Namespace 0**: OPC UA Standard (http://opcfoundation.org/UA/)
- **Namespace 1**: Controller Tags (`urn:softplc:tags`)
- **Namespace 2**: Controller Diagnostics (`urn:softplc:diagnostics`)

### Node Hierarchy
```
Root (i=84)
 └── Objects (i=85)
      └── SoftPLC (ns=1;s=SoftPLC)
           ├── Tags (ns=1;s=SoftPLC.Tags)
           │    ├── Inputs (ns=1;s=SoftPLC.Tags.Inputs)
           │    │    ├── Start_PB (ns=1;s=Inputs.Start_PB)
           │    │    └── Stop_PB (ns=1;s=Inputs.Stop_PB)
           │    ├── Outputs (ns=1;s=SoftPLC.Tags.Outputs)
           │    │    └── Motor_Run (ns=1;s=Outputs.Motor_Run)
           │    └── Internal (ns=1;s=SoftPLC.Tags.Internal)
           └── Diagnostics (ns=2;s=SoftPLC.Diagnostics)
                ├── ScanCount (ns=2;s=Diagnostics.ScanCount)
                ├── LastScanTimeMs (ns=2;s=Diagnostics.LastScanTimeMs)
                └── RuntimeState (ns=2;s=Diagnostics.RuntimeState)
```

---

## 🔄 Tag Type Mapping

| PLC Tag Type | OPC UA DataType | Node Id Format |
|--------------|─────────────────|────────────────|
| `BOOL` | `Boolean` | `ns=1;s=<tag_path>` |
| `INT16` | `Int16` | `ns=1;s=<tag_path>` |
| `INT32` | `Int32` | `ns=1;s=<tag_path>` |
| `INT64` | `Int64` | `ns=1;s=<tag_path>` |
| `FLOAT32` | `Float` | `ns=1;s=<tag_path>` |
| `FLOAT64` | `Double` | `ns=1;s=<tag_path>` |
| `STRING` | `String` | `ns=1;s=<tag_path>` |

---

## 🛡️ Security & Certificate Management

- **Endpoints**:
  - `opc.tcp://0.0.0.0:4840/freeopcua/server/`
- **Security Policies**:
  - `None` (for local development/testing)
  - `Basic256Sha256` / `SignAndEncrypt`
- **User Authentication**:
  - Anonymous access toggle
  - User/Password authentication mapping
