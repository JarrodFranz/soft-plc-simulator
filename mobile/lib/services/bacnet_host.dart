// The in-app BACnet/IP UDP host — mirrors `services/fins_host.dart`'s
// LIFECYCLE (a `ChangeNotifier` with `start`/`stop`/`dispose`, a nullable
// `AppLogger?` whose calls are all null-guarded and lazy on the hot path, and
// `status`/`lastError`/`endpointUrl` getters) and its TRANSPORT shape: ONE
// `RawDatagramSocket` bound once, no accept loop, no per-connection state —
// BACnet/IP rides UDP just like FINS, and one datagram is one complete
// BVLL/NPDU/APDU frame with nothing to reassemble.
//
// *** THE RESPONSE BYTES ARE NOT BUILT HERE ***
// Every response byte comes from `protocols/bacnet/bacnet_dispatch.dart`'s
// `dispatchBacnetDatagram`, which the E2E fixture host
// (`mobile/tool/bacnet_host_probe.dart`) calls too. The real third-party
// client (BAC0/bacpypes, driven by `tool/bacnet_e2e.sh`) can only be pointed
// at the fixture — this class extends `ChangeNotifier` and cannot run under a
// plain `dart run` — so sharing ONE dispatch is what makes that proof apply to
// the shipped host, instead of relying on two hand-written copies staying
// byte-identical.
//
// *** SCOPE ***
// The object model served is the tag-backed `BacnetTagImage`
// (`protocols/bacnet/bacnet_object_image.dart`): the Device object plus one
// Analog Value/Binary Value object per `BacnetMap` entry, exactly as
// `FinsHost._imageForProject` is backed by `FinsMap` — see
// [_imageForProject]. `deviceInstance` defaults to 3056 per the plan's
// additive default and is driven from the persisted `BacnetProtocolConfig`
// via the Outbound Protocols screen (mirrors how `port` is synced before
// [start]).
//
// *** ROBUSTNESS: THE BIND MUST NEVER WEDGE ***
// A malformed, short, or non-BACnet datagram — from any source, at any time —
// is dropped without disturbing the bind or the next datagram. The codecs
// (`protocols/bacnet/`) return `null` rather than throwing on hostile input,
// and every datagram is handled inside its own try/catch, so one bad packet
// can never take the host down.
//
// The app is byte-identical when hosting is stopped: nothing here runs unless
// [start] is called (an explicit, opt-in action).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/app_log.dart';
import '../models/bacnet_map.dart';
import '../models/project_model.dart';
import '../protocols/bacnet/bacnet_bvll.dart';
import '../protocols/bacnet/bacnet_dispatch.dart';
import '../protocols/bacnet/bacnet_object_image.dart';
import '../protocols/bacnet/bacnet_services.dart';
import 'app_logger.dart';

/// Lifecycle status of the [BacnetHost].
enum BacnetHostStatus { stopped, running, error }

/// The standard BACnet/IP UDP port (BACnet Annex J). Above 1023, so binding
/// it needs no elevated privilege.
const int kBacnetDefaultPort = 47808;

/// The additive default Device_Object_Instance this device advertises when a
/// project has no `bacnet` config (a later task wires this from
/// `BacnetProtocolConfig.deviceInstance`).
const int kBacnetDefaultDeviceInstance = 3056;

/// Honest, non-impersonating Object_Name/Vendor_Name/Model_Name this device
/// advertises — see the plan's "no competitor-tooling branding" constraint.
const String kBacnetDefaultDeviceName = 'Soft PLC Simulator';

/// Best-effort LAN IPv4 address for display in the endpoint line
/// (`bacnet-udp://<ip>:<port>`). Falls back to `localhost` if none can be
/// found (e.g. no network interfaces, or a platform that disallows the
/// lookup) — never throws. Mirrors `FinsHost._bestDisplayHost`.
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

/// The `dart:io` BACnet/IP UDP host. A [ChangeNotifier] so the Outbound
/// Protocols screen (a later task) can reactively show status/last-error/
/// recent peers.
///
/// Fully opt-in: until [start] is called, this class does nothing and the app
/// behaves exactly as it does today.
class BacnetHost extends ChangeNotifier {
  /// Optional diagnostics sink, so the in-app Logs window can show why a
  /// client's requests are going unanswered. Deliberately NULLABLE: a host
  /// constructed without one behaves byte-for-byte as it did before this
  /// parameter existed, and every log call site is null-guarded.
  final AppLogger? logger;

  /// UDP port bound by [start]. Defaults to the BACnet/IP standard
  /// [kBacnetDefaultPort]. A settable field (rather than a `start` parameter)
  /// so the interface stays `start(projectProvider)`: a later task drives
  /// this from the project's BACnet config, and a test can set it to `0` to
  /// bind an ephemeral port and read [boundPort]. Read once, at [start] — a
  /// bound socket cannot change port without a restart.
  int port;

  /// This device's Device_Object_Instance. Settable for the same reason as
  /// [port]; a later task drives this from `BacnetProtocolConfig`.
  int deviceInstance;

  BacnetHost({
    this.logger,
    this.port = kBacnetDefaultPort,
    this.deviceInstance = kBacnetDefaultDeviceInstance,
  });

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;

  /// Source `address:port` labels seen recently. UDP has no connection, so
  /// "who is talking to us" is inferred from datagram sources rather than
  /// from live sockets — this is the datagram-world analogue of the TCP
  /// hosts' connection list.
  final Set<String> _recentPeers = <String>{};

  /// Number of distinct source endpoints that have sent at least one
  /// datagram since [start]. Reset by [stop].
  int get recentPeerCount => _recentPeers.length;

  BacnetHostStatus _status = BacnetHostStatus.stopped;
  BacnetHostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  /// The actual bound UDP port, or `null` when not running. Useful when
  /// [port] was set to `0` to bind an ephemeral port (tests read the real one
  /// here).
  int? get boundPort => _socket?.port;

  bool _disposed = false;

  void _setStatus(BacnetHostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Starts hosting BACnet/IP over UDP. Binds a single [RawDatagramSocket] on
  /// [port] and serves every datagram that arrives on it.
  ///
  /// [projectProvider] is called FRESH on every datagram (mirroring
  /// `FinsHost`), so a project swap while the server is running serves the
  /// NEW project rather than a stale snapshot — this is the seam a later task
  /// uses to serve the project's tags via a `BacnetMap`. The *port* and
  /// *deviceInstance* are read once, at start time, since a bound socket
  /// cannot change either without a restart.
  ///
  /// BACnet/IP's default port 47808 is above 1023, so binding it needs no
  /// elevated privilege — a bind failure here is a genuine conflict (port
  /// already in use) rather than a permission problem.
  Future<void> start(PlcProject Function() projectProvider) async {
    if (_status == BacnetHostStatus.running) {
      return; // already running; caller should stop() first to change port
    }

    // Fail fast if the project cannot be read at all — every datagram would
    // otherwise silently drop. Serving reads still calls this FRESH per
    // datagram (see [_handleDatagram]).
    try {
      projectProvider();
    } catch (e) {
      logger?.log(
        kLogSourceBacnet,
        LogLevel.error,
        'Not started: the current project could not be read.',
        detail: e.toString(),
      );
      _setStatus(BacnetHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }

    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
      _socket = socket;
      _recentPeers.clear();

      final host = await _bestDisplayHost();
      _endpointUrl = 'bacnet-udp://$host:${socket.port}';

      _sub = socket.listen(
        (event) => _onEvent(event, projectProvider),
        onError: (Object e, StackTrace st) {
          logger?.log(
            kLogSourceBacnet,
            LogLevel.error,
            'The datagram socket reported an error.',
            detail: e.toString(),
          );
          _setStatus(BacnetHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      logger?.log(
        kLogSourceBacnet,
        LogLevel.info,
        'Listening on UDP port ${socket.port}.',
        detail: _endpointUrl,
      );
      _setStatus(BacnetHostStatus.running);

      _broadcastIAm(socket);
    } catch (e) {
      _socket = null;
      _endpointUrl = null;
      logger?.log(
        kLogSourceBacnet,
        LogLevel.error,
        'Could not bind UDP port $port.',
        detail: e.toString(),
      );
      _setStatus(BacnetHostStatus.error, error: e.toString());
    }
  }

  /// Best-effort broadcast of one I-Am on start, so passive BACnet clients
  /// (which discover devices by listening rather than sending Who-Is) learn
  /// about this device immediately. Wrapped entirely in its own try/catch:
  /// a broadcast failure (e.g. a platform/sandbox that disallows
  /// `broadcastEnabled`) must never prevent the host from starting or take
  /// it down.
  void _broadcastIAm(RawDatagramSocket socket) {
    try {
      socket.broadcastEnabled = true;
      final iAm = buildIAm(deviceInstance: deviceInstance);
      final frame = buildBvllBroadcast(iAm);
      socket.send(frame, InternetAddress('255.255.255.255'), port);
    } catch (e) {
      logger?.logLazy(
        kLogSourceBacnet,
        LogLevel.debug,
        () => 'Could not send the startup broadcast I-Am: $e',
      );
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
          kLogSourceBacnet,
          LogLevel.warn,
          'Dropped a datagram: the current project could not be read.',
          detail: e.toString(),
        );
        return;
      }

      final image = _imageForProject(project);
      final reply = dispatchBacnetDatagram(dg.data, image);
      if (reply == null) {
        logger?.logLazy(
          kLogSourceBacnet,
          LogLevel.warn,
          () => 'Dropped a datagram from ${dg.address.address}:${dg.port} '
              '(${dg.data.length} bytes): not a served BACnet/IP frame.',
          detail: () => _hexDump(dg.data),
        );
        return;
      }
      logger?.logLazy(
        kLogSourceBacnet,
        LogLevel.trace,
        () => 'Served a datagram from ${dg.address.address}:${dg.port}.',
      );
      socket.send(reply, dg.address, dg.port);
    } catch (e, st) {
      // A crash while dispatching must never take the host down — drop just
      // this datagram. The bind stays up for the next one.
      logger?.log(
        kLogSourceBacnet,
        LogLevel.warn,
        'Dropped a datagram: an internal error occurred while dispatching it.',
        detail: '$e\n$st',
      );
    }
  }

  /// The object image this host serves: the project's tags via a tag-backed
  /// [BacnetTagImage] — the Device object plus one Analog Value/Binary Value
  /// object per [BacnetMap] entry, exactly as `FinsHost._imageForProject` is
  /// backed by `FinsMap`. Uses the project's persisted map
  /// (`project.protocols?.bacnet?.map`) when present, falling back to
  /// `BacnetMap.autoGenerate` for a project that has never configured
  /// BACnet/IP — same additive-persistence fallback every other protocol's
  /// image uses. `deviceInstance` is THIS host's own field (read once, at
  /// [start], from `BacnetProtocolConfig.deviceInstance` via the Outbound
  /// Protocols screen — mirrors how `port` is synced before [start]);
  /// `deviceName` stays the fixed honest identity, since v1 has no
  /// configurable device name.
  BacnetObjectImage _imageForProject(PlcProject project) {
    final configured = project.protocols?.bacnet?.map;
    return BacnetTagImage(
      project,
      configured ?? BacnetMap.autoGenerate(project),
      deviceInstance: deviceInstance,
      deviceName: kBacnetDefaultDeviceName,
    );
  }

  void _recordPeer(Datagram dg) {
    final label = '${dg.address.address}:${dg.port}';
    if (_recentPeers.add(label)) {
      logger?.logLazy(
        kLogSourceBacnet,
        LogLevel.info,
        () => 'First datagram from $label (${_recentPeers.length} recent '
            'source${_recentPeers.length == 1 ? '' : 's'}).',
      );
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  /// Renders [data] as a space-separated hex string, capped so a hostile
  /// oversized datagram cannot bloat a log entry (the logger also caps detail
  /// length, but this keeps the WARN line itself readable).
  String _hexDump(Uint8List data) {
    const maxBytes = 64;
    final slice = data.length > maxBytes ? data.sublist(0, maxBytes) : data;
    final hex = slice.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    return data.length > maxBytes ? '$hex ... (${data.length} bytes total)' : hex;
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
      logger?.log(kLogSourceBacnet, LogLevel.info, 'Stopped hosting.');
    }
    _setStatus(BacnetHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
