# OPC UA Strict-Client Interop Design

**Date:** 2026-07-11
**Status:** Approved by user (chat, 2026-07-11): implement CreateSession `serverSignature`, add KeyUsage/ExtendedKeyUsage to the app cert, and verify the client's ActivateSession signature — validation loop = **iterate against the user's real Ignition/UAExpert** (I build unit-tested + Rust-E2E-green; the user tests a strict client and reports errors; I fix until it accepts).
**Builds on:** the OPC UA security workstream (ROADMAP Phase 4 v3 — Basic256Sha256 Sign/SignAndEncrypt + username/password, shipped 2026-07-11). That work is proven against the Rust `opcua` 0.12 client, which is deliberately lenient exactly where strict clients are strict; this workstream closes the three documented conformance gaps that a strict client (Ignition/Eclipse Milo/.NET) checks. See [[protocol-hosting-status]].

## Goal

Make the in-app OPC UA secure endpoint acceptable to a **conformant strict OPC UA client** by closing the three known gaps: (1) the server proves possession of its certificate's private key via a real `serverSignature` in CreateSessionResponse; (2) the application-instance certificate carries the KeyUsage/ExtendedKeyUsage extensions strict clients require; (3) the server verifies the client's ActivateSession signature (proof the client holds its own cert's private key) and rejects a missing/invalid one on a secured channel. Success = a real Ignition (and/or UAExpert/Kepware) client completes a Basic256Sha256/SignAndEncrypt session.

## Scope

**In (three conformance fixes; the None/Anonymous path stays byte-identical throughout):**

1. **CreateSession `serverSignature`** (`opcua_session.dart`, CreateSessionResponse writer ~`:1077-1083`). Today both the signature algorithm and signature ByteStrings are written `null`. Capture the `clientCertificate` (ByteString DER) and `clientNonce` (ByteString) from the CreateSessionRequest (currently skipped ~`:1041`). On a **secured** channel, write a real `SignatureData`:
   - `algorithm` = `http://www.w3.org/2001/04/xmldsig-more#rsa-sha256`
   - `signature` = `rsaPkcs1Sha256Sign(serverPrivateKey, clientCertificateDer ++ clientNonce)` (byte concatenation, in that order).
   A None channel continues to write `null`/`null` (byte-identical to today).

2. **KeyUsage + ExtendedKeyUsage on the app cert** (`opcua_certificate.dart`, `_buildExtensions`). Add two X.509 v3 extensions alongside the existing SubjectAltName, mirroring the vendored Rust `crypto/x509.rs` for exact encoding/criticality:
   - **KeyUsage** — OID `2.5.29.15`, **critical**, BIT STRING with `digitalSignature (bit 0) + nonRepudiation/contentCommitment (bit 1) + keyEncipherment (bit 2) + dataEncipherment (bit 3)`.
   - **ExtendedKeyUsage** — OID `2.5.29.37`, non-critical, `SEQUENCE OF OID { serverAuth 1.3.6.1.5.5.7.3.1, clientAuth 1.3.6.1.5.5.7.3.2 }`.
   These change the cert DER, so its SHA-1 thumbprint changes; on-device certs regenerate via the existing Regenerate control (or a fresh install generates the new format). The UI/docs note that connecting a strict client requires a regenerated cert.

3. **Verify the client's ActivateSession signature** (`opcua_session.dart`, `_handleActivateSession` ~`:1129-1134`). The `clientSignature` (`SignatureData`) is currently read and discarded. On a **secured** channel, verify it against the client certificate's public key (captured during the OPN handshake, available on the secure channel as `clientCertificate`) over `serverCertificateDer ++ serverNonce` — where `serverCertificateDer` is this server's own app cert DER (the value sent as `serverCertificate` in CreateSessionResponse) and `serverNonce` is exactly the nonce issued in that CreateSessionResponse. On a missing or invalid signature, reject with `Bad_ApplicationSignatureInvalid` (fall back to the existing rejection path). A None channel stays lenient (byte-identical — no signature is required/verified).

**Out (deferred, unchanged from the security workstream's deferrals):** per-ActivateSession serverNonce rotation (v1 reuses the CreateSession-issued nonce — see Note below); X.509 user identity tokens; a managed client-cert trust-list (auto-trust stays); deprecated policies; CRL/CA-chain validation.

## Data flow / state (small, contained additions)

The secured session must remember three values it already has access to at different points:
- `clientCertificateDer` + `clientNonce` — read from the CreateSessionRequest, used to **produce** the serverSignature in that same response.
- the issued `serverNonce` — used later to **verify** the ActivateSession clientSignature over `serverCertDer ++ serverNonce`. (This is the same nonce already tracked for the username/password OAEP path, so no new nonce bookkeeping beyond retaining it until ActivateSession.)
The client certificate public key for verification comes from the existing `OpcSecureChannel.clientCertificate` (parsed during OPN). The server private key + cert DER are already injected into the session (security workstream).

## Wire facts (verify against OPC UA Part 4 §5.6.2–5.6.3 and the vendored Rust `opcua-0.12.0`)

- `SignatureData` = `{ algorithm: String, signature: ByteString }` (`types/signature_data.rs`). Both null on a None channel; both populated on a secured channel.
- **serverSignature** covers `clientCertificate ++ clientNonce`; **clientSignature** covers `serverCertificate ++ serverNonce` — the two are mirror images, each signed by the sender's private key and verified with the sender's certificate's public key. Reference: `crypto/security_policy.rs` (`create_signature_data` / `verify_signature_data`) and `client/session/session.rs` (how the client builds its ActivateSession signature and expects the server's).
- Basic256Sha256 asymmetric signature = RSA PKCS#1 v1.5 + SHA-256, algorithm URI `http://www.w3.org/2001/04/xmldsig-more#rsa-sha256` — already implemented as `rsaPkcs1Sha256Sign`/`rsaPkcs1Sha256Verify` in `opcua_crypto.dart`.
- KeyUsage/EKU encoding: mirror `crypto/x509.rs` exactly for the BIT STRING unused-bits count and the critical flags; validate the emitted DER with `openssl x509 -text -noout` (as Task 2 of the security workstream did).

## Testing (same bar as the security workstream)

1. **Certificate tests** (`opcua_certificate_test.dart`): the built cert DER now contains the KeyUsage extension (OID 2.5.29.15, critical, the four bits) and ExtendedKeyUsage (OID 2.5.29.37, serverAuth+clientAuth); the existing SubjectAltName + round-trip + thumbprint tests still pass (the thumbprint value changes — update any fixture that pinned it); `openssl x509 -text` shows both extensions.
2. **CreateSession serverSignature test** (`opcua_session_test.dart`): on a secured session, the CreateSessionResponse's `SignatureData` has the rsa-sha256 algorithm URI and a signature that **verifies** (via `rsaPkcs1Sha256Verify` with the server cert's public key) over `clientCertDer ++ clientNonce`; on a None session both fields stay null.
3. **ActivateSession clientSignature test** (`opcua_session_test.dart`): a client ActivateSession carrying a correctly-computed signature over `serverCertDer ++ serverNonce` (built in-test with a known client key) is **accepted**; a tampered/wrong/missing signature on a secured channel is **rejected** with `Bad_ApplicationSignatureInvalid`; a None-channel ActivateSession is unaffected (byte-identical).
4. **Machine-proof E2E** (`tool/opcua_e2e.sh`): the existing live Rust `opcua` secure leg still prints `OPCUA SECURITY PROBE PASS` — the crate sends a real ActivateSession signature, so this is now a **live regression guard** for fix #3 (a broken verification rejects the real client and fails the probe). The None/Anonymous + subscription legs still pass.
5. **Regression:** full `flutter test`; `flutter analyze` ZERO; `flutter build web --release` compiles; WS6 lossless round-trip green; the None + Anonymous path byte-identical to before.
6. **Strict-client validation (user-in-the-loop):** the user connects Ignition/UAExpert/Kepware to the Basic256Sha256/SignAndEncrypt endpoint (after regenerating the cert) and reports the exact rejection error if any; iterate until the strict client completes a session.

## Global constraints

- No vendor branding; OPC UA / IEEE terms fine. Dark theme; zero `flutter analyze` warnings; brace all bodies; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/opcua/**` stays PURE Dart (pointycastle/asn1lib allowed); no `dart:io`/Flutter added there. Only the already-`dart:io` host/cert-store files are unchanged in that respect.
- The server never crashes on malformed/hostile input: a malformed clientSignature/clientCertificate → a clean `Bad_*` status or dropped connection, never an uncaught throw.
- Additive/back-compat: the None + Anonymous path is byte-identical; secured behavior only gains the signature/extension bytes strict clients require. No new dependencies. dart2js-safe (no `getInt64`/`setInt64`; the crypto primitives already exist). WS6 round-trip green.
- No config/model changes expected (these are wire-conformance fixes, not new options), so no persistence changes.

## Note (v1 simplification carried forward)

OPC UA prefers a **fresh serverNonce per ActivateSession** for replay protection; v1 reuses the CreateSession-issued serverNonce (matches current behavior — both the Rust client and Ignition sign over whatever serverNonce the server sent, so it is accepted). Full per-ActivateSession nonce rotation is deferred as a later hardening and does not block strict-client acceptance.

## Phasing (one spec → ~4 plan tasks)

1. **Cert extensions** — add KeyUsage + ExtendedKeyUsage to `opcua_certificate.dart` (`_buildExtensions`); cert tests + openssl validation; fix any thumbprint fixture.
2. **serverSignature** — capture clientCert+clientNonce in CreateSession; compute + write the secured `SignatureData`; unit test (verifies against server pubkey); None byte-identical.
3. **ActivateSession signature verification** — verify clientSignature over serverCert++serverNonce on secured channels, reject invalid; unit tests (accept correct / reject tampered); None byte-identical.
4. **E2E regression + docs + Ignition-iterate** — confirm the live Rust probe still passes (now guarding fix #3), full gates, update `docs/protocols/opcua.md` + ROADMAP (mark the three gaps closed; keep external-strict-client interop as the remaining-to-confirm-with-the-user item until Ignition is verified), then the user-in-the-loop Ignition validation + any fixes it surfaces.
