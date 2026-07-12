import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_certificate.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_crypto.dart';

/// Tests for the self-signed X.509 v3 certificate build/parse used by the
/// OPC UA Basic256Sha256 secure channel.
///
/// Field choices mirror the vendored Rust `opcua-0.12.0`
/// `src/crypto/x509.rs` (self-signed application-instance cert: issuer==subject
/// CN, the ApplicationUri carried as a URI SubjectAltName, SHA-256 signature)
/// and `src/crypto/thumbprint.rs` (thumbprint == SHA-1 of the DER cert).
void main() {
  // A single deterministic 2048-bit keypair is reused across tests: RSA keygen
  // is expensive, and a fixed Fortuna seed keeps the run reproducible.
  final kp = generateRsa2048(fortunaRandom(List<int>.filled(32, 9)));

  group('buildSelfSignedCertificate + parseCertificate', () {
    test('round-trips: build -> parse -> same public key + thumbprint', () {
      final der = buildSelfSignedCertificate(
        keyPair: kp,
        applicationUri: 'urn:softplc:sim',
        commonName: 'SoftPLC Simulator',
        notBefore: DateTime.utc(2020),
        notAfter: DateTime.utc(2040),
      );
      final parsed = parseCertificate(der)!;
      expect(parsed.thumbprint, sha1(der));
      expect(parsed.publicKey.modulus, kp.publicKey.modulus);
      expect(parsed.publicKey.exponent, kp.publicKey.exponent);
    });

    test('produces a well-formed X.509 Certificate SEQUENCE', () {
      final der = buildSelfSignedCertificate(
        keyPair: kp,
        applicationUri: 'urn:softplc:sim',
        commonName: 'SoftPLC Simulator',
        notBefore: DateTime.utc(2020),
        notAfter: DateTime.utc(2040),
      );
      // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm,
      //                            signatureValue BIT STRING }
      final cert = ASN1Parser(der).nextObject() as ASN1Sequence;
      expect(cert.elements.length, 3);
      expect(cert.elements[0], isA<ASN1Sequence>()); // TBSCertificate
      expect(cert.elements[2], isA<ASN1BitString>()); // signatureValue
    });

    test('signature verifies against the certificate public key', () {
      final der = buildSelfSignedCertificate(
        keyPair: kp,
        applicationUri: 'urn:softplc:sim',
        commonName: 'SoftPLC Simulator',
        notBefore: DateTime.utc(2020),
        notAfter: DateTime.utc(2040),
      );
      final cert = ASN1Parser(der).nextObject() as ASN1Sequence;
      final tbsBytes = cert.elements[0].encodedBytes;
      final signature = (cert.elements[2] as ASN1BitString).contentBytes();
      // Self-signed: signature over the TBS bytes must verify with the cert's
      // own public key (RSA PKCS#1 v1.5 / SHA-256).
      expect(
        rsaPkcs1Sha256Verify(
          kp.publicKey,
          Uint8List.fromList(tbsBytes),
          Uint8List.fromList(signature),
        ),
        isTrue,
      );
    });

    test('embeds the ApplicationUri as a URI SubjectAltName', () {
      const appUri = 'urn:softplc:sim:e2e';
      final der = buildSelfSignedCertificate(
        keyPair: kp,
        applicationUri: appUri,
        commonName: 'SoftPLC Simulator',
        notBefore: DateTime.utc(2020),
        notAfter: DateTime.utc(2040),
      );
      // The URI must appear verbatim in the DER (as the IA5String body of the
      // uniformResourceIdentifier [6] GeneralName).
      final uriBytes = Uint8List.fromList(appUri.codeUnits);
      expect(_containsSubsequence(der, uriBytes), isTrue);
    });

    test('notAfter in 2050+ still round-trips (GeneralizedTime path)', () {
      final der = buildSelfSignedCertificate(
        keyPair: kp,
        applicationUri: 'urn:softplc:sim',
        commonName: 'SoftPLC Simulator',
        notBefore: DateTime.utc(2049, 12, 31),
        notAfter: DateTime.utc(2060),
      );
      final parsed = parseCertificate(der);
      expect(parsed, isNotNull);
      expect(parsed!.publicKey.modulus, kp.publicKey.modulus);
    });
  });

  group('parseCertificate guards', () {
    test('returns null on garbage input', () {
      expect(parseCertificate(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('returns null on empty input', () {
      expect(parseCertificate(Uint8List(0)), isNull);
    });

    test('returns null on oversized input (> 8 KiB)', () {
      expect(parseCertificate(Uint8List(9000)), isNull);
    });

    test('returns null on a valid SEQUENCE that is not a certificate', () {
      final seq = ASN1Sequence()..add(ASN1Integer.fromInt(1));
      expect(parseCertificate(seq.encodedBytes), isNull);
    });
  });
}

/// True if [needle] appears as a contiguous subsequence of [haystack].
bool _containsSubsequence(Uint8List haystack, Uint8List needle) {
  if (needle.isEmpty || needle.length > haystack.length) {
    return false;
  }
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return true;
    }
  }
  return false;
}
