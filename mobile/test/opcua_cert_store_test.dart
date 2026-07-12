import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
