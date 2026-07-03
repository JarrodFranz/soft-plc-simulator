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

When exposing simulated controllers to network interfaces via the Companion Gateway or local protocol adapters, security controls must be maintained:

### 1. OPC UA Security
- **Endpoints**:
  - `None`: Development and offline virtual commissioning only.
  - `Basic256Sha256` / `Aes128_Sha256_RsaOaep`: Enabled for secure SCADA testing.
- **Authentication**: User token policies (Username/Password, X.509 Certificates). Anonymous access disabled by default in production-testing profiles.
- **Certificates**: Self-signed development certificates auto-generated in sandbox folder (`/gateway/certs`); trust lists managed in configurable PKI directories.

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

- **Inbound Port Restrictions**: Mobile operating systems prohibit binding privileged ports (<1024) without root access. Modbus TCP (port 502) and OPC UA (port 4840) should be mapped to non-privileged ports (>1024) on mobile or hosted via the Companion Gateway.
- **Background Execution Limits**: Mobile operating systems terminate idle TCP servers when the app moves to the background. Use Companion Gateway mode for persistent protocol server deployments.
