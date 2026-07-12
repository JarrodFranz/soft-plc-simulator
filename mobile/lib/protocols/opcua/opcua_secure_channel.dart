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

import 'dart:convert' show utf8;
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

/// Symmetric HMAC-SHA256 signature size (bytes) for Basic256Sha256
/// (security_policy.rs `symmetric_signature_size` -> `SHA256_SIZE`).
const int kSymSignatureSize = 32;

/// Symmetric AES-256-CBC block/plaintext block size (bytes)
/// (security_policy.rs `plain_block_size` -> 16).
const int kSymBlockSize = 16;

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

  /// The MESSAGE security mode negotiated for subsequent symmetric MSG/CLO
  /// chunks (Sign vs SignAndEncrypt), read from the OpenSecureChannelRequest's
  /// `securityMode` field by the session. The asymmetric OPN itself is always
  /// signed+encrypted when the policy is not None, so [_mode] (None vs secured)
  /// is a separate concern from this. Defaults to SignAndEncrypt — the mode a
  /// Basic256Sha256 client uses by default and the only symmetric mode Task 7's
  /// live E2E exercises.
  OpcSecurityMode messageSecurityMode = OpcSecurityMode.signAndEncrypt;

  OpcCertificate? _clientCertificate;
  Uint8List? _clientNonce;
  Uint8List? _serverNonce;
  OpcChannelKeys? _clientKeys;
  OpcChannelKeys? _serverKeys;

  // Per-token key sets so a Renew can install a fresh key set while the OLD
  // token's keys stay valid within its lifetime (a message secured under the
  // previous token must still verify until the client migrates). Keyed by the
  // ChannelSecurityToken.tokenId.
  final Map<int, OpcChannelKeys> _clientKeysByToken = <int, OpcChannelKeys>{};
  final Map<int, OpcChannelKeys> _serverKeysByToken = <int, OpcChannelKeys>{};

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
  /// - [rawHeader]: the exact on-wire chunk bytes
  ///   `frame.sublist(0, header.securityHeaderEnd)` (chunk header + security
  ///   header). This is part of the SIGNED range, so it MUST be a slice of the
  ///   original wire bytes — NEVER reconstruct/re-encode it from the parsed
  ///   header fields, since a re-encode risks a one-byte signed-range mismatch
  ///   that would make a legitimate client's OPN fail verification.
  /// - [rawAfterSecurityHeader]: the encrypted remainder `frame[
  ///   securityHeaderEnd..size]` (sequence header + body + padding + signature).
  /// - [receiverCertificateThumbprint]: the OPN security header's
  ///   `receiverCertificateThumbprint` field (from [parseChunkHeader]), if any.
  ///   When present it is checked against this server's own certificate
  ///   thumbprint before decryption (mirrors `asymmetric_decrypt_and_verify`'s
  ///   `BadNoValidCertificates` check); a null/empty thumbprint is not an error
  ///   on its own since some clients omit it.
  /// - [serverNonce] / [clientNonce]: the two nonces for key derivation.
  ///
  /// For `SecurityPolicy#None` the remainder is returned unchanged. Throws
  /// [OpcSecurityException] on any failure.
  /// When [deriveKeys] is true (the default) this derives+stores the symmetric
  /// key sets from ([serverNonce], [clientNonce]) as part of the call — used by
  /// the standalone loopback test which already knows both nonces. The SESSION
  /// passes `deriveKeys: false` (the real `clientNonce` is INSIDE the encrypted
  /// OPN body and is not known until this call returns the plaintext), then
  /// parses the real nonce and calls [deriveSymmetricKeys] itself. In that case
  /// the [clientNonce] argument is unused.
  Uint8List openFromClient({
    required String policyUri,
    required Uint8List? senderCertificate,
    required Uint8List rawHeader,
    required Uint8List rawAfterSecurityHeader,
    required Uint8List serverNonce,
    required Uint8List clientNonce,
    Uint8List? receiverCertificateThumbprint,
    bool deriveKeys = true,
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

      // A present receiver-certificate thumbprint must identify THIS server's
      // certificate; reject before decrypting otherwise (Rust:
      // `asymmetric_decrypt_and_verify` -> `BadNoValidCertificates`). A
      // null/empty thumbprint is tolerated since some clients omit it.
      if (receiverCertificateThumbprint != null &&
          receiverCertificateThumbprint.isNotEmpty &&
          !_bytesEqual(receiverCertificateThumbprint, sha1(_certificateDer))) {
        throw const OpcSecurityException(
            'OPN receiver certificate thumbprint does not match this server\'s certificate');
      }

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

      if (deriveKeys) {
        _deriveKeys(clientNonce: clientNonce, serverNonce: serverNonce);
      } else {
        // The session will call deriveSymmetricKeys once it has parsed the real
        // clientNonce from the decrypted body; still record the serverNonce now
        // so lastServerNonce (needed for the username-token decrypt during the
        // SAME channel setup) is available immediately.
        _serverNonce = serverNonce;
      }
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

    if (_mode == OpcSecurityMode.none) {
      return buildOpnChunk(
        secureChannelId: secureChannelId,
        securityPolicyUri: kSecurityPolicyNoneUri,
        senderCertificate: null,
        receiverCertificateThumbprint: null,
        sequenceNumber: sequenceNumber,
        requestId: requestId,
        body: Uint8List.sublistView(plaintextSequenceAndBody, 8),
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

  /// Derives and installs the symmetric key sets for [tokenId] from the OPN
  /// nonce exchange. The Client keys VERIFY/DECRYPT inbound client MSGs; the
  /// Server keys SIGN/ENCRYPT outbound server MSGs (Table 33). Called by the
  /// session once it has parsed the real [clientNonce] from the decrypted OPN
  /// body (Issue) or a fresh nonce pair on Renew. Prior tokens' key sets are
  /// retained so a message secured under an older-but-unexpired token still
  /// verifies.
  void deriveSymmetricKeys({
    required int tokenId,
    required Uint8List clientNonce,
    required Uint8List serverNonce,
  }) {
    _deriveKeys(clientNonce: clientNonce, serverNonce: serverNonce);
    _clientKeysByToken[tokenId] = _clientKeys!;
    _serverKeysByToken[tokenId] = _serverKeys!;
  }

  /// The most recent server nonce (used to verify the trailing nonce inside a
  /// decrypted UserNameIdentityToken password). Throws if no OPN has run yet.
  Uint8List get lastServerNonce {
    final nonce = _serverNonce;
    if (nonce == null) {
      throw const OpcSecurityException('no server nonce has been established yet');
    }
    return nonce;
  }

  OpcChannelKeys _clientKeysForToken(int tokenId) {
    final keys = _clientKeysByToken[tokenId] ?? _clientKeys;
    if (keys == null) {
      throw const OpcSecurityException('no symmetric keys for this channel/token');
    }
    return keys;
  }

  OpcChannelKeys _serverKeysForToken(int tokenId) {
    final keys = _serverKeysByToken[tokenId] ?? _serverKeys;
    if (keys == null) {
      throw const OpcSecurityException('no symmetric keys for this channel/token');
    }
    return keys;
  }

  /// Verifies (Sign / SignAndEncrypt) and decrypts (SignAndEncrypt) an inbound
  /// MSG/CLO chunk's secured remainder into its plaintext
  /// `sequenceHeader ++ body`.
  ///
  /// - [rawHeader]: the exact on-wire chunk header + symmetric security header
  ///   bytes `frame.sublist(0, header.securityHeaderEnd)`. This is part of the
  ///   HMAC-signed range, so — like [openFromClient]'s `rawHeader` — it MUST be
  ///   a slice of the original wire bytes, never re-encoded.
  /// - [rawAfterSecurityHeader]: the secured remainder
  ///   `frame.sublist(header.securityHeaderEnd, header.size)` — for both Sign
  ///   and SignAndEncrypt this is `sequenceHeader ++ body ++ padding ++
  ///   signature`; for SignAndEncrypt that whole region is AES-256-CBC
  ///   encrypted, for Sign it stays in the clear (mirrors `secure_channel.rs`'s
  ///   `symmetric_sign` vs `symmetric_sign_and_encrypt`, which share
  ///   `add_space_for_padding_and_signature` and differ only by the encrypt
  ///   step).
  /// - [tokenId]: the symmetric security header's tokenId, selecting the key set
  ///   (so a Renew's older token still verifies).
  ///
  /// For [OpcSecurityMode.none] the remainder is returned unchanged. Throws
  /// [OpcSecurityException] on any MAC / padding / length failure — never lets
  /// an uncaught exception escape.
  Uint8List openSymmetric({
    required int tokenId,
    required Uint8List rawHeader,
    required Uint8List rawAfterSecurityHeader,
  }) {
    if (messageSecurityMode == OpcSecurityMode.none) {
      return rawAfterSecurityHeader;
    }
    try {
      final keys = _clientKeysForToken(tokenId);

      // Sign and SignAndEncrypt share the same verify + padding-strip layout;
      // they differ ONLY in whether rawAfterSecurityHeader is first
      // AES-256-CBC decrypted.
      Uint8List decrypted;
      if (messageSecurityMode == OpcSecurityMode.sign) {
        decrypted = rawAfterSecurityHeader;
      } else {
        if (rawAfterSecurityHeader.isEmpty ||
            rawAfterSecurityHeader.length % kSymBlockSize != 0) {
          throw const OpcSecurityException(
              'symmetric MSG ciphertext is not a multiple of the AES block size');
        }
        decrypted = aes256CbcDecrypt(
          keys.encryptingKey,
          keys.iv,
          rawAfterSecurityHeader,
        );
      }
      if (decrypted.length < kSymSignatureSize + 1) {
        throw const OpcSecurityException('symmetric MSG plaintext too short');
      }
      final signedEnd = decrypted.length - kSymSignatureSize;
      _verifySymmetricSignature(
        signingKey: keys.signingKey,
        rawHeader: rawHeader,
        signedRemainder: Uint8List.sublistView(decrypted, 0, signedEnd),
        signature: Uint8List.sublistView(decrypted, signedEnd),
      );

      // Strip OPC UA symmetric padding: the last byte before the signature is
      // the padding value; there are (paddingByte + 1) padding bytes, all equal
      // to it (minimum_padding == 1 for a <=256-byte key; secure_channel.rs
      // add_space_for_padding_and_signature — applied for BOTH Sign and
      // SignAndEncrypt).
      final paddingByte = decrypted[signedEnd - 1];
      final paddingTotal = paddingByte + 1;
      if (paddingTotal > signedEnd) {
        throw const OpcSecurityException('symmetric MSG padding exceeds plaintext');
      }
      final bodyEnd = signedEnd - paddingTotal;
      for (var i = bodyEnd; i < signedEnd; i++) {
        if (decrypted[i] != paddingByte) {
          throw const OpcSecurityException('symmetric MSG padding byte mismatch');
        }
      }
      return Uint8List.fromList(Uint8List.sublistView(decrypted, 0, bodyEnd));
    } on OpcSecurityException {
      rethrow;
    } catch (e) {
      throw OpcSecurityException('symmetric MSG verify/decrypt failed: $e');
    }
  }

  void _verifySymmetricSignature({
    required Uint8List signingKey,
    required Uint8List rawHeader,
    required Uint8List signedRemainder,
    required Uint8List signature,
  }) {
    // Signed range = rawHeader ++ (decrypted plaintext minus the signature),
    // i.e. the whole chunk except the trailing HMAC (secure_channel.rs
    // symmetric_sign: signed_range = 0..end-signature).
    final signed = Uint8List(rawHeader.length + signedRemainder.length);
    signed.setRange(0, rawHeader.length, rawHeader);
    signed.setRange(rawHeader.length, signed.length, signedRemainder);
    final expected = hmacSha256(signingKey, signed);
    if (!_bytesEqual(expected, signature)) {
      throw const OpcSecurityException('symmetric MSG HMAC verification failed');
    }
  }

  /// Builds a secured (Sign / SignAndEncrypt) MSG chunk carrying [body] (the
  /// plaintext service-response body, WITHOUT its sequence header). Signs with
  /// the server signing key and, for SignAndEncrypt, encrypts to the server
  /// encrypting key/IV for [tokenId]. For [OpcSecurityMode.none] this is a plain
  /// [buildMsgChunk]. Mirrors `secure_channel.rs symmetric_sign_and_encrypt`.
  Uint8List buildSecuredMsg({
    required int secureChannelId,
    required int tokenId,
    required int sequenceNumber,
    required int requestId,
    required Uint8List body,
  }) {
    if (messageSecurityMode == OpcSecurityMode.none) {
      return buildMsgChunk(
        secureChannelId: secureChannelId,
        tokenId: tokenId,
        sequenceNumber: sequenceNumber,
        requestId: requestId,
        body: body,
      );
    }
    try {
      final keys = _serverKeysForToken(tokenId);

      // Plaintext frame: chunk header(12) ++ symmetric security header(4:
      // tokenId) ++ sequence header(8) ++ body. The encrypted region begins at
      // the sequence header (offset 16).
      final plainFrame = buildMsgChunk(
        secureChannelId: secureChannelId,
        tokenId: tokenId,
        sequenceNumber: sequenceNumber,
        requestId: requestId,
        body: body,
      );
      const headerSize = kChunkHeaderLen + 4; // 12 + tokenId(4) = 16

      // Sign and SignAndEncrypt share the same padding + HMAC byte layout —
      // messageHeader ++ securityHeader ++ sequenceHeader ++ body ++ padding
      // ++ HMAC(32) — and differ ONLY in whether the sequenceHeader..HMAC
      // region is then AES-256-CBC encrypted (mirrors `secure_channel.rs`'s
      // `symmetric_sign` vs `symmetric_sign_and_encrypt`, which both call
      // `add_space_for_padding_and_signature`).
      final padding = _symPadding(body.length);
      final encRegionLen =
          8 + body.length + padding.length + kSymSignatureSize;
      if (encRegionLen % kSymBlockSize != 0) {
        throw const OpcSecurityException(
            'internal error: symmetric encrypted region is not block-aligned');
      }
      final tmp = Uint8List(headerSize + encRegionLen);
      tmp.setRange(0, plainFrame.length, plainFrame);
      tmp.setRange(plainFrame.length, plainFrame.length + padding.length, padding);
      // The trailing signature region stays zero until signed below.

      // Neither AES-CBC nor the Sign-only path expand length beyond the
      // padded plaintext size, so the final chunk size is the same in both
      // modes. Set messageSize BEFORE signing (it is inside the signed range).
      final finalSize = tmp.length;
      ByteData.sublistView(tmp, 4, 8).setUint32(0, finalSize, Endian.little);

      final signedEnd = tmp.length - kSymSignatureSize;
      final sig =
          hmacSha256(keys.signingKey, Uint8List.sublistView(tmp, 0, signedEnd));
      tmp.setRange(signedEnd, tmp.length, sig);

      if (messageSecurityMode == OpcSecurityMode.sign) {
        // No AES step — tmp (header ++ seqHeader ++ body ++ padding ++ HMAC)
        // is already the final on-wire chunk, in the clear.
        return tmp;
      }

      // SignAndEncrypt: encrypt the region [headerSize .. end] (sequence
      // header + body + padding + signature) with the server encrypting
      // key/IV.
      final cipher = aes256CbcEncrypt(
        keys.encryptingKey,
        keys.iv,
        Uint8List.sublistView(tmp, headerSize, tmp.length),
      );
      final out = Uint8List(tmp.length);
      out.setRange(0, headerSize, tmp);
      out.setRange(headerSize, out.length, cipher);
      return out;
    } on OpcSecurityException {
      rethrow;
    } catch (e) {
      throw OpcSecurityException('buildSecuredMsg failed: $e');
    }
  }

  /// OAEP-SHA1-decrypts a UserNameIdentityToken password ByteString with the
  /// server private key, returning the UTF-8 password. Mirrors
  /// `user_identity.rs legacy_password_decrypt`: the plaintext is
  /// `UInt32-LE length ++ passwordBytes ++ serverNonce`, where `length ==
  /// passwordBytes.length + serverNonce.length`; the trailing bytes MUST equal
  /// [lastServerNonce]. Returns null on any decrypt / length / nonce mismatch
  /// (never throws).
  String? decryptUserPassword(Uint8List encryptedPassword) {
    Uint8List? nonce;
    try {
      nonce = _serverNonce;
      if (nonce == null) {
        return null;
      }
      if (encryptedPassword.isEmpty ||
          encryptedPassword.length % kAsymCipherTextBlockSize != 0) {
        return null;
      }
      final dec = BytesBuilder(copy: true);
      for (var i = 0;
          i < encryptedPassword.length;
          i += kAsymCipherTextBlockSize) {
        final block = Uint8List.sublistView(
            encryptedPassword, i, i + kAsymCipherTextBlockSize);
        dec.add(rsaOaepSha1Decrypt(_keyPair.privateKey, block));
      }
      final plain = dec.takeBytes();
      if (plain.length < 4) {
        return null;
      }
      final declaredLen =
          ByteData.sublistView(plain, 0, 4).getUint32(0, Endian.little);
      // declaredLen counts passwordBytes + serverNonce (everything after the
      // 4-byte length field).
      if (declaredLen + 4 != plain.length) {
        return null;
      }
      final nonceLen = nonce.length;
      if (plain.length < 4 + nonceLen) {
        return null;
      }
      final nonceBegin = plain.length - nonceLen;
      final gotNonce = Uint8List.sublistView(plain, nonceBegin, plain.length);
      if (!_bytesEqual(gotNonce, nonce)) {
        return null;
      }
      final passwordBytes = Uint8List.sublistView(plain, 4, nonceBegin);
      return utf8.decode(passwordBytes);
    } catch (_) {
      return null;
    }
  }
}

/// Number of OPC UA symmetric padding bytes to append so the encrypted region
/// `sequenceHeader(8) + body + padding + signature(32)` is a multiple of the
/// AES block size (16). Mirrors `secure_channel.rs padding_size` for the
/// symmetric `minimum_padding == 1` case (32-byte HMAC key <= 256): the
/// returned bytes all equal the inner padding count, and there are
/// `innerPadding + 1` of them.
Uint8List _symPadding(int bodySize) {
  // encrypt_size = 8 (sequence header) + body + signature + minimum_padding(1)
  final encryptSize = 8 + bodySize + kSymSignatureSize + 1;
  final rem = encryptSize % kSymBlockSize;
  final pInner = rem == 0 ? 0 : kSymBlockSize - rem;
  final total = 1 + pInner;
  final paddingByte = pInner & 0xff;
  return Uint8List(total)..fillRange(0, total, paddingByte);
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

/// Constant-length byte-sequence equality (no early-exit on the length check
/// itself since it is public data; the loop compares every byte so equal-
/// length mismatches take uniform time).
bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
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
