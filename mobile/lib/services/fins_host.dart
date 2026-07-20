// The in-app Omron FINS socket host: the ONLY file in this project allowed to
// import `dart:io` for FINS (v1 FINS workstream, Task 3). It is also the
// suite's FIRST datagram host — every other shipped protocol (OPC UA, Modbus,
// MQTT, DNP3, EtherNet/IP, S7comm) is TCP with a per-connection socket. FINS
// runs over UDP on port 9600.
//
// *** WHY THIS DOES NOT LOOK LIKE `s7_host.dart` ***
// It mirrors `services/s7_host.dart`'s LIFECYCLE — a `ChangeNotifier` with
// `start`/`stop`/`dispose`, a nullable `AppLogger?` whose calls are all
// null-guarded and lazy on the hot path, and `status`/`lastError`/
// `endpointUrl` getters — but NOT its transport. There is:
//   * NO `ServerSocket` and NO accept loop: a single `RawDatagramSocket` is
//     bound once and every peer's datagrams arrive on it.
//   * NO `_Connection` class and NO reassembly `_buffer`: ONE datagram is ONE
//     complete FINS frame. UDP preserves message boundaries, so there is
//     nothing to reassemble — copying the TPKT-length reassembly loop from
//     next door would be a category error.
//   * NO per-connection session state and NO "connection closed" event: a
//     reply is correlated to its request purely by the requester's source
//     address/port and the echoed `SID`. "Who is talking to us" is inferred
//     from recently-seen source addresses, not from live sockets.
//
// *** ROBUSTNESS: THE BIND MUST NEVER WEDGE ***
// A malformed, short, or non-FINS datagram — from any source, at any time — is
// dropped without disturbing the bind or the next datagram. The codecs
// (`protocols/fins/`) return `null` rather than throwing on hostile input, and
// every datagram is handled inside its own try/catch, so one bad packet can
// never take the host down.
//
// *** THE RESPONSE BYTES ARE NOT BUILT HERE ***
// Every response byte comes from `protocols/fins/fins_dispatch.dart`'s
// `dispatchFinsDatagram`, which the E2E fixture host
// (`mobile/tool/fins_host_probe.dart`) calls too. The real third-party client
// (`fins`, driven by `tool/fins_e2e.sh`) can only be pointed at the fixture —
// this class extends `ChangeNotifier` and cannot run under a plain `dart run`
// — so sharing ONE dispatch is what makes that proof apply to the shipped
// host, instead of relying on two hand-written copies staying byte-identical.
//
// *** SCOPE ***
// This host serves Memory Area Read AND Write against an image backed by the
// project's tags via `FinsMap` (Task 4). The map is the project's PERSISTED,
// user-editable FINS config map (`project.protocols.fins.map`, edited in the
// Outbound Protocols card) when one exists, falling back to a fresh
// `FinsMap.autoGenerate` for a project that has never configured FINS. It is
// read FRESH per datagram (`projectProvider` is called per datagram), so a map
// edit or a project swap is reflected on the next request — the map source is
// confined to [_imageForProject].
//
// The app is byte-identical when hosting is stopped: nothing here runs unless
// [start] is called (an explicit, opt-in action).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/app_log.dart';
import '../models/fins_map.dart';
import '../models/project_model.dart';
import '../protocols/fins/fins_dispatch.dart';
import 'app_logger.dart';

/// Lifecycle status of the [FinsHost].
enum FinsHostStatus { stopped, running, error }

/// The standard Omron FINS UDP port. Above 1023, so binding it needs no
/// elevated privilege (unlike S7comm's port 102).
const int kFinsDefaultPort = 9600;

/// Best-effort LAN IPv4 address for display in the endpoint line
/// (`fins-udp://<ip>:<port>`). Falls back to `localhost` if none can be found
/// (e.g. no network interfaces, or a platform that disallows the lookup) —
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

/// The `dart:io` FINS UDP host. A [ChangeNotifier] so the Outbound Protocols
/// screen (a later task) can reactively show status/last-error/recent peers.
///
/// Fully opt-in: until [start] is called, this class does nothing and the app
/// behaves exactly as it does today.
class FinsHost extends ChangeNotifier {
  /// Optional diagnostics sink, so the in-app Logs window can show why a
  /// client's requests are going unanswered. Deliberately NULLABLE: a host
  /// constructed without one behaves byte-for-byte as it did before this
  /// parameter existed, and every log call site is null-guarded.
  final AppLogger? logger;

  /// UDP port bound by [start]. Defaults to the FINS standard [kFinsDefaultPort].
  /// A settable field (rather than a `start` parameter) so the interface stays
  /// `start(projectProvider)`: a later task drives this from the project's FINS
  /// config, and a test can set it to `0` to bind an ephemeral port and read
  /// [boundPort]. Read once, at [start] — a bound socket cannot change port
  /// without a restart.
  int port;

  FinsHost({this.logger, this.port = kFinsDefaultPort});

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;

  /// Source `address:port` labels seen recently. UDP has no connection, so
  /// "who is talking to us" is inferred from datagram sources rather than from
  /// live sockets — this is the datagram-world analogue of the TCP hosts'
  /// connection list.
  final Set<String> _recentPeers = <String>{};

  /// Number of distinct source endpoints that have sent at least one datagram
  /// since [start]. Reset by [stop].
  int get recentPeerCount => _recentPeers.length;

  FinsHostStatus _status = FinsHostStatus.stopped;
  FinsHostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  /// The actual bound UDP port, or `null` when not running. Useful when [port]
  /// was set to `0` to bind an ephemeral port (tests read the real one here).
  int? get boundPort => _socket?.port;

  bool _disposed = false;

  void _setStatus(FinsHostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Starts hosting FINS over UDP. Binds a single [RawDatagramSocket] on [port]
  /// and serves every datagram that arrives on it.
  ///
  /// [projectProvider] is called FRESH on every datagram, so a project swap
  /// while the server is running serves the NEW project rather than a stale
  /// snapshot — this is the seam a later task uses to serve the project's tags
  /// via `FinsMap`. The *port* is read once, at start time, since a bound
  /// socket cannot change port without a restart.
  ///
  /// FINS's default port 9600 is above 1023, so binding it needs no elevated
  /// privilege (unlike S7comm's port 102) — a bind failure here is a genuine
  /// conflict (port already in use) rather than a permission problem.
  Future<void> start(PlcProject Function() projectProvider) async {
    if (_status == FinsHostStatus.running) {
      return; // already running; caller should stop() first to change port
    }

    // Fail fast if the project cannot be read at all — every datagram would
    // otherwise silently drop. Serving reads still calls this FRESH per
    // datagram (see [_handleDatagram]).
    try {
      projectProvider();
    } catch (e) {
      logger?.log(
        kLogSourceFins,
        LogLevel.error,
        'Not started: the current project could not be read.',
        detail: e.toString(),
      );
      _setStatus(FinsHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }

    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      _socket = socket;
      _recentPeers.clear();

      final host = await _bestDisplayHost();
      _endpointUrl = 'fins-udp://$host:${socket.port}';

      _sub = socket.listen(
        (event) => _onEvent(event, projectProvider),
        onError: (Object e, StackTrace st) {
          logger?.log(
            kLogSourceFins,
            LogLevel.error,
            'The datagram socket reported an error.',
            detail: e.toString(),
          );
          _setStatus(FinsHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      logger?.log(
        kLogSourceFins,
        LogLevel.info,
        'Listening on UDP port ${socket.port}.',
        detail: _endpointUrl,
      );
      _setStatus(FinsHostStatus.running);
    } catch (e) {
      _socket = null;
      _endpointUrl = null;
      logger?.log(
        kLogSourceFins,
        LogLevel.error,
        'Could not bind UDP port $port.',
        detail: e.toString(),
      );
      _setStatus(FinsHostStatus.error, error: e.toString());
    }
  }

  void _onEvent(RawSocketEvent event, PlcProject Function() projectProvider) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final socket = _socket;
    if (socket == null) {
      return;
    }
    // Drain every datagram currently queued: a single `read` event can cover
    // more than one, and `receive()` returns `null` once the queue is empty.
    while (true) {
      Datagram? dg;
      try {
        dg = socket.receive();
      } catch (_) {
        return;
      }
      if (dg == null) {
        return;
      }
      _handleDatagram(socket, dg, projectProvider);
    }
  }

  /// Serves one datagram: parse -> dispatch -> reply to the SENDER's address
  /// and port. Every failure path drops the datagram without disturbing the
  /// bind. A crash here is caught so one hostile datagram can never wedge the
  /// host — the codecs never throw, but this guard is belt-and-suspenders.
  void _handleDatagram(
    RawDatagramSocket socket,
    Datagram dg,
    PlcProject Function() projectProvider,
  ) {
    try {
      _recordPeer(dg);

      final PlcProject project;
      try {
        project = projectProvider();
      } catch (e) {
        logger?.log(
          kLogSourceFins,
          LogLevel.warn,
          'Dropped a datagram: the current project could not be read.',
          detail: e.toString(),
        );
        return;
      }

      final image = _imageForProject(project);
      final reply = dispatchFinsDatagram(dg.data, image);
      if (reply == null) {
        logger?.logLazy(
          kLogSourceFins,
          LogLevel.debug,
          () => 'Dropped a datagram from ${dg.address.address}:${dg.port} '
              '(${dg.data.length} bytes): not a served FINS command.',
        );
        return;
      }
      socket.send(reply, dg.address, dg.port);
    } catch (e, st) {
      // A crash while dispatching must never take the host down — drop just
      // this datagram. The bind stays up for the next one.
      logger?.log(
        kLogSourceFins,
        LogLevel.warn,
        'Dropped a datagram: an internal error occurred while dispatching it.',
        detail: '$e\n$st',
      );
    }
  }

  /// The memory image this host serves. It is backed by [project]'s tags via a
  /// `FinsMap`: the project's PERSISTED, user-editable FINS config map when one
  /// exists (`project.protocols.fins.map`, edited in the Outbound Protocols
  /// card), falling back to a fresh [FinsMap.autoGenerate] for a project that
  /// has never configured FINS. Read FRESH per datagram, so a map edit or tag
  /// change is reflected on the very next request without a restart.
  FinsMemoryImage _imageForProject(PlcProject project) {
    final configured = project.protocols?.fins?.map;
    return FinsTagImage(project, configured ?? FinsMap.autoGenerate(project));
  }

  void _recordPeer(Datagram dg) {
    final label = '${dg.address.address}:${dg.port}';
    if (_recentPeers.add(label)) {
      logger?.logLazy(
        kLogSourceFins,
        LogLevel.info,
        () => 'First datagram from $label (${_recentPeers.length} recent '
            'source${_recentPeers.length == 1 ? '' : 's'}).',
      );
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  /// Stops hosting: closes the datagram socket. Safe to call when already
  /// stopped.
  Future<void> stop() async {
    try {
      await _sub?.cancel();
    } catch (_) {
      // Ignore.
    }
    _sub = null;

    final wasBound = _socket != null;
    try {
      _socket?.close();
    } catch (_) {
      // Ignore.
    }
    _socket = null;
    _endpointUrl = null;
    _recentPeers.clear();
    if (wasBound) {
      logger?.log(kLogSourceFins, LogLevel.info, 'Stopped hosting.');
    }
    _setStatus(FinsHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
