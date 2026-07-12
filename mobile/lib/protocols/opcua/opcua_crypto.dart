// Pure-Dart OPC UA crypto primitives for the Basic256Sha256 security policy.
//
// This file is the byte-exact foundation of the OPC UA security workstream.
// It intentionally imports ONLY pointycastle + dart:typed_data/dart:math so it
// stays pure Dart (no dart:io / Flutter) and dart2js/web-safe.
//
// Basic256Sha256 algorithm bindings (per OPC UA Part 7 / the vendored
// `opcua-0.12.0` Rust crate this codebase cross-checks against):
//   - AsymmetricEncryptionAlgorithm : RSA-OAEP with MGF1-SHA1  (SHA-1, NOT SHA-256)
//   - AsymmetricSignatureAlgorithm  : RSA PKCS#1 v1.5 with SHA-256
//   - SymmetricEncryptionAlgorithm  : AES-256-CBC
//   - SymmetricSignatureAlgorithm   : HMAC-SHA256
//   - KeyDerivationAlgorithm        : P-SHA256 (RFC 5246 P_hash / HMAC-SHA256)

import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// Re-export the pointycastle key/random types so callers in later tasks need
// not import pointycastle directly.
export 'package:pointycastle/export.dart'
    show RSAPublicKey, RSAPrivateKey, AsymmetricKeyPair, SecureRandom;

/// Immutable holder for a generated RSA keypair, so callers can pass a single
/// value around without depending on pointycastle's generic pair type.
class OpcRsaKeyPair {
  const OpcRsaKeyPair(this.publicKey, this.privateKey);

  final RSAPublicKey publicKey;
  final RSAPrivateKey privateKey;
}

/// SHA-256 digest of [data].
Uint8List sha256(Uint8List data) => SHA256Digest().process(data);

/// SHA-1 digest of [data].
Uint8List sha1(Uint8List data) => SHA1Digest().process(data);

/// HMAC-SHA256 of [data] under [key] (32-byte output).
Uint8List hmacSha256(Uint8List key, Uint8List data) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  return mac.process(data);
}

/// AES-256-CBC encryption. [plaintext] length MUST be a multiple of 16 (the
/// caller / secure channel is responsible for OPC UA padding). No PKCS7
/// padding is added here.
Uint8List aes256CbcEncrypt(Uint8List key, Uint8List iv, Uint8List plaintext) {
  return _aes256Cbc(forEncryption: true, key: key, iv: iv, input: plaintext);
}

/// AES-256-CBC decryption. [ciphertext] length MUST be a multiple of 16.
Uint8List aes256CbcDecrypt(Uint8List key, Uint8List iv, Uint8List ciphertext) {
  return _aes256Cbc(forEncryption: false, key: key, iv: iv, input: ciphertext);
}

Uint8List _aes256Cbc({
  required bool forEncryption,
  required Uint8List key,
  required Uint8List iv,
  required Uint8List input,
}) {
  const blockSize = 16;
  if (input.length % blockSize != 0) {
    throw ArgumentError.value(
      input.length,
      'input.length',
      'AES-256-CBC requires a multiple of $blockSize bytes',
    );
  }
  final cipher = CBCBlockCipher(AESEngine())
    ..init(forEncryption, ParametersWithIV(KeyParameter(key), iv));
  final out = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += blockSize) {
    cipher.processBlock(input, offset, out, offset);
  }
  return out;
}

/// RSA-OAEP (MGF1-SHA1) encryption of a SINGLE block. For a 2048-bit key the
/// plaintext must be <= 214 bytes; the caller performs block chunking. Returns
/// one 256-byte ciphertext block.
Uint8List rsaOaepSha1Encrypt(RSAPublicKey pub, Uint8List plaintext) {
  final oaep = OAEPEncoding.withSHA1(RSAEngine())
    ..init(true, PublicKeyParameter<RSAPublicKey>(pub));
  return oaep.process(plaintext);
}

/// RSA-OAEP (MGF1-SHA1) decryption of a SINGLE 256-byte ciphertext block.
Uint8List rsaOaepSha1Decrypt(RSAPrivateKey priv, Uint8List ciphertext) {
  final oaep = OAEPEncoding.withSHA1(RSAEngine())
    ..init(false, PrivateKeyParameter<RSAPrivateKey>(priv));
  return oaep.process(ciphertext);
}

/// RSA PKCS#1 v1.5 signature over SHA-256(data). The hex string is the DER
/// DigestInfo prefix (OID) for SHA-256.
Uint8List rsaPkcs1Sha256Sign(RSAPrivateKey priv, Uint8List data) {
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(priv));
  return signer.generateSignature(data).bytes;
}

/// Verifies an RSA PKCS#1 v1.5 / SHA-256 [signature] over [data].
bool rsaPkcs1Sha256Verify(RSAPublicKey pub, Uint8List data, Uint8List signature) {
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(false, PublicKeyParameter<RSAPublicKey>(pub));
  try {
    return signer.verifySignature(data, RSASignature(signature));
  } catch (_) {
    // A malformed/short signature can throw during RSA decoding; treat any
    // such failure as "not verified" rather than propagating.
    return false;
  }
}

/// Generates a 2048-bit RSA keypair (public exponent 65537) using [rng].
/// Tests seed [rng] deterministically; production uses a secure random.
OpcRsaKeyPair generateRsa2048(SecureRandom rng) {
  final generator = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
      rng,
    ));
  final pair = generator.generateKeyPair();
  return OpcRsaKeyPair(
    pair.publicKey as RSAPublicKey,
    pair.privateKey as RSAPrivateKey,
  );
}

/// Returns a [FortunaRandom]. If [seed] is supplied it is used verbatim as the
/// Fortuna seed key (for reproducible test keygen); otherwise a 32-byte seed is
/// drawn from `Random.secure()`.
SecureRandom fortunaRandom([List<int>? seed]) {
  final seedBytes = seed != null
      ? Uint8List.fromList(seed)
      : _secureSeed(32);
  return FortunaRandom()..seed(KeyParameter(seedBytes));
}

Uint8List _secureSeed(int length) {
  final rng = Random.secure();
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// OPC UA P_SHA256 key-derivation function: RFC 5246 §5 P_hash with
/// HMAC-SHA256, producing exactly [length] bytes.
///
///   A(0) = seed
///   A(i) = HMAC_SHA256(secret, A(i-1))
///   output += HMAC_SHA256(secret, A(i) ++ seed)   until >= length, truncated.
Uint8List pSha256(Uint8List secret, Uint8List seed, int length) {
  final out = Uint8List(length);
  var filled = 0;
  var a = seed; // A(0)
  while (filled < length) {
    a = hmacSha256(secret, a); // A(i)
    final block = hmacSha256(
      secret,
      Uint8List.fromList(<int>[...a, ...seed]),
    );
    final take = (length - filled) < block.length ? (length - filled) : block.length;
    out.setRange(filled, filled + take, block);
    filled += take;
  }
  return out;
}
