// The in-app Mitsubishi SLMP (MELSEC Communication) socket host: the ONLY file
// in this project allowed to import `dart:io` for SLMP (v1 SLMP workstream,
// Task 3). Mirrors `mobile/lib/services/s7_host.dart`'s
// `ServerSocket`/`_Connection` length-prefixed reassembly pattern — SLMP 3E
// rides a length-prefixed TCP stream exactly as S7comm does, and NOT the FINS
// UDP datagram model.
//
// *** THE SLMP LENGTH FIELD EXCLUDES THE FIXED HEADER BEFORE IT ***
// The 3E `requestDataLength` u16 (little-endian, at byte offset 7) counts the
// bytes that FOLLOW it — monitoring timer + command + subcommand + command
// data — and does NOT include the 9-byte fixed prefix (subheader + routing +
// the length field itself) before it. So the reassembly `total` is
// `9 + requestDataLength`, i.e. `(offset-of-length-field 7 + 2) +
// requestDataLength`. This is the SLMP analogue of the exact off-by-header-size
// trap the S7 host's big warning exists to prevent: TPKT's length INCLUDES its
// own 4-byte header (`s7_host.dart` uses `total = header.length`), whereas SLMP
// (like EtherNet/IP's encapsulation length) EXCLUDES its header. This
// convention was VERIFIED against the real `pymcprotocol` client at Task 3
// (`_make_senddata` emits `self._wordsize + len(requestdata)` as the length,
// i.e. timer + command + subcommand + data) — the client is the arbiter.
//
// *** ENDIANNESS: BODY LITTLE-ENDIAN, SUBHEADER BIG-ENDIAN ***
// SLMP 3E binary is little-endian for its body but big-endian for its 2-byte
// subheader — see the ENDIANNESS WARNING in `protocols/slmp/slmp_frame.dart`.
// The length field this host reads is LITTLE-ENDIAN.
//
// *** THE READ/WRITE RESPONSE BYTES ARE NOT BUILT HERE ***
// Every response byte for a Batch Read / Batch Write comes from
// `protocols/slmp/slmp_dispatch.dart`'s `dispatchSlmpFrame`, which the E2E
// fixture host (`mobile/tool/slmp_host_probe.dart`) calls too. The real
// third-party client (`pymcprotocol`, driven by `tool/slmp_e2e.sh`) can only be
// pointed at the fixture — this class extends `ChangeNotifier` and cannot run
// under a plain `dart run` — so sharing ONE dispatch is what makes that proof
// apply to the shipped host, instead of relying on two hand-written copies
// staying byte-identical.
//
// *** SCOPE (Task 3) ***
// The dispatch serves a Batch Read / Batch Write (word units) against a small
// built-in fixture [SlmpDeviceImage] (a seeded D/W word bank). Read/Write
// against the project's real tags via a `SlmpMap` arrives in Task 4, which
// slots a tag-backed image into the same `_imageFor` seam; force- and
// access-aware write refusal will live in that image (as `applyAreaWrite` does
// for S7/FINS), not here.
//
// The app is byte-identical when hosting is stopped: nothing here runs unless
// [start] is called (an explicit, opt-in action).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/app_log.dart';
import '../models/project_model.dart';
import '../models/slmp_map.dart';
import '../protocols/slmp/slmp_dispatch.dart';
import 'app_logger.dart';
import 'drop_log_gate.dart';

/// Lifecycle status of the [SlmpHost].
enum SlmpHostStatus { stopped, running, error }

/// The default TCP port the SLMP host binds. MC protocol defines NO universal
/// default port (unlike FINS's 9600 or S7's 102) — the port is configured per
/// Ethernet module. 5007 is a widely-used convention in MELSEC MC-protocol
/// examples and simulators, and it is unprivileged (> 1023) so it binds without
/// elevation on Linux/macOS. The port is user-editable; `pymcprotocol`'s
/// `connect(host, port)` takes it explicitly and works against any bound port
/// (verified at Task 3). Task 5 moves the persisted default into
/// `SlmpProtocolConfig`, sourced from this constant.
const int kSlmpDefaultPort = 5007;

/// The byte offset of the little-endian `requestDataLength` u16 in a 3E frame:
/// subheader(2) + network(1) + pc(1) + destModuleIo(2) + destModuleStation(1)
/// = 7. The two length bytes occupy offsets 7 and 8.
const int _kLengthFieldOffset = 7;

/// The number of bytes that must be buffered before the length field can be
/// read: [_kLengthFieldOffset] + 2. The reassembly `total` is this plus the
/// decoded `requestDataLength` (which counts everything AFTER the length
/// field), so `total = _kLengthPrefixEnd + requestDataLength`.
const int _kLengthPrefixEnd = _kLengthFieldOffset + 2;

/// A hostile/malformed frame-size guard. `requestDataLength` is a 16-bit
/// little-endian word, so a well-formed frame's `total` can never exceed
/// `_kLengthPrefixEnd + 0xFFFF`. This constant documents that bound explicitly
/// (mirroring the other hosts' `_maxFrameBytes` guards) rather than relying on
/// it being merely structurally true; a `total` above it closes only the
/// offending connection. `total` is always at least [_kLengthPrefixEnd] (the
/// length field counts a non-negative number of following bytes), so it always
/// advances the reassembly loop — a zero length yields a 9-byte slice that the
/// codec rejects as too short, never an infinite spin.
const int _maxFrameBytes = _kLengthPrefixEnd + 0xFFFF;

/// One accepted TCP connection: owns the socket and the byte-accumulation
/// buffer used to reassemble whole SLMP 3E frames out of arbitrary TCP
/// chunking. Two sockets never share any of it.
class _Connection {
  final Socket socket;
  final List<int> _buffer = [];
  bool _closed = false;

  /// Optional diagnostics sink. Null (the default for a bare host) makes every
  /// log call in this class a no-op — instrumentation NEVER changes protocol
  /// behaviour, it only observes it.
  final AppLogger? logger;

  /// This connection's view of the host's first-occurrence WARN gate.
  final ConnectionDropLog dropLog;

  /// Builds the [SlmpDeviceImage] to serve a request against, from the project
  /// as it is RIGHT NOW. At Task 3 this returns the host's fixed fixture image
  /// (the project argument is ignored); Task 4 makes it a tag-backed image over
  /// the project's `SlmpMap`. Kept as an injected closure so the connection
  /// never reaches back into the host's private state.
  final SlmpDeviceImage Function(PlcProject) imageFor;

  _Connection(this.socket, this.logger, this.dropLog, this.imageFor);

  /// Records a request this connection PARSED (or reassembled) but did not
  /// SERVE. The FIRST drop of a given [reason] on this connection is a WARN
  /// (visible at the default level); every repeat is DEBUG and lazy.
  void _logDrop(String reason, String Function() build) {
    dropLog.drop(reason, build);
  }

  /// Feeds newly-arrived [data] into the reassembly buffer, then extracts and
  /// dispatches as many complete 3E frames as are available. A single socket
  /// `data` event may contain a partial frame, exactly one frame, or several
  /// frames back-to-back — all three are handled here.
  void onData(List<int> data, PlcProject Function() projectProvider) {
    if (_closed) {
      return;
    }
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < _kLengthPrefixEnd) {
          return; // not even the fixed header through the length field yet
        }
        // requestDataLength is LITTLE-ENDIAN at offset 7 (the body is
        // little-endian; only the subheader is big-endian). It counts the
        // bytes AFTER itself, so the whole frame is _kLengthPrefixEnd + it.
        final requestDataLength =
            _buffer[_kLengthFieldOffset] | (_buffer[_kLengthFieldOffset + 1] << 8);
        final total = _kLengthPrefixEnd + requestDataLength;
        if (total > _maxFrameBytes) {
          // Hostile/garbage length field: close ONLY this connection.
          logger?.logLazy(
            kLogSourceSlmp,
            LogLevel.warn,
            () => 'Closing a client: its SLMP frame declared an unusable '
                'length of $requestDataLength bytes (total $total).',
          );
          close();
          return;
        }
        if (_buffer.length < total) {
          return; // wait for more bytes
        }
        final frame = Uint8List.fromList(_buffer.sublist(0, total));
        _buffer.removeRange(0, total);
        _handleFrame(frame, projectProvider);
      }
    } catch (e, st) {
      // A crash while reassembling/dispatching must never take down the host —
      // just drop this one connection.
      logger?.log(
        kLogSourceSlmp,
        LogLevel.warn,
        'Dropping a client: an internal error occurred while reassembling or '
        'dispatching its data.',
        detail: '$e\n$st',
      );
      close();
    }
  }

  /// Dispatches one complete, reassembled 3E frame via the shared pure
  /// [dispatchSlmpFrame]. A frame the dispatch does not serve
  /// (malformed/short, unparseable command data, a bit-units subcommand, or an
  /// unsupported command) yields a `null` reply and is dropped, leaving the
  /// connection open — a frame we do not understand is not itself grounds to
  /// hang up on a client.
  ///
  /// [projectProvider] is called FRESH here, on every frame, so a project swap
  /// while this socket is open serves the NEW project (Task 4) rather than a
  /// stale snapshot.
  void _handleFrame(Uint8List frame, PlcProject Function() projectProvider) {
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      // Cannot read the project — drop rather than crash the socket.
      logger?.log(
        kLogSourceSlmp,
        LogLevel.warn,
        'Dropped a frame: the current project could not be read.',
        detail: e.toString(),
      );
      return;
    }
    final SlmpDeviceImage image;
    try {
      image = imageFor(project);
    } catch (e) {
      logger?.log(
        kLogSourceSlmp,
        LogLevel.warn,
        'Dropped a frame: the SLMP device image could not be built.',
        detail: e.toString(),
      );
      return;
    }
    final reply = dispatchSlmpFrame(frame, image);
    if (reply == null) {
      _logDrop('slmp-unserved',
          () => 'Dropped a frame: unparseable, malformed, or unsupported SLMP '
              'request (${frame.length} bytes).');
      return;
    }
    socket.add(reply);
  }

  void close() {
    if (_closed) {
      return;
    }
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
/// (`slmp-tcp://<ip>:<port>`). Falls back to `localhost` if none can be found —
/// never throws. Mirrors the other hosts' `_bestDisplayHost`.
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

/// The `dart:io` SLMP socket host. A [ChangeNotifier] so the Outbound Protocols
/// screen (Task 5) can reactively show status/client-count/last-error.
///
/// Fully opt-in: until [start] is called, this class does nothing and the app
/// behaves exactly as it does today.
class SlmpHost extends ChangeNotifier {
  /// Optional diagnostics sink, so the in-app Logs window can show why a
  /// client's requests are going unanswered. Deliberately NULLABLE: a host
  /// constructed without one behaves byte-for-byte as it did before this
  /// parameter existed, and every log call site is null-guarded.
  final AppLogger? logger;

  SlmpHost({this.logger});

  /// The TCP port [start] binds. Defaults to [kSlmpDefaultPort]; a test (or, at
  /// Task 5, the Outbound Protocols card via the persisted `SlmpProtocolConfig`)
  /// sets it before [start]. Read ONCE at start time, since a bound socket
  /// cannot change port without a restart.
  int port = kSlmpDefaultPort;

  /// Host-wide first-occurrence WARN policy for dropped requests, shared by
  /// every accepted connection so a client in a reconnect loop cannot re-arm
  /// the WARN on each new socket. See `drop_log_gate.dart`.
  late final DropLogGate _dropGate = DropLogGate(kLogSourceSlmp, logger);

  ServerSocket? _serverSocket;
  final List<_Connection> _connections = [];
  StreamSubscription<Socket>? _acceptSub;

  SlmpHostStatus _status = SlmpHostStatus.stopped;
  SlmpHostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  int get clientCount => _connections.length;

  bool _disposed = false;

  void _setStatus(SlmpHostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// The image to serve [project] against: a tag-backed [SlmpTagImage] over the
  /// project's tags via a freshly auto-generated `SlmpMap` (Task 4). Read FRESH
  /// per frame (see `_Connection._handleFrame`), so a tag change is reflected on
  /// the very next request without a restart. Task 5 sources the map from the
  /// persisted, user-editable `SlmpProtocolConfig` when one exists, falling back
  /// to this auto-generated default — mirroring `FinsHost._imageForProject`.
  SlmpDeviceImage _imageFor(PlcProject project) =>
      SlmpTagImage(project, SlmpMap.autoGenerate(project));

  /// Starts hosting on [port], serving the tag-backed image.
  ///
  /// [projectProvider] is called fresh on every dispatched frame, so a project
  /// swap while the server is running is safe (Task 4) — but the *port* is read
  /// once, at start time.
  ///
  /// Task 5 adds a `SlmpProtocolConfig`-driven `enabled`/`port` gate here
  /// (mirroring `S7Host.start`'s `project.protocols.s7` check); at Task 3,
  /// calling [start] IS the opt-in.
  Future<void> start(PlcProject Function() projectProvider) async {
    if (_status == SlmpHostStatus.running) {
      return; // already running; caller should stop() first to change port
    }
    // A fresh run re-announces a still-broken configuration.
    _dropGate.reset();

    final boundPort = port;
    try {
      final serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, boundPort);
      _serverSocket = serverSocket;

      final host = await _bestDisplayHost();
      _endpointUrl = 'slmp-tcp://$host:${serverSocket.port}';

      _acceptSub = serverSocket.listen(
        (socket) => _acceptConnection(socket, projectProvider),
        onError: (Object e, StackTrace st) {
          logger?.log(
            kLogSourceSlmp,
            LogLevel.error,
            'The listening socket reported an error.',
            detail: e.toString(),
          );
          _setStatus(SlmpHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      logger?.log(
        kLogSourceSlmp,
        LogLevel.info,
        'Listening on port ${serverSocket.port}.',
        detail: _endpointUrl,
      );
      _setStatus(SlmpHostStatus.running);
    } catch (e) {
      _serverSocket = null;
      _endpointUrl = null;
      final privileged = boundPort > 0 && boundPort < 1024;
      logger?.log(
        kLogSourceSlmp,
        LogLevel.error,
        privileged
            ? 'Could not bind port $boundPort. Ports below 1024 require '
                'elevated privileges on Linux/macOS — choose a port above 1023 '
                'to run unprivileged.'
            : 'Could not bind port $boundPort.',
        detail: e.toString(),
      );
      _setStatus(SlmpHostStatus.error, error: e.toString());
    }
  }

  void _acceptConnection(Socket socket, PlcProject Function() projectProvider) {
    try {
      final conn = _Connection(
        socket,
        logger,
        _dropGate.forConnection(),
        _imageFor,
      );
      _connections.add(conn);
      logger?.log(
        kLogSourceSlmp,
        LogLevel.info,
        'Client connected (${_connections.length} connected).',
        detail: _peerLabel(socket),
      );
      if (!_disposed) {
        notifyListeners();
      }

      socket.listen(
        (data) {
          try {
            conn.onData(data, projectProvider);
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
        kLogSourceSlmp,
        LogLevel.info,
        'Client disconnected (${_connections.length} connected).',
      );
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  /// A best-effort `address:port` label for a peer, for the connect entry's
  /// detail. Never throws — a socket can already be gone by the time this runs.
  String? _peerLabel(Socket socket) {
    try {
      return '${socket.remoteAddress.address}:${socket.remotePort}';
    } catch (_) {
      return null;
    }
  }

  /// Stops hosting: closes every live connection and the listening socket.
  /// Safe to call when already stopped.
  Future<void> stop() async {
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
      logger?.log(kLogSourceSlmp, LogLevel.info, 'Stopped hosting.');
    }
    _setStatus(SlmpHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
