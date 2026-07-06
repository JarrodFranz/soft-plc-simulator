// The app-side WebSocket client for the OPC UA companion gateway bridge
// (WS16). Speaks the pure tag-sync protocol defined in
// `../models/gateway_sync.dart` over a `WebSocketChannel`. The app is always
// the WebSocket *client* (outbound only); the gateway is the server.
//
// See docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md,
// "App side". The channel is injected so tests can substitute a fake
// `StreamChannel`-backed channel with no real socket.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/gateway_sync.dart';
import '../models/opcua_map.dart';
import '../models/project_model.dart';
import '../models/tag_resolver.dart';

/// Connection lifecycle of the [GatewayClient].
enum GatewayStatus { disconnected, connecting, connected, error }

/// Default gateway WebSocket endpoint shown as the panel's starting value.
/// Port 4855 is arbitrary but fixed so users/docs can rely on it as the
/// convention for this project's companion gateway.
const String kDefaultGatewayUrl = 'ws://localhost:4855';

PlcTag? _rootTagOf(PlcProject p, String path) {
  final rootName = path.split('.').first.split('[').first;
  for (final t in p.tags) {
    if (t.name == rootName) {
      return t;
    }
  }
  return null;
}

/// Applies [value] to [path] unless the root tag is forced — mirrors the
/// exact rule `fbd_exec.dart`'s `_forceAwareWrite` uses (forcing wins; an
/// inbound protocol write must never clobber a forced tag).
void _forceAwareWrite(PlcProject p, String path, dynamic value) {
  final root = _rootTagOf(p, path);
  if (root != null && root.isForced && root.name == path) {
    return; // forcing wins
  }
  writePath(p, path, value);
}

/// Builds the exposed-tag set for [project]: its `opcuaMap` nodes (or an
/// auto-generated default when no map is set) resolved against the tag
/// database into wire-ready [ExposedTag]s.
List<ExposedTag> _exposedTagsOf(PlcProject project) {
  final map = project.opcuaMap ?? OpcuaMap.autoGenerate(project);
  final out = <ExposedTag>[];
  for (final node in map.nodes) {
    final tag = project.tags.where((t) => t.name == node.tag).firstOrNull;
    if (tag == null) {
      continue;
    }
    final value = readPath(project, node.tag);
    out.add(ExposedTag(
      path: node.tag,
      dataType: tag.dataType,
      value: tagValueToJson(value, tag.dataType),
      access: node.access,
    ));
  }
  return out;
}

/// WebSocket client that speaks the app<->gateway tag-sync protocol.
///
/// A [ChangeNotifier] so a Flutter UI can listen for status/error/count
/// changes. Fully opt-in: until [connect] is called the client does nothing,
/// and the rest of the app behaves exactly as it does today.
class GatewayClient extends ChangeNotifier {
  /// Injectable channel factory. Defaults to the real
  /// `WebSocketChannel.connect`; tests inject a fake returning a
  /// controllable `StreamChannel`.
  final WebSocketChannel Function(Uri uri) _connectChannel;

  GatewayClient({WebSocketChannel Function(Uri uri)? connect})
      : _connectChannel = connect ?? WebSocketChannel.connect;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  String? _url;

  GatewayStatus _status = GatewayStatus.disconnected;
  GatewayStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  int _exposedTagCount = 0;
  int get exposedTagCount => _exposedTagCount;

  /// Last value sent to the gateway per exposed tag path, so [syncTags] can
  /// compute a changed-only delta.
  final Map<String, dynamic> _lastSent = {};

  void _setStatus(GatewayStatus s) {
    _status = s;
    notifyListeners();
  }

  /// Opens the channel, sends `hello` then a full `snapshot` of the
  /// project's exposed tags. Never throws.
  Future<void> connect(String url, PlcProject project) async {
    _url = url;
    _lastError = null;
    _setStatus(GatewayStatus.connecting);
    try {
      final uri = Uri.parse(url);
      final channel = _connectChannel(uri);
      // Yield so callers can observe the `connecting` status before this
      // completes synchronously (mirrors a real socket's async handshake).
      await Future<void>.value();
      _channel = channel;
      _sub = channel.stream.listen(
        (data) => _handleInbound(data, project),
        onError: (Object err, StackTrace st) {
          _lastError = err.toString();
          _setStatus(GatewayStatus.error);
        },
        onDone: () {
          if (_status != GatewayStatus.error) {
            _setStatus(GatewayStatus.disconnected);
          }
        },
        cancelOnError: false,
      );
      _sendHelloAndSnapshot(project);
      _setStatus(GatewayStatus.connected);
    } catch (e) {
      _lastError = e.toString();
      _setStatus(GatewayStatus.error);
    }
  }

  void _sendHelloAndSnapshot(PlcProject project) {
    final exposed = _exposedTagsOf(project);
    _exposedTagCount = exposed.length;
    _lastSent
      ..clear()
      ..addEntries(exposed.map((t) => MapEntry(t.path, t.value)));
    _send(HelloMsg(
      project: project.name,
      controller: project.controllerName,
      scanMs: project.scanPeriodMs,
    ));
    _send(SnapshotMsg(tags: exposed));
  }

  /// Computes changed exposed tags vs last-sent and sends a `delta` if any
  /// changed. No-op when nothing changed or not connected.
  void syncTags(PlcProject project) {
    if (_status != GatewayStatus.connected) {
      return;
    }
    try {
      final exposed = _exposedTagsOf(project);
      _exposedTagCount = exposed.length;
      final changes = <TagChange>[];
      for (final tag in exposed) {
        final prev = _lastSent[tag.path];
        if (!_lastSent.containsKey(tag.path) || prev != tag.value) {
          changes.add(TagChange(path: tag.path, value: tag.value));
          _lastSent[tag.path] = tag.value;
        }
      }
      if (changes.isNotEmpty) {
        _send(DeltaMsg(changes: changes));
      }
    } catch (_) {
      // Never let a sync error break the scan loop.
    }
  }

  void _handleInbound(dynamic data, PlcProject project) {
    try {
      if (data is! String) {
        return;
      }
      final msg = decodeMessage(data);
      if (msg is WriteMsg) {
        _forceAwareWrite(project, msg.path, msg.value);
        notifyListeners();
      } else if (msg is PingMsg) {
        _send(const PongMsg());
      } else if (msg is ReadyMsg) {
        _setStatus(GatewayStatus.connected);
      } else {
        // UnknownMsg (or any other type) is ignored.
      }
    } catch (_) {
      // Guard: never let a malformed inbound frame throw into the app.
    }
  }

  void _send(SyncMessage m) {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    try {
      channel.sink.add(encodeMessage(m));
    } catch (e) {
      _lastError = e.toString();
      _setStatus(GatewayStatus.error);
    }
  }

  /// Closes the channel and moves to disconnected. Safe to call when not
  /// connected.
  Future<void> disconnect() async {
    try {
      await _sub?.cancel();
      await _channel?.sink.close();
    } catch (_) {
      // Ignore close errors — we're tearing down anyway.
    }
    _channel = null;
    _sub = null;
    _lastSent.clear();
    _setStatus(GatewayStatus.disconnected);
  }

  /// Manual reconnect: re-opens the channel at the last-used URL and
  /// re-sends `hello`+`snapshot`.
  Future<void> reconnect(PlcProject project) async {
    final url = _url;
    if (url == null) {
      return;
    }
    await connect(url, project);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_channel?.sink.close());
    super.dispose();
  }
}
