# Security & Safety Guidelines

## ⚠️ Simulator & Non-Safety Disclaimer

> [!CAUTION]
> **NOT FOR PRODUCTION CONTROL OR MACHINE SAFETY**  
> The Mobile Soft PLC Simulator is designed exclusively for educational training, virtual commissioning, software testing, and SCADA protocol integration.
> 
> - **No SIL / Safety Ratings**: This software is not certified under IEC 61508, ISO 13849, NFPA 79, or any safety standard.
> - **Non-Deterministic Scheduling**: Mobile and desktop consumer operating systems (Android, iOS, Windows, macOS) do not provide real-time kernel guarantees. Scan jitter or OS background suspension can disrupt execution.
> - **No Physical Hardware Safety Interlocks**: Software forcing or logic simulation can never replace hardwired safety relays, emergency stop safety circuits, or hardware watchdog timers.

---

## 🔒 Protocol Security Architecture

When exposing simulated controllers to network interfaces via the app's in-app protocol hosts (OPC UA, Modbus TCP, MQTT, DNP3 — see ADR-010 in `DECISIONS.md`), security controls must be maintained:

### 1. OPC UA Security
- **Endpoints**:
  - `None`: what v1 implements today — anonymous auth, no encryption. Appropriate for LAN commissioning/training only (see `docs/protocols/opcua.md`).
  - `Basic256Sha256` / `Aes128_Sha256_RsaOaep` and user-token authentication (Username/Password, X.509 Certificates): **not yet implemented** — deferred to a later version if warranted (see ADR-010 in `DECISIONS.md`).
- **Certificates**: None are generated or required in v1 (Security Policy `None` only); a PKI/trust-list story is deferred alongside encryption support above.

### 2. Modbus TCP Security
- **Raw Modbus Warning**: Modbus TCP lacks inherent encryption or authentication.
- **Mitigation**: Expose Modbus TCP only on trusted local subnets, localhost loopback, or through encrypted VPN tunnels / SSH tunnels.

### 3. MQTT TLS & Authentication
- **TLS**: Enforce TLS 1.2 or TLS 1.3 on transport connections (`mqtts://`).
- **Authentication**: Username/Password and TLS Client Certificate Authentication.
- **Payload Integrity**: Optional payload signing when operating in Sparkplug B mode.

### 4. DNP3 Outstation Security
- **Authentication**: Awareness of DNP3 Secure Authentication (SA v5 / IEC 62351-5) challenge-response mechanics.
- **Network Boundaries**: IP access control whitelists restricting master connections.

---

## 📱 Mobile Networking & OS Limits

- **Inbound Port Restrictions**: Mobile operating systems prohibit binding privileged ports (<1024) without root access. Modbus TCP (port 502) and OPC UA (port 4840) should be reconfigured to non-privileged ports (>1024, e.g. `5020`/`14840`) when hosting directly from an Android/iOS device — the port fields in the Outbound Protocols screen are user-editable for this reason.
- **Background Execution Limits**: iOS accepts new inbound connections only while the app is foregrounded; backgrounding pauses hosting until the app is foregrounded again. Android continues hosting while the app process is alive but requires the client on the same LAN (no NAT traversal/port-forwarding). These are OS constraints on the in-app protocol hosts (ADR-010), not gaps to be worked around with a companion process.
- **On-device network permissions**: the app declares its cosmetic identity (icons, bundle id) but has **not yet** added the platform network permissions the protocol hosts need at the OS level (iOS `NSLocalNetworkUsageDescription`, Android `INTERNET`) — see `SHIPPING.md`.
