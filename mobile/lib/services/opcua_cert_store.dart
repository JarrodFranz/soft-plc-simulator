// The OPC UA application-instance certificate store — the ONLY file in the
// OPC UA security workstream allowed to import `dart:io` / `path_provider`
// (Task 3 of the OPC UA security plan; see
// docs/superpowers/specs — OPC UA security design spec). Generates the app's
// RSA-2048 keypair + self-signed X.509 certificate once on first run, persists
// both to app-local storage, and returns the SAME identity on every
// subsequent `loadOrCreate` until `regenerate` is explicitly called.
//
// The private key never leaves this device: it is written only to the app's
// local support directory (or the caller-supplied `overrideDir`, used by
// tests), never logged, and never serialized into project JSON.

import 'dart:io';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:path_provider/path_provider.dart';

import '../protocols/opcua/opcua_certificate.dart';
import '../protocols/opcua/opcua_crypto.dart';

/// The certificate validity window: a day of clock-skew slack before "now",
/// and roughly 20 years of validity — this is a simulator's own self-signed
/// application-instance certificate, not something needing frequent rotation.
const Duration _validityBackdate = Duration(days: 1);
const int _validityYears = 20;

/// The app's OPC UA application instance: the RSA keypair backing the secure
/// channel and the self-signed certificate presenting its public key.
class OpcAppIdentity {
  const OpcAppIdentity({required this.keyPair, required this.certificateDer});

  final OpcRsaKeyPair keyPair;
  final Uint8List certificateDer;

  /// The OPC UA thumbprint: SHA-1 of the DER certificate.
  Uint8List get thumbprint => sha1(certificateDer);
}

/// Loads or creates the app's OPC UA application-instance identity, persisting
/// the RSA private key and certificate to app-local storage so the identity
/// survives restarts.
class OpcUaCertStore {
  OpcUaCertStore({String? overrideDir}) : _overrideDir = overrideDir;

  final String? _overrideDir;

  static const String _keyFileName = 'key.der';
  static const String _certFileName = 'cert.der';

  /// Returns the persisted identity if `key.der` + `cert.der` already exist
  /// under the store directory; otherwise generates a fresh RSA-2048 keypair
  /// and self-signed certificate (seeded from real randomness), persists both,
  /// and returns it. Never regenerates an identity that already exists.
  Future<OpcAppIdentity> loadOrCreate({
    required String applicationUri,
    required String commonName,
  }) async {
    final dir = await _resolveDir();
    final keyFile = File('${dir.path}${Platform.pathSeparator}$_keyFileName');
    final certFile =
        File('${dir.path}${Platform.pathSeparator}$_certFileName');

    if (await keyFile.exists() && await certFile.exists()) {
      try {
        final keyPair = _decodePrivateKeyPair(await keyFile.readAsBytes());
        final certificateDer =
            Uint8List.fromList(await certFile.readAsBytes());
        return OpcAppIdentity(keyPair: keyPair, certificateDer: certificateDer);
      } catch (_) {
        // A truncated/corrupt store (e.g. a killed write on a device) must
        // not permanently break OPC UA hosting — fall through and regenerate.
      }
    }

    return _generateAndPersist(
      dir: dir,
      keyFile: keyFile,
      certFile: certFile,
      applicationUri: applicationUri,
      commonName: commonName,
    );
  }

  /// Always generates a fresh RSA-2048 keypair + self-signed certificate and
  /// overwrites whatever identity was previously persisted.
  Future<OpcAppIdentity> regenerate({
    required String applicationUri,
    required String commonName,
  }) async {
    final dir = await _resolveDir();
    final keyFile = File('${dir.path}${Platform.pathSeparator}$_keyFileName');
    final certFile =
        File('${dir.path}${Platform.pathSeparator}$_certFileName');
    return _generateAndPersist(
      dir: dir,
      keyFile: keyFile,
      certFile: certFile,
      applicationUri: applicationUri,
      commonName: commonName,
    );
  }

  Future<OpcAppIdentity> _generateAndPersist({
    required Directory dir,
    required File keyFile,
    required File certFile,
    required String applicationUri,
    required String commonName,
  }) async {
    final keyPair = generateRsa2048(fortunaRandom());
    final now = DateTime.now().toUtc();
    final certificateDer = buildSelfSignedCertificate(
      keyPair: keyPair,
      applicationUri: applicationUri,
      commonName: commonName,
      notBefore: now.subtract(_validityBackdate),
      notAfter: DateTime.utc(now.year + _validityYears, now.month, now.day),
    );

    await keyFile.writeAsBytes(
      _encodePrivateKeyPair(keyPair.privateKey),
      flush: true,
    );
    await certFile.writeAsBytes(certificateDer, flush: true);

    return OpcAppIdentity(keyPair: keyPair, certificateDer: certificateDer);
  }

  /// Resolves the storage directory: `_overrideDir` if supplied (tests),
  /// otherwise `<app support dir>/opcua`. Creates it if missing.
  Future<Directory> _resolveDir() async {
    late final Directory dir;
    if (_overrideDir != null) {
      dir = Directory(_overrideDir);
    } else {
      final supportDir = await getApplicationSupportDirectory();
      dir = Directory('${supportDir.path}${Platform.pathSeparator}opcua');
    }
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}

/// Encodes an RSA private key as a minimal DER SEQUENCE of the four values
/// that losslessly determine the key: modulus, privateExponent, p, q. (The
/// public exponent is re-derived on load via `RSAPrivateKey.publicExponent`,
/// which pointycastle computes from `privateExponent.modInverse((p-1)(q-1))`,
/// so it need not be stored separately.)
Uint8List _encodePrivateKeyPair(RSAPrivateKey key) {
  final sequence = ASN1Sequence()
    ..add(ASN1Integer(key.modulus!))
    ..add(ASN1Integer(key.privateExponent!))
    ..add(ASN1Integer(key.p!))
    ..add(ASN1Integer(key.q!));
  return Uint8List.fromList(sequence.encodedBytes);
}

/// Decodes the DER SEQUENCE written by [_encodePrivateKeyPair] back into an
/// [OpcRsaKeyPair], reconstructing both the private key and its matching
/// public key ([RSAPublicKey.new] modulus + the re-derived public exponent).
OpcRsaKeyPair _decodePrivateKeyPair(Uint8List der) {
  final sequence = ASN1Parser(der).nextObject() as ASN1Sequence;
  final modulus = (sequence.elements[0] as ASN1Integer).valueAsBigInteger;
  final privateExponent =
      (sequence.elements[1] as ASN1Integer).valueAsBigInteger;
  final p = (sequence.elements[2] as ASN1Integer).valueAsBigInteger;
  final q = (sequence.elements[3] as ASN1Integer).valueAsBigInteger;

  final privateKey = RSAPrivateKey(modulus, privateExponent, p, q);
  final publicKey = RSAPublicKey(modulus, privateKey.publicExponent!);
  return OpcRsaKeyPair(publicKey, privateKey);
}
