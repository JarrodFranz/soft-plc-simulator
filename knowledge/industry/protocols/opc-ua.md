---
id: knowledge:industry/protocols/opc-ua
title: OPC UA
domain: industry/protocols
version: "2026-08"
topics: [opc-ua, opc.tcp, secure-channel, basic256sha256, subscriptions, address-space, little-endian]
summary: OPC UA binary transport wire format, the OpenSecureChannel/session handshake, address-space Browse/Read/Write/Subscribe services, and how an in-app pure-Dart server implements and E2E-proves both None and Basic256Sha256 security against a real Rust opcua-crate client.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/modbus
learnings: [CL-15]
---

# OPC UA

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/opcua/opcua_binary.dart`,
> `opcua_secure_channel.dart`, `opcua_certificate.dart`, `opcua_services.dart`,
> `opcua_subscriptions.dart`, `mobile/lib/services/opcua_host.dart`, and the
> real-client E2E script `tool/opcua_e2e.sh`.
> **Read this before:** implementing or debugging an OPC UA server/client,
> diagnosing a secure-channel handshake failure, or comparing OPC UA's
> name-addressed model against a register/byte-addressed fieldbus.

---

## 1. The headline rule

**OPC UA binary encoding is little-endian throughout, and the protocol is a two-layer handshake - a SecureChannel (transport-level, `OpenSecureChannel`) wraps a Session (application-level, `CreateSession`/`ActivateSession`) - with every subsequent service call riding inside both.**

Nothing is served until a channel exists, and nothing application-meaningful happens until a session is also active on top of it; conflating "channel open" with "session active" is the most common state-machine bug in a hand-rolled implementation.

---

## 2. Wire format

### 2.1 Transport framing

`opc.tcp` starts with an ASCII **Hello/Acknowledge** handshake (protocol version, buffer sizes) before any secure-channel traffic. After that, every message is a sequence of **chunks**, each with an 8-byte chunk header: a 3-character message type (`HEL`/`ACK`/`ERR`/`OPN`/`MSG`/`CLO`), a 1-byte chunk indicator (`F` final / `C` continuation / `A` abort), and a u32 total chunk size. A conformant implementation negotiates generous single-chunk buffers and rejects an oversize message cleanly rather than attempting multi-chunk reassembly (a legitimate scope-reduction for a simulator-class server; a full driver stack implements true reassembly).

### 2.2 NodeId encoding

A NodeId (namespace index + identifier) has four wire forms, and the encoder always picks the smallest applicable one:

| Form | Byte | Shape |
|---|---|---|
| Two-byte | `0x00` | `ns==0 && numeric<=255` -> `[0x00, id]` |
| Four-byte | `0x01` | `ns<=255 && numeric<=65535` -> `[0x01, ns(u8), id(u16 LE)]` |
| Numeric | `0x02` | otherwise -> `[0x02, ns(u16 LE), id(u32 LE)]` |
| String | `0x03` | `[0x03, ns(u16 LE), string]` |

### 2.3 Byte order

**All multi-byte integers in OPC UA Binary encoding (Part 6, §5.2) are little-endian** - the inverse convention from S7comm/FINS/BACnet next door, and the same convention as EtherNet/IP.

### 2.4 The secure-channel handshake (Basic256Sha256)

1. **Asymmetric `OpenSecureChannel` (OPN).** The body is RSA-OAEP-SHA1-encrypted to the peer's certificate public key and RSA-PKCS#1-v1.5-SHA256-signed with the sender's private key. Each side contributes a 32-byte nonce.
2. **`P_SHA256` key derivation.** The OPC UA `P_SHA256(secret, seed)` PRF derives separate signing/encrypting keys and an IV per direction from the two nonces.
3. **Symmetric `MSG`/`CLO`.** Subsequent chunks use HMAC-SHA256 signatures and (for `SignAndEncrypt`) AES-256-CBC encryption with PKCS#7-style padding.
4. **Session + user auth.** `CreateSession`/`ActivateSession` run over the secured channel; a secured `CreateSessionResponse` returns the server's certificate and a fresh server nonce, and a `UserNameIdentityToken` password is RSA-OAEP-encrypted as `UInt32-LE length ++ passwordBytes ++ serverNonce`.

A certificate's **thumbprint is SHA-1 over the DER-encoded certificate** (CL-15). A self-signed application certificate used as its own trust anchor needs the `keyCertSign` KeyUsage bit set even though it is a leaf cert - a strict validator (Eclipse Milo, the stack Ignition 8.3 uses) rejects an anchor lacking it with `Bad_CertificateUseNotAllowed` ("required KeyUsage 'keyCertSign' not found") - confirmed live against Ignition 8.3, not just the Rust E2E client.

---

## 3. Transport and port

TCP, IANA-registered port **4840**, unprivileged on every platform. `opc.tcp://` is the standard URL scheme.

---

## 4. Addressing / map model

OPC UA addresses data **by name** (a NodeId), not by register or byte offset - the opposite addressing philosophy from Modbus/S7comm/FINS/SLMP. A general binding model: every exposed point becomes a `Variable` node under a browsable hierarchy (conventionally under the standard `Objects` folder), with `Browse` letting a client discover the whole address space top-down from `RootFolder` rather than needing any node id hardcoded in advance. A folder/grouping concept in the source data maps naturally onto a synthesized `Object` node with `FolderType`, organized under `Objects` alongside plain top-level variables.

A composite (struct/array) value has no single "structured Variant" representation in a scalar-leaf exposure model - each scalar leaf of a composite becomes its own dotted-path node (`Motor.Speed`, `Recipe_Steps[0]`) rather than the whole struct reading back in one `Read`. `STRING`-typed leaves *are* representable here (unlike a byte/word-table protocol like Modbus/S7comm/FINS/SLMP, which have no wire slot for a length-prefixed string without inventing one) - OPC UA's `String` built-in type covers it directly.

## 5. What the in-app host implements

*(app-specific - this section describes this repository's implementation, not the OPC UA standard itself.)*

v1: `opc.tcp` transport, `OpenSecureChannel` with Security Policy `None` (incl. token renewal), `CreateSession`/`ActivateSession` (anonymous)/`CloseSession`, `GetEndpoints` (echoing the client's own dialed host back, so a client behind NAT/an alternate hostname still gets a reachable endpoint), `Browse` (top-down from `RootFolder`), the standard `Server_NamespaceArray` variable, `Read`/`Write` (force-aware, `ReadWrite` nodes only). v2 added the full subscription surface (`CreateSubscription`/`ModifySubscription`/`DeleteSubscriptions`/`SetPublishingMode`, `CreateMonitoredItems`/`ModifyMonitoredItems`/`DeleteMonitoredItems`, `Publish`/`Republish`) with data-change monitoring on the Value attribute, an absolute deadband, and per-subscription keep-alive/lifetime counters, capped (10 subscriptions/session, 500 monitored items/subscription, 10 parked Publish requests/session, 20 retransmission messages retained/subscription). v3 added the Basic256Sha256 security stack above, plus username/password authentication.

Fixed caps not client-negotiable: `TimestampsToReturn` is ignored (server timestamps always used); `Sampling` monitoring mode is reported the same as `Reporting` (no server-side suppression). `mobile/lib/protocols/opcua/opcua_certificate.dart` is the only OPC UA security file allowed to touch `dart:io`/`path_provider`; the private key never leaves the device or gets written to project JSON.

## 6. Write-gate interaction

Writing a `ReadOnly` node returns `Bad_NotWritable`; writing a currently **forced** tag returns `Bad_UserAccessDenied` and the value is left unchanged - forcing always wins over an external write. This is the model every other protocol adapter's write-gate refusal is measured against in this suite (Modbus's exception `02`, CIP's `0x0F`, S7comm's per-item `0x03`, and so on, are each that protocol's closest equivalent to this `Bad_UserAccessDenied` signal).

## 7. Real-client E2E proof

Proven against a genuine Rust **`opcua`** crate client (v0.12.0). The plaintext leg runs `GetEndpoints` -> `Read NamespaceArray` -> `Browse` top-down from `RootFolder` (discovering `Objects` as a reference off Root, not by hardcoding its node id) -> `Browse`/`Read`/`Write`/`Read`-back-verify -> `CreateSubscription` + `CreateMonitoredItems`, then waits for a real pushed `DataChangeNotification` the fixture host emits server-side on its own timer - proof of a genuine push, not a polled illusion. A second session then opens at Security Policy `Basic256Sha256`/`SignAndEncrypt`, authenticated with username/password, and repeats `Browse`/`Read`/`Write`/`Read`-back-verify **over the fully encrypted channel** - exercising the entire asymmetric OPN + `P_SHA256` derivation + symmetric AES-256/HMAC-SHA256 channel + OAEP-encrypted password path; a byte-layout error anywhere in that chain surfaces as the real client rejecting the channel (`Bad_SecurityChecksFailed`/`Bad_CertificateInvalid`/a decrypt failure), not a silent pass.

### 7.1 Ignition 8.3 interop (a second, independent client)

Separately from the Rust E2E harness, this server has been confirmed live against **Ignition 8.3** (whose OPC UA stack is Eclipse Milo) at `Basic256Sha256`/`SignAndEncrypt`, including the `keyCertSign` KeyUsage requirement above - Ignition's Milo-based client is the strict validator that first surfaced `Bad_CertificateUseNotAllowed` on a trust-anchor certificate missing that bit. A folder-organized address space (synthesized `FolderType` nodes for tags with a non-empty `folder`) is expected to render identically in Ignition/Milo, since it uses only the standard `Organizes` reference and `FolderType` type definition every OPC UA client already understands - no Ignition-specific accommodation was needed for that feature.

## 8. Gotchas

- **CL-15: certificate thumbprint = SHA-1 over the DER certificate; `Basic256Sha256` OPN padding/sign-then-encrypt ordering must be byte-exact.** Validated against a strict Rust client - a one-byte padding or ordering mistake in the asymmetric OPN step fails the whole secure-channel handshake, not just one field.
- **A self-signed leaf certificate used as its own trust anchor needs `keyCertSign` in its KeyUsage extension.** Without it, a strict validator (confirmed live: Ignition 8.3 / Eclipse Milo) refuses the certificate with `Bad_CertificateUseNotAllowed` even though the certificate is otherwise well-formed - this is a trust-anchor requirement, not a leaf-certificate requirement, and easy to miss when generating a single self-signed cert used for both roles.
- **An existing on-device certificate is not retroactively upgraded** when new required extensions are added to the certificate-generation code - a cert generated before such a change lacks them and needs regenerating, not just a code update, before it will satisfy a strict client.
- **Never assume little-endian throughout the OPC UA stack means every neighboring protocol shares it.** S7comm, FINS, and BACnet/IP are big-endian; do not copy an `Endian.little` read across a codec boundary (see [endianness-and-framing.md](./endianness-and-framing.md)).

```
Wrong: treat OpenSecureChannel success as sufficient to start serving Read/
       Write/Browse requests.
Correct: a channel being open is necessary but not sufficient - Read/Write/
       Browse are session-scoped services and require a completed
       CreateSession + ActivateSession on top of the channel first.
```

---

## What this means practically

### "Why does my subscription never fire a DataChangeNotification even though the value is changing server-side?"
Two independent things have to both be true: a `MonitoredItem` must exist on that node's Value attribute (created via `CreateMonitoredItems`), and the client must have an outstanding `Publish` request parked at the server - a subscription with no parked `Publish` request has nowhere to deliver a notification to, and the server will simply queue it.

### "My client's Browse from a hardcoded node id works in testing but fails against another server - why?"
Because hardcoding `i=85` (Objects) or any other node id bypasses the address-space's actual navigational structure. A client that instead browses top-down from `RootFolder` (`i=84`) and follows the standard `Organizes` references works against any conformant server regardless of what node ids that server happens to assign.

---

## Related

- [ethernet-ip-cip.md](./ethernet-ip-cip.md) - the other little-endian protocol in this suite, and a name-addressed (symbolic) contrast to OPC UA's node-id addressing.
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
