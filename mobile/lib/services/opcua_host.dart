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

import '../models/app_log.dart';
import '../models/project_model.dart';
import '../models/protocol_settings.dart';
import '../protocols/opcua/opcua_secure_channel.dart';
import '../protocols/opcua/opcua_session.dart';
import '../protocols/opcua/opcua_services.dart';
import '../protocols/opcua/opcua_transport.dart';
import 'app_logger.dart';
import 'drop_log_gate.dart';
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

  /// Optional diagnostics sink. Null (the default for a bare host) makes
  /// every log call in this class a no-op — instrumentation NEVER changes
  /// protocol behaviour, it only observes it.
  final AppLogger? logger;

  /// This connection's view of the host's first-occurrence WARN gate.
  final ConnectionDropLog dropLog;

  _Connection(
    this.socket,
    this.session,
    this.nowMs, {
    required this.dropLog,
    this.logger,
  });

  /// The 3-character OPC UA message type ('HEL', 'OPN', 'MSG', 'CLO') at the
  /// front of every frame, for the per-frame DEBUG entry. Non-printable bytes
  /// are rendered as '?' so a hostile frame can never inject control
  /// characters into the log.
  static String _messageType(Uint8List frame) {
    final out = StringBuffer();
    for (var i = 0; i < 3 && i < frame.length; i++) {
      final b = frame[i];
      out.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x3F);
    }
    return out.toString();
  }

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
          logger?.logLazy(
            kLogSourceOpcUa,
            LogLevel.warn,
            () => 'Closing a client: its message header declared an unusable '
                'size of $size bytes.',
          );
          close();
          return;
        }
        if (_buffer.length < size) {
          return; // wait for more bytes
        }
        final frame = Uint8List.fromList(_buffer.sublist(0, size));
        _buffer.removeRange(0, size);
        final outFrames = session.onBytes(frame, nowMs());
        logger?.logLazy(
          kLogSourceOpcUa,
          LogLevel.debug,
          () => 'Message ${_messageType(frame)}: ${frame.length} bytes in, '
              '${outFrames.length} frame(s) out.',
        );
        if (outFrames.isEmpty) {
          // The session consumed the message and produced nothing — the OPC
          // UA equivalent of the other hosts' parsed-but-unserved drop. The
          // FIRST such silence is a WARN so a session serving nothing
          // announces itself at the default level; repeats are DEBUG.
          dropLog.drop(
            'opcua-no-reply',
            () => 'No reply produced for a ${_messageType(frame)} message of '
                '${frame.length} bytes.',
          );
        }
        for (final out in outFrames) {
          socket.add(out);
        }
        if (session.shouldClose) {
          logger?.log(
            kLogSourceOpcUa,
            LogLevel.warn,
            'Closing a client: the session asked for the connection to be '
            'torn down (a protocol error, or a client-requested close).',
          );
          close();
          return;
        }
      }
    } catch (e, st) {
      // A crash while reassembling/dispatching must never take down the
      // host — just drop this one connection. The BEHAVIOUR is unchanged;
      // only the record is new, so the operator no longer sees a bare
      // "Client disconnected" with no cause. Fires at most once per
      // connection, so an always-on WARN costs nothing.
      logger?.log(
        kLogSourceOpcUa,
        LogLevel.warn,
        'Dropping a client: an internal error occurred while reassembling or '
        'dispatching its data.',
        detail: '$e\n$st',
      );
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
  /// [logger] is an optional diagnostics sink. Deliberately NULLABLE: a host
  /// constructed without one behaves exactly as it did before this parameter
  /// existed.
  OpcUaHost({OpcUaCertStore? certStore, this.logger}) : _certStore = certStore;

  /// Host-wide first-occurrence WARN policy for dropped requests, shared by
  /// every accepted connection so a client in a reconnect loop cannot re-arm
  /// the WARN on each new socket. See `drop_log_gate.dart`.
  late final DropLogGate _dropGate = DropLogGate(kLogSourceOpcUa, logger);

  final OpcUaCertStore? _certStore;

  final AppLogger? logger;

  ServerSocket? _serverSocket;
  final List<_Connection> _connections = [];
  StreamSubscription<Socket>? _acceptSub;

  /// The app's OPC UA application-instance identity (RSA keypair + self-signed
  /// certificate), loaded from the cert store at `start()` — but ONLY when
  /// the project's `securityModes` configures a secured policy (see
  /// `start()`). Null for a `['None']`-only project (the cert store is never
  /// touched, so there is no RSA-2048 keygen cost on first run), and also
  /// null if a secured project's identity load ever fails — in that case
  /// `start()` surfaces `OpcUaHostStatus.error` instead of serving a broken
  /// secure endpoint (see `_loadAppIdentity`).
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
  /// store. Only ever called from `start()` when the project's
  /// `securityModes` configures a secured policy — a `['None']`-only project
  /// never calls this, so it never pays the RSA-2048 keygen cost nor touches
  /// the cert store at all. Any failure (corrupt store, filesystem/platform-
  /// channel error, etc.) propagates to the caller: `start()` turns it into
  /// `OpcUaHostStatus.error` rather than serving a secured endpoint with a
  /// null certificate.
  Future<OpcAppIdentity> _loadAppIdentity({
    required String applicationUri,
    required String commonName,
  }) {
    final store = _certStore ?? OpcUaCertStore();
    return store.loadOrCreate(
      applicationUri: applicationUri,
      commonName: commonName,
    );
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
      // Always-on: hosting did not start, and without this the operator gets
      // an error status with no recorded cause — while the "not enabled"
      // branch just below has been logged all along.
      logger?.log(
        kLogSourceOpcUa,
        LogLevel.error,
        'Not started: the current project could not be read.',
        detail: e.toString(),
      );
      _setStatus(OpcUaHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }
    // A fresh run re-announces a still-broken configuration.
    _dropGate.reset();

    final opcua = project.protocols?.opcua;
    if (opcua == null || !opcua.enabled) {
      logger?.log(
        kLogSourceOpcUa,
        LogLevel.warn,
        'Not started: OPC UA is not enabled for this project.',
      );
      _setStatus(OpcUaHostStatus.error, error: 'OPC UA is not enabled for this project.');
      return;
    }
    final port = opcua.port;
    final applicationUri = 'urn:softplc:${project.id}';
    final commonName = project.name.isEmpty ? 'Mobile Soft PLC' : project.name;
    // Retained regardless of secure policy so `regenerateCertificate()` (an
    // explicit, on-demand operator action from the gateway screen) always
    // knows the identity parameters to generate against, even for a
    // ['None']-only project that never auto-loads/generates one at start().
    _appCertApplicationUri = applicationUri;
    _appCertCommonName = commonName;

    final hasSecurePolicy = opcua.securityModes.any((m) => m != 'None');

    // Load (or create on first run) the app's certificate identity BEFORE
    // binding/accepting — a per-connection OpcSecureChannel (built in
    // _acceptConnection) needs it. Only done when the project actually
    // configures a secured policy: a `['None']`-only project must never pay
    // the RSA-2048 keygen cost nor touch the cert store at all. A secured
    // project whose identity load fails must NOT silently start with a null
    // certificate (a configured secure endpoint would advertise no cert and
    // simply not work, with no error surfaced) — surface it as a start()
    // failure instead, mirroring how a bind failure below already does.
    if (hasSecurePolicy) {
      try {
        _appIdentity = await _loadAppIdentity(
          applicationUri: applicationUri,
          commonName: commonName,
        );
      } catch (e) {
        _appIdentity = null;
        logger?.log(
          kLogSourceOpcUa,
          LogLevel.error,
          'Not started: security is enabled but the application certificate '
          'could not be generated or loaded.',
          detail: e.toString(),
        );
        _setStatus(
          OpcUaHostStatus.error,
          error: 'OPC UA security is enabled but the application certificate '
              'could not be generated/loaded: $e',
        );
        return;
      }
    } else {
      _appIdentity = null;
    }

    try {
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
          logger?.log(
            kLogSourceOpcUa,
            LogLevel.error,
            'The listening socket reported an error.',
            detail: e.toString(),
          );
          _setStatus(OpcUaHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      logger?.log(
        kLogSourceOpcUa,
        LogLevel.info,
        'Listening on port ${serverSocket.port} '
        '(security modes: ${opcua.securityModes.join(', ')}).',
        detail: endpoint,
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
      final privileged = port > 0 && port < 1024;
      logger?.log(
        kLogSourceOpcUa,
        LogLevel.error,
        privileged
            ? 'Could not bind port $port. Ports below 1024 require elevated '
                'privileges on Linux/macOS — choose a port above 1023 to run '
                'unprivileged.'
            : 'Could not bind port $port.',
        detail: e.toString(),
      );
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
        // Fail closed: passwords are never persisted, so after a restart /
        // project reload every configured credential has a blank password.
        // Skip any credential with an empty username OR empty password so a
        // blank-after-reload entry is simply not an accepted login (rather
        // than an empty-password login that any known username could use).
        credentials: <String, String>{
          for (final c in config.credentials)
            if (c.username.isNotEmpty && c.password.isNotEmpty)
              c.username: c.password,
        },
        allowAnonymous: config.allowAnonymous,
        secureChannel: channel,
      );
      final conn = _Connection(
        socket,
        session,
        () => _clock.elapsedMilliseconds,
        dropLog: _dropGate.forConnection(),
        logger: logger,
      );
      _connections.add(conn);
      // COUNTS ONLY — never a username, never a password, never the
      // credential map itself. The whole point of logging an authentication
      // path is the OUTCOME, not the secret.
      logger?.log(
        kLogSourceOpcUa,
        LogLevel.info,
        'Client connected (${_connections.length} connected; anonymous login '
        '${config.allowAnonymous ? 'allowed' : 'not allowed'}, '
        '${config.credentials.length} credential(s) configured).',
        detail: _peerLabel(socket),
      );
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
    if (_connections.remove(conn)) {
      logger?.log(
        kLogSourceOpcUa,
        LogLevel.info,
        'Client disconnected (${_connections.length} connected).',
      );
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  /// A best-effort `address:port` label for a peer. Never throws — a socket
  /// can already be gone by the time this runs.
  String? _peerLabel(Socket socket) {
    try {
      return '${socket.remoteAddress.address}:${socket.remotePort}';
    } catch (_) {
      return null;
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

    final wasBound = _serverSocket != null;
    try {
      await _serverSocket?.close();
    } catch (_) {
      // Ignore.
    }
    _serverSocket = null;
    _endpointUrl = null;
    if (wasBound) {
      logger?.log(kLogSourceOpcUa, LogLevel.info, 'Stopped hosting.');
    }
    _setStatus(OpcUaHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
