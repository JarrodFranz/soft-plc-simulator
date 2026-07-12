import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_crypto.dart';
import 'package:soft_plc_mobile/services/opcua_cert_store.dart';

/// Tests for the OPC UA application-instance certificate store: first-run
/// keygen, persistence across reloads, and explicit regeneration.
///
/// Uses a temp directory (`overrideDir`) so no real device storage is
/// touched; the private key never leaves this process's filesystem sandbox.
void main() {
  test(
    'loadOrCreate generates then persists; second load returns same cert; '
    'regenerate replaces',
    () async {
      final dir = await Directory.systemTemp.createTemp('opcua_cert_test');
      try {
        final store = OpcUaCertStore(overrideDir: dir.path);
        final a = await store.loadOrCreate(
          applicationUri: 'urn:x',
          commonName: 'X',
        );
        final b = await store.loadOrCreate(
          applicationUri: 'urn:x',
          commonName: 'X',
        );
        expect(b.thumbprint, a.thumbprint); // persisted, not regenerated

        // Prove the RELOADED private key is functional, not just that the
        // thumbprint (sha1 of the verbatim-loaded cert bytes) matches — that
        // alone says nothing about whether key.der deserialized correctly.
        final msg =
            Uint8List.fromList(utf8.encode('opcua-key-roundtrip-probe'));
        final sig = rsaPkcs1Sha256Sign(b.keyPair.privateKey, msg);
        expect(rsaPkcs1Sha256Verify(b.keyPair.publicKey, msg, sig), isTrue);
        expect(b.keyPair.privateKey.publicExponent, BigInt.from(65537));

        final c = await store.regenerate(
          applicationUri: 'urn:x',
          commonName: 'X',
        );
        expect(c.thumbprint, isNot(a.thumbprint));
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'loadOrCreate falls through to regenerate when the stored key is '
    'corrupt/truncated',
    () async {
      final dir = await Directory.systemTemp.createTemp('opcua_cert_test');
      try {
        final store = OpcUaCertStore(overrideDir: dir.path);
        await store.loadOrCreate(applicationUri: 'urn:x', commonName: 'X');

        // Simulate a killed write / corrupted device file.
        final keyFile = File('${dir.path}${Platform.pathSeparator}key.der');
        await keyFile.writeAsBytes(<int>[1, 2, 3, 4, 5], flush: true);

        final recovered = await store.loadOrCreate(
          applicationUri: 'urn:x',
          commonName: 'X',
        );

        expect(recovered.certificateDer, isNotEmpty);
        final msg =
            Uint8List.fromList(utf8.encode('opcua-key-roundtrip-probe'));
        final sig = rsaPkcs1Sha256Sign(recovered.keyPair.privateKey, msg);
        expect(
          rsaPkcs1Sha256Verify(recovered.keyPair.publicKey, msg, sig),
          isTrue,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
