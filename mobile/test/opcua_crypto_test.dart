import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_crypto.dart';

/// Known-answer test vectors for the OPC UA Basic256Sha256 crypto primitives.
///
/// Vector provenance:
///  - SHA-256 "abc": RFC 6234 §8.5.
///  - HMAC-SHA256: ported verbatim from the vendored Rust `opcua-0.12.0`
///    `src/crypto/tests/crypto.rs::sign_hmac_sha256` (key="key").
///  - P_SHA256: the IETF TLS 1.2 PRF SHA-256 known-answer vector
///    (TLS WG mailing list, widely reproduced). TLS PRF(secret,label,seed)
///    == P_hash(secret, label||seed); cross-checked with an independent
///    Python `hmac`/`hashlib` implementation. The vendored Rust tests only
///    carry a P_SHA1 (Basic128Rsa15) derivation vector, so this standard
///    SHA-256 vector is used for the SHA-256 PRF instead.
///  - AES-256-CBC: NIST SP 800-38A §F.2.5 (CBC-AES256.Encrypt).

Uint8List _ascii(String s) => Uint8List.fromList(ascii.encode(s));

Uint8List _hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

void main() {
  group('hashes', () {
    test('sha256 matches RFC 6234 "abc" vector', () {
      expect(
        _hex(sha256(_ascii('abc'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('sha1 matches RFC 3174 "abc" vector', () {
      expect(
        _hex(sha1(_ascii('abc'))),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
    });
  });

  group('hmac-sha256 (vendored Rust vectors, key="key")', () {
    test('empty message', () {
      expect(
        _hex(hmacSha256(_ascii('key'), _ascii(''))),
        '5d5d139563c95b5967b9bd9a8c9b233a9dedb45072794cd232dc1b74832607d0',
      );
    });

    test('quick brown fox', () {
      expect(
        _hex(hmacSha256(
          _ascii('key'),
          _ascii('The quick brown fox jumps over the lazy dog'),
        )),
        'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
      );
    });
  });

  group('P_SHA256 (RFC 5246 P_hash / HMAC-SHA256)', () {
    // TLS 1.2 PRF SHA-256 known-answer vector.
    final secret = _hexToBytes('9bbe436ba940f017b17652849a71db35');
    final seed = Uint8List.fromList(<int>[
      ..._ascii('test label'),
      ..._hexToBytes('a0ba9f936cda311827a6f796ffd5198c'),
    ]);
    final expected = _hexToBytes(
      'e3f229ba727be17b8d122620557cd453c2aab21d07c3d495329b52d4e61edb5a'
      '6b301791e90d35c9c9a46b4e14baf9af0fa022f7077def17abfd3797c0564bab'
      '4fbc91666e9def9b97fce34f796789baa48082d122ee42c5a72e5a5110fff701'
      '87347b66',
    );

    test('derives the expected 100-byte key stream', () {
      expect(pSha256(secret, seed, expected.length), expected);
    });

    test('truncates to the requested length (prefix property)', () {
      final short = pSha256(secret, seed, 40);
      expect(short, expected.sublist(0, 40));
    });
  });

  group('AES-256-CBC (NIST SP 800-38A F.2.5)', () {
    final key = _hexToBytes(
      '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4',
    );
    final iv = _hexToBytes('000102030405060708090a0b0c0d0e0f');
    final plaintext = _hexToBytes(
      '6bc1bee22e409f96e93d7e117393172a'
      'ae2d8a571e03ac9c9eb76fac45af8e51'
      '30c81c46a35ce411e5fbc1191a0a52ef'
      'f69f2445df4f9b17ad2b417be66c3710',
    );
    final ciphertext = _hexToBytes(
      'f58c4c04d6e5f1ba779eabfb5f7bfbd6'
      '9cfc4e967edb808d679f777bc6702c7d'
      '39f23369a9d9bacfa530e26304231461'
      'b2eb05e2c39be9fcda6c19078c6a9d1b',
    );

    test('encrypt matches the NIST ciphertext', () {
      expect(aes256CbcEncrypt(key, iv, plaintext), ciphertext);
    });

    test('decrypt matches the NIST plaintext', () {
      expect(aes256CbcDecrypt(key, iv, ciphertext), plaintext);
    });

    test('round-trips arbitrary 16-byte-multiple data', () {
      final data = Uint8List.fromList(
        List<int>.generate(48, (i) => (i * 7 + 3) & 0xff),
      );
      final ct = aes256CbcEncrypt(key, iv, data);
      expect(aes256CbcDecrypt(key, iv, ct), data);
    });
  });

  group('RSA-2048 (deterministic keypair)', () {
    // Deterministic keygen so the test is reproducible.
    final kp = generateRsa2048(fortunaRandom(List<int>.filled(32, 7)));

    test('RSA-OAEP-SHA1 round-trips a single block (<=214 bytes)', () {
      final msg = Uint8List.fromList(
        List<int>.generate(200, (i) => (i * 3 + 1) & 0xff),
      );
      final ct = rsaOaepSha1Encrypt(kp.publicKey, msg);
      expect(ct.length, 256); // 2048-bit modulus block size
      expect(rsaOaepSha1Decrypt(kp.privateKey, ct), msg);
    });

    test('RSA PKCS1-SHA256 sign verifies and tamper fails', () {
      final data = _ascii('Mary had a little lamb');
      final sig = rsaPkcs1Sha256Sign(kp.privateKey, data);
      expect(sig.length, 256);
      expect(rsaPkcs1Sha256Verify(kp.publicKey, data, sig), isTrue);

      final tampered = Uint8List.fromList(data)..[0] ^= 0xff;
      expect(rsaPkcs1Sha256Verify(kp.publicKey, tampered, sig), isFalse);
    });
  });
}
