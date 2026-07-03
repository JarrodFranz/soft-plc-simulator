# Project Brief: Mobile Soft PLC Simulator

## 🎯 Product Vision

The **Mobile Soft PLC Simulator** empowers automation engineers, SCADA developers, students, and system integrators to execute IEC 61131-3 style control logic on portable devices and desktop systems. It bridges the gap between hardware PLCs and SCADA software by providing a lightweight, virtual controller equipped with interactive I/O simulation and industrial protocol adapters.

---

## 👥 Target Users

1. **Automation & Control Engineers**: Testing PLC logic concepts, virtual commissioning, and protocol integration prior to deployment on hardware PLCs.
2. **SCADA & HMI Integrators**: Developing and testing SCADA screens (Ignition, Kepware, Wonderware, etc.) against realistic tag models without needing physical controller hardware.
3. **Protocol Testers & Cybersecurity Researchers**: Validating OPC UA, Modbus TCP, MQTT, and DNP3 outstation behavior, certificate handling, and firewall rules.
4. **Students & Educators**: Learning industrial control programming, scan cycle concepts, and ladder logic on personal mobile devices or laptops.

---

## 💡 Primary Use Cases

- **Offline PLC Logic Prototyping**: Create, load, and debug Structured Text or Ladder Logic programs directly on a smartphone or tablet.
- **Virtual Commissioning & Factory Acceptance Testing (FAT)**: Simulate complex machine sequences and field device responses (valves, motors, sensors) to validate HMI/SCADA screens.
- **Protocol Integration Testing**: Test OPC UA subscriptions, Modbus register maps, MQTT Sparkplug B topic layouts, and DNP3 event buffering.
- **Demonstration & Training**: Deliver live control system training without requiring heavy demo rigs or expensive industrial hardware.

---

## 🚫 Non-Goals

> [!CAUTION]
> - **NOT a Production Controller**: This software MUST NOT be used to control real physical machinery, factory floors, or hazardous processes.
> - **NOT Safety Certified**: Does not comply with IEC 61508 (SIL), ISO 13849, or UL standards.
> - **NOT a Hardware Replacement**: Not built for hard real-time deterministic execution on real-world industrial buses (EtherCAT, PROFINET, EtherNet/IP I/O scanner).

---

## 📦 MVP Scope vs. Future Scope

### MVP Scope (Phases 0–3)
- **Tag Engine**: In-memory database with `BOOL`, `INT`, `REAL`, `STRING`, quality flags, forcing, and timestamps.
- **Scan Loop**: Configurable scan execution (e.g., 50ms – 1000ms) with execution metrics.
- **Instruction Set**: Boolean contacts (NO, NC), coils (Standard, Set, Reset), and TON timers.
- **Simulated I/O**: Manual force toggle and simulated input toggles.
- **Mobile UI Scaffold**: Basic Flutter app with status dashboard, tag browser, and manual I/O forcing controls.

### Future Scope (Phases 4–10)
- **Full IEC Languages**: Complete Structured Text (ST) and Ladder Logic (LD) compilers, Function Block Diagram (FBD), and Sequential Function Chart (SFC).
- **Industrial Protocols**: Native OPC UA Server, Modbus TCP Server, MQTT client (with Sparkplug B), and DNP3 Outstation.
- **Companion Gateway Mode**: High-performance Rust desktop/server process exposing protocol servers while synchronizing with mobile devices via WebSockets.
- **Process Simulation Engine**: Built-in process models (tank level, PID thermal loop, conveyor motor).
- **PLCopen XML**: Import/Export compatibility with standard IEC 61131-3 tools.

---

## ⚠️ Risks and Constraints

1. **Mobile OS Networking Restrictions**: Mobile operating systems (iOS and Android) heavily restrict inbound socket servers, custom port binding (<1024), and background thread execution.
   - *Mitigation*: Dual-mode architecture utilizing a Companion Gateway for heavy protocol hosting.
2. **Deterministic Scan Timing**: Mobile background task schedulers do not guarantee microsecond deterministic execution.
   - *Mitigation*: Clear UI indicators for scan jitter and overrun warnings.
3. **Cross-Platform FFI Overhead**: Passing tag updates between Rust core and Flutter UI across native boundary.
   - *Mitigation*: Binary memory sharing via `flutter_rust_bridge` and batch tag updates.
