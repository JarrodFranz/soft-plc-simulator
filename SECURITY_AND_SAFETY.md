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
- **Endpoints** (all advertised simultaneously; the client picks one):
  - `None` — anonymous, unencrypted. Appropriate for LAN commissioning/training only.
  - `Basic256Sha256` with **Sign** (HMAC-SHA256) or **SignAndEncrypt** (AES-256-CBC) — **shipped** (v3), implemented as a hand-rolled pure-Dart crypto stack (RSA-2048, AES-256-CBC, SHA-256/HMAC-SHA256, RSA-OAEP, RSA-PKCS#1-v1.5-SHA256, and the OPC UA `P_SHA256` key derivation) with no crypto FFI.
  - **User authentication**: Anonymous and `UserNameIdentityToken` (password RSA-OAEP-decrypted and server-nonce-verified) — **shipped**. X.509 *user* tokens remain deferred.
- **Certificates**: a self-signed RSA-2048 X.509 application-instance certificate is generated and persisted once on first run (`services/opcua_cert_store.dart`). **The private key never leaves the device and is never serialized into project JSON or an exported `.splc.json`.** Clients trust it **on first use** (auto-trust), as they would any self-signed dev certificate.
- **Known limitations** (deliberate, documented in `docs/protocols/opcua.md`): a single app-wide certificate is reused across projects (so `applicationUri` must be app-wide stable); the `ActivateSession` signature check reuses the `CreateSession` server nonce rather than rotating a fresh nonce per activation; and a managed trust-list, certificate revocation, and `Aes128_Sha256_RsaOaep` are not implemented. Treat the hosted server as a **simulation/commissioning** endpoint, not a production-hardened one.

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
