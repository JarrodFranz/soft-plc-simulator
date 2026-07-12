// The in-app DNP3 outstation TCP server host: the ONLY file in this project
// allowed to import `dart:io` for DNP3 (WS26 DNP3 outstation, Task 5).
// Mirrors `mobile/lib/services/modbus_host.dart`'s `ServerSocket` pattern
// exactly, but frames on the DNP3 data-link layer instead of the Modbus MBAP
// header, and dispatches through two extra pure-Dart layers before reaching
// the outstation handler:
//
//   TCP bytes -> DnpLinkBuffer (link-layer reassembly, `dnp3_link.dart`)
//             -> per-frame DESTINATION-address filter (frames not addressed
//                to this outstation are silently ignored, never answered)
//             -> DnpTransportReassembler (strips/reassembles the 1-byte
//                transport-segment header, `dnp3_transport.dart`) into a
//                complete APPLICATION fragment
//             -> DnpOutstation.handleAppRequest (`dnp3_outstation.dart`) ->
//                response APPLICATION fragment
//             -> re-segmented into transport segments -> each wrapped in a
//                `buildLinkFrame` (dest = master address, src = this
//                outstation's address) -> written back to the socket.
//
// The app is byte-identical when hosting is stopped: nothing here runs
// unless [start] is called (an explicit, opt-in action from the Outbound
// Protocols screen).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/project_model.dart';
import '../protocols/dnp3/dnp3_link.dart';
import '../protocols/dnp3/dnp3_outstation.dart';
import '../protocols/dnp3/dnp3_transport.dart';

/// Lifecycle status of the [DnpHost].
enum DnpHostStatus { stopped, running, error }

/// A single transport segment's application-data budget (250-byte link
/// user-data max, minus the 1-byte transport header) — response fragments
/// longer than this are split across multiple segments/link frames by
/// [_buildResponseFrames].
const int _maxSegmentPayload = 249;

/// Link-layer CONTROL byte used on every outgoing (outstation -> master)
/// response frame. This v1 host does not implement the data-link
/// confirmation/FCB state machine (`dnp3_link.dart` treats CONTROL as an
/// opaque byte it never interprets) — a fixed "unconfirmed user data" value
/// is used for every response, matching the value this codebase's own
/// link-layer tests use to represent that case. Task 6's real DNP3 master is
/// the authority on whether a stricter link-layer state machine is needed
/// for interop; this is a deliberate v1 simplification, not an oversight.
const int _responseLinkControl = 0x44;

/// A hostile/never-resolving buffer guard: a legitimate DNP3 link frame is
/// always well under 300 bytes (LENGTH is a single byte, capped at 255), so
/// a connection that has pushed more than this many bytes into its
/// reassembly buffer without producing even one complete frame is either
/// broken or hostile — mirrors `modbus_host.dart`'s declared-size guard, but
/// since the DNP3 link-layer LENGTH byte is already self-limiting, the risk
/// here is a huge single non-matching byte flood driving `DnpLinkBuffer`'s
/// internal byte-at-a-time resync into pathological (O(n^2)) work rather
/// than an unbounded frame size — capping total pending bytes closes both.
const int _maxPendingBytes = 4096;

/// One accepted TCP connection: owns the socket, the link-layer reassembly
/// buffer, and the transport-segment reassembler used to turn arbitrary
/// TCP-chunked bytes back into complete APPLICATION fragments.
class _Connection {
  final Socket socket;
  final DnpOutstation outstation;
  final int outstationAddress;
  final int masterAddress;
  final DnpLinkBuffer _linkBuffer = DnpLinkBuffer();
  final DnpTransportReassembler _transport = DnpTransportReassembler();
  bool _closed = false;
  int _pendingBytes = 0;

  _Connection(
    this.socket,
    this.outstation, {
    required this.outstationAddress,
    required this.masterAddress,
  });

  /// Feeds newly-arrived [data] into the link-layer reassembly buffer, then
  /// dispatches every complete frame it yields. Guarded end-to-end: any
  /// internal error drops just this connection, never the whole host.
  void onData(List<int> data) {
    if (_closed) return;
    try {
      _pendingBytes += data.length;
      if (_pendingBytes > _maxPendingBytes) {
        // Hostile/never-resolving flood: close ONLY this connection.
        close();
        return;
      }
      final frames = _linkBuffer.add(data);
      if (frames.isNotEmpty) {
        _pendingBytes = 0; // Real progress was made; reset the flood guard.
      }
      for (final frame in frames) {
        if (_closed) return;
        _handleFrame(frame);
      }
    } catch (_) {
      // A crash while reassembling/dispatching must never take down the
      // host — just drop this one connection.
      close();
    }
  }

  void _handleFrame(DnpLinkFrame frame) {
    if (frame.dest != outstationAddress) {
      // Not addressed to this outstation — silently ignore (per the DNP3
      // outstation brief: only frames whose DESTINATION matches our
      // configured link address are processed).
      return;
    }
    final appFragment = _transport.addSegment(frame.userData);
    if (appFragment == null) {
      return; // Waiting on more transport segments of a multi-segment fragment.
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final response = outstation.handleAppRequest(appFragment, nowMs: nowMs);
    if (response.isEmpty) {
      // A CONFIRM (function code 0) yields an empty response fragment —
      // CONFIRMs never get a reply of their own.
      return;
    }
    final responseFrames = _buildResponseFrames(
      appFragment: response,
      outstationAddress: outstationAddress,
      masterAddress: masterAddress,
    );
    for (final respFrame in responseFrames) {
      if (_closed) return;
      socket.add(respFrame);
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

/// Splits [appFragment] into one-or-more transport segments (FIR on the
/// first, FIN on the last, sequence incrementing mod 64) and wraps each in a
/// complete `0x0564` link frame addressed from [outstationAddress] to
/// [masterAddress]. A fragment at or under [_maxSegmentPayload] bytes (true
/// of every response this v1 outstation ever builds) yields exactly one
/// frame; this only splits further as defensive future-proofing.
List<Uint8List> _buildResponseFrames({
  required Uint8List appFragment,
  required int outstationAddress,
  required int masterAddress,
}) {
  final frames = <Uint8List>[];
  var offset = 0;
  var seq = 0;
  do {
    final remaining = appFragment.length - offset;
    final chunkLen = remaining < _maxSegmentPayload ? remaining : _maxSegmentPayload;
    final chunk = appFragment.sublist(offset, offset + chunkLen);
    final fir = offset == 0;
    offset += chunkLen;
    final fin = offset >= appFragment.length;
    final segment = buildTransport(seq, fir: fir, fin: fin, appData: chunk);
    frames.add(buildLinkFrame(
      control: _responseLinkControl,
      dest: masterAddress,
      src: outstationAddress,
      userData: segment,
    ));
    seq = (seq + 1) & 0x3F;
  } while (offset < appFragment.length);
  return frames;
}

/// Best-effort LAN IPv4 address for display in the endpoint line
/// (`dnp3://<ip>:<port>`). Falls back to `localhost` if none can be found
/// (e.g. no network interfaces, or a platform that disallows the lookup) —
/// never throws.
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

/// The `dart:io` DNP3 outstation TCP server host. A [ChangeNotifier] so the
/// Outbound Protocols screen can reactively show status/client-count/
/// last-error.
///
/// Fully opt-in: until [start] is called, this class does nothing and the
/// app behaves exactly as it does today.
class DnpHost extends ChangeNotifier {
  ServerSocket? _serverSocket;
  final List<_Connection> _connections = [];
  StreamSubscription<Socket>? _acceptSub;

  /// The shared outstation instance driving every connection — also read by
  /// the periodic [tickForTest] tick to run change detection and the
  /// unsolicited push/retry loop. Null whenever the host is stopped.
  DnpOutstation? _outstation;

  /// Periodic change-detection + unsolicited push/retry driver — see
  /// [tickForTest]. Ticks on wall-clock time in production; tests drive
  /// [tickForTest] directly with a controlled clock instead.
  Timer? _tick;
  int _unsolSentAtMs = 0;
  int _unsolRetryCount = 0;
  int _unsolTimeoutMs = 5000;
  int _unsolMaxRetries = 3;
  static const int _tickPeriodMs = 500;

  DnpHostStatus _status = DnpHostStatus.stopped;
  DnpHostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  int get clientCount => _connections.length;

  bool _disposed = false;

  void _setStatus(DnpHostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Starts hosting `projectProvider()`'s current project's DNP3 outstation
  /// configuration. Requires `protocols.dnp3` to be non-null AND `enabled`;
  /// otherwise moves to [DnpHostStatus.error] with an explanatory message
  /// and returns without binding a socket.
  ///
  /// [projectProvider] is called fresh on every request (via the
  /// `DnpOutstation` it hands to each connection), so a project swap while
  /// the server is running is safe — but the *port*/*outstation address*/
  /// *master address* are read once, at start time, since a bound socket
  /// can't change port without a restart and the link-address filter is
  /// fixed per accepted connection.
  Future<void> start(PlcProject Function() projectProvider) async {
    if (_status == DnpHostStatus.running) {
      return; // already running; caller should stop() first to change config
    }
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      _setStatus(DnpHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }

    final dnp3 = project.protocols?.dnp3;
    if (dnp3 == null || !dnp3.enabled) {
      _setStatus(DnpHostStatus.error, error: 'DNP3 is not enabled for this project.');
      return;
    }
    final port = dnp3.port;
    final outstationAddress = dnp3.outstationAddress;
    final masterAddress = dnp3.masterAddress;
    _unsolTimeoutMs = dnp3.unsolConfirmTimeoutMs;
    _unsolMaxRetries = dnp3.unsolMaxRetries;
    final eventBufferPerClass = dnp3.eventBufferPerClass;

    try {
      final serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _serverSocket = serverSocket;

      final host = await _bestDisplayHost();
      _endpointUrl = 'dnp3://$host:${serverSocket.port}';

      final outstation = DnpOutstation(
        projectProvider: projectProvider,
        eventBufferPerClass: eventBufferPerClass,
      );

      _acceptSub = serverSocket.listen(
        (socket) => _acceptConnection(socket, outstation, outstationAddress, masterAddress),
        onError: (Object e, StackTrace st) {
          _setStatus(DnpHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      _setStatus(DnpHostStatus.running);
      _outstation = outstation;
      _tick = Timer.periodic(const Duration(milliseconds: _tickPeriodMs), (_) {
        try {
          tickForTest(DateTime.now().millisecondsSinceEpoch);
        } catch (_) {
          // A tick must never crash the host.
        }
      });
    } catch (e) {
      _serverSocket = null;
      _setStatus(DnpHostStatus.error, error: e.toString());
    }
  }

  void _acceptConnection(
    Socket socket,
    DnpOutstation outstation,
    int outstationAddress,
    int masterAddress,
  ) {
    try {
      final conn = _Connection(
        socket,
        outstation,
        outstationAddress: outstationAddress,
        masterAddress: masterAddress,
      );
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

  /// One change-detection + unsolicited-push/retry pass. Package-visible so
  /// tests can drive it with a controlled clock instead of wall time.
  @visibleForTesting
  void tickForTest(int nowMs) {
    final os = _outstation;
    if (os == null || _connections.isEmpty) {
      return;
    }
    os.detectChanges(nowMs);

    if (os.hasUnsolicitedInFlight) {
      // Awaiting CONFIRM: retry on timeout, give up after the cap.
      if (nowMs - _unsolSentAtMs >= _unsolTimeoutMs) {
        if (_unsolRetryCount < _unsolMaxRetries) {
          _unsolRetryCount++;
          _unsolSentAtMs = nowMs;
          final bytes = os.inFlightUnsolicitedBytes;
          if (bytes != null) {
            _broadcast(bytes);
          }
        } else {
          os.failUnsolicited();
          _unsolRetryCount = 0;
        }
      }
      return;
    }

    // Nothing in flight: a CONFIRM (or nothing sent yet) — reset retry state.
    _unsolRetryCount = 0;
    final frame = os.takeNullUnsolicited() ?? os.takeEventUnsolicited(nowMs);
    if (frame != null) {
      _unsolSentAtMs = nowMs;
      _broadcast(frame);
    }
  }

  /// Wraps an application fragment in transport + link framing (dest = master,
  /// src = outstation) and writes it to every live connection.
  ///
  /// v1 simplification: one shared outstation broadcasting to every
  /// connected socket, rather than per-master unsolicited state — a typical
  /// DNP3 TCP deployment has exactly one master connected, so this is not a
  /// behavioral gap in practice, just a simplification this host doesn't
  /// need to outgrow yet.
  void _broadcast(Uint8List appFragment) {
    for (final conn in List<_Connection>.from(_connections)) {
      if (conn._closed) {
        continue;
      }
      final frames = _buildResponseFrames(
        appFragment: appFragment,
        outstationAddress: conn.outstationAddress,
        masterAddress: conn.masterAddress,
      );
      for (final f in frames) {
        try {
          conn.socket.add(f);
        } catch (_) {
          // Drop broadcast errors per-connection.
        }
      }
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
    _tick?.cancel();
    _tick = null;
    _outstation = null;
    _unsolRetryCount = 0;
    _setStatus(DnpHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
