# OPC UA Security (Basic256Sha256 + user auth) Design

**Date:** 2026-07-11
**Status:** Approved by user (chat, 2026-07-11): Basic256Sha256 Sign + SignAndEncrypt (keep None); Anonymous + username/password user auth; persisted self-signed app instance certificate with auto-trusted client certificates; pure-Dart crypto via `pointycastle` + `asn1lib`.
**Builds on:** WS19 (in-app OPC UA binary server — `opcua_binary.dart`/`opcua_transport.dart`/`opcua_session.dart`/`opcua_address_space.dart`/`opcua_services.dart` + `opcua_host.dart`) and WS20 (subscriptions, `opcua_subscriptions.dart`). Those shipped SecurityPolicy **None** + **Anonymous** only. The asymmetric security header (securityPolicyUri / senderCertificate / receiverCertificateThumbprint) is already parsed by `opcua_transport.dart` but only ever carries "None". This workstream adds real transport security.

## Goal

Let the in-app OPC UA server accept **secure** connections: advertise and honor **Basic256Sha256** in **Sign** and **SignAndEncrypt** security modes (alongside the existing **None**), authenticate sessions with **Anonymous or username/password**, and identify itself with a **persisted self-signed X.509 application instance certificate**. A real SCADA client (Ignition, and the machine-proof Rust `opcua` master) can then connect with an encrypted, mutually-authenticated channel — the last of the four-protocol config-depth items.

## Scope

**In:**
- **Security policies:** `http://opcfoundation.org/UA/SecurityPolicy#None` (unchanged) **and** `http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256`. For Basic256Sha256, both **SecurityMode Sign (2)** and **SignAndEncrypt (3)**. The `GetEndpoints`/`CreateSession` EndpointDescription list advertises every enabled (policy, mode) combination the operator turned on.
- **Asymmetric channel (OpenSecureChannel):** RSA-2048. On an OPN chunk secured with Basic256Sha256: verify the client's PKCS#1 v1.5 **RSA-SHA256 signature** over the chunk, **RSA-OAEP (MGF1-SHA1)** decrypt the body, issue a `SecurityToken` (channelId + tokenId + created/lifetime), and return an OPN response signed with our private key and encrypted to the client's public key. Client and server nonces are 32 bytes.
- **Symmetric channel (MSG/CLO):** derive symmetric keys from the two nonces via **P_SHA256** (OPC UA key derivation), then on every subsequent MSG chunk apply **AES-256-CBC** encryption (SignAndEncrypt only) and an **HMAC-SHA256** signature (Sign and SignAndEncrypt), with the padding + sequence-header rules from OPC UA Part 6. Symmetric key material: signing key 32 B, encrypting key 32 B, IV/block 16 B.
- **Token renewal:** honor a client's OPN **Issue** and **Renew** (RequestType) — Renew derives a new key set from fresh nonces while the old token stays valid through its lifetime overlap.
- **User authentication:** Anonymous (unchanged) **and** `UserNameIdentityToken`. The password is delivered encrypted with the channel's user-token security policy (RSA-OAEP with the server cert for Basic256Sha256; for a None channel the password is sent in the clear per the spec). The server OAEP-decrypts, strips the 4-byte length prefix + server nonce, and compares against the operator-configured credential list. A bad credential returns `Bad_UserAccessDenied` / `Bad_IdentityTokenRejected`.
- **Application instance certificate:** a self-signed X.509 v3 certificate (RSA-2048, SHA-256 signature, a subject commonName + a URI SubjectAltName matching the server ApplicationUri) generated **once on first host start** and persisted to app-local storage (private key + cert). Reused across restarts; regenerable on demand from the UI. The SHA-1 thumbprint (of the DER) is shown in the UI and used in the asymmetric security header.
- **Client certificate trust:** **auto-trust** — the server parses the client's certificate to extract its RSA public key (needed to verify the client signature and encrypt responses) and its thumbprint (displayed in the UI), but does not reject on trust grounds. Malformed/oversized client certs are rejected at parse (never crash).
- **Config UI:** OPC UA card gains security-policy/mode toggles, a username/password credential editor, a "Regenerate certificate" action, and a read-only app-cert thumbprint display.
- **E2E:** extend the Rust `opcua` probe — connect with Basic256Sha256 / SignAndEncrypt + username/password, Browse/Read/Write, assert success; the existing None + Anonymous path still works.

**Out (v-next):**
- Deprecated/weak policies `Basic128Rsa15`, `Basic256`, `Aes128_Sha256_RsaOaep`, `Aes256_Sha256_RsaPss` (Basic256Sha256 is the modern interop baseline).
- **X.509 user identity tokens** (`X509IdentityToken`) — username/password only for v1.
- A **client-certificate trust list / reject-until-approved** UI (auto-trust in v1).
- Certificate **expiry/renewal policy** beyond manual regenerate; CRL/CA-chain validation; GDS/push certificate management.
- Hardware-backed key storage / OS keychain (the key persists to app-local application storage; standard file-system protection, not a secure enclave).

## Config model (additive)

`OpcUaProtocolConfig` (in `protocol_settings.dart`) gains, all additive with back-compat defaults so older projects round-trip unchanged (WS6 lossless guard stays green):
- `List<String> securityModes` — which (policy, mode) endpoints to advertise, e.g. `['None', 'Basic256Sha256/Sign', 'Basic256Sha256/SignAndEncrypt']`. Default `['None']` (identical to today's behavior).
- `List<OpcUaUserCredential> credentials` — operator username/password pairs. **Passwords are NOT written to committed project JSON** (mirrors the MQTT broker-password rule): the credential list persists usernames; passwords live in the in-memory/app-local runtime config only. (If lossless round-trip requires a placeholder, the toJson omits the password field entirely and the UI re-prompts.)
- `bool allowAnonymous` (default true) — whether Anonymous sessions are accepted when security is enabled.

The app instance certificate + private key are **not** part of `OpcUaProtocolConfig` — they live in the cert store (app-local storage), keyed per device, never in project files.

## Architecture

| Unit | File | Layer | Responsibility |
|---|---|---|---|
| Crypto primitives (NEW, pure) | `mobile/lib/protocols/opcua/opcua_crypto.dart` | pure Dart (`pointycastle`) | RSA-2048 keygen; RSA PKCS#1v1.5 **SHA-256** sign/verify; **RSA-OAEP (MGF1-SHA1)** encrypt/decrypt; AES-256-CBC encrypt/decrypt; SHA-256; HMAC-SHA256; **P_SHA256** key derivation. No `dart:io`/Flutter. |
| Certificate (NEW, pure) | `mobile/lib/protocols/opcua/opcua_certificate.dart` | pure Dart (`asn1lib`) | Build a self-signed X.509 v3 cert (DER) from an RSA keypair + ApplicationUri; parse a peer cert → RSA public key + SHA-1 thumbprint. No `dart:io`/Flutter. |
| Secure channel (NEW, pure) | `mobile/lib/protocols/opcua/opcua_secure_channel.dart` | pure Dart | The security state machine: asymmetric OPN verify/decrypt + sign/encrypt response; token Issue/Renew; P_SHA256 key derivation from nonces; per-MSG symmetric sign+encrypt / verify+decrypt; padding, sequence header, chunk sizing. Consumes `opcua_crypto`/`opcua_certificate`. No `dart:io`. |
| Certificate store (NEW, service) | `mobile/lib/services/opcua_cert_store.dart` | service (`dart:io` + `path_provider`) | First-run RSA keygen + self-signed cert build; persist key + cert to app-local storage; load on start; regenerate on demand. The ONLY new file touching storage. |
| Session/transport (MODIFY, pure) | `opcua_session.dart`, `opcua_transport.dart` | pure Dart | Advertise enabled (policy, mode) EndpointDescriptions; route OPN/MSG/CLO through the secure channel; decode `UserNameIdentityToken` (OAEP-decrypt password, strip length+nonce) and validate credentials. |
| Host (MODIFY, service) | `mobile/lib/services/opcua_host.dart` | service | Load the cert store at start; give each connection a secure-channel instance seeded with the app cert/key; expose active-policy + client-thumbprint status. Never crashes on malformed secured input. |
| Config (MODIFY) | `mobile/lib/models/protocol_settings.dart` | model | `securityModes`, `credentials` (password-less persistence), `allowAnonymous`. |
| UI (MODIFY) | `mobile/lib/screens/gateway_screen.dart` | UI | Security-policy/mode toggles, username/password editor, Regenerate-cert action, app-cert thumbprint display. |
| E2E (MODIFY) | `gateway/examples/opcua_probe.rs` (+ `tool/opcua_e2e.sh`) | Rust | `opcua` master connects Basic256Sha256/SignAndEncrypt + username/password, Browse/Read/Write; None path still works. |

## Crypto / wire facts (verify against OPC UA Part 4 §5.5, Part 6 §6.7–6.8, and the Rust `opcua` crate)

- **Basic256Sha256 algorithms:** asymmetric signature = RSA PKCS#1 v1.5 + **SHA-256**; asymmetric encryption = **RSA-OAEP** with MGF1-**SHA-1** (plaintext block = keyBytes−42 = 214 for RSA-2048; cipher block = 256). Symmetric signature = **HMAC-SHA256**; symmetric encryption = **AES-256-CBC**. Thumbprint = **SHA-1** of the DER certificate. Nonce length = **32**.
- **P_SHA256 key derivation:** `derivedKeys = P_hash(secret=serverNonce, seed=clientNonce)` for the client→server keys and `(secret=clientNonce, seed=serverNonce)` for server→client, split into `[signingKey(32) | encryptingKey(32) | iv(16)]` per direction (client keys used to VERIFY/DECRYPT inbound; server keys to SIGN/ENCRYPT outbound). P_hash uses HMAC-SHA256 iterated per RFC 5246 §5.
- **Asymmetric OPN chunk (secured):** SecurityHeader carries the full securityPolicyUri, the sender (server) certificate, and the SHA-1 thumbprint of the receiver (client) certificate. The plaintext (sequence header + body + padding + optional signature) is signed then encrypted in RSA-OAEP blocks; padding makes the pre-encryption length a multiple of the plaintext block size, with the OPC UA PaddingByte(s) convention. Response mirrors this using the server key to sign and the client public key to encrypt.
- **Symmetric MSG chunk:** after the token is issued, each MSG/CLO chunk uses the symmetric SecurityHeader (TokenId), AES-256-CBC with the derived IV, HMAC-SHA256 signature appended, padding to the AES block (16). SequenceNumber/RequestId in the (encrypted) sequence header increment per chunk.
- **UserNameIdentityToken:** `policyId`, `userName`, `password` (ByteString), `encryptionAlgorithm`. For a Basic256Sha256 user-token policy the password ByteString is `RSA-OAEP( length(4, LE) ++ passwordUtf8 ++ serverNonce )` under the SERVER cert; the server OAEP-decrypts with its private key, reads the 4-byte length, extracts the password, and checks the trailing bytes match the last server nonce it issued.
- **Never** use `getInt64`/`setInt64` on the wire (dart2js). All lengths already go through `opcua_binary.dart`'s existing helpers.

## Testing (same bar as WS19/WS20)

1. **Crypto known-answer tests** (`opcua_crypto_test.dart`): SHA-256/HMAC-SHA256 against RFC vectors; P_SHA256 against an OPC UA / RFC 5246 reference vector; AES-256-CBC against a NIST vector; RSA sign→verify and OAEP encrypt→decrypt round-trips with a fixed test key; reject a tampered signature.
2. **Certificate tests** (`opcua_certificate_test.dart`): build a self-signed cert from a fixed keypair → parse it back → public key + thumbprint round-trip; SHA-1 thumbprint matches an independently-computed DER hash; a malformed/oversized cert returns null (never throws).
3. **Secure-channel tests** (`opcua_secure_channel_test.dart`): a full asymmetric OPN request built from a known client keypair is verified + decrypted + answered, and the response verifies + decrypts back on the client side (loopback using both keypairs); P_SHA256-derived keys round-trip a symmetric MSG (sign+encrypt → verify+decrypt); a tampered symmetric MAC is rejected; Renew produces a new key set while the old token still validates within its lifetime.
4. **Session/user-auth tests** (`opcua_session_test.dart` additions): EndpointDescription advertises exactly the enabled (policy, mode) set; a `UserNameIdentityToken` with the correct OAEP-encrypted password activates; a wrong password is rejected with the right status; Anonymous still works when allowed and is refused when disabled.
5. **Cert-store test** (`opcua_cert_store_test.dart`): first call generates + persists a key/cert; a second load returns the same cert (persistence); regenerate replaces it. (Uses a temp dir; the service is the only dart:io surface.)
6. **Machine-proof E2E** (`tool/opcua_e2e.sh`): the Rust `opcua` master connects with **Basic256Sha256 / SignAndEncrypt** + username/password, runs Browse + Read + Write against the fixture, and asserts success → `OPCUA SECURITY PROBE PASS`; the existing None/Anonymous leg still passes. Honest build+unit fallback if the environment can't run the live master.
7. **Regression:** full `flutter test`; `flutter analyze` ZERO; `flutter build web --release` compiles (pointycastle/asn1lib are pure Dart); WS6 lossless round-trip green (additive config); the None + Anonymous path is byte-identical to today when no security is enabled.

## Global constraints

- No vendor branding; OPC UA / IEEE terms fine. Dark theme; zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; braces; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/opcua/**` stays PURE Dart (pointycastle/asn1lib are pure Dart and allowed there); only `opcua_host.dart` and the new `opcua_cert_store.dart` use `dart:io`/storage. The server never crashes on malformed or hostile secured input (bad signature/padding/cert → a clean error status or dropped connection, never an uncaught exception).
- **Secrets:** the app private key persists ONLY to app-local device storage, never to project files and never committed (`gateway/pki` and any key/cert artifacts stay gitignored). User passwords are in-memory/app-local only, never written to committed project JSON — same rule as the MQTT broker password.
- Additive persistence; WS6 round-trip green; the app is byte-identical on the wire when security is disabled (`securityModes == ['None']`), preserving WS19/WS20 behavior exactly.
- Two new pure-Dart dependencies: `pointycastle` and `asn1lib`. dart2js-safe (no `getInt64`/`setInt64`).
- Security-correctness is unforgiving: known-answer crypto vectors gate the primitives, and the live Rust `opcua` client is the falsifiable end-to-end proof — a wrong pad/sign/derive byte makes a real client reject the channel.

## Phasing (one spec → plan tasks)

1. **Crypto primitives** — `opcua_crypto.dart` (RSA/AES/SHA/HMAC/OAEP/PKCS1v15 + P_SHA256) with known-answer tests.
2. **Certificate build/parse** — `opcua_certificate.dart` (self-signed X.509 + thumbprint + peer-cert parse) with tests.
3. **Cert store service** — `opcua_cert_store.dart` (first-run keygen + persist/load/regenerate) with a temp-dir test.
4. **Asymmetric secure channel** — OPN Issue/Renew verify+decrypt / sign+encrypt, token lifecycle (`opcua_secure_channel.dart` part 1) with loopback tests.
5. **Symmetric security + user auth + endpoints** — P_SHA256 keys, AES/HMAC MSG chunks, EndpointDescription advertisement, `UserNameIdentityToken` decrypt/validate (`opcua_secure_channel.dart` part 2 + `opcua_session.dart`/`opcua_transport.dart`).
6. **Host wiring + config + UI** — cert-store load into the host, `OpcUaProtocolConfig` additions, OPC UA card security toggles/credentials/thumbprint.
7. **Rust `opcua` E2E (secure connect + user auth) + docs + final review** — machine-proof, all gates, `docs/protocols/OPCUA.md` update, ROADMAP note, whole-branch review, merge.
