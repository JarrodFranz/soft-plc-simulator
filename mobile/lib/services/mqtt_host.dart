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
// --- bdSeq monotonicity ACROSS reconnects ------------------------------
// The pairing above holds WITHIN one attempt, but `bdSeq` must also never
// reset across attempts (Sparkplug B requires it strictly increase every
// (re)connect, so a subscriber can tell a stale NDEATH from the current
// session's — see the design doc, "bdSeq increments each (re)connect").
// This host owns `_bdSeqCounter`, an in-memory counter that survives across
// the per-attempt `MqttPublisher` instances: each fresh publisher is
// constructed with `MqttPublisher(initialBdSeq: _bdSeqCounter)`, and right
// after `willMessage` advances it, `_bdSeqCounter` is updated to that
// publisher's new `bdSeq` value so the NEXT attempt's publisher continues
// from there (session 1 -> bdSeq 1, session 2 -> bdSeq 2, and so on).
// `_bdSeqCounter` is NEVER reset by [connect]/[disconnect] — it only starts
// at 0 for the lifetime of this [MqttHost] instance, so an explicit
// disconnect-then-reconnect from the UI (not just the automatic backoff
// loop) still advances bdSeq, exactly like every other reconnect.
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
// --- Wall-clock message timestamps vs. the monotonic `_clock` --------------
// This host owns TWO separate notions of "now", and they must never be
// confused:
//   - `_clock` (a `Stopwatch`) is monotonic time since [connect] was first
//     called. It exists ONLY to drive the heartbeat interval gate in
//     [_onTick] (`intervalMs - _lastHeartbeatMs >= heartbeatSeconds * 1000`)
//     and the `_lastHeartbeatMs` baseline it's compared against — pure
//     elapsed-time arithmetic, for which a Stopwatch is exactly right.
//   - [_wallNowMs] is real wall-clock time
//     (`DateTime.now().toUtc().millisecondsSinceEpoch`, overridable via
//     [nowMsOverride] for tests) — what gets stamped on every OUTBOUND
//     message (`birthMessages`/`changedPublishes`/`heartbeatPublishes`'s
//     `nowMs` parameter), because Sparkplug B (and the JSON payload's
//     `timestamp` field) require the current UTC epoch, not an
//     arbitrary monotonic counter. A subscriber (e.g. Ignition's MQTT
//     Engine) treats a message whose timestamp is decades stale as bad data
//     and never applies it — passing `_clock.elapsedMilliseconds` here was
//     exactly that bug.
// Never pass `_clock.elapsedMilliseconds` to a publisher method that stamps a
// message timestamp, and never pass [_wallNowMs]'s value into the heartbeat
// interval gate.
//
// --- Sparkplug rebirth (Node Control/Rebirth NCMD) -------------------------
// A Sparkplug B subscriber requests a rebirth by publishing a boolean-true
// `Node Control/Rebirth` metric to the NCMD topic. This host subscribes to
// that topic on every (re)connect via `_publisher.ncmdSubscriptionTopic`
// (independent of `allowRemoteWrites`, which only gates ordinary tag-write
// commands — a rebirth request is not a tag write) and, in [_handlePublish],
// checks `_publisher.isRebirthRequest` BEFORE the `allowRemoteWrites` gate.
// Answering re-sends NBIRTH (same bdSeq — no `willMessage` call, since a
// rebirth isn't a new connection attempt) via the same `birthMessages` +
// `_sendPublish` path the initial birth uses. [requestRebirth] exposes the
// exact same re-publish for the UI's manual "Rebirth" button — e.g. after
// the operator edits the tag map (Gateway screen) while already connected,
// so a remote Sparkplug B subscriber sees the new metric set without a
// disconnect/reconnect round trip.
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

import '../models/app_log.dart';
import '../models/project_model.dart';
import '../models/protocol_settings.dart';
import '../models/tag_resolver.dart';
import '../protocols/mqtt/mqtt_codec.dart';
import '../protocols/mqtt/mqtt_publisher.dart';
import 'app_logger.dart';
import 'notify_throttle.dart';

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

  /// Overrides the keep-alive PINGREQ timer's period. Production code never
  /// passes this (it always uses the fixed `_keepAliveSecs ~/ 2` interval —
  /// see [_startKeepAliveTimer]); it exists solely so tests can shrink the
  /// timer far enough to deterministically exercise the guarded ping-send
  /// path against a broker connection that closes mid-session, without
  /// waiting out the real 30-second production interval.
  @visibleForTesting
  final Duration? pingIntervalOverride;

  /// Overrides the wall-clock source used to stamp every outbound message
  /// timestamp (NBIRTH/NDATA/NDEATH `timestampMs`, and the JSON payload's
  /// `timestamp` field). Production code never passes this — it always uses
  /// the real `DateTime.now().toUtc().millisecondsSinceEpoch` (see
  /// [_wallNowMs]); it exists solely so tests can inject a fixed, easily
  /// asserted epoch value instead of a moving real-world clock. The
  /// monotonic `_clock` (Stopwatch) below is a SEPARATE thing — it's kept
  /// only for the heartbeat interval gate, which needs elapsed-time math, not
  /// wall-clock time.
  @visibleForTesting
  final int Function()? nowMsOverride;

  /// Optional diagnostics sink. Deliberately NULLABLE: a host constructed
  /// without one behaves exactly as it did before this parameter existed.
  ///
  /// *** THE BROKER PASSWORD MUST NEVER REACH THIS SINK. *** Every log call
  /// in this class records an OUTCOME ("the broker refused the connection")
  /// and never the credential, and never a whole packet/descriptor object
  /// that could carry one. See `_password`'s own doc above.
  final AppLogger? logger;

  MqttHost({this.pingIntervalOverride, this.nowMsOverride, this.logger}) {
    _throttle = NotifyThrottle(() => notifyListeners(), window: const Duration(milliseconds: 250));
  }

  /// Coalesces the high-frequency per-tick `notifyListeners()` calls (up to
  /// 20x/sec at the fastest configurable publish interval) to at most one
  /// trailing UI rebuild every 250ms — see `notify_throttle.dart`. State
  /// transitions (connect/connack/disconnect/error/rebirth) instead call
  /// [NotifyThrottle.immediate] so the UI reflects them without delay (and
  /// coalesces away any pending trailing tick-driven fire).
  late final NotifyThrottle _throttle;

  /// The current wall-clock time in UTC epoch milliseconds — what Sparkplug B
  /// (and the JSON payload) require for a message timestamp. Defers to
  /// [nowMsOverride] when a test has supplied one.
  int _wallNowMs() => nowMsOverride?.call() ?? DateTime.now().toUtc().millisecondsSinceEpoch;

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
  int _bdSeqCounter = 0;
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
      _throttle.immediate();
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
      // Always-on: the connection attempt did not happen, and without this
      // the operator gets an error status with no recorded cause — while the
      // "not enabled" branch just below has been logged all along.
      logger?.log(
        kLogSourceMqtt,
        LogLevel.error,
        'Not connecting: the current project could not be read.',
        detail: e.toString(),
      );
      _setStatus(MqttHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }

    final cfg = project.protocols?.mqtt;
    if (cfg == null || !cfg.enabled) {
      logger?.log(
        kLogSourceMqtt,
        LogLevel.warn,
        'Not connecting: MQTT is not enabled for this project.',
      );
      _setStatus(MqttHostStatus.error, error: 'MQTT is not enabled for this project.');
      return;
    }

    _setStatus(MqttHostStatus.connecting);
    _endpointUrl = '${cfg.tls ? 'mqtts' : 'mqtt'}://${cfg.host}:${cfg.port}';
    // Endpoint and whether a username was configured — an OUTCOME-shaped
    // fact. The password is never named, quoted, or length-hinted here.
    logger?.log(
      kLogSourceMqtt,
      LogLevel.info,
      'Connecting to the broker (attempt ${_reconnectAttempt + 1}, '
      '${cfg.username.trim().isEmpty ? 'no username configured' : 'username auth'}).',
      detail: _endpointUrl,
    );

    // Fresh per-attempt state — see the file doc comment, "bdSeq ordering",
    // for why a brand-new MqttPublisher (and a fresh frame guard/packet-id
    // counter) on EVERY attempt (not just the first) matters. `_bdSeqCounter`
    // is NOT reset here — see "bdSeq monotonicity ACROSS reconnects" — it
    // seeds this fresh publisher so bdSeq keeps climbing instead of
    // restarting at 0/1 on every (re)connect.
    final publisher = MqttPublisher(initialBdSeq: _bdSeqCounter);
    _publisher = publisher;
    _guard = _FrameGuard();
    _packetIdCounter = 1;
    _pendingAcks.clear();
    _connacked = false;

    try {
      // MUST run before a single CONNECT byte is sent (see "bdSeq ordering").
      final will = publisher.willMessage(project);
      _bdSeqCounter = publisher.bdSeq;

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
      logger?.log(
        kLogSourceMqtt,
        LogLevel.error,
        'Could not connect to the broker.',
        detail: e.toString(),
      );
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
        logger?.log(
          kLogSourceMqtt,
          LogLevel.warn,
          'Dropped the connection: the broker declared an oversized frame.',
        );
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
        // perspective — drop rather than guess at recovery. Naming the type
        // is the whole difference between "it keeps reconnecting" and a
        // diagnosable cause.
        logger?.logLazy(
          kLogSourceMqtt,
          LogLevel.warn,
          () => 'Dropped the connection: the broker sent an unrecognized '
              'packet type $type (${packet.length} bytes).',
        );
        _dropAndReconnect('The broker sent an unrecognized packet.');
    }
  }

  void _handleConnack(Uint8List packet) {
    if (_connacked) {
      return; // An unexpected second CONNACK — ignore rather than re-birth.
    }
    final connack = parseConnack(packet);
    if (connack == null) {
      logger?.log(
        kLogSourceMqtt,
        LogLevel.warn,
        'Dropped the connection: the broker sent a malformed CONNACK.',
      );
      _dropAndReconnect('The broker sent a malformed CONNACK.');
      return;
    }
    if (connack.returnCode != 0) {
      // *** OUTCOME ONLY. *** Return code 4 is bad username/password and 5 is
      // not-authorized; the credential itself is NEVER recorded — not the
      // password, not its length, not a masked form of it.
      final code = connack.returnCode;
      logger?.logLazy(
        kLogSourceMqtt,
        LogLevel.warn,
        () => 'The broker refused the connection (CONNACK code $code'
            '${code == 4 ? ' — username/password rejected' : ''}'
            '${code == 5 ? ' — not authorized' : ''}).',
      );
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
      // Always-on, and more severe than the start-time case: this drops a
      // LIVE broker connection. Without a record the operator sees only a
      // reconnect cycle with no stated cause.
      logger?.log(
        kLogSourceMqtt,
        LogLevel.error,
        'Dropping the broker connection: the current project could not be '
        'read after CONNACK.',
        detail: e.toString(),
      );
      _dropAndReconnect('Could not read the current project: $e');
      return;
    }

    _connacked = true;
    _reconnectAttempt = 0;

    // ONLY after CONNACK-accepted — see "bdSeq ordering" in the file doc.
    // `_lastHeartbeatMs` stays on the monotonic clock (it's only ever
    // compared against another `_clock.elapsedMilliseconds` reading in
    // `_onTick`'s heartbeat gate) — see the file doc comment, "wall-clock
    // message timestamps". The message itself carries the WALL-CLOCK time.
    _lastHeartbeatMs = _clock.elapsedMilliseconds;
    final wallMs = _wallNowMs();
    for (final d in _publisher.birthMessages(project, wallMs)) {
      _sendPublish(d);
    }

    // Sparkplug rebirth requests (NCMD carrying `Node Control/Rebirth`) must
    // be serviced regardless of `allowRemoteWrites` — that setting only
    // gates ordinary tag-write commands — so the NCMD topic is subscribed
    // here independently of `commandTopicFilters`. A `Set` naturally avoids a
    // duplicate SUBSCRIBE entry when `allowRemoteWrites` is already on and
    // `commandTopicFilters` returned that same NCMD topic.
    final ncmdTopic = _publisher.ncmdSubscriptionTopic(project);
    final filters = <String>{
      ..._publisher.commandTopicFilters(project),
      if (ncmdTopic != null) ncmdTopic,
    };
    if (filters.isNotEmpty) {
      final qos = project.protocols?.mqtt?.qos ?? 0;
      final subscribePacket = encodeSubscribe(
        packetId: _nextPacketId(),
        topicFilters: filters.map((f) => MqttTopicFilter(f, qos: qos)).toList(),
      );
      _socket?.add(subscribePacket);
    }

    _startKeepAliveTimer();
    _startTickTimer(project);
    logger?.log(
      kLogSourceMqtt,
      LogLevel.info,
      'Connected: the broker accepted the connection '
      '(${filters.length} command topic filter(s) subscribed).',
      detail: _endpointUrl,
    );
    _setStatus(MqttHostStatus.running);
  }

  void _handlePublish(Uint8List packet) {
    final pub = parsePublish(packet);
    if (pub == null) {
      logger?.log(
        kLogSourceMqtt,
        LogLevel.warn,
        'Dropped the connection: the broker sent a malformed PUBLISH.',
      );
      _dropAndReconnect('The broker sent a malformed PUBLISH.');
      return;
    }
    // Topic and sizes only — a command PAYLOAD is never logged. It is
    // attacker/operator-controlled content of unbounded size, and dumping a
    // whole inbound message is exactly how a secret ends up in a log.
    logger?.logLazy(
      kLogSourceMqtt,
      LogLevel.debug,
      () => 'Inbound PUBLISH on "${pub.topic}" '
          '(${pub.payload.length} payload bytes, QoS ${pub.qos}).',
    );
    if (pub.qos > 0 && pub.packetId != null) {
      _socket?.add(_encodePuback(pub.packetId!));
    }

    final projectProvider = _projectProvider;
    if (projectProvider == null) {
      logger?.logLazy(
        kLogSourceMqtt,
        LogLevel.debug,
        () => 'Dropped an inbound message on "${pub.topic}": no project is '
            'currently loaded.',
      );
      return;
    }
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      logger?.log(
        kLogSourceMqtt,
        LogLevel.warn,
        'Dropped an inbound message: the current project could not be read.',
        detail: e.toString(),
      );
      return;
    }

    // A Sparkplug rebirth request must be answered regardless of
    // `allowRemoteWrites` — see the file doc comment. Re-issuing NBIRTH here
    // mirrors the initial birth send in `_handleConnack`: same bdSeq (no
    // `willMessage` call — a rebirth is not a new connection), seq reset to
    // 0, and the alias table/report-by-exception baseline rebuilt, all of
    // which `birthMessages` already does.
    if (_publisher.isRebirthRequest(pub.topic, pub.payload, project)) {
      final wallMs = _wallNowMs();
      for (final d in _publisher.birthMessages(project, wallMs)) {
        _sendPublish(d);
      }
      _lastHeartbeatMs = _clock.elapsedMilliseconds;
      if (!_disposed) {
        _throttle.immediate();
      }
      return;
    }

    if (project.protocols?.mqtt?.allowRemoteWrites != true) {
      // A WRITE REFUSAL — always on, because an operator wondering why a
      // remote command "does nothing" needs to see it without first raising
      // the verbosity. Topic only; never the payload.
      logger?.logLazy(
        kLogSourceMqtt,
        LogLevel.warn,
        () => 'Remote write refused on "${pub.topic}": remote writes are '
            'disabled for this project.',
      );
      return;
    }

    final commands = _publisher.decodeCommand(pub.topic, pub.payload, project);
    for (final cmd in commands) {
      if (_isForcedSkip(project, cmd.tagPath)) {
        // A WRITE REFUSAL: the forcing engineer's value keeps winning, and
        // MQTT has no synchronous response channel to say so — so the log is
        // the only place this can ever surface. Tag path only; never the
        // value the remote publisher tried to write.
        logger?.logLazy(
          kLogSourceMqtt,
          LogLevel.warn,
          () => 'Remote write refused on tag "${cmd.tagPath}": the tag is '
              'forced.',
        );
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
      // `intervalMs` (monotonic) drives ONLY the heartbeat interval gate
      // below; `wallMs` (wall-clock, overridable in tests) is what actually
      // gets stamped on the outbound messages — see the file doc comment,
      // "wall-clock message timestamps".
      final intervalMs = _clock.elapsedMilliseconds;
      final wallMs = _wallNowMs();
      var sentAny = false;
      for (final d in _publisher.changedPublishes(project, wallMs)) {
        _sendPublish(d);
        sentAny = true;
      }
      if (cfg.heartbeatSeconds > 0 && (intervalMs - _lastHeartbeatMs) >= cfg.heartbeatSeconds * 1000) {
        _lastHeartbeatMs = intervalMs;
        for (final d in _publisher.heartbeatPublishes(project, wallMs)) {
          _sendPublish(d);
          sentAny = true;
        }
      }
      if (sentAny && !_disposed) {
        _throttle.request();
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
    final interval = pingIntervalOverride ?? const Duration(seconds: _keepAliveSecs ~/ 2);
    _pingTimer = Timer.periodic(interval, (_) {
      try {
        _socket?.add(encodePingReq());
      } catch (_) {
        // A socket that closed in the window before onDone/onError fires
        // (and thus before this timer is cancelled) must not crash the
        // host — mirrors disconnect()'s own guarded DISCONNECT send below.
      }
    });
  }

  void _startTickTimer(PlcProject project) {
    _tickTimer?.cancel();
    // Configurable publish interval (default 250ms; was hardcoded 50ms) —
    // event-loop-flood fix: 100 tags at 20Hz re-evaluated `changedPublishes`
    // every 50ms regardless of how many tags actually changed. Clamped to a
    // floor of 20ms so a misconfigured/zero/negative value can't spin the
    // event loop. Re-armed on every (re)connect (this method's only caller),
    // so a config change takes effect on the NEXT connect.
    final configuredMs = project.protocols?.mqtt?.publishIntervalMs ?? 250;
    final clampedMs = configuredMs < 20 ? 20 : configuredMs;
    _tickTimer = Timer.periodic(Duration(milliseconds: clampedMs), _onTick);
  }

  void _onSocketProblem(Object? error) {
    if (_stopping || _disposed) {
      return;
    }
    logger?.log(
      kLogSourceMqtt,
      LogLevel.warn,
      'Disconnected from the broker; a reconnect is scheduled.',
      detail: error?.toString(),
    );
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

  /// Manually re-publishes NBIRTH (a Sparkplug B "rebirth") for the current
  /// project's tag map WITHOUT disconnecting/reconnecting — e.g. after the
  /// user adds/edits/removes an entry in the MQTT tag map editor while
  /// already connected, so an external Sparkplug B subscriber (Ignition MQTT
  /// Engine, etc.) picks up the new metric set without this host ever
  /// dropping the socket. Mirrors EXACTLY the inbound-rebirth branch in
  /// [_handlePublish]: same `bdSeq` (no [MqttPublisher.willMessage] call —
  /// this isn't a new connection attempt), `seq` reset to 0, and the alias
  /// table/report-by-exception baseline rebuilt — all of which
  /// [MqttPublisher.birthMessages] already does — then resets
  /// `_lastHeartbeatMs` exactly like that branch does.
  ///
  /// A no-op (and never throws) unless [status] is
  /// [MqttHostStatus.running] with a resolvable project — safe to call from
  /// the UI in any state. For the JSON payload format, `birthMessages`
  /// merely re-publishes the retained "ONLINE" status message (harmless);
  /// the UI is expected to only surface this action for Sparkplug format,
  /// since JSON has no rebirth concept, but this method itself doesn't
  /// enforce that.
  void requestRebirth() {
    if (_status != MqttHostStatus.running || _disposed) {
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
        return;
      }
      final wallMs = _wallNowMs();
      for (final d in _publisher.birthMessages(project, wallMs)) {
        _sendPublish(d);
      }
      _lastHeartbeatMs = _clock.elapsedMilliseconds;
      if (!_disposed) {
        _throttle.immediate();
      }
    } catch (_) {
      // A manual rebirth request must never throw — it's a best-effort UI
      // action, not part of the connect/reconnect lifecycle.
    }
  }

  /// Stops the publisher session: publishes an explicit Sparkplug B NDEATH
  /// (see below), then sends a graceful MQTT DISCONNECT (which tells the
  /// broker NOT to fire the registered Will — the Will remains a
  /// dead-connection safety net for an UNEXPECTED drop; see
  /// `mqtt_publisher.dart`'s `willMessage` doc comment), tears down the
  /// socket, and cancels every timer. Safe to call when never connected or
  /// already stopped.
  Future<void> disconnect() async {
    _stopping = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Sparkplug B: a clean MQTT DISCONNECT tells the broker NOT to fire the
    // registered Will (NDEATH). So on an INTENTIONAL stop we must publish the
    // death certificate ourselves first — otherwise the host keeps the node
    // Online forever. Uses the CURRENT session bdSeq (deathMessage does not
    // advance it). Best-effort: a broken socket here must not block teardown.
    final provider = _projectProvider;
    if (_connacked && _socket != null && provider != null) {
      try {
        final project = provider();
        final death = _publisher.deathMessage(project, _wallNowMs());
        if (death != null) {
          _sendPublish(death);
          await _socket?.flush();
        }
      } catch (_) {
        // Ignore — best-effort death notice only.
      }
    }

    try {
      _socket?.add(encodeDisconnect());
      await _socket?.flush();
    } catch (_) {
      // Ignore — best-effort graceful notice only.
    }
    final wasConnected = _socket != null;
    _teardownConnectionOnly();
    _clock.stop();
    if (wasConnected) {
      logger?.log(kLogSourceMqtt, LogLevel.info, 'Disconnected from the broker.');
    }
    _setStatus(MqttHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    _throttle.dispose();
    unawaited(disconnect());
    super.dispose();
  }
}
