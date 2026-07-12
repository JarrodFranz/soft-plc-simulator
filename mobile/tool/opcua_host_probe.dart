// A tiny `dart run` CLI that builds a small fixture project in code (three
// mapped tags: BOOL RW, FLOAT64 RO, INT32 RW), hosts it over a real
// `ServerSocket` (length-prefixed frame reassembly, same rules as
// `mobile/lib/services/opcua_host.dart`), prints `READY <port>` on
// listening, then serves until killed. Used ONLY by `tool/opcua_e2e.sh` as
// the Dart half of the WS19 Task 4 E2E machine-proof (a real Rust
// `opcua`-crate client, `gateway/examples/opcua_probe.rs`, connects here).
//
// IMPORTANT: this does NOT import `services/opcua_host.dart` directly.
// `OpcUaHost extends ChangeNotifier` (`package:flutter/foundation.dart`),
// which transitively imports `dart:ui` — unavailable under a plain
// `dart run` (only `flutter test`'s harness provides a `dart:ui` shim, and
// this must run as a standalone process, not inside a test binding). So
// this tool talks to the pure-Dart protocol layer
// (`OpcUaServerSession`/`OpcUaProjectServices`, no Flutter dependency)
// directly, reimplementing just the same small reassembly loop
// `OpcUaHost` uses — see that file's `_Connection` class for the
// authoritative version this mirrors.
//
// This directory (`mobile/tool/`) is analyzer-excluded per
// `analysis_options.yaml`, but is kept clean anyway.
//
// Usage: dart run tool/opcua_host_probe.dart <port>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart' show writePath;
import 'package:soft_plc_mobile/protocols/opcua/opcua_certificate.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_crypto.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_secure_channel.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_services.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_session.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_transport.dart';

const int _maxFrameBytes = 16 * 1024 * 1024;

/// The one username/password credential the secure endpoint accepts, matching
/// the Rust probe's `IdentityToken::UserName("operator", "opcua-secret-1")`
/// (see `gateway/examples/opcua_probe.rs`).
const String _fixtureUsername = 'operator';
const String _fixturePassword = 'opcua-secret-1';

/// Builds the fixture project the E2E probe expects:
///   - `Start_PB` : BOOL,    ReadWrite -> ns=1;s=Start_PB
///   - `Temp`     : FLOAT64, ReadOnly  -> ns=1;s=Temp
///   - `Counter`  : INT32,   ReadWrite -> ns=1;s=Counter
PlcProject _fixtureProject(int port) {
  final project = PlcProject(
    id: 'proj_opcua_e2e_fixture',
    name: 'OPC UA E2E Fixture',
    controllerName: 'PLC_E2E',
    tags: [
      PlcTag(
        name: 'Start_PB',
        path: 'Inputs.Start_PB',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'Temp',
        path: 'Inputs.Temp',
        dataType: 'FLOAT64',
        value: 21.5,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'Counter',
        path: 'Internal.Counter',
        dataType: 'INT32',
        value: 0,
        ioType: 'Internal',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );

  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.opcua = OpcUaProtocolConfig(
    enabled: true,
    namespaceUri: 'urn:softplc:e2e-fixture',
    port: port,
    // Advertise BOTH a None/Anonymous endpoint (the pre-security leg the Rust
    // probe still exercises) AND a Basic256Sha256/SignAndEncrypt endpoint (the
    // WS-security leg Task 7 proves). Anonymous stays allowed for the None leg;
    // the secure leg authenticates with the one known username/password below.
    // The token strings here are the EXACT values `OpcUaServerSession` parses
    // (see its `_advertisedEndpoints`): 'None' and 'Basic256Sha256/SignAndEncrypt'.
    securityModes: <String>['None', 'Basic256Sha256/SignAndEncrypt'],
    allowAnonymous: true,
    credentials: <OpcUaUserCredential>[
      OpcUaUserCredential(username: _fixtureUsername, password: _fixturePassword),
    ],
    map: OpcuaMap(
      namespaceUri: 'urn:softplc:e2e-fixture',
      nodes: [
        OpcuaNode(nodeId: 'ns=1;s=Start_PB', tag: 'Start_PB', access: 'ReadWrite'),
        OpcuaNode(nodeId: 'ns=1;s=Temp', tag: 'Temp', access: 'ReadOnly'),
        OpcuaNode(nodeId: 'ns=1;s=Counter', tag: 'Counter', access: 'ReadWrite'),
      ],
    ),
  );
  return project;
}

/// Per-connection byte-frame reassembly, mirroring
/// `OpcUaHost`'s `_Connection` (see `mobile/lib/services/opcua_host.dart`):
/// accumulate arbitrary TCP chunks; once >= header size, read the UInt32
/// total-size at offset 4; once the buffer holds a whole frame, slice it,
/// feed the session, write back whatever it returns, honor `shouldClose`.
class _Connection {
  final Socket socket;
  final OpcUaServerSession session;
  final Stopwatch clock;
  final List<int> _buffer = [];
  bool _closed = false;

  _Connection(this.socket, this.session, this.clock);

  void onData(List<int> data) {
    if (_closed) return;
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < kMessageHeaderLen) return;
        final size = _buffer[4] | (_buffer[5] << 8) | (_buffer[6] << 16) | (_buffer[7] << 24);
        if (size < kMessageHeaderLen || size > _maxFrameBytes) {
          close();
          return;
        }
        if (_buffer.length < size) return;
        final frame = Uint8List.fromList(_buffer.sublist(0, size));
        _buffer.removeRange(0, size);
        for (final out in session.onBytes(frame, clock.elapsedMilliseconds)) {
          socket.add(out);
        }
        if (session.shouldClose) {
          close();
          return;
        }
      }
    } catch (_) {
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _connections.remove(this);
    try {
      socket.destroy();
    } catch (_) {
      // Ignore.
    }
  }
}

/// The list of currently-live connections, ticked at 20 Hz by [main] below
/// so the subscription engine's clock-driven publishes (unsolicited
/// PublishResponse pushes on data change / keep-alive) actually fire —
/// mirrors `OpcUaHost._onTick` (see `mobile/lib/services/opcua_host.dart`),
/// which is the ONLY thing that drives `OpcUaServerSession.onClockTick` in
/// the real app. Without this, a fixture host that only feeds bytes on
/// `onData` would never push a subscription notification no matter how
/// long a client waits, since nothing ever calls `onClockTick`.
final List<_Connection> _connections = [];

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/opcua_host_probe.dart <port>');
    exit(64);
  }
  final port = int.tryParse(args[0]);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('invalid port argument: ${args[0]}');
    exit(64);
  }

  final project = _fixtureProject(port);
  final opcua = project.protocols!.opcua!;

  ServerSocket serverSocket;
  try {
    serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, opcua.port);
  } catch (e) {
    stderr.writeln('FAILED TO BIND: $e');
    exit(1);
  }

  final endpoint = 'opc.tcp://127.0.0.1:${serverSocket.port}';
  final services = OpcUaProjectServices(projectProvider: () => project);
  // The app cert's SubjectAltName URI MUST equal the applicationUri the
  // endpoint advertises, or a strict OPC UA client rejects the certificate
  // during the OPN handshake. Derive it ONCE and feed the SAME value to both
  // `OpcUaCertStore.loadOrCreate` (SAN) and `OpcUaServerInfo` (advertised URI),
  // exactly as `OpcUaHost.start` does (`urn:softplc:${project.id}`).
  final applicationUri = 'urn:softplc:${project.id}';
  final info = OpcUaServerInfo(
    applicationName: 'Mobile Soft PLC E2E Fixture',
    applicationUri: applicationUri,
    endpointUrl: endpoint,
    namespaceUri: opcua.namespaceUri,
  );

  // Generate the app's RSA-2048 keypair + self-signed certificate ONCE at
  // startup, when a secured policy is enabled. This deliberately does NOT go
  // through `services/opcua_cert_store.dart` (the real app's store): that file
  // imports `path_provider`, whose import graph pulls in `dart:ui`, which is
  // unavailable under a plain `dart run` process — the very reason this
  // fixture talks to the pure `protocols/opcua` layer directly instead of
  // importing `services/opcua_host.dart` (see the file header). So we call the
  // SAME pure primitives the cert store itself calls (`generateRsa2048` +
  // `buildSelfSignedCertificate` — see `OpcUaCertStore._generateAndPersist`),
  // producing a byte-identical self-signed application-instance cert whose
  // SubjectAltName URI is `applicationUri`. Persistence is irrelevant for a
  // short-lived fixture, so we skip it and keep the identity in memory.
  final hasSecurePolicy = opcua.securityModes.any((m) => m != 'None');
  OpcRsaKeyPair? appKeyPair;
  Uint8List? appCertDer;
  if (hasSecurePolicy) {
    try {
      final keyPair = generateRsa2048(fortunaRandom());
      final now = DateTime.now().toUtc();
      final certificateDer = buildSelfSignedCertificate(
        keyPair: keyPair,
        applicationUri: applicationUri,
        commonName: project.name.isEmpty ? 'Mobile Soft PLC E2E Fixture' : project.name,
        notBefore: now.subtract(const Duration(days: 1)),
        notAfter: DateTime.utc(now.year + 20, now.month, now.day),
      );
      appKeyPair = keyPair;
      appCertDer = certificateDer;
      final thumbprint =
          sha1(certificateDer).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      // ignore: avoid_print
      print('[fixture host] generated app certificate '
          '(applicationUri=$applicationUri thumbprint=$thumbprint)');
    } catch (e) {
      stderr.writeln('FAILED TO GENERATE APP CERTIFICATE: $e');
      exit(1);
    }
  }

  final clock = Stopwatch()..start();
  serverSocket.listen((socket) {
    try {
      // Per accepted connection, build a fresh `OpcSecureChannel` from the
      // app identity (only when a secured policy is enabled AND the identity
      // was generated) and inject it + the security config into that
      // connection's brand-new session — mirroring `OpcUaHost._acceptConnection`.
      // The None path (no secure policy) leaves `secureChannel` null and is
      // byte-identical to the pre-security flow.
      final keyPair = appKeyPair;
      final certDer = appCertDer;
      final channel = (hasSecurePolicy && keyPair != null && certDer != null)
          ? OpcSecureChannel(
              keyPair: keyPair,
              certificateDer: certDer,
            )
          : null;
      final session = OpcUaServerSession(
        info: info,
        services: services,
        sampler: services.sample,
        securityModes: opcua.securityModes,
        serverCertificateDer: certDer,
        credentials: <String, String>{
          for (final c in opcua.credentials) c.username: c.password,
        },
        allowAnonymous: opcua.allowAnonymous,
        secureChannel: channel,
      );
      final conn = _Connection(socket, session, clock);
      _connections.add(conn);
      socket.listen(
        (data) {
          try {
            conn.onData(data);
          } catch (_) {
            conn.close();
          }
        },
        onError: (Object _, StackTrace __) => conn.close(),
        onDone: () => conn.close(),
        cancelOnError: false,
      );
    } catch (_) {
      try {
        socket.destroy();
      } catch (_) {
        // Ignore.
      }
    }
  });

  // 20 Hz clock tick, mirroring `OpcUaHost._onTick`: this is what actually
  // drives the subscription engine's unsolicited PublishResponse pushes
  // (data-change notifications, keep-alives). Without it, `onBytes` alone
  // (only called when a client frame arrives) never fires the tick-driven
  // publish path, so a subscribed client would never receive a push no
  // matter how long it waits.
  Timer.periodic(const Duration(milliseconds: 50), (timer) {
    final nowMs = clock.elapsedMilliseconds;
    for (final conn in List<_Connection>.from(_connections)) {
      try {
        final frames = conn.session.onClockTick(nowMs);
        for (final f in frames) {
          conn.socket.add(f);
        }
      } catch (_) {
        conn.close();
      }
    }
  });

  // ignore: avoid_print
  print('READY $endpoint');

  // WS20 Task 4 subscription E2E: mutate the served project's `Counter` tag
  // server-side (via the same `writePath` other fixtures/tests use), on a
  // fixed schedule after READY, entirely independently of any client
  // connection. This is what a real third-party OPC UA subscriber
  // (`gateway/examples/opcua_probe.rs`) is meant to observe as a *pushed*
  // DataChangeNotification, proving the change did not originate from the
  // probing client itself. Two mutations so a second notification is also
  // observable, though the probe only needs to assert the first (7777).
  // `Timer` is fine here: this is a `dart run` dev/test tool, not app code.
  Timer(const Duration(seconds: 4), () {
    writePath(project, 'Counter', 7777);
    // ignore: avoid_print
    print('[fixture host] mutated Counter -> 7777 at T+4s');
  });
  Timer(const Duration(seconds: 8), () {
    writePath(project, 'Counter', 8888);
    // ignore: avoid_print
    print('[fixture host] mutated Counter -> 8888 at T+8s');
  });

  // Serve until killed. SIGINT is watched for a graceful Ctrl+C exit;
  // SIGTERM is intentionally NOT watched here (unsupported on Windows and
  // throws asynchronously if attempted) — the E2E harness
  // (`tool/opcua_e2e.sh`) simply kills this process outright when done,
  // which is fine for a short-lived fixture host with no state to flush.
  final done = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) => done.complete());
  await done.future;
  await serverSocket.close();
}
