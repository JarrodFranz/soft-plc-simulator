// The in-app Modbus TCP server host: the ONLY file in this project allowed to
// import `dart:io` for Modbus (WS24 Task 3). Mirrors
// `mobile/lib/services/opcua_host.dart`'s `ServerSocket` pattern exactly, but
// frames on the Modbus MBAP header instead of the OPC UA message header: for
// each connection, bytes accumulate in a buffer; once at least 6 bytes are
// present, `length = (buf[4]<<8)|buf[5]` (the MBAP length field) tells us the
// total frame size is `6 + length`; once the buffer holds that many bytes the
// frame is sliced off, decoded via `parseMbap`, handled by `ModbusServer`, and
// the response re-wrapped via `buildMbap` and written back.
//
// The app is byte-identical when hosting is stopped: nothing here runs unless
// [start] is called (an explicit, opt-in action from the Outbound Protocols
// screen).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/app_log.dart';
import '../models/project_model.dart';
import '../protocols/modbus/modbus_pdu.dart';
import '../protocols/modbus/modbus_rtu.dart';
import 'app_logger.dart';

/// Lifecycle status of the [ModbusHost].
enum ModbusHostStatus { stopped, running, error }

/// A hostile or malformed frame-size guard: the Modbus TCP spec caps the
/// whole ADU (MBAP header + PDU) at 260 bytes, so anything claiming to be
/// larger is bogus and closes just that connection rather than being
/// buffered indefinitely.
const int _maxFrameBytes = 260;

/// `0x1f`-style formatting for a wire code, so a dropped-request log entry
/// names the offending byte in the same notation the specification (and
/// every client's own log) uses.
String _hex(int v) => '0x${v.toRadixString(16).padLeft(2, '0').toUpperCase()}';

/// One accepted TCP connection: owns the socket and the byte-accumulation
/// buffer used to reassemble whole MBAP+PDU frames out of arbitrary TCP
/// chunking.
class _Connection {
  final Socket socket;
  final Uint8List? Function(ModbusFrame) handle;

  /// Wire framing mode for this connection — `kModbusFramingTcp` (the
  /// existing MBAP-header reassembly, unmodified) or
  /// `kModbusFramingRtuOverTcp` (RTU framing: no MBAP header, CRC-16 framed,
  /// function-code-derived length). Read once per connection from the
  /// project's `ModbusProtocolConfig.framing` at accept time.
  final String framing;
  final List<int> _buffer = [];
  bool _closed = false;

  /// Optional diagnostics sink. Null (the default for a bare host) makes
  /// every log call in this class a no-op — instrumentation NEVER changes
  /// protocol behaviour, it only observes it.
  final AppLogger? logger;

  _Connection(
    this.socket,
    this.handle, {
    this.framing = kModbusFramingTcp,
    this.logger,
  });

  /// Records a request this connection PARSED but did not SERVE. DEBUG (off
  /// by default) and lazy: a mis-configured master can hit these paths on
  /// every poll cycle, so neither the formatting cost nor the buffer
  /// pressure of a WARN is acceptable here.
  void _logDrop(String Function() build) {
    logger?.logLazy(kLogSourceModbus, LogLevel.debug, build);
  }

  /// Feeds newly-arrived [data] into the reassembly buffer, then extracts
  /// and dispatches as many complete frames as are available. A single
  /// socket `data` event may contain a partial frame, exactly one frame, or
  /// several frames back-to-back — all three are handled here.
  void onData(List<int> data) {
    if (_closed) return;
    _buffer.addAll(data);
    try {
      if (framing == kModbusFramingRtuOverTcp) {
        _onDataRtu();
      } else {
        _onDataTcp();
      }
    } catch (_) {
      // A crash while reassembling/dispatching must never take down the
      // host — just drop this one connection.
      close();
    }
  }

  /// The original Modbus TCP (MBAP header) reassembly path — byte-for-byte
  /// unmodified from before the RTU-over-TCP framing option existed.
  void _onDataTcp() {
    while (true) {
      if (_buffer.length < 6) {
        return; // not even the length field yet
      }
      final length = (_buffer[4] << 8) | _buffer[5];
      final totalSize = 6 + length;
      if (length < 1 || totalSize > _maxFrameBytes) {
        // Hostile/garbage size: close ONLY this connection, never crash.
        logger?.logLazy(
          kLogSourceModbus,
          LogLevel.warn,
          () => 'Closing a client: its MBAP header declared an unusable '
              'length of $length bytes.',
        );
        close();
        return;
      }
      if (_buffer.length < totalSize) {
        return; // wait for more bytes
      }
      final rawFrame = Uint8List.fromList(_buffer.sublist(0, totalSize));
      _buffer.removeRange(0, totalSize);

      final parsed = parseMbap(rawFrame);
      if (parsed == null) {
        // Malformed frame (e.g. non-zero protocolId) — drop this
        // connection rather than guess at recovery.
        logger?.log(
          kLogSourceModbus,
          LogLevel.warn,
          'Closing a client: its MBAP header was malformed (a non-zero '
          'protocol id, or a truncated frame).',
        );
        close();
        return;
      }
      _logRequest(parsed, rawFrame.length);
      final responsePdu = handle(parsed);
      if (responsePdu == null) {
        _logDrop(() => 'Dropped a request: unit id ${parsed.unitId} is not '
            'the configured unit id, so no reply was sent (function '
            '${_hex(parsed.pdu.isEmpty ? 0 : parsed.pdu[0])}).');
      }
      if (responsePdu != null) {
        // A `null` response means the configured unit id didn't match this
        // request's unit id — a real outstation stays silent rather than
        // answering on someone else's behalf, so no bytes go back at all.
        final responseFrame = buildMbap(parsed.transactionId, parsed.unitId, responsePdu);
        socket.add(responseFrame);
      }
    }
  }

  /// The Modbus RTU-over-TCP reassembly path: no MBAP header, so the total
  /// frame length is derived purely from the function code (and, for the
  /// variable-length write-multiple codes, the byteCount field) via
  /// [rtuRequestLength]. A bad-CRC frame is dropped silently (no reply,
  /// connection stays open) rather than closing the connection — RTU masters
  /// commonly retry on silence. Unit id 0 (broadcast) is likewise never
  /// replied to, even though [handle] still runs and any write still takes
  /// effect — see the comment at the write-suppression check below.
  void _onDataRtu() {
    while (true) {
      final buf = Uint8List.fromList(_buffer);
      final total = rtuRequestLength(buf);
      if (total == null) {
        return; // need more bytes to decide the frame length
      }
      if (total < 0 || total > _maxFrameBytes) {
        // Unsupported function code or an oversized/hostile frame: resync by
        // dropping everything buffered for this connection so far.
        final function = buf.length > 1 ? buf[1] : 0;
        _logDrop(() => 'Dropped ${buf.length} buffered RTU byte(s): '
            'unsupported function code ${_hex(function)} (or an oversized '
            'frame), so the frame length could not be derived.');
        _buffer.clear();
        return;
      }
      if (_buffer.length < total) {
        return; // wait for more bytes
      }
      final rawFrame = Uint8List.fromList(_buffer.sublist(0, total));
      _buffer.removeRange(0, total);

      final parsed = parseRtu(rawFrame);
      if (parsed == null) {
        // Bad CRC: drop this frame silently and keep the connection open —
        // no reply is sent (mirrors a real RTU outstation staying silent on
        // a corrupted request rather than tearing down the link).
        _logDrop(() => 'Dropped an RTU frame of ${rawFrame.length} bytes: '
            'its CRC-16 did not check out, so no reply was sent.');
        _buffer.clear();
        return;
      }
      _logRequest(parsed, rawFrame.length);
      final responsePdu = handle(parsed);
      if (responsePdu == null) {
        _logDrop(() => 'Dropped an RTU request: unit id ${parsed.unitId} is '
            'not the configured unit id, so no reply was sent (function '
            '${_hex(parsed.pdu.isEmpty ? 0 : parsed.pdu[0])}).');
      } else if (parsed.unitId == 0) {
        _logDrop(() => 'Answered nothing to an RTU broadcast (unit id 0), as '
            'the protocol requires; the request itself was executed.');
      }
      // Unit id 0 is the RTU broadcast address: the request is still
      // executed (handle() ran above, so any write took effect), but a real
      // RTU outstation MUST NOT reply to a broadcast — staying silent is
      // part of the protocol, not an error case. Replying here would hand a
      // master its own unexpected broadcast echo, which it would then
      // consume as the response to whatever unicast request it sends next,
      // desyncing every subsequent transaction on the link.
      if (responsePdu != null && parsed.unitId != 0) {
        socket.add(buildRtu(parsed.unitId, responsePdu));
      }
    }
  }

  /// Per-request function code and byte count — DEBUG, off by default, and
  /// lazy so a polling master pays nothing for it when the level is disabled.
  void _logRequest(ModbusFrame frame, int frameBytes) {
    logger?.logLazy(
      kLogSourceModbus,
      LogLevel.debug,
      () => 'Request: function '
          '${_hex(frame.pdu.isEmpty ? 0 : frame.pdu[0])}, unit '
          '${frame.unitId}, $frameBytes frame bytes.',
    );
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
/// (`modbus-tcp://<ip>:<port>`). Falls back to `localhost` if none can be
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

/// The `dart:io` Modbus TCP server host. A [ChangeNotifier] so the Outbound
/// Protocols screen can reactively show status/client-count/last-error.
///
/// Fully opt-in: until [start] is called, this class does nothing and the
/// app behaves exactly as it does today.
class ModbusHost extends ChangeNotifier {
  /// Optional diagnostics sink. Deliberately NULLABLE: a host constructed
  /// without one behaves exactly as it did before this parameter existed.
  final AppLogger? logger;

  ModbusHost({this.logger});

  ServerSocket? _serverSocket;
  final List<_Connection> _connections = [];
  StreamSubscription<Socket>? _acceptSub;

  ModbusHostStatus _status = ModbusHostStatus.stopped;
  ModbusHostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  int get clientCount => _connections.length;

  bool _disposed = false;

  void _setStatus(ModbusHostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Starts hosting `projectProvider()`'s current project's Modbus TCP
  /// configuration. Requires `protocols.modbus` to be non-null AND
  /// `enabled`; otherwise moves to [ModbusHostStatus.error] with an
  /// explanatory message and returns without binding a socket.
  ///
  /// [projectProvider] is called fresh on every request (via
  /// `ModbusServer`), so a project swap while the server is running is
  /// safe — but the *port* and *enabled* flag are read once, at start time,
  /// since a bound socket can't change port without a restart.
  Future<void> start(PlcProject Function() projectProvider) async {
    if (_status == ModbusHostStatus.running) {
      return; // already running; caller should stop() first to change port
    }
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      _setStatus(ModbusHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }

    final modbus = project.protocols?.modbus;
    if (modbus == null || !modbus.enabled) {
      logger?.log(
        kLogSourceModbus,
        LogLevel.warn,
        'Not started: Modbus TCP is not enabled for this project.',
      );
      _setStatus(ModbusHostStatus.error, error: 'Modbus TCP is not enabled for this project.');
      return;
    }
    final port = modbus.port;
    // Read once at start time, like `port`/`enabled` above — a bound socket
    // can't switch framing mid-connection, so a project swap while running
    // never changes how already-accepted connections are reassembled.
    final framing = modbus.framing;

    try {
      final serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _serverSocket = serverSocket;

      final host = await _bestDisplayHost();
      _endpointUrl = 'modbus-tcp://$host:${serverSocket.port}';

      final server = ModbusServer(projectProvider: projectProvider);

      _acceptSub = serverSocket.listen(
        (socket) => _acceptConnection(socket, server, framing),
        onError: (Object e, StackTrace st) {
          logger?.log(
            kLogSourceModbus,
            LogLevel.error,
            'The listening socket reported an error.',
            detail: e.toString(),
          );
          _setStatus(ModbusHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      logger?.log(
        kLogSourceModbus,
        LogLevel.info,
        'Listening on port ${serverSocket.port} ($framing framing).',
        detail: _endpointUrl,
      );
      _setStatus(ModbusHostStatus.running);
    } catch (e) {
      _serverSocket = null;
      final privileged = port > 0 && port < 1024;
      logger?.log(
        kLogSourceModbus,
        LogLevel.error,
        privileged
            ? 'Could not bind port $port. Ports below 1024 require elevated '
                'privileges on Linux/macOS — choose a port above 1023 to run '
                'unprivileged.'
            : 'Could not bind port $port.',
        detail: e.toString(),
      );
      _setStatus(ModbusHostStatus.error, error: e.toString());
    }
  }

  void _acceptConnection(Socket socket, ModbusServer server, String framing) {
    try {
      final conn = _Connection(socket, server.handle, framing: framing, logger: logger);
      _connections.add(conn);
      logger?.log(
        kLogSourceModbus,
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
        kLogSourceModbus,
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
      logger?.log(kLogSourceModbus, LogLevel.info, 'Stopped hosting.');
    }
    _setStatus(ModbusHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
