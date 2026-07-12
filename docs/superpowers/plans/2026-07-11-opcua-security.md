# OPC UA Security (Basic256Sha256 + user auth) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the in-app OPC UA server real transport security — advertise and honor Basic256Sha256 (Sign + SignAndEncrypt) alongside None, authenticate sessions with Anonymous or username/password, and identify with a persisted self-signed X.509 application instance certificate.

**Architecture:** A new pure-Dart crypto layer (`opcua_crypto.dart` over `pointycastle`, `opcua_certificate.dart` over `asn1lib`) provides RSA/AES/SHA/HMAC/OAEP + P_SHA256 + X.509. A pure `opcua_secure_channel.dart` state machine sits between chunk-header parsing and body parsing: it verifies+decrypts inbound OPN/MSG and signs+encrypts outbound chunks. A `dart:io` `opcua_cert_store.dart` service generates+persists the app key/cert on first run. `opcua_session.dart`/`opcua_transport.dart`/`opcua_host.dart` are wired to route secured chunks through the channel and to decode username/password tokens.

**Tech Stack:** Dart/Flutter (`mobile/`), pure-Dart `pointycastle` + `asn1lib`, `path_provider` for key storage, existing `opcua_binary.dart` reader/writer, Rust `opcua` crate (`gateway/examples/opcua_probe.rs`) for the machine-proof E2E.

**THE AUTHORITATIVE WIRE + CRYPTO REFERENCE (read before every crypto/channel task):** a vendored copy of the Rust `opcua-0.12.0` crate is on disk and is the byte-exact spec this codebase already cross-checks against. Cite and mirror it:
- `C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/crypto/security_policy.rs` — Basic256Sha256 algorithm identifiers, key sizes, nonce length, **P_SHA / derive_keys**, asymmetric/symmetric sign+encrypt+decrypt+verify, padding.
- `.../src/crypto/{pkey.rs,aeskey.rs,hash.rs,thumbprint.rs,x509.rs,user_identity.rs}.rs` — RSA/AES/SHA/HMAC/thumbprint/X.509/user-token specifics.
- `.../src/core/comms/secure_channel.rs` and `secure_channel.rs` tests under `.../src/core/tests/secure_channel.rs` and `.../src/crypto/tests/{crypto.rs,security_policy.rs,authentication.rs}` — **known-answer test vectors** to reuse verbatim.
- `.../src/server/comms/secure_channel_service.rs` — the server-side OPN handling flow.

## Global Constraints

- No vendor branding; OPC UA / IEEE terms fine. Dark theme; zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; brace all bodies; `const`; `withValues(alpha:)`.
- `mobile/lib/protocols/opcua/**` stays PURE Dart — `pointycastle`/`asn1lib` are pure Dart and allowed there; NO `dart:io`/Flutter imports in that directory. Only `opcua_host.dart` and the new `opcua_cert_store.dart` use `dart:io`/storage.
- The server NEVER crashes on malformed/hostile secured input (bad signature/padding/cert → a clean error status or dropped connection, never an uncaught exception). Every parser guards length and returns/throws a typed error the caller converts to a status.
- **Secrets:** the app private key persists ONLY to app-local device storage, never to project files, never committed (keep `gateway/pki` and any key/cert artifacts gitignored). User passwords are in-memory/app-local only, never written to committed project JSON (same rule as the MQTT broker password).
- Additive persistence: every new config field defaults so older projects round-trip unchanged; the WS6 lossless round-trip test stays green. The app is **byte-identical on the wire when security is disabled** (`securityModes == ['None']`) — the WS19/WS20 None + Anonymous behavior is preserved exactly.
- Little-endian wire; dart2js-safe (no `getInt64`/`setInt64`); `flutter build web --release` must compile (pointycastle/asn1lib compile to JS).
- Basic256Sha256 concrete algorithms (verify against `crypto/security_policy.rs`): asymmetric signature = RSA PKCS#1 v1.5 + SHA-256; asymmetric encryption = RSA-OAEP + MGF1-SHA1 (plaintext block = 214, cipher block = 256 for RSA-2048); symmetric signature = HMAC-SHA256; symmetric encryption = AES-256-CBC; thumbprint = SHA-1(DER); nonce = 32 bytes; symmetric key sizes signing=32/encrypting=32/iv=16.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `mobile/pubspec.yaml` | MODIFY | add `pointycastle`, `asn1lib`, `path_provider` deps. |
| `mobile/lib/protocols/opcua/opcua_crypto.dart` | CREATE | pure crypto primitives + P_SHA256 (pointycastle). |
| `mobile/lib/protocols/opcua/opcua_certificate.dart` | CREATE | self-signed X.509 build + peer parse + thumbprint (asn1lib). |
| `mobile/lib/protocols/opcua/opcua_secure_channel.dart` | CREATE | asymmetric+symmetric secure-channel state machine. |
| `mobile/lib/services/opcua_cert_store.dart` | CREATE | first-run keygen + persist/load/regenerate (dart:io). |
| `mobile/lib/protocols/opcua/opcua_transport.dart` | MODIFY | header-only parse + raw remainder for secured chunks; secured build helpers. |
| `mobile/lib/protocols/opcua/opcua_session.dart` | MODIFY | secured OPN handshake; endpoint advertisement; username/password token decode. |
| `mobile/lib/services/opcua_host.dart` | MODIFY | load cert store; per-connection secure channel; status. |
| `mobile/lib/models/protocol_settings.dart` | MODIFY | `OpcUaProtocolConfig.securityModes`/`credentials`/`allowAnonymous` (additive). |
| `mobile/lib/screens/gateway_screen.dart` | MODIFY | OPC UA card: policy toggles, credentials editor, thumbprint. |
| `gateway/examples/opcua_probe.rs` + `tool/opcua_e2e.sh` | MODIFY | secure connect + user-auth E2E. |
| `docs/protocols/OPCUA.md`, ROADMAP | MODIFY | document the security layer. |

---

## Task 1: Dependencies + crypto primitives (`opcua_crypto.dart`)

**Files:**
- Modify: `mobile/pubspec.yaml`
- Create: `mobile/lib/protocols/opcua/opcua_crypto.dart`
- Test: `mobile/test/opcua_crypto_test.dart`

**Reference (read first):** vendored `crypto/security_policy.rs` (`derive_keys`, `PSHA`), `crypto/hash.rs` (sha256/hmac_sha256), `crypto/tests/crypto.rs` + `crypto/tests/security_policy.rs` (KNOWN-ANSWER VECTORS — reuse the exact input/expected bytes as your Dart test fixtures).

**Interfaces produced (later tasks depend on these EXACT signatures):**
```dart
// All Uint8List in/out; no dart:io/Flutter imports.
Uint8List sha256(Uint8List data);
Uint8List hmacSha256(Uint8List key, Uint8List data);
Uint8List sha1(Uint8List data);
Uint8List aes256CbcEncrypt(Uint8List key, Uint8List iv, Uint8List plaintext); // no padding added here
Uint8List aes256CbcDecrypt(Uint8List key, Uint8List iv, Uint8List ciphertext);
Uint8List rsaOaepSha1Encrypt(RSAPublicKey pub, Uint8List plaintext);   // single block (<=214B); caller blocks
Uint8List rsaOaepSha1Decrypt(RSAPrivateKey priv, Uint8List ciphertext); // single block (256B)
Uint8List rsaPkcs1Sha256Sign(RSAPrivateKey priv, Uint8List data);
bool rsaPkcs1Sha256Verify(RSAPublicKey pub, Uint8List data, Uint8List signature);
AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> generateRsa2048(SecureRandom rng);
SecureRandom fortunaRandom([List<int>? seed]); // FortunaRandom seeded; seed for deterministic tests
// OPC UA P_SHA256 (RFC 5246 §5 P_hash with HMAC-SHA256), producing `length` bytes.
Uint8List pSha256(Uint8List secret, Uint8List seed, int length);
```
(`RSAPublicKey`/`RSAPrivateKey`/`AsymmetricKeyPair`/`SecureRandom` are pointycastle types — export them or a thin wrapper so callers need not import pointycastle directly; a small `OpcRsaKeyPair` wrapper holding both keys is acceptable.)

- [ ] **Step 1: Add dependencies**

In `mobile/pubspec.yaml` under `dependencies:` add (use the latest 3.x/1.x compatible with the project's Dart SDK — the implementer resolves exact versions with `flutter pub get`):
```yaml
  pointycastle: ^3.9.1
  asn1lib: ^1.5.3
  path_provider: ^2.1.4
```
Run `cd mobile && flutter pub get`. Expected: resolves cleanly.

- [ ] **Step 2: Write failing known-answer tests**

Create `mobile/test/opcua_crypto_test.dart`. Port the vectors from the vendored `crypto/tests/crypto.rs` / `security_policy.rs` (SHA-256, HMAC-SHA256, AES-256-CBC, and especially a **P_SHA256** derivation vector). Include an RSA round-trip using a FIXED deterministic keypair (seed `fortunaRandom` with 32 constant bytes so keygen is reproducible in the test):
```dart
test('sha256 matches RFC 6234 "abc" vector', () {
  expect(hex(sha256(ascii('abc'))),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});
test('hmac-sha256 matches an RFC 4231 vector', () { /* ... key/data/expected from vendored tests */ });
test('P_SHA256 derives the expected key stream', () {
  // secret/seed/expected copied from crypto/tests/security_policy.rs
  final out = pSha256(secret, seed, expected.length);
  expect(out, expected);
});
test('AES-256-CBC round-trips and matches a NIST vector', () { /* encrypt==expected; decrypt==plaintext */ });
test('RSA-OAEP-SHA1 round-trips on a fixed 2048-bit key', () {
  final kp = generateRsa2048(fortunaRandom(List<int>.filled(32, 7)));
  final ct = rsaOaepSha1Encrypt(kp.publicKey, msg);       // msg <= 214 bytes
  expect(rsaOaepSha1Decrypt(kp.privateKey, ct), msg);
});
test('RSA PKCS1-SHA256 sign verifies, tamper fails', () {
  final kp = generateRsa2048(fortunaRandom(List<int>.filled(32, 7)));
  final sig = rsaPkcs1Sha256Sign(kp.privateKey, data);
  expect(rsaPkcs1Sha256Verify(kp.publicKey, data, sig), isTrue);
  expect(rsaPkcs1Sha256Verify(kp.publicKey, tamper(data), sig), isFalse);
});
```

- [ ] **Step 3: Run — expect FAIL** (`cd mobile && flutter test test/opcua_crypto_test.dart` → undefined functions).

- [ ] **Step 4: Implement `opcua_crypto.dart`**

Implement each function with pointycastle. Guidance (verify the exact pointycastle class names against the installed package source under `~/AppData/Local/Pub/Cache/hosted/pub.dev/pointycastle-*/lib`):
- `sha256`/`sha1`: `SHA256Digest`/`SHA1Digest` `.process(data)`.
- `hmacSha256`: `HMac(SHA256Digest(), 64)..init(KeyParameter(key))` then `.process(data)`.
- `aes256Cbc*`: `CBCBlockCipher(AESEngine())..init(forEncryption, ParametersWithIV(KeyParameter(key), iv))`, process block-by-block (caller guarantees 16-byte-multiple length; do NOT add PKCS7 padding — OPC UA padding is handled by the secure channel).
- `rsaOaepSha1*`: `OAEPEncoding.withSHA1(RSAEngine())` (or `OAEPEncoding(RSAEngine())` if that defaults to SHA-1 — CONFIRM the MGF/hash is SHA-1 to match Basic256Sha256) `..init(forEncryption, PublicKeyParameter/PrivateKeyParameter)`, `.process(block)`.
- `rsaPkcs1Sha256*`: `RSASigner(SHA256Digest(), '0609608648016503040201')` (the SHA-256 DigestInfo OID prefix) `..init(...)`, `generateSignature`/`verifySignature`.
- `generateRsa2048`: `RSAKeyGenerator()..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64), rng))`, `.generateKeyPair()`.
- `fortunaRandom`: `FortunaRandom()..seed(KeyParameter(seedBytes))`.
- `pSha256`: implement RFC 5246 P_hash with HMAC-SHA256: `A(0)=seed; A(i)=HMAC(secret, A(i-1)); output += HMAC(secret, A(i) ++ seed)` until `length` bytes, truncate.

- [ ] **Step 5: Run — expect PASS.** Then `cd mobile && flutter analyze` (No issues) and `flutter build web --release` (compiles — proves pointycastle is web-safe).

- [ ] **Step 6: Commit**
```bash
git add mobile/pubspec.yaml mobile/pubspec.lock mobile/lib/protocols/opcua/opcua_crypto.dart mobile/test/opcua_crypto_test.dart
git commit -m "feat(opcua): pure-Dart crypto primitives (RSA/AES/SHA/HMAC/OAEP + P_SHA256) via pointycastle"
```

---

## Task 2: X.509 certificate build/parse (`opcua_certificate.dart`)

**Files:**
- Create: `mobile/lib/protocols/opcua/opcua_certificate.dart`
- Test: `mobile/test/opcua_certificate_test.dart`

**Reference:** vendored `crypto/x509.rs` (cert fields, self-signed generation, the ApplicationUri SubjectAltName), `crypto/thumbprint.rs` (thumbprint = SHA-1 of DER).

**Interfaces produced:**
```dart
class OpcCertificate {
  final Uint8List der;            // the DER-encoded X.509 certificate
  final RSAPublicKey publicKey;   // extracted subject public key
  Uint8List get thumbprint;       // sha1(der)
}
/// Builds a self-signed X.509 v3 cert (SHA-256 signature) for [keyPair] with the
/// given [applicationUri] (as a URI SubjectAltName) and [commonName]. Returns the DER.
Uint8List buildSelfSignedCertificate({
  required OpcRsaKeyPair keyPair, required String applicationUri, required String commonName,
  required DateTime notBefore, required DateTime notAfter,
});
/// Parses a DER certificate → OpcCertificate (public key + thumbprint). Returns null on
/// malformed/oversized input (never throws). Enforces a sane max length (e.g. 8 KiB).
OpcCertificate? parseCertificate(Uint8List der);
```

- [ ] **Step 1: Write failing tests**
```dart
test('self-signed cert round-trips: build -> parse -> same public key + thumbprint', () {
  final kp = generateRsa2048(fortunaRandom(List<int>.filled(32, 9)));
  final der = buildSelfSignedCertificate(keyPair: kp, applicationUri: 'urn:softplc:sim',
    commonName: 'SoftPLC Simulator', notBefore: DateTime.utc(2020), notAfter: DateTime.utc(2040));
  final parsed = parseCertificate(der)!;
  expect(parsed.thumbprint, sha1(der));
  // public key modulus round-trips
  expect(parsed.publicKey.modulus, kp.publicKey.modulus);
});
test('parseCertificate returns null on garbage / oversized input', () {
  expect(parseCertificate(Uint8List.fromList([1,2,3])), isNull);
  expect(parseCertificate(Uint8List(9000)), isNull);
});
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement with asn1lib.** Build the TBSCertificate (version v3, serial, SHA256WithRSA algorithm id, issuer==subject Name with the commonName, validity, SubjectPublicKeyInfo from the RSA public key, and a SubjectAltName extension carrying the `applicationUri` as a uniformResourceIdentifier), DER-encode it, sign the TBS bytes with `rsaPkcs1Sha256Sign`, and wrap `[tbs, algId, BIT STRING signature]`. For parse: decode the outer SEQUENCE, extract SubjectPublicKeyInfo → `RSAPublicKey`, guard length. Mirror `crypto/x509.rs` for exact field choices. Keep it pure Dart (asn1lib only).

- [ ] **Step 4: Run — expect PASS.** analyze clean.

- [ ] **Step 5: Commit** `feat(opcua): self-signed X.509 build + peer-cert parse + SHA-1 thumbprint`.

---

## Task 3: Certificate store service (`opcua_cert_store.dart`)

**Files:**
- Create: `mobile/lib/services/opcua_cert_store.dart`
- Test: `mobile/test/opcua_cert_store_test.dart`

**Interfaces produced:**
```dart
class OpcAppIdentity { final OpcRsaKeyPair keyPair; final Uint8List certificateDer; Uint8List get thumbprint; }
class OpcUaCertStore {
  OpcUaCertStore({String? overrideDir}); // overrideDir for tests (temp dir)
  Future<OpcAppIdentity> loadOrCreate({required String applicationUri, required String commonName});
  Future<OpcAppIdentity> regenerate({required String applicationUri, required String commonName});
}
```

- [ ] **Step 1: Write failing test** (temp dir; no real device storage):
```dart
test('loadOrCreate generates then persists; second load returns same cert; regenerate replaces', () async {
  final dir = await Directory.systemTemp.createTemp('opcua_cert_test');
  final store = OpcUaCertStore(overrideDir: dir.path);
  final a = await store.loadOrCreate(applicationUri: 'urn:x', commonName: 'X');
  final b = await store.loadOrCreate(applicationUri: 'urn:x', commonName: 'X');
  expect(b.thumbprint, a.thumbprint); // persisted, not regenerated
  final c = await store.regenerate(applicationUri: 'urn:x', commonName: 'X');
  expect(c.thumbprint, isNot(a.thumbprint));
  await dir.delete(recursive: true);
});
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement.** `loadOrCreate`: resolve the storage dir (`overrideDir` if set, else `path_provider`'s `getApplicationSupportDirectory()` + `/opcua`); if `key.der` + `cert.der` exist, load them (parse the private key from stored PKCS#8/DER and the cert); else `generateRsa2048` (seed from `Random.secure()` bytes — NOT the deterministic test seed), `buildSelfSignedCertificate`, write both files (private key DER + cert DER), return. `regenerate`: same but always overwrite. Serialize the RSA private key deterministically (store modulus/privateExponent/p/q as DER or a simple length-prefixed encoding you also read back). This is the ONLY new file importing `dart:io`; keep pointycastle/cert calls via Tasks 1–2.

- [ ] **Step 4: Run — expect PASS.** analyze clean.

- [ ] **Step 5: Commit** `feat(opcua): app instance cert store — first-run keygen + persist/load/regenerate`.

---

## Task 4: Asymmetric secure channel — OPN handshake (`opcua_secure_channel.dart` part 1)

**Files:**
- Create: `mobile/lib/protocols/opcua/opcua_secure_channel.dart`
- Modify: `mobile/lib/protocols/opcua/opcua_transport.dart` (add a header-only parse + raw-remainder accessor; see Step 3)
- Test: `mobile/test/opcua_secure_channel_test.dart`

**Reference:** vendored `core/comms/secure_channel.rs` (`open_secure_channel`, asymmetric sign/encrypt/decrypt/verify, padding, the message-footer signature), `crypto/security_policy.rs` (`asymmetric_sign`/`asymmetric_encrypt`/`asymmetric_decrypt`/`asymmetric_verify`, `symmetric_...`), and `crypto/tests/security_policy.rs` for a full OPN encrypt/decrypt fixture.

**Interfaces produced:**
```dart
enum OpcSecurityMode { none, sign, signAndEncrypt }
class OpcSecureChannel {
  OpcSecureChannel({required OpcAppIdentity appIdentity});
  OpcSecurityMode get mode;
  OpcCertificate? get clientCertificate; // set after a secured OPN
  /// Given a parsed OPN chunk's securityPolicyUri, senderCertificate, and the RAW post-security-header
  /// bytes, verify+decrypt into the plaintext (sequenceHeader ++ body). Derives channel keys from the
  /// two nonces. Throws OpcSecurityException on any failure. For None, returns the bytes unchanged.
  Uint8List openFromClient({required String policyUri, required Uint8List? senderCertificate,
    required Uint8List rawAfterSecurityHeader, required Uint8List serverNonce, required Uint8List clientNonce});
  /// Build the SIGNED+ENCRYPTED OPN response chunk carrying [plaintextSequenceAndBody].
  Uint8List buildSecuredOpnResponse({required int secureChannelId, required int sequenceNumber,
    required int requestId, required Uint8List plaintextSequenceAndBody});
  // symmetric methods added in Task 5
}
```

- [ ] **Step 1: Add a header-only chunk parse to `opcua_transport.dart`.** The existing `parseChunk` reads the sequence header + body assuming plaintext, which is wrong for a secured chunk. Add a sibling that stops after the security header and exposes the raw remainder:
```dart
class OpcChunkHeader { // message type, chunk type, secureChannelId, security-header fields, and:
  final int securityHeaderEnd; // offset in the frame where the (encrypted) sequence-header+body+sig begin
}
/// Parses ONLY the chunk header + security header (all plaintext). The bytes from
/// [securityHeaderEnd]..size are the secured remainder for the secure channel to decrypt.
OpcChunkHeader parseChunkHeader(Uint8List frame);
```
Keep the existing `parseChunk` for None-mode/back-compat (Task 5 routes None through it unchanged).

- [ ] **Step 2: Write failing loopback test** (build a client-side OPN using a second keypair, feed it to the server channel, assert it verifies+decrypts; then the server response verifies+decrypts on the client side):
```dart
test('asymmetric OPN loopback: client-signed+encrypted OPN verifies & decrypts; response round-trips', () {
  final serverId = /* OpcAppIdentity from a fixed keypair via Task 2/3 helpers */;
  final clientKp = generateRsa2048(fortunaRandom(List<int>.filled(32, 11)));
  final clientCertDer = buildSelfSignedCertificate(keyPair: clientKp, applicationUri: 'urn:client', commonName: 'C', notBefore: DateTime.utc(2020), notAfter: DateTime.utc(2040));
  // Build a Basic256Sha256 OPN body (plaintext sequenceHeader ++ OpenSecureChannelRequest with clientNonce),
  // sign+encrypt it to the SERVER cert using a small test-only client-side helper mirroring the server's build.
  // Feed rawAfterSecurityHeader to channel.openFromClient(...) and assert the recovered plaintext equals the original.
  // Then channel.buildSecuredOpnResponse(...) and decrypt it with the CLIENT key -> assert body round-trips.
});
```
(A test-only client-side encrypt helper is acceptable in the test file; production only needs the server side. Prefer, if practical, reusing a fixture captured from the Rust crate's OPN test in `crypto/tests/security_policy.rs`.)

- [ ] **Step 3: Run — expect FAIL.**

- [ ] **Step 4: Implement the asymmetric path.** For `openFromClient` (Basic256Sha256): parse `senderCertificate` via `parseCertificate` → client public key (store as `clientCertificate`); RSA-OAEP-decrypt the remainder in 256-byte blocks with the server private key; the decrypted plaintext ends with a signature (256 bytes, RSA-PKCS1-SHA256 by the CLIENT over `[chunk header + security header + decrypted plaintext-minus-signature]` per Part 6 — mirror `secure_channel.rs`); verify it with the client public key; strip OPC UA padding; return the plaintext sequence-header+body. For `buildSecuredOpnResponse`: assemble the plaintext (sequence header ++ body), append OPC UA padding to reach an OAEP-plaintext-block multiple, sign `[headers ++ plaintext ++ padding]` with the server key, append the signature, RSA-OAEP-encrypt to the client key in blocks, and frame with `buildOpnChunk` (server cert in senderCertificate, sha1(client cert) in receiverCertificateThumbprint). Derive+store the symmetric keys via `pSha256` from (clientNonce, serverNonce) for Task 5. For None mode, pass through. **Follow `secure_channel.rs` exactly for padding byte(s), signature placement, and the signed-range definition — one wrong byte and a real client rejects the channel.**

- [ ] **Step 5: Run — expect PASS.** analyze clean; `flutter build web --release`.

- [ ] **Step 6: Commit** `feat(opcua): asymmetric secure channel — Basic256Sha256 OPN verify/decrypt + sign/encrypt`.

---

## Task 5: Symmetric message security + user auth + endpoint advertisement

**Files:**
- Modify: `mobile/lib/protocols/opcua/opcua_secure_channel.dart` (symmetric methods)
- Modify: `mobile/lib/protocols/opcua/opcua_session.dart` (OPN routing, endpoint list, activate/username token)
- Modify: `mobile/lib/models/protocol_settings.dart` (config — see Task 6 note; the SESSION reads it here)
- Test: `mobile/test/opcua_secure_channel_test.dart` (symmetric), `mobile/test/opcua_session_test.dart` (additions)

**Reference:** `crypto/security_policy.rs` (`symmetric_sign`/`verify`/`encrypt`/`decrypt`, `make_secure_channel_keys`/`derive_keys`), `crypto/user_identity.rs` (`legacy_password_decrypt` — the `length(4 LE) ++ password ++ serverNonce` OAEP layout), `types/service_types/user_name_identity_token.rs`.

**Interfaces produced (added to `OpcSecureChannel`):**
```dart
/// Verify (Sign/SignAndEncrypt) + decrypt (SignAndEncrypt) an inbound MSG/CLO remainder into plaintext
/// (sequenceHeader ++ body). Throws on MAC/padding failure. None → passthrough.
Uint8List openSymmetric(Uint8List rawAfterSecurityHeader);
/// Build a secured MSG chunk (sign + encrypt per mode) from plaintext body.
Uint8List buildSecuredMsg({required int secureChannelId, required int tokenId,
  required int sequenceNumber, required int requestId, required Uint8List body});
Uint8List get lastServerNonce; // for user-token decrypt verification
/// OAEP-decrypt a UserNameIdentityToken password ByteString with the server key; returns the UTF-8 password
/// (after stripping the 4-byte LE length prefix and validating the trailing serverNonce). Null on failure.
String? decryptUserPassword(Uint8List encryptedPassword);
```

- [ ] **Step 1: Write failing symmetric + user-auth tests.**
```dart
test('symmetric MSG round-trips (sign+encrypt) and a tampered MAC is rejected', () { /* derive keys via an OPN loopback, then buildSecuredMsg -> openSymmetric == body; flip a byte -> throws */ });
test('Renew derives fresh keys while old token still validates within lifetime', () { /* ... */ });
```
In `opcua_session_test.dart`:
```dart
test('EndpointDescription advertises exactly the enabled (policy,mode) set', () { /* config [None, Basic256Sha256/SignAndEncrypt] -> 2 endpoints with correct securityMode ints + policy URIs + server cert present for secure ones */ });
test('username/password activate succeeds with correct creds and is rejected with wrong password', () { /* ... */ });
test('anonymous refused when allowAnonymous=false', () { /* ... */ });
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement symmetric channel.** `openSymmetric`: for SignAndEncrypt, AES-256-CBC-decrypt with the client→server encrypting key/IV, verify the trailing HMAC-SHA256 (client→server signing key) over the pre-signature bytes, strip padding; for Sign, verify the HMAC over plaintext; for None, passthrough. `buildSecuredMsg`: append padding (SignAndEncrypt), compute HMAC (server→client signing key), append, AES-encrypt (SignAndEncrypt) with the server→client key/IV, frame via `buildMsgChunk`. Mirror `security_policy.rs` `symmetric_*`.

- [ ] **Step 4: Implement session wiring.** In `opcua_session.dart`:
  - `_writeEndpointDescription` → iterate the configured `securityModes`, emitting one EndpointDescription per (policy, mode) with the correct `securityMode` int (None=1/Sign=2/SignAndEncrypt=3), policy URI, the server certificate ByteString (the app cert DER for secure endpoints; null for None), and per-endpoint UserTokenPolicy list (anonymous if allowed + a username policy with `securityPolicyUri` = Basic256Sha256 when secured). Add a `_writeUserNameUserTokenPolicy`.
  - `_handleOpn` → when `chunk.securityPolicyUri != None`, route through the connection's `OpcSecureChannel.openFromClient` (Task 4) to get the plaintext, read the real `clientNonce`, generate a 32-byte `serverNonce`, and use `buildSecuredOpnResponse` with a non-null `serverNonce` in the body. Keep the None path exactly as today.
  - `_handleActivateSession` → decode the `UserIdentityToken` extension object: if `UserNameIdentityToken`, read `policyId`/`userName`/`password`(ByteString)/`encryptionAlgorithm`, call `channel.decryptUserPassword`, and validate `(userName, password)` against the configured credentials; anonymous only if `allowAnonymous`. Return `Bad_IdentityTokenRejected`/`Bad_UserAccessDenied` on mismatch.
  - MSG in/out for a secured channel must route through `openSymmetric`/`buildSecuredMsg` instead of raw `parseChunk`/`buildMsgChunk` — thread the channel into `_handleMsg`/`_wrapMsgResponse` (the host passes the channel per connection in Task 6; for now accept an injected `OpcSecureChannel?` on the session, null = None/back-compat).

- [ ] **Step 5: Run — expect PASS** (new + all existing WS19/WS20 session tests unchanged). analyze clean; `flutter build web --release`.

- [ ] **Step 6: Commit** `feat(opcua): symmetric MSG security + username/password auth + multi-policy endpoints`.

---

## Task 6: Host wiring + config model + UI

**Files:**
- Modify: `mobile/lib/models/protocol_settings.dart`
- Modify: `mobile/lib/services/opcua_host.dart`
- Modify: `mobile/lib/screens/gateway_screen.dart`
- Test: `mobile/test/protocol_settings_test.dart`, `mobile/test/opcua_host_test.dart` (if present), `mobile/test/gateway_screen_test.dart`

**Interfaces produced/consumed:** `OpcUaProtocolConfig.securityModes` (`List<String>`, default `['None']`), `.credentials` (`List<OpcUaUserCredential>` with `username`; password NOT serialized to committed JSON), `.allowAnonymous` (default true). `OpcUaHost` loads an `OpcAppIdentity` from `OpcUaCertStore` at `start()` and constructs one `OpcSecureChannel(appIdentity:)` per connection.

- [ ] **Step 1: Config additive round-trip test** (mirror the DNP3/Modbus additive pattern): `securityModes`/`allowAnonymous` round-trip; legacy JSON without them defaults to `['None']`/true; a credential's password is NOT present in `toJson()` output (usernames are). Assert the WS6 lossless guard (`serialization_roundtrip_test.dart`) still passes.

- [ ] **Step 2: Implement config.** Add the three fields to `OpcUaProtocolConfig` with additive `fromJson`/`toJson`/`defaults`. `OpcUaUserCredential.toJson` emits `username` only (never `password`). `defaults(p)` keeps `['None']` + `allowAnonymous:true` so existing projects are byte-identical.

- [ ] **Step 3: Host wiring test + impl.** At `OpcUaHost.start()`: build the `applicationUri` (reuse the existing server info), `loadOrCreate` the `OpcAppIdentity` from `OpcUaCertStore`, and give each accepted connection its own `OpcSecureChannel(appIdentity:)` wired into that connection's `OpcUaSession`. Expose `appCertThumbprint` (hex) and the active security policy/client thumbprint via the host's status for the UI. Never crash on malformed secured input (the session already returns error frames; ensure a thrown `OpcSecurityException` drops just the connection). Regenerating the cert is a host method delegating to `OpcUaCertStore.regenerate`.

- [ ] **Step 4: UI test + impl** (tab-aware — select the OPC UA tab). In the OPC UA card in `gateway_screen.dart`: add (a) security-policy/mode toggles bound to `securityModes` (None always on; Basic256Sha256 Sign and SignAndEncrypt as switches), (b) an `allowAnonymous` switch, (c) a username/password credential editor (add/remove rows; passwords held in the in-memory config only), and (d) a read-only app-cert thumbprint display with a "Regenerate certificate" button. Dark theme, `withValues(alpha:)`, no overflow at 320/360/1400. Assert the dropdown/toggles edit the config.

- [ ] **Step 5: Run** `flutter test` (full suite green — report count), `flutter analyze` (clean), `flutter build web --release`.

- [ ] **Step 6: Commit** `feat(opcua): security config (policies/credentials/anonymous) + host cert-store wiring + OPC UA-card UI`.

---

## Task 7: Rust `opcua` E2E (secure connect + user auth) + docs + final review

**Files:**
- Modify: `gateway/examples/opcua_probe.rs`, `tool/opcua_e2e.sh`
- Modify: `docs/protocols/OPCUA.md` (+ ROADMAP)

**Reference:** the vendored Rust `opcua` crate is the SAME crate the probe already uses — its client supports Basic256Sha256 + username/password directly.

- [ ] **Step 1: Read the existing probe + runner + fixture.** `gateway/examples/opcua_probe.rs` + `tool/opcua_e2e.sh` (mirror how the DNP3/Modbus E2E fixtures are launched — the OPC UA host fixture is a headless `dart run` entrypoint under `mobile/tool/`; find it). Preserve every existing None/Anonymous assertion.

- [ ] **Step 2: Extend the fixture** so the hosted project enables a secure endpoint (`securityModes` includes `Basic256Sha256/SignAndEncrypt`) and configures a known username/password credential, with the cert store pointed at a temp dir. Keep the existing None/Anonymous points/behavior.

- [ ] **Step 3: Add the secure-connect probe leg.** In `opcua_probe.rs`, add a second connection configured for `SecurityPolicy::Basic256Sha256` + `MessageSecurityMode::SignAndEncrypt` + `IdentityToken::UserName(user, pass)` (the crate auto-trusts/creates a client cert; point its PKI at a temp dir and set it to auto-trust the server cert). Run Browse + Read + Write and assert success. Keep the existing None leg. On full success print `OPCUA SECURITY PROBE PASS`.

- [ ] **Step 4: Runner + honest fallback.** Update `tool/opcua_e2e.sh` to run the extended probe; preserve/add the honest fallback (if cargo/crate can't run: `cargo build --example opcua_probe` + the Dart unit suite, and clearly report the live leg SKIPPED — never a fake pass). Mirror `tool/dnp3_e2e.sh`'s fallback.

- [ ] **Step 5: Run every gate** (report verbatim): `cd mobile && flutter test` (full suite), `flutter analyze`, `flutter build web --release`, `cd gateway && cargo build --examples`, `bash tool/opcua_e2e.sh` (→ `OPCUA SECURITY PROBE PASS` or honest fallback), and confirm `serialization_roundtrip_test.dart` green + the None/Anonymous leg still passes.

- [ ] **Step 6: Docs.** Update `docs/protocols/OPCUA.md`: security policies (None + Basic256Sha256 Sign/SignAndEncrypt), the asymmetric+symmetric handshake, P_SHA256, username/password auth, the persisted self-signed app cert + auto-trust, and the v1 deferrals (deprecated policies, X.509 user tokens, trust-list). Update the ROADMAP/phase tracker to mark OPC UA security done.

- [ ] **Step 7: Commit** `test(opcua): Rust opcua master secure-connect + user-auth E2E; docs; OPC UA security complete`.

- [ ] **Step 8: Whole-branch review.** Dispatch the final whole-branch code review (most capable model) over the full branch diff, focusing on crypto/wire correctness and the never-crash-on-hostile-input guarantee; address Critical/Important; complete via superpowers:finishing-a-development-branch.

---

## Self-Review

**Spec coverage:** policies None+Basic256Sha256 Sign/SignAndEncrypt → Tasks 4–5; RSA/AES/SHA/HMAC/OAEP/P_SHA256 → Task 1; X.509 self-signed + thumbprint + peer parse → Task 2; persisted app cert + auto-trust → Tasks 3/6 (auto-trust = `parseCertificate` used cryptographically, never rejected on trust); asymmetric OPN Issue/Renew → Task 4 (+ renew test in 5); symmetric MSG + token lifecycle → Task 5; Anonymous + username/password → Task 5; endpoint advertisement of enabled set → Task 5; config additive (securityModes/credentials/allowAnonymous, password-less persistence) → Task 6; UI toggles/credentials/thumbprint/regenerate → Task 6; Rust E2E + docs → Task 7. ✅

**Placeholder scan:** crypto internals (Task 1 pointycastle calls, Task 4/5 padding/signature byte layout) are specified by algorithm + the exact vendored Rust reference file to mirror + known-answer vectors, rather than reproduced byte-for-byte inline — deliberate, because the vendored `opcua-0.12.0` crate is the byte-exact spec-of-record this codebase already cross-checks against, and hand-copying crypto byte layouts into the plan would inject transcription bugs. Every such step names the reference file and the falsifiable test/vector that gates it. No `TBD`/"handle edge cases".

**Type consistency:** `OpcRsaKeyPair`/`OpcCertificate`/`OpcAppIdentity`/`OpcSecureChannel`/`OpcSecurityMode`/`OpcUaCertStore` names are consistent across Tasks 1–6; `securityModes`/`credentials`/`allowAnonymous` consistent Tasks 5–7; `pSha256`/`rsaOaepSha1*`/`rsaPkcs1Sha256*`/`buildSelfSignedCertificate`/`parseCertificate`/`openFromClient`/`buildSecuredOpnResponse`/`openSymmetric`/`buildSecuredMsg`/`decryptUserPassword` are defined once and consumed with the same signatures. The `parseChunkHeader`/`OpcChunkHeader` addition (Task 4) leaves the existing `parseChunk` intact for the None path.
