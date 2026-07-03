# Protocol Specification: Modbus TCP Server

## 📌 Overview

The Modbus TCP Server adapter enables legacy SCADA systems, PLCs, and Modbus masters (e.g., Modscan, QModMaster) to interface with the Soft PLC simulator.

---

## 🔢 Modbus Address Table Mapping

| Register Type | Address Range | Function Codes | Tag Data Type | Access |
|---------------|---------------|----------------|---------------|--------|
| **Discrete Inputs** | 10001 – 19999 | `FC02` (Read Discrete Inputs) | `BOOL` (Inputs) | Read-Only |
| **Coils** | 00001 – 09999 | `FC01` (Read Coils), `FC05` (Write Coil), `FC15` (Write Multiple Coils) | `BOOL` (Outputs/Internal) | Read/Write |
| **Input Registers** | 30001 – 39999 | `FC04` (Read Input Registers) | `INT16`, `REAL` (Inputs) | Read-Only |
| **Holding Registers** | 40001 – 49999 | `FC03` (Read Holding), `FC06` (Write Single), `FC16` (Write Multiple) | `INT16`, `INT32`, `REAL` | Read/Write |

---

## ⚙️ Data Encoding & Endianness

Multi-register numeric types (`INT32`, `FLOAT32/REAL`, `FLOAT64`) are mapped across contiguous 16-bit registers with configurable word swapping:

- **Big-Endian (AB CD)**: Default IEEE-754 floating point.
- **Little-Endian Word Swap (CD AB)**: Configurable per device profile.
