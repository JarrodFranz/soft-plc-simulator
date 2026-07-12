// OPC UA asymmetric secure channel (OPN handshake) for the Basic256Sha256
// security policy — pure Dart, no dart:io / Flutter imports.
//
// This is the byte-unforgiving part of the OPC UA security workstream: the
// OpenSecureChannel (OPN) request from a client is signed + encrypted with
// asymmetric RSA, and the server's OPN response is signed + encrypted the same
// way. A single wrong padding/signature/signed-range byte makes a real client
// reject the channel.
//
// The wire layout, padding scheme, signed byte-range and the sign-then-encrypt
// ordering are mirrored byte-for-byte from the vendored Rust `opcua` crate
// (v0.12.0):
//   core/comms/secure_channel.rs:
//     - padding_size()                       (lines ~412-454)
//     - add_space_for_padding_and_signature  (lines ~458-512)
//     - asymmetric_sign_and_encrypt          (lines ~762-837)
//     - asymmetric_decrypt_and_verify        (lines ~905-1008)
//   crypto/security_policy.rs:
//     - plain_text_block_size = 214, cipher_text_block_size = 256 (RSA-2048)
//     - make_secure_channel_keys / P-SHA256   (lines ~477-505)
//     - secure_channel_nonce_length = 32
//
// Basic256Sha256 asymmetric bindings:
//   - encryption : RSA-OAEP with MGF1-SHA1  (plaintext block 214, cipher 256)
//   - signature  : RSA PKCS#1 v1.5 with SHA-256 (256-byte signature)

import 'dart:typed_data';

import 'opcua_certificate.dart';
import 'opcua_crypto.dart';
import 'opcua_transport.dart';

/// The security policy URI for `SecurityPolicy#Basic256Sha256` — the only
/// secured policy v1 supports. Verified against
/// opcua-0.12.0 `basic_256_sha_256::SECURITY_POLICY_URI`.
const String kSecurityPolicyBasic256Sha256Uri =
    'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256';

/// RSA-2048 OAEP-SHA1 plaintext block size: `keySize(256) - 42`.
const int kAsymPlainTextBlockSize = 214;

/// RSA-2048 ciphertext block size (one RSA operation output).
const int kAsymCipherTextBlockSize = 256;

/// RSA-2048 PKCS#1-SHA256 signature size in bytes.
const int kAsymSignatureSize = 256;

/// OPC UA secure-channel nonce length for Basic256Sha256 (bytes).
const int kSecureChannelNonceLength = 32;

/// The security mode negotiated for a secure channel. For an asymmetric OPN the
/// message is always signed AND encrypted when the policy is not None (Part 6),
/// so this reflects the policy at OPN time; Task 5 refines Sign vs
/// SignAndEncrypt once the OpenSecureChannelRequest body is decoded.
enum OpcSecurityMode { none, sign, signAndEncrypt }

/// Thrown for any parse / verify / decrypt / padding failure. The caller
/// (Task 5/6 session layer) catches this and rejects the channel cleanly —
/// this class NEVER lets an uncaught exception escape from malformed input.
class OpcSecurityException implements Exception {
  const OpcSecurityException(this.message);
  final String message;

  @override
  String toString() => 'OpcSecurityException: $message';
}

/// The symmetric keys derived from the OPN nonce exchange, for one direction.
/// Produced here for Task 5's symmetric MSG path (Basic256Sha256: 32-byte
/// signing key, 32-byte AES-256 key, 16-byte IV).
class OpcChannelKeys {
  const OpcChannelKeys({
    required this.signingKey,
    required this.encryptingKey,
    required this.iv,
  });

  final Uint8List signingKey;
  final Uint8List encryptingKey;
  final Uint8List iv;
}

/// The asymmetric half of an OPC UA secure channel: verifies + decrypts an
/// inbound OPN from a client, builds the signed + encrypted OPN response, and
/// derives the symmetric keys (from the two nonces) that Task 5's MSG path
/// uses.
///
/// Takes the app's RSA keypair + certificate DER directly (pure types) rather
/// than the `OpcAppIdentity` service type, so this file stays in the pure
/// `protocols/opcua` layer (no dart:io).
class OpcSecureChannel {
  OpcSecureChannel({
    required OpcRsaKeyPair keyPair,
    required Uint8List certificateDer,
  })  : _keyPair = keyPair,
        _certificateDer = certificateDer;

  final OpcRsaKeyPair _keyPair;
  final Uint8List _certificateDer;

  OpcSecurityMode _mode = OpcSecurityMode.none;
  OpcCertificate? _clientCertificate;
  Uint8List? _clientNonce;
  Uint8List? _serverNonce;
  OpcChannelKeys? _clientKeys;
  OpcChannelKeys? _serverKeys;

  /// The negotiated security mode (None until an OPN is processed).
  OpcSecurityMode get mode => _mode;

  /// The client's certificate, populated after a secured [openFromClient].
  OpcCertificate? get clientCertificate => _clientCertificate;

  /// The client nonce from the OPN request (for Task 5 key wiring).
  Uint8List? get clientNonce => _clientNonce;

  /// The server nonce sent in the OPN response (for Task 5 key wiring).
  Uint8List? get serverNonce => _serverNonce;

  /// Keys securing messages sent by the CLIENT (server verifies/decrypts with
  /// these). Derived: secret = serverNonce, seed = clientNonce.
  OpcChannelKeys? get clientKeys => _clientKeys;

  /// Keys securing messages sent by the SERVER (server signs/encrypts with
  /// these). Derived: secret = clientNonce, seed = serverNonce.
  OpcChannelKeys? get serverKeys => _serverKeys;

  /// Verifies + decrypts an inbound OPN chunk's secured remainder into its
  /// plaintext `sequenceHeader ++ body`.
  ///
  /// - [policyUri] / [senderCertificate]: from the plaintext asymmetric
  ///   security header (see [parseChunkHeader]).
  /// - [rawHeader]: the plaintext `frame[0..securityHeaderEnd]` (chunk header +
  ///   security header). This is part of the signed range, so it MUST be the
  ///   exact on-wire bytes — it is reconstructed from the parsed fields by the
  ///   session layer via [parseChunkHeader].
  /// - [rawAfterSecurityHeader]: the encrypted remainder `frame[
  ///   securityHeaderEnd..size]` (sequence header + body + padding + signature).
  /// - [serverNonce] / [clientNonce]: the two nonces for key derivation.
  ///
  /// For `SecurityPolicy#None` the remainder is returned unchanged. Throws
  /// [OpcSecurityException] on any failure.
  Uint8List openFromClient({
    required String policyUri,
    required Uint8List? senderCertificate,
    required Uint8List rawHeader,
    required Uint8List rawAfterSecurityHeader,
    required Uint8List serverNonce,
    required Uint8List clientNonce,
  }) {
    if (policyUri == kSecurityPolicyNoneUri) {
      _mode = OpcSecurityMode.none;
      return rawAfterSecurityHeader;
    }
    if (policyUri != kSecurityPolicyBasic256Sha256Uri) {
      throw OpcSecurityException('unsupported security policy "$policyUri"');
    }
    _mode = OpcSecurityMode.signAndEncrypt;
    try {
      if (senderCertificate == null || senderCertificate.isEmpty) {
        throw const OpcSecurityException('OPN is missing a sender certificate');
      }
      final cert = parseCertificate(senderCertificate);
      if (cert == null) {
        throw const OpcSecurityException(
            'OPN sender certificate could not be parsed');
      }
      _clientCertificate = cert;

      // Decrypt the remainder in 256-byte RSA blocks with the server key.
      if (rawAfterSecurityHeader.isEmpty ||
          rawAfterSecurityHeader.length % kAsymCipherTextBlockSize != 0) {
        throw const OpcSecurityException(
            'OPN encrypted body is not a multiple of the RSA block size');
      }
      final decrypted = BytesBuilder(copy: true);
      for (var i = 0;
          i < rawAfterSecurityHeader.length;
          i += kAsymCipherTextBlockSize) {
        final block = Uint8List.sublistView(
            rawAfterSecurityHeader, i, i + kAsymCipherTextBlockSize);
        decrypted.add(rsaOaepSha1Decrypt(_keyPair.privateKey, block));
      }
      final plain = decrypted.takeBytes();
      if (plain.length < kAsymSignatureSize + 1) {
        throw const OpcSecurityException('OPN decrypted plaintext too short');
      }

      // Signature = last 256 bytes; signed range = rawHeader ++ plaintext
      // (minus the signature). Verify with the CLIENT public key.
      final signedEnd = plain.length - kAsymSignatureSize;
      final signature = Uint8List.sublistView(plain, signedEnd);
      final signed = Uint8List(rawHeader.length + signedEnd);
      signed.setRange(0, rawHeader.length, rawHeader);
      signed.setRange(rawHeader.length, signed.length, plain);
      if (!rsaPkcs1Sha256Verify(cert.publicKey, signed, signature)) {
        throw const OpcSecurityException('OPN signature verification failed');
      }

      // Strip OPC UA padding (single padding-size byte for RSA-2048).
      final paddingByte = plain[signedEnd - 1];
      final paddingTotal = paddingByte + 1;
      if (paddingTotal > signedEnd) {
        throw const OpcSecurityException('OPN padding size exceeds plaintext');
      }
      final bodyEnd = signedEnd - paddingTotal;
      for (var i = bodyEnd; i < signedEnd; i++) {
        if (plain[i] != paddingByte) {
          throw const OpcSecurityException('OPN padding byte mismatch');
        }
      }

      _deriveKeys(clientNonce: clientNonce, serverNonce: serverNonce);
      return Uint8List.fromList(Uint8List.sublistView(plain, 0, bodyEnd));
    } on OpcSecurityException {
      rethrow;
    } catch (e) {
      throw OpcSecurityException('OPN verify/decrypt failed: $e');
    }
  }

  /// Builds the OPN response chunk carrying [plaintextSequenceAndBody]
  /// (`sequenceHeader ++ body`). For a secured channel this signs with the
  /// server key and encrypts to the client key; for None it is framed
  /// unencrypted (byte-identical to the WS19 path). Throws
  /// [OpcSecurityException] on failure.
  Uint8List buildSecuredOpnResponse({
    required int secureChannelId,
    required int sequenceNumber,
    required int requestId,
    required Uint8List plaintextSequenceAndBody,
  }) {
    if (plaintextSequenceAndBody.length < 8) {
      throw const OpcSecurityException(
          'plaintextSequenceAndBody is shorter than the 8-byte sequence header');
    }
    final body = Uint8List.sublistView(plaintextSequenceAndBody, 8);

    if (_mode == OpcSecurityMode.none) {
      return buildOpnChunk(
        secureChannelId: secureChannelId,
        securityPolicyUri: kSecurityPolicyNoneUri,
        senderCertificate: null,
        receiverCertificateThumbprint: null,
        sequenceNumber: sequenceNumber,
        requestId: requestId,
        body: body,
      );
    }

    final client = _clientCertificate;
    if (client == null) {
      throw const OpcSecurityException(
          'buildSecuredOpnResponse called before a secured openFromClient');
    }
    try {
      return _buildSecuredOpnChunk(
        signingKey: _keyPair.privateKey,
        encryptionKey: client.publicKey,
        senderCertificateDer: _certificateDer,
        receiverThumbprint: client.thumbprint,
        policyUri: kSecurityPolicyBasic256Sha256Uri,
        secureChannelId: secureChannelId,
        sequenceNumber: sequenceNumber,
        requestId: requestId,
        plaintextSequenceAndBody: plaintextSequenceAndBody,
      );
    } on OpcSecurityException {
      rethrow;
    } catch (e) {
      throw OpcSecurityException('buildSecuredOpnResponse failed: $e');
    }
  }

  void _deriveKeys({
    required Uint8List clientNonce,
    required Uint8List serverNonce,
  }) {
    _clientNonce = clientNonce;
    _serverNonce = serverNonce;
    // Table 33: Client keys secret=ServerNonce seed=ClientNonce;
    //           Server keys secret=ClientNonce seed=ServerNonce.
    _clientKeys = _makeChannelKeys(serverNonce, clientNonce);
    _serverKeys = _makeChannelKeys(clientNonce, serverNonce);
  }
}

/// Derives one direction's (signingKey, encryptingKey, iv) via P-SHA256, in the
/// contiguous layout `signing(32) || encrypting(32) || iv(16)`, exactly as
/// `security_policy.rs make_secure_channel_keys` slices the PRF output.
OpcChannelKeys _makeChannelKeys(Uint8List secret, Uint8List seed) {
  const signLen = 32; // DerivedSignatureKeyLength 256 bits / 8
  const encLen = 32; // AES-256 key
  const ivLen = 16; // AES block size
  final material = pSha256(secret, seed, signLen + encLen + ivLen);
  return OpcChannelKeys(
    signingKey: Uint8List.fromList(Uint8List.sublistView(material, 0, signLen)),
    encryptingKey: Uint8List.fromList(
        Uint8List.sublistView(material, signLen, signLen + encLen)),
    iv: Uint8List.fromList(
        Uint8List.sublistView(material, signLen + encLen, signLen + encLen + ivLen)),
  );
}

/// Number of OPC UA padding bytes to append so that
/// `sequenceHeader(8) + body + padding + signature(256)` is a multiple of the
/// RSA-2048 OAEP plaintext block size (214). Mirrors `secure_channel.rs
/// padding_size` for the `minimum_padding == 1` (key <= 256 bytes) case: the
/// returned bytes are all equal to `paddingSize` (the count excluding the
/// single size byte), and there are `paddingSize + 1` of them.
Uint8List _asymPadding(int bodySize) {
  // encrypt_size = 8 (sequence header) + body + signature + minimum_padding(1)
  final encryptSize = 8 + bodySize + kAsymSignatureSize + 1;
  final rem = encryptSize % kAsymPlainTextBlockSize;
  final pInner = rem == 0 ? 0 : kAsymPlainTextBlockSize - rem;
  final total = 1 + pInner;
  final paddingByte = pInner & 0xff;
  return Uint8List(total)..fillRange(0, total, paddingByte);
}

/// Left-pads an RSA signature to the full 256-byte block (canonical I2OSP).
Uint8List _sig256(Uint8List sig) {
  if (sig.length == kAsymSignatureSize) {
    return sig;
  }
  if (sig.length > kAsymSignatureSize) {
    throw const OpcSecurityException('RSA signature longer than 256 bytes');
  }
  final out = Uint8List(kAsymSignatureSize);
  out.setRange(kAsymSignatureSize - sig.length, kAsymSignatureSize, sig);
  return out;
}

/// Signs (sender key) then encrypts (receiver key) an OPN chunk. Shared by the
/// server's response build and — with roles swapped — the loopback test's
/// client build. Mirrors `asymmetric_sign_and_encrypt`: the message header's
/// `messageSize` is set to the FINAL encrypted size BEFORE signing; the signed
/// range is `[0 .. len - signature]` (message header + security header +
/// sequence header + body + padding); the signature is appended, and the
/// `sequenceHeader..end` range is RSA-OAEP encrypted in 214-byte blocks.
Uint8List _buildSecuredOpnChunk({
  required RSAPrivateKey signingKey,
  required RSAPublicKey encryptionKey,
  required List<int> senderCertificateDer,
  required List<int> receiverThumbprint,
  required String policyUri,
  required int secureChannelId,
  required int sequenceNumber,
  required int requestId,
  required Uint8List plaintextSequenceAndBody,
}) {
  final body = Uint8List.sublistView(plaintextSequenceAndBody, 8);

  // Plaintext frame: chunk header (plaintext size) ++ security header ++
  // sequence header ++ body.
  final plainFrame = buildOpnChunk(
    secureChannelId: secureChannelId,
    securityPolicyUri: policyUri,
    senderCertificate: senderCertificateDer,
    receiverCertificateThumbprint: receiverThumbprint,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
  final headerSize = plainFrame.length - plaintextSequenceAndBody.length;

  final padding = _asymPadding(body.length);
  final encryptedPlaintextLen =
      plaintextSequenceAndBody.length + padding.length + kAsymSignatureSize;
  if (encryptedPlaintextLen % kAsymPlainTextBlockSize != 0) {
    throw const OpcSecurityException(
        'internal error: padded plaintext is not a 214-byte multiple');
  }

  final tmp = Uint8List(headerSize + encryptedPlaintextLen);
  tmp.setRange(0, plainFrame.length, plainFrame);
  tmp.setRange(plainFrame.length, plainFrame.length + padding.length, padding);
  // The trailing signature region stays zero until signed below.

  // Encryption expands the length; set the header's messageSize to the FINAL
  // encrypted chunk size BEFORE signing (signed range covers the header).
  final blockCount = encryptedPlaintextLen ~/ kAsymPlainTextBlockSize;
  final cipherTextSize = blockCount * kAsymCipherTextBlockSize;
  final finalMessageSize = headerSize + cipherTextSize;
  ByteData.sublistView(tmp, 4, 8).setUint32(0, finalMessageSize, Endian.little);

  final signedEnd = tmp.length - kAsymSignatureSize;
  final signature = _sig256(
      rsaPkcs1Sha256Sign(signingKey, Uint8List.sublistView(tmp, 0, signedEnd)));
  tmp.setRange(signedEnd, tmp.length, signature);

  // Encrypt sequenceHeader..end (a 214-byte multiple) to the receiver key.
  final out = BytesBuilder(copy: true);
  out.add(Uint8List.sublistView(tmp, 0, headerSize));
  for (var i = headerSize; i < tmp.length; i += kAsymPlainTextBlockSize) {
    final block =
        Uint8List.sublistView(tmp, i, i + kAsymPlainTextBlockSize);
    out.add(rsaOaepSha1Encrypt(encryptionKey, block));
  }
  return out.takeBytes();
}
