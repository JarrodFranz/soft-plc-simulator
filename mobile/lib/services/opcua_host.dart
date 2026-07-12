// The in-app OPC UA server host: the ONLY file in this project allowed to
// import `dart:io` for OPC UA (WS19 Task 4 — see
// docs/superpowers/specs/2026-07-06-in-app-opcua-server-design.md,
// "Architecture"). Binds a real `ServerSocket` on the project's configured
// port, and for every accepted connection creates a fresh
// `OpcUaServerSession` (Tasks 2-3's pure state machine) fed by a per-socket
// byte-frame reassembly loop.
//
// The app is byte-identical when hosting is stopped: nothing here runs
// unless [start] is called (an explicit, opt-in action from the Outbound
// Protocols screen).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/project_model.dart';
import '../models/protocol_settings.dart';
import '../protocols/opcua/opcua_secure_channel.dart';
import '../protocols/opcua/opcua_session.dart';
import '../protocols/opcua/opcua_services.dart';
import '../protocols/opcua/opcua_transport.dart';
import 'opcua_cert_store.dart';

/// Lifecycle status of the [OpcUaHost].
enum OpcUaHostStatus { stopped, running, error }

/// A hostile or malformed frame-size guard: reject anything claiming to be
/// smaller than a message header or larger than this many bytes (16 MB, well
/// beyond any real OPC UA v1 chunk this server negotiates — see the 1 MB
/// buffer cap in `opcua_session.dart`) by closing just that connection.
const int _maxFrameBytes = 16 * 1024 * 1024;

/// One accepted TCP connection: owns the socket, the per-connection
/// [OpcUaServerSession], and the byte-accumulation buffer used to reassemble
/// whole frames out of arbitrary TCP chunking.
class _Connection {
  final Socket socket;
  final OpcUaServerSession session;
  final int Function() nowMs;
  final List<int> _buffer = [];
  bool _closed = false;

  _Connection(this.socket, this.session, this.nowMs);

  /// Feeds newly-arrived [data] into the reassembly buffer, then extracts
  /// and dispatches as many complete frames as are available. A single
  /// socket `data` event may contain a partial frame, exactly one frame, or
  /// several frames back-to-back — all three are handled here.
  void onData(List<int> data) {
    if (_closed) return;
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < kMessageHeaderLen) {
          return; // not even a full header yet
        }
        // Total message size is the UInt32LE at header offset 4 (see
        // `MessageHeader.parse`/`_readU32LE(data, 4)` in opcua_transport.dart).
        final size = _buffer[4] | (_buffer[5] << 8) | (_buffer[6] << 16) | (_buffer[7] << 24);
        if (size < kMessageHeaderLen || size > _maxFrameBytes) {
          // Hostile/garbage size: close ONLY this connection, never crash.
          close();
          return;
        }
        if (_buffer.length < size) {
          return; // wait for more bytes
        }
        final frame = Uint8List.fromList(_buffer.sublist(0, size));
        _buffer.removeRange(0, size);
        final outFrames = session.onBytes(frame, nowMs());
        for (final out in outFrames) {
          socket.add(out);
        }
        if (session.shouldClose) {
          close();
          return;
        }
      }
    } catch (_) {
      // A crash while reassembling/dispatching must never take down the
      // host — just drop this one connection.
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      socket.flush().whenComplete(() {
        try {
          socket.destroy();
        } catch (_) {
          // Ignore — socket may already be gone.
        }
      });
    } catch (_) {
      try {
        socket.destroy();
      } catch (_) {
        // Ignore.
      }
    }
  }
}

/// Best-effort LAN IPv4 address for display in the endpoint line
/// (`opc.tcp://<ip>:<port>`). Falls back to `localhost` if none can be
/// found (e.g. no network interfaces, or a platform that disallows the
/// lookup) — never throws.
Future<String> _bestDisplayHost() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
          return addr.address;
        }
      }
    }
  } catch (_) {
    // Fall through to localhost.
  }
  return 'localhost';
}

/// The `dart:io` OPC UA server host. A [ChangeNotifier] so the Outbound
/// Protocols screen can reactively show status/client-count/last-error.
///
/// Fully opt-in: until [start] is called, this class does nothing and the
/// app behaves exactly as it does today.
class OpcUaHost extends ChangeNotifier {
  /// Injected certificate store (tests supply one with `overrideDir` pointed
  /// at a temp directory). `null` (the production default) resolves to a
  /// fresh `OpcUaCertStore()` — the real app-support-directory store — the
  /// first time an identity is needed.
  OpcUaHost({OpcUaCertStore? certStore}) : _certStore = certStore;

  final OpcUaCertStore? _certStore;

  ServerSocket? _serverSocket;
  final List<_Connection> _connections = [];
  StreamSubscription<Socket>? _acceptSub;

  /// The app's OPC UA application-instance identity (RSA keypair + self-signed
  /// certificate), loaded from the cert store at `start()`. Null until a
  /// successful `start()` has loaded one (or if loading ever fails — see
  /// `_loadAppIdentity`, which never lets a cert-store failure crash the
  /// host: the None-only path stays fully functional without an identity).
  OpcAppIdentity? _appIdentity;

  /// The (applicationUri, commonName) an identity was last loaded/regenerated
  /// with — retained so `regenerateCertificate()` (callable at any time after
  /// a start) uses the same identity parameters without needing the original
  /// `projectProvider` again.
  String? _appCertApplicationUri;
  String? _appCertCommonName;

  /// The app certificate's SHA-1 thumbprint as colon-separated hex (e.g.
  /// `AA:BB:CC:...`), for display in the OPC UA card. Null until an identity
  /// has been loaded (i.e. before the first successful `start()`, or if
  /// cert-store loading failed).
  String? get appCertThumbprint {
    final identity = _appIdentity;
    if (identity == null) return null;
    return identity.thumbprint
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  /// Regenerates the app's OPC UA application-instance certificate (a fresh
  /// RSA-2048 keypair + self-signed cert), replacing whatever identity was
  /// previously loaded/generated. A no-op if `start()` has never successfully
  /// loaded an identity yet (nothing to regenerate against). Never throws —
  /// a cert-store failure here just leaves the previous identity in place.
  Future<void> regenerateCertificate() async {
    final applicationUri = _appCertApplicationUri;
    final commonName = _appCertCommonName;
    if (applicationUri == null || commonName == null) {
      return;
    }
    try {
      final store = _certStore ?? OpcUaCertStore();
      final identity = await store.regenerate(
        applicationUri: applicationUri,
        commonName: commonName,
      );
      _appIdentity = identity;
      if (!_disposed) {
        notifyListeners();
      }
    } catch (_) {
      // Keep the previous identity; regeneration failing must never crash
      // the app or drop the existing (still-valid) certificate.
    }
  }

  /// Loads (or creates on first run) the app's OPC UA identity from the cert
  /// store. Any failure (corrupt store, filesystem/platform-channel error,
  /// etc.) degrades to `null` — the host still binds and serves the
  /// None-only path exactly as before Task 6; only secured connections
  /// (which need a certificate) are affected, and those already reject
  /// cleanly per-connection when no [OpcSecureChannel] is available.
  Future<OpcAppIdentity?> _loadAppIdentity({
    required String applicationUri,
    required String commonName,
  }) async {
    _appCertApplicationUri = applicationUri;
    _appCertCommonName = commonName;
    try {
      final store = _certStore ?? OpcUaCertStore();
      return await store.loadOrCreate(
        applicationUri: applicationUri,
        commonName: commonName,
      );
    } catch (_) {
      return null;
    }
  }

  /// The ONLY Timer this app ever owns for OPC UA: a 20 Hz (50ms) clock tick
  /// driving every connection's `onClockTick`. Exists ONLY between a
  /// successful `start()` and `stop()` — never idles the app when hosting
  /// isn't running (see file doc, "byte-identical when hosting is stopped").
  Timer? _tickTimer;

  /// Monotonic clock fed to `session.onBytes`/`onClockTick` as `nowMs`.
  /// Reset+started in `start()`, stopped in `stop()` — never read while
  /// hosting is stopped (no timer exists to read it).
  final Stopwatch _clock = Stopwatch();

  OpcUaHostStatus _status = OpcUaHostStatus.stopped;
  OpcUaHostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  int get clientCount => _connections.length;

  /// Sum of every live connection's subscription/monitored-item count. 0
  /// when stopped (no connections) or when no client has created any
  /// subscriptions yet.
  int get subscriptionCount =>
      _connections.fold(0, (sum, c) => sum + c.session.subscriptionCount);
  int get monitoredItemCount =>
      _connections.fold(0, (sum, c) => sum + c.session.monitoredItemCount);

  int _lastNotifiedSubscriptionCount = 0;
  int _lastNotifiedMonitoredItemCount = 0;

  bool _disposed = false;

  void _setStatus(OpcUaHostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Starts hosting `projectProvider()`'s current project's OPC UA
  /// configuration. Requires `protocols.opcua` to be non-null AND `enabled`;
  /// otherwise moves to [OpcUaHostStatus.error] with an explanatory message
  /// and returns without binding a socket.
  ///
  /// [projectProvider] is called fresh on every new connection (via
  /// `OpcUaProjectServices`), so a project swap while the server is running
  /// is safe — but the *port* and *enabled* flag are read once, at start
  /// time, since a bound socket can't change port without a restart.
  Future<void> start(PlcProject Function() projectProvider) async {
    if (_status == OpcUaHostStatus.running) {
      return; // already running; caller should stop() first to change port
    }
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      _setStatus(OpcUaHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }

    final opcua = project.protocols?.opcua;
    if (opcua == null || !opcua.enabled) {
      _setStatus(OpcUaHostStatus.error, error: 'OPC UA is not enabled for this project.');
      return;
    }
    final port = opcua.port;
    final applicationUri = 'urn:softplc:${project.id}';
    final commonName = project.name.isEmpty ? 'Mobile Soft PLC' : project.name;

    try {
      // Load (or create on first run) the app's certificate identity BEFORE
      // binding/accepting — a per-connection OpcSecureChannel (built in
      // _acceptConnection) needs it, and RSA keygen on first run is worth
      // finishing before we start accepting sockets. A failure here (see
      // _loadAppIdentity) degrades to a null identity rather than aborting
      // start(): the None-only path must keep working even if the cert store
      // is unavailable.
      _appIdentity = await _loadAppIdentity(
        applicationUri: applicationUri,
        commonName: commonName,
      );

      final serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _serverSocket = serverSocket;

      final host = await _bestDisplayHost();
      final endpoint = 'opc.tcp://$host:${serverSocket.port}';
      _endpointUrl = endpoint;

      final services = OpcUaProjectServices(projectProvider: projectProvider);
      final info = OpcUaServerInfo(
        applicationName: 'Mobile Soft PLC',
        applicationUri: applicationUri,
        endpointUrl: endpoint,
        namespaceUri: opcua.namespaceUri,
      );

      _acceptSub = serverSocket.listen(
        (socket) => _acceptConnection(socket, info, services, opcua),
        onError: (Object e, StackTrace st) {
          _setStatus(OpcUaHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      _clock
        ..reset()
        ..start();
      _lastNotifiedSubscriptionCount = 0;
      _lastNotifiedMonitoredItemCount = 0;
      _tickTimer = Timer.periodic(const Duration(milliseconds: 50), _onTick);

      _setStatus(OpcUaHostStatus.running);
    } catch (e) {
      _serverSocket = null;
      _setStatus(OpcUaHostStatus.error, error: e.toString());
    }
  }

  /// The 20 Hz clock tick: pushes every live connection's
  /// `session.onClockTick` output straight to its socket (unsolicited
  /// PublishResponse pushes), then notifies listeners ONLY when the
  /// subscription/monitored-item counts actually changed since the last
  /// notification — never spamming `notifyListeners()` at 20 Hz when
  /// nothing observable changed.
  void _onTick(Timer timer) {
    final nowMs = _clock.elapsedMilliseconds;
    for (final conn in List<_Connection>.from(_connections)) {
      try {
        final frames = conn.session.onClockTick(nowMs);
        for (final f in frames) {
          conn.socket.add(f);
        }
      } catch (_) {
        // A crash driving this connection's tick must never take down the
        // host or the other connections — drop just this one.
        _dropConnection(conn);
      }
    }

    final subs = subscriptionCount;
    final items = monitoredItemCount;
    if (subs != _lastNotifiedSubscriptionCount || items != _lastNotifiedMonitoredItemCount) {
      _lastNotifiedSubscriptionCount = subs;
      _lastNotifiedMonitoredItemCount = items;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  /// Accepts one inbound connection: builds a fresh per-connection
  /// [OpcSecureChannel] (when [config] enables a secured policy AND an app
  /// identity is available — see [_appIdentity]) and wires it, together with
  /// [config]'s security settings, into that connection's brand-new
  /// [OpcUaServerSession]. A `securityModes: ['None']`-only config still
  /// passes its (unused) settings through so endpoint advertisement stays
  /// correct, but never allocates a channel — the None path stays exactly
  /// the pre-security byte-identical flow.
  void _acceptConnection(
    Socket socket,
    OpcUaServerInfo info,
    OpcUaProjectServices services,
    OpcUaProtocolConfig config,
  ) {
    try {
      final identity = _appIdentity;
      final hasSecurePolicy = config.securityModes.any((m) => m != 'None');
      final channel = (hasSecurePolicy && identity != null)
          ? OpcSecureChannel(
              keyPair: identity.keyPair,
              certificateDer: identity.certificateDer,
            )
          : null;
      final session = OpcUaServerSession(
        info: info,
        services: services,
        sampler: services.sample,
        securityModes: config.securityModes,
        serverCertificateDer: identity?.certificateDer,
        credentials: <String, String>{
          for (final c in config.credentials) c.username: c.password,
        },
        allowAnonymous: config.allowAnonymous,
        secureChannel: channel,
      );
      final conn = _Connection(socket, session, () => _clock.elapsedMilliseconds);
      _connections.add(conn);
      if (!_disposed) {
        notifyListeners();
      }

      socket.listen(
        (data) {
          try {
            conn.onData(data);
          } catch (_) {
            _dropConnection(conn);
          }
          if (conn._closed) {
            _dropConnection(conn);
          }
        },
        onError: (Object e, StackTrace st) {
          _dropConnection(conn);
        },
        onDone: () {
          _dropConnection(conn);
        },
        cancelOnError: false,
      );
    } catch (_) {
      // A crash while accepting must never take the host down.
      try {
        socket.destroy();
      } catch (_) {
        // Ignore.
      }
    }
  }

  void _dropConnection(_Connection conn) {
    conn.close();
    if (_connections.remove(conn) && !_disposed) {
      notifyListeners();
    }
  }

  /// Stops hosting: closes every live connection and the listening socket.
  /// Safe to call when already stopped. Cancels the tick timer FIRST (before
  /// any other teardown) so no further tick can ever fire mid-stop.
  Future<void> stop() async {
    _tickTimer?.cancel();
    _tickTimer = null;
    _clock.stop();

    try {
      await _acceptSub?.cancel();
    } catch (_) {
      // Ignore.
    }
    _acceptSub = null;

    for (final conn in List<_Connection>.from(_connections)) {
      conn.close();
    }
    _connections.clear();

    try {
      await _serverSocket?.close();
    } catch (_) {
      // Ignore.
    }
    _serverSocket = null;
    _endpointUrl = null;
    _setStatus(OpcUaHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
