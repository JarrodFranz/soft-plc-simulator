// The in-app MQTT / Sparkplug B publisher CLIENT host: the ONLY file in the
// MQTT feature allowed to import `dart:io` (WS-mqtt Task 5). Unlike
// `opcua_host.dart`/`modbus_host.dart` (which bind a listening
// `ServerSocket` and wait for inbound connections), this host is an
// OUTBOUND client: it dials the project's configured broker via
// `Socket.connect`/`SecureSocket.connect`, sends CONNECT, and — once the
// broker accepts — drives the pure session logic in `mqtt_publisher.dart`
// (birth/telemetry/heartbeat/command decode) and the pure wire codec in
// `mqtt_codec.dart` (encode/parse + `MqttFrameBuffer`) on top of that one
// socket.
//
// The app is byte-identical when no MQTT connection is active: nothing here
// runs unless [connect] is called (an explicit, opt-in action from the
// Outbound Protocols screen).
//
// --- bdSeq ordering (Sparkplug B rebirth pairing) ---------------------------
// Every (re)connect attempt in [_attemptConnect] builds a FRESH
// `MqttPublisher()` and, in order:
//   1. calls `publisher.willMessage(project)` FIRST — this both computes the
//      Will descriptor (JSON "OFFLINE" or Sparkplug NDEATH) AND, for
//      Sparkplug, advances that fresh publisher's `bdSeq` counter — then
//      registers it as the CONNECT packet's Will (topic+payload+retain)
//      before a single byte of CONNECT is sent;
//   2. sends CONNECT;
//   3. ONLY after the broker's CONNACK reports acceptance does it call
//      `publisher.birthMessages(project, nowMs)`, whose NBIRTH reads that
//      SAME publisher's current `bdSeq` (no further increment) — pairing the
//      Will's NDEATH bdSeq with the following NBIRTH's bdSeq, exactly the
//      convention Sparkplug B subscribers use to detect a rebirth.
// Because a brand-new `MqttPublisher` is constructed on every attempt (not
// reused across reconnects), this ordering — and the pairing it produces —
// holds on EVERY reconnect, not just the first.
//
// --- Max-frame guard ---------------------------------------------------------
// `_FrameGuard` wraps `MqttFrameBuffer` with a proactive size check: as soon
// as a fixed header + remaining-length varint can be decoded, the DECLARED
// frame size is checked against `_maxFrameBytes` (4 MB — see its doc comment)
// and the connection is dropped immediately on an oversized/hostile value,
// rather than buffering however many bytes a hostile broker (or a
// man-in-the-middle) feels like sending. Mirrors the eager-reject style in
// `opcua_host.dart` (16 MB) / `modbus_host.dart` (260 bytes), just layered on
// top of the already-tested `MqttFrameBuffer` instead of hand-rolling
// reassembly again here.
//
// --- Never crash --------------------------------------------------------
// Every inbound-byte path (`_onSocketData`/`_dispatchPacket`/handlers) is
// guarded so a malformed/hostile broker byte stream drops the connection and
// schedules a backoff reconnect — it never throws uncaught.
//
// --- Password handling ---------------------------------------------------
// `password` is a constructor-style argument to [connect] held ONLY in the
// `_password` field of this in-memory object — see `MqttProtocolConfig`'s
// own doc comment: the broker password must never be persisted to the
// project file, and this host never writes it anywhere.
library mqtt_host;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/project_model.dart';
import '../models/protocol_settings.dart';
import '../models/tag_resolver.dart';
import '../protocols/mqtt/mqtt_codec.dart';
import '../protocols/mqtt/mqtt_publisher.dart';

/// Lifecycle status of the [MqttHost]. `connecting` (absent from the
/// listen-only hosts, which bind synchronously) covers the time between
/// dialing the broker and receiving an accepted CONNACK — useful UX for a
/// client that may be reconnecting/backing off against a broker that's
/// slow or unreachable.
enum MqttHostStatus { stopped, connecting, running, error }

/// A hostile or malformed frame-size guard: bounds how large a single
/// inbound MQTT control packet this host will ever buffer. 4 MB is generous
/// for anything this app's JSON/Sparkplug B payloads ever produce (a
/// handful of KB at most for even a large tag map) while still refusing to
/// buffer a broker/MITM's arbitrarily large claimed frame size forever.
const int _maxFrameBytes = 4 * 1024 * 1024;

/// The fixed MQTT keep-alive this host advertises in CONNECT. Not exposed in
/// `MqttProtocolConfig` (only `heartbeatSeconds`, the Sparkplug/JSON
/// application-level heartbeat, is user-configurable) — 60s is a
/// conservative, widely-supported default. The PINGREQ timer runs at half
/// this, per spec guidance.
const int _keepAliveSecs = 60;

/// Wraps [MqttFrameBuffer] (the pure reassembler from mqtt_codec.dart) with
/// a proactive size guard. See the file doc comment, "Max-frame guard".
class _FrameGuard {
  final MqttFrameBuffer _frameBuffer = MqttFrameBuffer();
  Uint8List _shadow = Uint8List(0);

  /// Feeds [chunk] in. Returns the complete packets now available, or null
  /// if the DECLARED size of the frame currently being assembled exceeds
  /// [_maxFrameBytes] — the caller must drop the connection in that case
  /// rather than continue buffering.
  List<Uint8List>? onData(Uint8List chunk) {
    _shadow = _appendBytes(_shadow, chunk);
    if (_shadow.length >= 2) {
      final rl = decodeRemainingLength(_shadow, 1);
      if (rl != null) {
        final total = 1 + rl.bytesConsumed + rl.value;
        if (total > _maxFrameBytes) {
          return null;
        }
      }
    }
    final packets = _frameBuffer.add(chunk);
    if (packets.isNotEmpty) {
      final consumed = packets.fold<int>(0, (sum, p) => sum + p.length);
      _shadow = consumed >= _shadow.length ? Uint8List(0) : Uint8List.sublistView(_shadow, consumed);
    }
    return packets;
  }
}

Uint8List _appendBytes(Uint8List a, Uint8List b) {
  if (a.isEmpty) {
    return b;
  }
  if (b.isEmpty) {
    return a;
  }
  final out = Uint8List(a.length + b.length);
  out.setRange(0, a.length, a);
  out.setRange(a.length, a.length + b.length, b);
  return out;
}

/// Builds a raw PUBACK packet (section 3.4) for an inbound QoS-1 PUBLISH.
/// `mqtt_codec.dart` deliberately doesn't export a PUBACK builder (only a
/// client ever needs to originate one, and this is that client) — the wire
/// format is a fixed 4 bytes, trivial enough to inline here rather than
/// growing the shared pure codec for a single caller.
Uint8List _encodePuback(int packetId) {
  return Uint8List.fromList([
    MqttPacketType.puback << 4,
    2,
    (packetId >> 8) & 0xFF,
    packetId & 0xFF,
  ]);
}

PlcTag? _findRootTag(PlcProject project, String path) {
  final rootName = path.split('.').first.split('[').first;
  for (final t in project.tags) {
    if (t.name == rootName) {
      return t;
    }
  }
  return null;
}

/// Force-aware write guard mirroring `modbus_pdu.dart`'s `_isForcedSkip`:
/// find the ROOT tag of the (possibly dotted) path and honor its `isForced`
/// flag. Like Modbus (and unlike the OPC UA host's visible
/// Bad_UserAccessDenied refusal), MQTT command messages have no synchronous
/// response channel back to the remote publisher, so a forced tag's remote
/// write is silently dropped — the value the forcing engineer chose keeps
/// winning.
bool _isForcedSkip(PlcProject project, String path) {
  final root = _findRootTag(project, path);
  return root != null && root.isForced && root.value is! Map && root.value is! List;
}

/// The `dart:io` MQTT/Sparkplug B publisher client host. A [ChangeNotifier]
/// so the Outbound Protocols screen can reactively show status/endpoint/
/// last-error/publish-count.
///
/// Fully opt-in: until [connect] is called, this class does nothing and the
/// app behaves exactly as it does today.
class MqttHost extends ChangeNotifier {
  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  _FrameGuard _guard = _FrameGuard();
  MqttPublisher _publisher = MqttPublisher();

  PlcProject Function()? _projectProvider;
  String _password = '';

  Timer? _pingTimer;
  Timer? _tickTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _stopping = false;
  bool _disposed = false;
  bool _connacked = false;
  int _packetIdCounter = 1;
  final Set<int> _pendingAcks = {};
  final Stopwatch _clock = Stopwatch();
  int _lastHeartbeatMs = 0;

  MqttHostStatus _status = MqttHostStatus.stopped;
  MqttHostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  /// True once the broker has accepted CONNECT (CONNACK return code 0).
  bool get connected => _status == MqttHostStatus.running;

  int _publishCount = 0;
  int get publishCount => _publishCount;

  void _setStatus(MqttHostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Starts (or restarts) connecting `projectProvider()`'s current project's
  /// MQTT configuration to its configured broker. Idempotent while already
  /// connecting/running — call [disconnect] first to force a fresh attempt
  /// (e.g. after editing host/port/format). `password` is supplied fresh by
  /// the caller every time (see the file doc comment, "Password handling")
  /// and is never read from `MqttProtocolConfig`.
  Future<void> connect(PlcProject Function() projectProvider, {required String password}) async {
    if (_status == MqttHostStatus.running || _status == MqttHostStatus.connecting) {
      return;
    }
    _stopping = false;
    _projectProvider = projectProvider;
    _password = password;
    _reconnectAttempt = 0;
    if (!_clock.isRunning) {
      _clock
        ..reset()
        ..start();
    }
    await _attemptConnect();
  }

  Future<void> _attemptConnect() async {
    if (_stopping || _disposed) {
      return;
    }
    final projectProvider = _projectProvider;
    if (projectProvider == null) {
      return;
    }

    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      _setStatus(MqttHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }

    final cfg = project.protocols?.mqtt;
    if (cfg == null || !cfg.enabled) {
      _setStatus(MqttHostStatus.error, error: 'MQTT is not enabled for this project.');
      return;
    }

    _setStatus(MqttHostStatus.connecting);
    _endpointUrl = '${cfg.tls ? 'mqtts' : 'mqtt'}://${cfg.host}:${cfg.port}';

    // Fresh per-attempt state — see the file doc comment, "bdSeq ordering",
    // for why a brand-new MqttPublisher (and a fresh frame guard/packet-id
    // counter) on EVERY attempt (not just the first) matters.
    final publisher = MqttPublisher();
    _publisher = publisher;
    _guard = _FrameGuard();
    _packetIdCounter = 1;
    _pendingAcks.clear();
    _connacked = false;

    try {
      // MUST run before a single CONNECT byte is sent (see "bdSeq ordering").
      final will = publisher.willMessage(project);

      final socket = cfg.tls
          ? await SecureSocket.connect(cfg.host, cfg.port, timeout: const Duration(seconds: 10))
          : await Socket.connect(cfg.host, cfg.port, timeout: const Duration(seconds: 10));

      if (_stopping || _disposed) {
        // A disconnect()/dispose() raced this attempt while the socket
        // handshake was in flight — tear the now-unwanted socket back down
        // instead of resurrecting a stale connection.
        try {
          socket.destroy();
        } catch (_) {
          // Ignore.
        }
        return;
      }

      _socket = socket;
      final connectPacket = encodeConnect(
        clientId: _clientId(cfg, project),
        keepAliveSecs: _keepAliveSecs,
        cleanSession: true,
        username: cfg.username.trim().isEmpty ? null : cfg.username,
        password: _password.isEmpty ? null : _password,
        willTopic: will?.topic,
        willPayload: will?.payload,
        willRetain: will?.retain ?? false,
        willQos: will?.qos ?? 0,
      );
      socket.add(connectPacket);

      _sub = socket.listen(
        _onSocketData,
        onError: (Object e, StackTrace st) => _onSocketProblem(e),
        onDone: () => _onSocketProblem(null),
        cancelOnError: false,
      );
    } catch (e) {
      _socket = null;
      _setStatus(MqttHostStatus.error, error: e.toString());
      _scheduleReconnect();
    }
  }

  String _clientId(MqttProtocolConfig cfg, PlcProject project) {
    final edge = cfg.edgeNodeId.trim().isEmpty ? project.name : cfg.edgeNodeId;
    final sanitized = edge.trim().replaceAll(RegExp(r'\s+'), '_');
    return 'softplc-$sanitized';
  }

  void _onSocketData(Uint8List data) {
    if (_stopping || _disposed) {
      return;
    }
    try {
      final packets = _guard.onData(data);
      if (packets == null) {
        _dropAndReconnect('The broker sent an oversized frame.');
        return;
      }
      for (final packet in packets) {
        _dispatchPacket(packet);
        if (_stopping || _disposed || _socket == null) {
          // The connection may have already been dropped by an earlier
          // packet in this same batch — stop processing the rest of it.
          return;
        }
      }
    } catch (_) {
      // A crash while reassembling/dispatching must never take this host
      // down — drop the connection and let the reconnect loop retry.
      _dropAndReconnect('Unexpected error handling data from the broker.');
    }
  }

  void _dispatchPacket(Uint8List packet) {
    if (packet.isEmpty) {
      return;
    }
    final type = (packet[0] >> 4) & 0x0F;
    switch (type) {
      case MqttPacketType.connack:
        _handleConnack(packet);
        break;
      case MqttPacketType.publish:
        _handlePublish(packet);
        break;
      case MqttPacketType.puback:
        final id = parsePuback(packet);
        if (id != null) {
          _pendingAcks.remove(id);
        }
        break;
      case MqttPacketType.suback:
        // Granted-QoS values aren't tracked further — the SUBSCRIBE already
        // requested the config's desired QoS; a broker downgrade isn't
        // separately acted on.
        break;
      case MqttPacketType.pingresp:
        break;
      default:
        // An unrecognized/reserved packet type (or a byte stream that isn't
        // MQTT at all) is a protocol violation from this host's
        // perspective — drop rather than guess at recovery.
        _dropAndReconnect('The broker sent an unrecognized packet.');
    }
  }

  void _handleConnack(Uint8List packet) {
    if (_connacked) {
      return; // An unexpected second CONNACK — ignore rather than re-birth.
    }
    final connack = parseConnack(packet);
    if (connack == null) {
      _dropAndReconnect('The broker sent a malformed CONNACK.');
      return;
    }
    if (connack.returnCode != 0) {
      _dropAndReconnect('The broker refused the connection (code ${connack.returnCode}).');
      return;
    }

    final projectProvider = _projectProvider;
    if (projectProvider == null) {
      return;
    }
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      _dropAndReconnect('Could not read the current project: $e');
      return;
    }

    _connacked = true;
    _reconnectAttempt = 0;

    // ONLY after CONNACK-accepted — see "bdSeq ordering" in the file doc.
    final nowMs = _clock.elapsedMilliseconds;
    _lastHeartbeatMs = nowMs;
    for (final d in _publisher.birthMessages(project, nowMs)) {
      _sendPublish(d);
    }

    final filters = _publisher.commandTopicFilters(project);
    if (filters.isNotEmpty) {
      final qos = project.protocols?.mqtt?.qos ?? 0;
      final subscribePacket = encodeSubscribe(
        packetId: _nextPacketId(),
        topicFilters: filters.map((f) => MqttTopicFilter(f, qos: qos)).toList(),
      );
      _socket?.add(subscribePacket);
    }

    _startKeepAliveTimer();
    _startTickTimer();
    _setStatus(MqttHostStatus.running);
  }

  void _handlePublish(Uint8List packet) {
    final pub = parsePublish(packet);
    if (pub == null) {
      _dropAndReconnect('The broker sent a malformed PUBLISH.');
      return;
    }
    if (pub.qos > 0 && pub.packetId != null) {
      _socket?.add(_encodePuback(pub.packetId!));
    }

    final projectProvider = _projectProvider;
    if (projectProvider == null) {
      return;
    }
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (_) {
      return;
    }
    if (project.protocols?.mqtt?.allowRemoteWrites != true) {
      return;
    }

    final commands = _publisher.decodeCommand(pub.topic, pub.payload, project);
    for (final cmd in commands) {
      if (_isForcedSkip(project, cmd.tagPath)) {
        continue;
      }
      writePath(project, cmd.tagPath, cmd.value);
    }
  }

  void _onTick(Timer timer) {
    if (!_connacked || _disposed) {
      return;
    }
    final projectProvider = _projectProvider;
    if (projectProvider == null) {
      return;
    }
    try {
      final PlcProject project;
      try {
        project = projectProvider();
      } catch (_) {
        return; // a transient project-read failure just skips this tick
      }
      final cfg = project.protocols?.mqtt;
      if (cfg == null) {
        return;
      }
      final nowMs = _clock.elapsedMilliseconds;
      var sentAny = false;
      for (final d in _publisher.changedPublishes(project, nowMs)) {
        _sendPublish(d);
        sentAny = true;
      }
      if (cfg.heartbeatSeconds > 0 && (nowMs - _lastHeartbeatMs) >= cfg.heartbeatSeconds * 1000) {
        _lastHeartbeatMs = nowMs;
        for (final d in _publisher.heartbeatPublishes(project, nowMs)) {
          _sendPublish(d);
          sentAny = true;
        }
      }
      if (sentAny && !_disposed) {
        notifyListeners();
      }
    } catch (_) {
      // A crash driving the publish tick must never take this host down —
      // drop the connection and let the reconnect loop retry from a clean
      // state.
      _dropAndReconnect('Unexpected error while publishing.');
    }
  }

  void _sendPublish(MqttPublishDescriptor d) {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    int? packetId;
    if (d.qos > 0) {
      packetId = _nextPacketId();
      _pendingAcks.add(packetId);
    }
    socket.add(encodePublish(topic: d.topic, payload: d.payload, qos: d.qos, retain: d.retain, packetId: packetId));
    _publishCount++;
  }

  int _nextPacketId() {
    final id = _packetIdCounter;
    _packetIdCounter = _packetIdCounter >= 0xFFFF ? 1 : _packetIdCounter + 1;
    return id;
  }

  void _startKeepAliveTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: _keepAliveSecs ~/ 2), (_) {
      _socket?.add(encodePingReq());
    });
  }

  void _startTickTimer() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(milliseconds: 50), _onTick);
  }

  void _onSocketProblem(Object? error) {
    if (_stopping || _disposed) {
      return;
    }
    _teardownConnectionOnly();
    _setStatus(MqttHostStatus.error, error: error?.toString() ?? 'Connection to the broker was closed.');
    _scheduleReconnect();
  }

  void _dropAndReconnect(String reason) {
    if (_stopping || _disposed) {
      return;
    }
    _teardownConnectionOnly();
    _setStatus(MqttHostStatus.error, error: reason);
    _scheduleReconnect();
  }

  void _teardownConnectionOnly() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _connacked = false;
    try {
      _sub?.cancel();
    } catch (_) {
      // Ignore.
    }
    _sub = null;
    try {
      _socket?.destroy();
    } catch (_) {
      // Ignore.
    }
    _socket = null;
    _endpointUrl = null;
  }

  void _scheduleReconnect() {
    if (_stopping || _disposed) {
      return;
    }
    _reconnectAttempt++;
    final capped = _reconnectAttempt.clamp(1, 6);
    final delayMs = 1000 * (1 << (capped - 1)); // 1s,2s,4s,8s,16s,32s cap
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      unawaited(_attemptConnect());
    });
  }

  /// Stops the publisher session: sends a graceful MQTT DISCONNECT (which
  /// tells the broker NOT to fire the registered Will — the Will is a
  /// dead-connection safety net, not something a clean shutdown re-publishes
  /// itself; see `mqtt_publisher.dart`'s `willMessage` doc comment), tears
  /// down the socket, and cancels every timer. Safe to call when never
  /// connected or already stopped.
  Future<void> disconnect() async {
    _stopping = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    try {
      _socket?.add(encodeDisconnect());
      await _socket?.flush();
    } catch (_) {
      // Ignore — best-effort graceful notice only.
    }
    _teardownConnectionOnly();
    _clock.stop();
    _setStatus(MqttHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    super.dispose();
  }
}
