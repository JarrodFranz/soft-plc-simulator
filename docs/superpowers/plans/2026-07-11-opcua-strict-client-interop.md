# OPC UA Strict-Client Interop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three OPC UA conformance gaps a strict client (Ignition/Eclipse Milo/.NET) checks — CreateSession `serverSignature`, cert KeyUsage/ExtendedKeyUsage, and ActivateSession client-signature verification — so a real strict client completes a Basic256Sha256/SignAndEncrypt session.

**Architecture:** Three surgical wire-conformance changes to two existing pure-Dart files (`opcua_certificate.dart`, `opcua_session.dart`) plus two small methods on `opcua_secure_channel.dart`. No config/model/persistence changes; the None/Anonymous path stays byte-identical. All crypto reuses the shipped `opcua_crypto.dart` primitives; the secure channel already holds the server keyPair and the parsed client certificate.

**Tech Stack:** Dart/Flutter (`mobile/`), pure-Dart `pointycastle`/`asn1lib` (already deps), the existing OPC UA codec/session/channel, Rust `opcua` E2E (`tool/opcua_e2e.sh`) as a live regression guard, plus a user-in-the-loop Ignition validation.

**THE AUTHORITATIVE WIRE + CRYPTO REFERENCE:** the vendored Rust `opcua-0.12.0` crate on disk (`C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/`). Cite/mirror: `src/crypto/x509.rs` (KeyUsage/EKU extension encoding), `src/crypto/security_policy.rs` (`create_signature_data`/`verify_signature_data`, rsa-sha256), `src/types/service_types/signature_data.rs`, `src/client/session/session.rs` (how the client builds its ActivateSession signature).

## Global Constraints

- No vendor branding; OPC UA / IEEE terms fine. Zero `flutter analyze` warnings (`cd mobile && flutter analyze` → "No issues found!"). Brace all bodies; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/opcua/**` stays PURE Dart — no `dart:io`/Flutter imports added; pointycastle/asn1lib allowed.
- The server NEVER crashes on malformed/hostile input: a malformed clientSignature/clientCertificate → a clean `Bad_*` status or dropped connection, never an uncaught throw.
- Additive/back-compat: the **None + Anonymous path is byte-identical** — only the secured path gains signature/extension bytes. WS6 lossless round-trip stays green. No new dependencies. dart2js-safe (`flutter build web --release` compiles; no `getInt64`/`setInt64`).
- Basic256Sha256 asymmetric signature = RSA PKCS#1 v1.5 + SHA-256, algorithm URI `http://www.w3.org/2001/04/xmldsig-more#rsa-sha256` — already implemented as `rsaPkcs1Sha256Sign`/`rsaPkcs1Sha256Verify` in `opcua_crypto.dart`.
- `serverSignature` covers `clientCertificateDer ++ clientNonce`; `clientSignature` covers `serverCertificateDer ++ serverNonce` (mirror images). The `serverNonce` used to verify the clientSignature must be exactly the one issued in CreateSessionResponse.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `mobile/lib/protocols/opcua/opcua_certificate.dart` | MODIFY | add KeyUsage + ExtendedKeyUsage extensions to `_buildExtensions`. |
| `mobile/lib/protocols/opcua/opcua_secure_channel.dart` | MODIFY | add `signApplicationData` + `verifyClientSignature` (thin wrappers over the existing keyPair / parsed client cert). |
| `mobile/lib/protocols/opcua/opcua_session.dart` | MODIFY | CreateSession: capture clientCert+clientNonce, write real serverSignature; store the issued serverNonce; ActivateSession: verify clientSignature on secured channels. |
| `mobile/test/opcua_certificate_test.dart` | MODIFY | assert the new extensions (+ openssl in report). |
| `mobile/test/opcua_secure_channel_test.dart` | MODIFY | sign/verify helper tests. |
| `mobile/test/opcua_session_test.dart` | MODIFY | serverSignature verifies; ActivateSession accept/reject; None byte-identical. |
| `gateway/examples/opcua_probe.rs`, `tool/opcua_e2e.sh`, `docs/protocols/opcua.md`, `ROADMAP.md` | VERIFY/UPDATE | confirm the live probe still passes (now guards fix #3); docs. |

---

## Task 1: App-cert KeyUsage + ExtendedKeyUsage

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_certificate.dart` (`_buildExtensions`, ~`:217`)
- Test: `mobile/test/opcua_certificate_test.dart`

**Reference:** vendored `crypto/x509.rs` — the exact KeyUsage BIT STRING bits + criticality and the EKU OID set an OPC UA application-instance cert carries.

**Interfaces:**
- Consumes: existing `buildSelfSignedCertificate(...)` / `parseCertificate(...)` and the `_oidSubjectAltName` pattern in this file.
- Produces: the cert DER now also contains KeyUsage (OID `2.5.29.15`) + ExtendedKeyUsage (OID `2.5.29.37`). The cert thumbprint (SHA-1 of DER) CHANGES — any test that pinned a thumbprint value must be updated.

- [ ] **Step 1: Write the failing test**

Add to `mobile/test/opcua_certificate_test.dart`. Parse the emitted DER with asn1lib in-test (or assert on raw DER bytes) that the extensions are present:
```dart
test('self-signed cert carries KeyUsage (critical) + ExtendedKeyUsage(serverAuth,clientAuth)', () {
  final kp = generateRsa2048(fortunaRandom(List<int>.filled(32, 9)));
  final der = buildSelfSignedCertificate(keyPair: kp, applicationUri: 'urn:softplc:sim',
    commonName: 'SoftPLC Simulator', notBefore: DateTime.utc(2020), notAfter: DateTime.utc(2040));
  // KeyUsage OID 2.5.29.15 present, critical, with digitalSignature+nonRepudiation+keyEncipherment+dataEncipherment.
  expect(_derContainsOid(der, '2.5.29.15'), isTrue);
  // ExtendedKeyUsage OID 2.5.29.37 present, with serverAuth (1.3.6.1.5.5.7.3.1) + clientAuth (1.3.6.1.5.5.7.3.2).
  expect(_derContainsOid(der, '2.5.29.37'), isTrue);
  expect(_derContainsOid(der, '1.3.6.1.5.5.7.3.1'), isTrue);
  expect(_derContainsOid(der, '1.3.6.1.5.5.7.3.2'), isTrue);
  // Existing guarantees still hold:
  expect(parseCertificate(der)!.publicKey.modulus, kp.publicKey.modulus);
  expect(_derContainsOid(der, '2.5.29.17'), isTrue); // SubjectAltName still present
});
```
Provide a small `_derContainsOid(Uint8List der, String dottedOid)` test helper (encode the OID to its DER bytes and search, or walk the extensions SEQUENCE with asn1lib). Grep the existing test file first — if a thumbprint value is pinned anywhere, note it will change.

- [ ] **Step 2: Run — expect FAIL** (`cd mobile && flutter test test/opcua_certificate_test.dart` → the new extensions aren't emitted yet; a pinned-thumbprint test may also now fail — that's expected).

- [ ] **Step 3: Implement the extensions.** In `_buildExtensions(applicationUri)` add, alongside the SubjectAltName extension, two more `Extension` entries in the `[3] EXPLICIT` Extensions SEQUENCE, mirroring `crypto/x509.rs`:
  - **KeyUsage** — `SEQUENCE { OID 2.5.29.15, BOOLEAN TRUE (critical), OCTET STRING { BIT STRING <bits> } }` where the BIT STRING sets `digitalSignature(0)|nonRepudiation(1)|keyEncipherment(2)|dataEncipherment(3)` — i.e. the leading value byte `0xF0` with the correct DER unused-bits count (verify the exact BIT STRING bytes against `x509.rs`; asn1lib's `ASN1BitString` must emit the OPC UA-standard encoding).
  - **ExtendedKeyUsage** — `SEQUENCE { OID 2.5.29.37, OCTET STRING { SEQUENCE OF OID { 1.3.6.1.5.5.7.3.1, 1.3.6.1.5.5.7.3.2 } } }` (non-critical → omit the BOOLEAN, DEFAULT FALSE).
  Keep the existing SubjectAltName extension unchanged and emit all three in the Extensions SEQUENCE. Pure Dart (asn1lib only).

- [ ] **Step 4: Run — expect PASS.** Update any pinned-thumbprint fixture in the test file to the new value (or, better, assert `thumbprint == sha1(der)` dynamically rather than pinning a constant). `cd mobile && flutter analyze` (No issues).

- [ ] **Step 5: openssl sanity-check (report only).** In the implementer report, paste `openssl x509 -in <tmp.der> -inform DER -text -noout` output showing `X509v3 Key Usage: critical` (Digital Signature, Non Repudiation, Key Encipherment, Data Encipherment) and `X509v3 Extended Key Usage` (TLS Web Server Authentication, TLS Web Client Authentication) and the URI SAN. (Write the DER to a temp file via a throwaway `dart run` or the existing test's DER.)

- [ ] **Step 6: Commit**
```bash
git add mobile/lib/protocols/opcua/opcua_certificate.dart mobile/test/opcua_certificate_test.dart
git commit -m "feat(opcua): app cert carries KeyUsage(critical) + ExtendedKeyUsage(server/clientAuth) for strict clients"
```

---

## Task 2: CreateSession serverSignature

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_secure_channel.dart` (add `signApplicationData`)
- Modify: `mobile/lib/protocols/opcua/opcua_session.dart` (`_handleCreateSession`, `:1036-1085`)
- Test: `mobile/test/opcua_secure_channel_test.dart`, `mobile/test/opcua_session_test.dart`

**Reference:** `crypto/security_policy.rs` `create_signature_data`; `types/service_types/signature_data.rs`.

**Interfaces:**
- Consumes: `OpcSecureChannel` (holds the server `keyPair`); `rsaPkcs1Sha256Sign`/`rsaPkcs1Sha256Verify` from `opcua_crypto.dart`; the session's `_channelSecured`/`_secureChannel`.
- Produces: `Uint8List OpcSecureChannel.signApplicationData(Uint8List data)` → `rsaPkcs1Sha256Sign(serverPrivateKey, data)`; a public `const kRsaSha256SignatureUri = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256'` (add to `opcua_secure_channel.dart` or `opcua_session.dart` — wherever the session can reference it).

- [ ] **Step 1: Write the failing channel-method test**
```dart
test('signApplicationData produces a signature that verifies with the server public key', () {
  final kp = generateRsa2048(fortunaRandom(List<int>.filled(32, 3)));
  final certDer = buildSelfSignedCertificate(keyPair: kp, applicationUri: 'urn:s', commonName: 'S', notBefore: DateTime.utc(2020), notAfter: DateTime.utc(2040));
  final ch = OpcSecureChannel(keyPair: kp, certificateDer: certDer);
  final data = Uint8List.fromList([1, 2, 3, 4, 5]);
  final sig = ch.signApplicationData(data);
  expect(rsaPkcs1Sha256Verify(kp.publicKey, data, sig), isTrue);
});
```

- [ ] **Step 2: Write the failing session serverSignature test** in `opcua_session_test.dart`. Drive a secured OPN → CreateSession (reuse the existing secured-session scaffold), read the full CreateSessionResponse, extract the `SignatureData` (algorithm String + signature ByteString) that currently follows `serverSoftwareCertificates`, and assert:
```dart
// secured: algorithm is rsa-sha256 and the signature verifies over clientCertDer ++ clientNonce
expect(algorithm, 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256');
final signedData = Uint8List.fromList([...clientCertDerSentByTest, ...clientNonceSentByTest]);
expect(rsaPkcs1Sha256Verify(serverKeyPair.publicKey, signedData, signature), isTrue);
// None channel: both null (unchanged)
```
Use the client cert DER + clientNonce the test's CreateSessionRequest actually sent, and the server keypair the test's cert store / channel used.

- [ ] **Step 3: Run — expect FAIL** (`signApplicationData` undefined; serverSignature still null).

- [ ] **Step 4: Implement.**
  - In `opcua_secure_channel.dart`: add `Uint8List signApplicationData(Uint8List data) => rsaPkcs1Sha256Sign(_keyPair.privateKey, data);` (use the actual private-field name for the keyPair — grep the constructor). Add `const kRsaSha256SignatureUri = 'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256';` at library scope.
  - In `opcua_session.dart` `_handleCreateSession`: capture the two currently-discarded fields — change `:1040-1041` to `final clientNonce = reader.byteString(); final clientCertDer = reader.byteString();`. At the serverSignature write site (`:1081-1083`), for a secured channel compute and write the real SignatureData; for None keep null/null:
```dart
if (secureChannel != null && clientCertDer != null && clientNonce != null) {
  final signed = Uint8List.fromList([...clientCertDer, ...clientNonce]);
  w.string(kRsaSha256SignatureUri);
  w.byteString(secureChannel.signApplicationData(signed));
} else {
  w.string(null);
  w.byteString(null);
}
```
  Update the doc comment at `:1066-1069` (which currently says serverSignature "stays null") to describe the new behavior. Also store the issued serverNonce on the session for Task 3: add a field to `_SessionState` (e.g. `Uint8List? createSessionServerNonce`) and set it to `secureChannel?.serverNonce` here.

- [ ] **Step 5: Run — expect PASS** (channel + session tests). `cd mobile && flutter analyze`; `cd mobile && flutter build web --release`.

- [ ] **Step 6: Commit**
```bash
git add mobile/lib/protocols/opcua/opcua_secure_channel.dart mobile/lib/protocols/opcua/opcua_session.dart mobile/test/
git commit -m "feat(opcua): CreateSession serverSignature (RSA-SHA256 over clientCert||clientNonce) on secured channels"
```

---

## Task 3: Verify the client's ActivateSession signature

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_secure_channel.dart` (add `verifyClientSignature`)
- Modify: `mobile/lib/protocols/opcua/opcua_session.dart` (`_handleActivateSession`, `:1129-1141`; add the status constant)
- Test: `mobile/test/opcua_session_test.dart`

**Reference:** `crypto/security_policy.rs` `verify_signature_data`; `client/session/session.rs` (how the client signs `serverCert ++ serverNonce`).

**Interfaces:**
- Consumes: `OpcSecureChannel.clientCertificate` (parsed during OPN, has `.publicKey`); the session's `serverCertificateDer`, `_channelSecured`, and the `_SessionState.createSessionServerNonce` stored in Task 2.
- Produces: `bool OpcSecureChannel.verifyClientSignature(Uint8List signedData, Uint8List signature)` → false if no client cert, else `rsaPkcs1Sha256Verify(clientCertificate!.publicKey, signedData, signature)`; a new `OpcUaStatusCodes.badApplicationSignatureInvalid = 0x80590000` constant (if not already present — grep first).

- [ ] **Step 1: Write the failing tests** in `opcua_session_test.dart`, on the secured-session scaffold. Build the client's ActivateSession clientSignature in-test with a known client key: `sig = rsaPkcs1Sha256Sign(clientKey.privateKey, serverCertDer ++ createSessionServerNonce)` where `serverCertDer` and `createSessionServerNonce` are the exact values the server sent this test in CreateSessionResponse.
```dart
test('secured ActivateSession accepts a correct client signature and rejects a tampered one', () {
  // ... drive secured OPN + CreateSession, capture serverCertDer + serverNonce from the response ...
  // GOOD: correct signature over serverCertDer ++ serverNonce -> ActivateSessionResponse (Good)
  // BAD: flip a byte of the signature -> ServiceFault Bad_ApplicationSignatureInvalid
  // MISSING: null/empty signature on a secured channel -> Bad_ApplicationSignatureInvalid
});
test('None-channel ActivateSession is unaffected (no signature required)', () { /* existing anonymous/None path still Good */ });
```
(The client cert is the one presented in the OPN handshake — reuse the client keypair/cert the secured-scaffold already builds.)

- [ ] **Step 2: Run — expect FAIL** (no verification yet; a bad signature is currently accepted).

- [ ] **Step 3: Implement.**
  - In `opcua_secure_channel.dart`: `bool verifyClientSignature(Uint8List signedData, Uint8List signature) { final c = clientCertificate; if (c == null) { return false; } return rsaPkcs1Sha256Verify(c.publicKey, signedData, signature); }`.
  - In `opcua_session.dart`: add `static const int badApplicationSignatureInvalid = 0x80590000;` to `OpcUaStatusCodes` (grep to confirm it's absent). In `_handleActivateSession`, capture the currently-discarded clientSignature (`:1130-1131`) → `final clientSigAlgorithm = reader.string(); final clientSig = reader.byteString();`. On a **secured** channel, before the identity-token auth, verify it:
```dart
if (_channelSecured) {
  final nonce = _session!.createSessionServerNonce;
  final chan = _secureChannel;
  if (clientSig == null || clientSig.isEmpty || nonce == null || chan == null ||
      !chan.verifyClientSignature(
          Uint8List.fromList([...serverCertificateDer, ...nonce]), Uint8List.fromList(clientSig))) {
    return _fault(chunk, requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badApplicationSignatureInvalid);
  }
}
```
  Keep the None path exactly as today (no verification). Ensure nothing throws on a malformed/short signature — `rsaPkcs1Sha256Verify` already returns false on bad input; the `try/catch` in `onBytes` remains the backstop.

- [ ] **Step 4: Run — expect PASS** (accept correct / reject tampered / reject missing / None unaffected). `flutter analyze`; `flutter build web --release`.

- [ ] **Step 5: Commit**
```bash
git add mobile/lib/protocols/opcua/opcua_secure_channel.dart mobile/lib/protocols/opcua/opcua_session.dart mobile/test/opcua_session_test.dart
git commit -m "feat(opcua): verify client ActivateSession signature on secured channels (reject invalid)"
```

---

## Task 4: E2E regression + docs

**Files:**
- Verify: `gateway/examples/opcua_probe.rs`, `tool/opcua_e2e.sh` (likely no change — the crate already sends a real ActivateSession signature)
- Modify: `docs/protocols/opcua.md`, `ROADMAP.md`
- Modify (if needed): the Dart E2E fixture `mobile/tool/opcua_host_probe.dart` (only if it hard-codes an app cert without the new extensions — it generates the identity inline via `buildSelfSignedCertificate`, so it gets the extensions automatically; confirm)

- [ ] **Step 1: Run the full gate set** (report each verbatim):
```bash
cd mobile && flutter test          # full suite green (report count)
cd mobile && flutter analyze       # No issues found
cd mobile && flutter build web --release
cd gateway && cargo build --examples
bash tool/opcua_e2e.sh             # must still print OPCUA SECURITY PROBE PASS
```
The live probe is now a **regression guard for Task 3**: the Rust `opcua` client sends a genuine ActivateSession signature, so if the server's new verification is wrong it will reject the real client and the probe fails. If the probe fails, that is a real bug in Task 2/3 (the signed range or the serverNonce echoed) — debug it (capture the exact client error) before proceeding; do NOT loosen the probe. Also confirm the None/Anonymous + subscription legs still pass and `serialization_roundtrip_test.dart` is green.

- [ ] **Step 2: Docs.** Update `docs/protocols/opcua.md`'s "Known limitations" / security section: the three gaps are now CLOSED — `serverSignature` is sent, the app cert carries KeyUsage/ExtendedKeyUsage, and the client's ActivateSession signature is verified. Note that a strict client requires a **regenerated cert** (existing on-device certs predating this change lack the extensions — use the Regenerate control), and keep the v1 note that the CreateSession serverNonce is reused for the ActivateSession signature (fresh-per-activation rotation deferred). Update `ROADMAP.md` Phase 4: mark the strict-client conformance gaps closed; keep the external-strict-client (Ignition/UAExpert/Kepware) confirmation as ⏳ **pending the user's live test** (it is not "done" until the user confirms Ignition connects).

- [ ] **Step 3: Commit**
```bash
git add docs/protocols/opcua.md ROADMAP.md mobile/
git commit -m "test(opcua): confirm live Rust E2E guards client-signature verify; docs — strict-client gaps closed"
```

- [ ] **Step 4: Whole-branch review + finish.** Dispatch the final whole-branch code review (most capable model) focusing on the signed-range correctness (serverSignature over clientCert||clientNonce; clientSignature over serverCert||serverNonce with the CreateSession-issued nonce), None byte-identity, and never-crash. Address Critical/Important, then complete via superpowers:finishing-a-development-branch.

- [ ] **Step 5: Hand off for Ignition validation (user-in-the-loop, post-merge).** After merge, the user regenerates the app cert (OPC UA card → Regenerate) and connects Ignition/UAExpert/Kepware to the Basic256Sha256/SignAndEncrypt endpoint. If the strict client rejects, capture the exact error and open a focused follow-up fix (this plan's spec `docs/superpowers/specs/2026-07-11-opcua-strict-client-interop-design.md` lists the likely culprits). Only then mark ROADMAP Phase 4's external-client confirmation ✅.

---

## Self-Review

**Spec coverage:** serverSignature → Task 2; KeyUsage/EKU → Task 1; ActivateSession client-signature verification → Task 3; None byte-identity → asserted in Tasks 2 & 3; unit tests (serverSignature verifies, cert carries extensions + openssl, accept/reject client sig) → Tasks 1–3; live Rust E2E regression guard + docs → Task 4; user-in-the-loop Ignition validation → Task 4 Step 5. ✅ All spec sections map to a task.

**Placeholder scan:** no `TBD`/"handle edge cases". The KeyUsage BIT STRING exact bytes and the asn1lib extension-encoding calls are specified by intent + the exact vendored `x509.rs` reference + an openssl validation gate (rather than hand-copied DER), because the asn1lib BIT STRING unused-bits encoding must be confirmed against the installed package and the authoritative crate — the same approach the security workstream used for wire-exact bytes, and it is gated by a falsifiable openssl check.

**Type consistency:** `signApplicationData(Uint8List)→Uint8List`, `verifyClientSignature(Uint8List,Uint8List)→bool`, `kRsaSha256SignatureUri`, `OpcUaStatusCodes.badApplicationSignatureInvalid`, and `_SessionState.createSessionServerNonce` are each defined once (Tasks 2–3) and consumed with the same signatures. serverSignature signs `clientCertDer ++ clientNonce`; clientSignature verifies over `serverCertificateDer ++ createSessionServerNonce` — the mirror is consistent across Tasks 2 and 3. Task 1's thumbprint-change caveat is flagged so a pinned fixture doesn't silently break a later task.
