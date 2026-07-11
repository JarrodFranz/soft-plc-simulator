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

import '../models/project_model.dart';
import '../protocols/modbus/modbus_pdu.dart';

/// Lifecycle status of the [ModbusHost].
enum ModbusHostStatus { stopped, running, error }

/// A hostile or malformed frame-size guard: the Modbus TCP spec caps the
/// whole ADU (MBAP header + PDU) at 260 bytes, so anything claiming to be
/// larger is bogus and closes just that connection rather than being
/// buffered indefinitely.
const int _maxFrameBytes = 260;

/// One accepted TCP connection: owns the socket and the byte-accumulation
/// buffer used to reassemble whole MBAP+PDU frames out of arbitrary TCP
/// chunking.
class _Connection {
  final Socket socket;
  final Uint8List? Function(ModbusFrame) handle;
  final List<int> _buffer = [];
  bool _closed = false;

  _Connection(this.socket, this.handle);

  /// Feeds newly-arrived [data] into the reassembly buffer, then extracts
  /// and dispatches as many complete frames as are available. A single
  /// socket `data` event may contain a partial frame, exactly one frame, or
  /// several frames back-to-back — all three are handled here.
  void onData(List<int> data) {
    if (_closed) return;
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < 6) {
          return; // not even the length field yet
        }
        final length = (_buffer[4] << 8) | _buffer[5];
        final totalSize = 6 + length;
        if (length < 1 || totalSize > _maxFrameBytes) {
          // Hostile/garbage size: close ONLY this connection, never crash.
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
          close();
          return;
        }
        final responsePdu = handle(parsed);
        if (responsePdu != null) {
          // A `null` response means the configured unit id didn't match this
          // request's unit id — a real outstation stays silent rather than
          // answering on someone else's behalf, so no bytes go back at all.
          final responseFrame = buildMbap(parsed.transactionId, parsed.unitId, responsePdu);
          socket.add(responseFrame);
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
      _setStatus(ModbusHostStatus.error, error: 'Modbus TCP is not enabled for this project.');
      return;
    }
    final port = modbus.port;

    try {
      final serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _serverSocket = serverSocket;

      final host = await _bestDisplayHost();
      _endpointUrl = 'modbus-tcp://$host:${serverSocket.port}';

      final server = ModbusServer(projectProvider: projectProvider);

      _acceptSub = serverSocket.listen(
        (socket) => _acceptConnection(socket, server),
        onError: (Object e, StackTrace st) {
          _setStatus(ModbusHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      _setStatus(ModbusHostStatus.running);
    } catch (e) {
      _serverSocket = null;
      _setStatus(ModbusHostStatus.error, error: e.toString());
    }
  }

  void _acceptConnection(Socket socket, ModbusServer server) {
    try {
      final conn = _Connection(socket, server.handle);
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

    try {
      await _serverSocket?.close();
    } catch (_) {
      // Ignore.
    }
    _serverSocket = null;
    _endpointUrl = null;
    _setStatus(ModbusHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
