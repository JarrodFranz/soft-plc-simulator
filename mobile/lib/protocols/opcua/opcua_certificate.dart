// Pure-Dart X.509 v3 certificate build + parse for the OPC UA secure channel.
//
// Scope (mirrors the vendored Rust `opcua-0.12.0` `src/crypto/x509.rs`
// self-signed application-instance certificate, and `src/crypto/thumbprint.rs`
// where thumbprint == SHA-1 of the DER certificate):
//   - build a self-signed X.509 v3 cert (SHA-256 / RSA signature) whose
//     issuer == subject Name (a single CN), carrying the OPC UA ApplicationUri
//     as a uniformResourceIdentifier SubjectAltName;
//   - parse a peer certificate's DER back to its RSA public key + SHA-1
//     thumbprint, never throwing on malformed / oversized input.
//
// The reference `CertificateStore` validation (certificate_store.rs) enforces
// only: key length (needs the public key), validity times, an optional
// hostname, and the ApplicationUri SubjectAltName. It does NOT inspect
// keyUsage / extendedKeyUsage, so those extensions (present in x509.rs) are
// intentionally omitted here to keep the DER minimal and unambiguous.
//
// Pure Dart: imports ONLY asn1lib, the Task-1 crypto primitives and
// dart:typed_data (no dart:io / Flutter), and is dart2js / web safe.

import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';

import 'opcua_crypto.dart';

/// Maximum accepted DER length for [parseCertificate]. An RSA-2048
/// application-instance certificate is well under 2 KiB; 8 KiB is a generous
/// ceiling that still rejects absurd / hostile inputs cheaply.
const int _maxCertificateDerLength = 8192;

// Object identifiers used in the certificate (dotted form).
const String _oidRsaEncryption = '1.2.840.113549.1.1.1';
const String _oidSha256WithRsaEncryption = '1.2.840.113549.1.1.11';
const String _oidCommonName = '2.5.4.3';
const String _oidSubjectAltName = '2.5.29.17';

// Context-specific / tagged BER identifier octets.
const int _tagVersionExplicit = 0xA0; // [0] EXPLICIT (constructed)
const int _tagExtensionsExplicit = 0xA3; // [3] EXPLICIT (constructed)
const int _tagUriGeneralName = 0x86; // [6] IMPLICIT IA5String (primitive)

/// A parsed X.509 certificate: its DER bytes, the extracted subject RSA public
/// key, and the OPC UA thumbprint (SHA-1 of the DER).
class OpcCertificate {
  const OpcCertificate(this.der, this.publicKey);

  /// The DER-encoded X.509 certificate.
  final Uint8List der;

  /// The subject public key extracted from the certificate.
  final RSAPublicKey publicKey;

  /// The OPC UA certificate thumbprint: SHA-1 of the DER certificate
  /// (`crypto/thumbprint.rs`).
  Uint8List get thumbprint => sha1(der);
}

/// Builds a self-signed X.509 v3 certificate (SHA-256 with RSA signature) for
/// [keyPair], with issuer == subject Name `CN=[commonName]`, validity
/// [notBefore]..[notAfter], and the OPC UA [applicationUri] carried as a URI
/// SubjectAltName. Returns the DER encoding.
Uint8List buildSelfSignedCertificate({
  required OpcRsaKeyPair keyPair,
  required String applicationUri,
  required String commonName,
  required DateTime notBefore,
  required DateTime notAfter,
}) {
  final publicKey = keyPair.publicKey;

  // subjectPublicKeyInfo = SEQUENCE { AlgorithmIdentifier(rsaEncryption, NULL),
  //                                   BIT STRING { RSAPublicKey } }
  final rsaPublicKey = ASN1Sequence()
    ..add(ASN1Integer(publicKey.modulus!))
    ..add(ASN1Integer(publicKey.exponent!));
  final subjectPublicKeyInfo = ASN1Sequence()
    ..add(_algorithmIdentifier(_oidRsaEncryption))
    ..add(ASN1BitString(rsaPublicKey.encodedBytes));

  // Name ::= SEQUENCE OF RDN ; a single RDN carrying the common name. The same
  // instance is reused for issuer and subject (byte-identical, as required for
  // a self-signed cert).
  final name = _buildName(commonName);

  // Serial number: a positive integer derived deterministically from the key so
  // it is stable and unique per key without requiring a random source here.
  final serialNumber = ASN1Integer(_deriveSerial(rsaPublicKey.encodedBytes));

  // version [0] EXPLICIT INTEGER 2  (v3)
  final version = ASN1Object.preEncoded(
    _tagVersionExplicit,
    ASN1Integer.fromInt(2).encodedBytes,
  );

  final validity = ASN1Sequence()
    ..add(_asn1Time(notBefore))
    ..add(_asn1Time(notAfter));

  final extensions = _buildExtensions(applicationUri);

  // TBSCertificate ::= SEQUENCE { [0] version, serialNumber, signature,
  //   issuer, validity, subject, subjectPublicKeyInfo, [3] extensions }
  final tbsCertificate = ASN1Sequence()
    ..add(version)
    ..add(serialNumber)
    ..add(_algorithmIdentifier(_oidSha256WithRsaEncryption))
    ..add(name) // issuer
    ..add(validity)
    ..add(name) // subject == issuer
    ..add(subjectPublicKeyInfo)
    ..add(extensions);

  // Sign the DER of the TBSCertificate (RSA PKCS#1 v1.5 over SHA-256).
  final tbsBytes = Uint8List.fromList(tbsCertificate.encodedBytes);
  final signature = rsaPkcs1Sha256Sign(keyPair.privateKey, tbsBytes);

  // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm,
  //                            signatureValue BIT STRING }
  final certificate = ASN1Sequence()
    ..add(tbsCertificate)
    ..add(_algorithmIdentifier(_oidSha256WithRsaEncryption))
    ..add(ASN1BitString(signature));

  return Uint8List.fromList(certificate.encodedBytes);
}

/// Parses a DER-encoded X.509 certificate into an [OpcCertificate] (subject RSA
/// public key + thumbprint). Returns null on malformed or oversized input
/// (> 8 KiB) and never throws.
OpcCertificate? parseCertificate(Uint8List der) {
  if (der.isEmpty || der.length > _maxCertificateDerLength) {
    return null;
  }
  try {
    final parser = ASN1Parser(der);
    if (!parser.hasNext()) {
      return null;
    }
    final certificate = parser.nextObject();
    if (certificate is! ASN1Sequence || certificate.elements.length < 3) {
      return null;
    }
    final tbsCertificate = certificate.elements[0];
    if (tbsCertificate is! ASN1Sequence) {
      return null;
    }
    final subjectPublicKeyInfo = _findSubjectPublicKeyInfo(tbsCertificate);
    if (subjectPublicKeyInfo == null) {
      return null;
    }
    final keyBits = subjectPublicKeyInfo.elements[1];
    if (keyBits is! ASN1BitString) {
      return null;
    }
    // The BIT STRING wraps RSAPublicKey ::= SEQUENCE { modulus, publicExponent }.
    final rsaKey = ASN1Parser(keyBits.contentBytes()).nextObject();
    if (rsaKey is! ASN1Sequence || rsaKey.elements.length < 2) {
      return null;
    }
    final modulus = rsaKey.elements[0];
    final exponent = rsaKey.elements[1];
    if (modulus is! ASN1Integer || exponent is! ASN1Integer) {
      return null;
    }
    final publicKey = RSAPublicKey(
      modulus.valueAsBigInteger,
      exponent.valueAsBigInteger,
    );
    return OpcCertificate(Uint8List.fromList(der), publicKey);
  } catch (_) {
    // asn1lib throws ASN1Exception / range errors on truncated or unexpected
    // structures; treat every failure as "not a certificate".
    return null;
  }
}

/// Finds the SubjectPublicKeyInfo inside a TBSCertificate: the SEQUENCE whose
/// first child is an AlgorithmIdentifier carrying the rsaEncryption OID and
/// whose second child is a BIT STRING. Locating it structurally (rather than by
/// fixed index) tolerates peer certs with or without the optional version /
/// extension fields.
ASN1Sequence? _findSubjectPublicKeyInfo(ASN1Sequence tbsCertificate) {
  for (final element in tbsCertificate.elements) {
    if (element is! ASN1Sequence || element.elements.length != 2) {
      continue;
    }
    final algorithm = element.elements[0];
    final key = element.elements[1];
    if (key is! ASN1BitString ||
        algorithm is! ASN1Sequence ||
        algorithm.elements.isEmpty) {
      continue;
    }
    final oid = algorithm.elements[0];
    if (oid is ASN1ObjectIdentifier && oid.identifier == _oidRsaEncryption) {
      return element;
    }
  }
  return null;
}

/// AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters NULL }.
ASN1Sequence _algorithmIdentifier(String oid) => ASN1Sequence()
  ..add(ASN1ObjectIdentifier.fromComponentString(oid))
  ..add(ASN1Null());

/// Name ::= SEQUENCE { RDNSequence }, one RDN of `CN=[commonName]`.
ASN1Sequence _buildName(String commonName) {
  final attribute = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString(_oidCommonName))
    ..add(ASN1UTF8String(commonName));
  final rdn = ASN1Set()..add(attribute);
  return ASN1Sequence()..add(rdn);
}

/// Builds the [3] EXPLICIT Extensions field carrying a single SubjectAltName
/// extension: GeneralNames { uniformResourceIdentifier [6] = [applicationUri] }.
ASN1Object _buildExtensions(String applicationUri) {
  final uriGeneralName = ASN1Object.preEncoded(
    _tagUriGeneralName,
    Uint8List.fromList(applicationUri.codeUnits),
  );
  final generalNames = ASN1Sequence()..add(uriGeneralName);
  final subjectAltName = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString(_oidSubjectAltName))
    ..add(ASN1OctetString(generalNames.encodedBytes));
  final extensionSequence = ASN1Sequence()..add(subjectAltName);
  return ASN1Object.preEncoded(
    _tagExtensionsExplicit,
    extensionSequence.encodedBytes,
  );
}

/// Encodes [dateTime] as the X.509 Time choice: UTCTime for years <= 2049,
/// GeneralizedTime for 2050 and later (RFC 5280 §4.1.2.5).
ASN1Object _asn1Time(DateTime dateTime) {
  final utc = dateTime.toUtc();
  if (utc.year <= 2049) {
    return ASN1UtcTime(utc);
  }
  return ASN1GeneralizedTime(utc);
}

/// Derives a stable, positive serial number from the public key bytes (SHA-1,
/// first 16 bytes) so the certificate has a non-trivial unique serial without
/// needing a random source in this pure module.
BigInt _deriveSerial(Uint8List publicKeyDer) {
  final digest = sha1(publicKeyDer);
  var value = BigInt.zero;
  for (var i = 0; i < 16; i++) {
    value = (value << 8) | BigInt.from(digest[i]);
  }
  // Guard against the (practically impossible) all-zero case; a zero serial is
  // not a valid positive INTEGER for this purpose.
  return value == BigInt.zero ? BigInt.one : value;
}
