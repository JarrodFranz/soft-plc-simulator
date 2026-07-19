// The in-app S7comm socket host: the ONLY file in this project allowed to
// import `dart:io` for S7comm (v1 S7comm workstream, Task 3). Mirrors
// `mobile/lib/services/enip_host.dart`'s `ServerSocket`/`_Connection`
// pattern, but frames on the TPKT header (`protocols/s7/tpkt_cotp.dart`)
// instead of the EtherNet/IP encapsulation header.
//
// *** THE TPKT LENGTH INCLUDES ITS OWN 4-BYTE HEADER ***
// Once at least `kTpktHeaderLen` (4) bytes are buffered, the header's own
// big-endian `length` field (bytes 2-3) is the size of the WHOLE packet —
// so the reassembly loop uses `total = header.length`, NOT
// `kTpktHeaderLen + header.length`. This is the exact inverse of
// `enip_host.dart`, whose encapsulation `length` EXCLUDED its 24-byte
// header (`total = kEnipHeaderLen + header.length`). Copying that line
// unchanged from next door shifts every frame boundary on this socket.
//
// *** SCOPE ***
// This host serves a COTP Connection Request (CR) answered with a Connection
// Confirm (CC), an S7 Setup Communication job answered with its Ack_Data
// reply, and Read Var / Write Var jobs answered from the project's tags via
// the S7 area map. Any other S7 function is dropped without a reply.
//
// *** THE READ/WRITE RESPONSE BYTES ARE NOT BUILT HERE ***
// Every response byte for Read Var and Write Var comes from
// `protocols/s7/s7_services.dart`'s `dispatchS7VarJob`, which the E2E fixture
// host (`mobile/tool/s7_host_probe.dart`) calls too. The real third-party
// client (`python-snap7`, driven by `tool/s7_e2e.sh`) can only be pointed at
// the fixture — this class extends `ChangeNotifier` and cannot run under a
// plain `dart run` — so sharing ONE definition is what makes that proof apply
// to the shipped host, instead of relying on two hand-written copies staying
// byte-identical.
//
// Force-aware and access-aware write refusal is NOT re-implemented here: it
// lives in `applyAreaWrite` (`protocols/s7/s7_area_image.dart`), checked
// against the ROOT tag, and every write this host performs routes through it.
//
// Per-connection state (one per accepted socket): whether the COTP
// connection has been established, the peer's TSAPs as sent in its CR, and
// the PDU length negotiated by Setup Communication. Two sockets never share
// any of it.
//
// The app is byte-identical when hosting is stopped: nothing here runs
// unless [start] is called (an explicit, opt-in action).

import 'dart:async';
import 'dart:io';

// `Uint8List`/`ByteData` come from `package:flutter/foundation.dart`, which is
// imported below for `ChangeNotifier` — a separate `dart:typed_data` import
// would be flagged as unnecessary by the analyzer.
import 'package:flutter/foundation.dart';

import '../models/project_model.dart';
import '../models/s7_map.dart';
import '../protocols/s7/s7_pdu.dart';
import '../protocols/s7/s7_services.dart';
import '../protocols/s7/tpkt_cotp.dart';

/// Lifecycle status of the [S7Host].
enum S7HostStatus { stopped, running, error }

/// A hostile or malformed frame-size guard. The TPKT header's `length` field
/// is a 16-bit big-endian word counting the whole packet, so a well-formed
/// TPKT frame can never exceed 65535 bytes — this constant documents that
/// bound explicitly (mirroring the other hosts' `_maxFrameBytes` guards)
/// rather than relying on it being merely structurally true. A declared
/// length BELOW [kTpktHeaderLen] is rejected by the same check in
/// `_Connection.onData`: it would otherwise consume zero (or fewer) bytes
/// per iteration and spin the reassembly loop forever.
const int _maxFrameBytes = 0xFFFF;

/// The largest number of outstanding jobs (in either direction) this device
/// will agree to during Setup Communication. Like the PDU length, this is
/// negotiated DOWN from the client's proposal and never up — a client
/// asking for more parallel jobs than this gets this value instead.
const int _kMaxAmq = 8;

/// One accepted TCP connection: owns the socket, the byte-accumulation
/// buffer used to reassemble whole TPKT frames out of arbitrary TCP
/// chunking, and this connection's own COTP/S7 session state (so no two
/// sockets can observe each other's handshake).
class _Connection {
  final Socket socket;
  final List<int> _buffer = [];
  bool _closed = false;

  /// True once this connection's COTP Connection Request has been confirmed.
  /// An S7 message arriving before that is dropped rather than served — a
  /// COTP data TPDU is only meaningful inside an established connection.
  bool cotpEstablished = false;

  /// The TSAPs this peer sent in its CR, echoed back verbatim in the CC.
  /// The destination TSAP encodes rack/slot, but this is a simulator: v1
  /// accepts ANY rack/slot rather than rejecting a mismatch, which would
  /// give a confusing failure with no diagnostic value.
  int? peerSrcTsap;
  int? peerDstTsap;

  /// The PDU length agreed by Setup Communication. Until one is negotiated
  /// this is the documented floor; every response this device builds must
  /// respect the AGREED value, never the client's raw proposal.
  int negotiatedPduLength = kS7MinPduLength;

  /// The COTP source reference this host chose for this connection,
  /// allocated from the host's monotonic counter (never randomness, never
  /// the clock) so the handshake stays deterministic and testable.
  final int localRef;

  _Connection(this.socket, this.localRef);

  /// Feeds newly-arrived [data] into the reassembly buffer, then extracts
  /// and dispatches as many complete TPKT frames as are available. A single
  /// socket `data` event may contain a partial frame, exactly one frame, or
  /// several frames back-to-back — all three are handled here.
  void onData(List<int> data, PlcProject Function() projectProvider) {
    if (_closed) {
      return;
    }
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < kTpktHeaderLen) {
          return; // not even a full TPKT header yet
        }
        final headerBytes = Uint8List.fromList(_buffer.sublist(0, kTpktHeaderLen));
        final header = parseTpkt(headerBytes);
        if (header == null) {
          // Cannot happen — `headerBytes` is always exactly kTpktHeaderLen
          // long — but never trust wire-derived control flow to be
          // unreachable; close only this connection rather than assume.
          close();
          return;
        }
        // THE TPKT LENGTH IS THE WHOLE PACKET, HEADER INCLUDED — see this
        // file's header comment. Not `kTpktHeaderLen + header.length`.
        final total = header.length;
        if (total < kTpktHeaderLen || total > _maxFrameBytes) {
          // Hostile/garbage length field (including 0 and 1, which would
          // make the loop consume nothing and spin forever): close ONLY
          // this connection.
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
    } catch (_) {
      // A crash while reassembling/dispatching must never take down the
      // host — just drop this one connection.
      close();
    }
  }

  /// Dispatches one complete TPKT frame. The TPKT payload is a COTP TPDU; a
  /// TPDU this codec cannot parse (`parseCotp` returns `null`) or does not
  /// serve is dropped silently, leaving the connection open — a frame we do
  /// not understand is not itself grounds to hang up on a client.
  void _handleFrame(Uint8List frame, PlcProject Function() projectProvider) {
    final cotpBytes = Uint8List.sublistView(frame, kTpktHeaderLen);
    final cotp = parseCotp(cotpBytes);
    if (cotp == null) {
      return;
    }
    if (cotp.pduType == kCotpCr) {
      _handleConnectRequest(cotp);
      return;
    }
    if (cotp.pduType == kCotpDt) {
      if (!cotpEstablished) {
        return; // data before the COTP connection was confirmed
      }
      _handleS7(cotp.payload, projectProvider);
      return;
    }
    // Any other COTP TPDU type (e.g. CC — which a server receives only from
    // a misbehaving peer) is not served here.
  }

  /// Answers a COTP Connection Request with a Connection Confirm. The CC's
  /// `dstRef` is the reference the CLIENT chose (its CR's `srcRef`), and its
  /// `srcRef` is this host's own per-connection reference; the client's
  /// TSAPs are echoed back verbatim. Rack/slot (encoded in the destination
  /// TSAP) are deliberately not validated — see [peerDstTsap].
  void _handleConnectRequest(CotpPacket cr) {
    peerSrcTsap = cr.srcTsap;
    peerDstTsap = cr.dstTsap;
    final cc = buildCotpConnectConfirm(
      // The client's own reference becomes the DESTINATION of our confirm.
      dstRef: cr.srcRef ?? 0,
      srcRef: localRef,
      srcTsap: cr.srcTsap ?? 0,
      dstTsap: cr.dstTsap ?? 0,
    );
    cotpEstablished = true;
    socket.add(buildTpkt(cc));
  }

  /// Dispatches the S7 message carried by a COTP data TPDU: Setup
  /// Communication, Read Var and Write Var are served; a malformed message, a
  /// non-Job ROSCTR, or any other function is dropped without a reply.
  ///
  /// [projectProvider] is called FRESH here, on every message, so a project
  /// swap while this socket is open serves the NEW project rather than a
  /// stale snapshot.
  void _handleS7(Uint8List s7Bytes, PlcProject Function() projectProvider) {
    final msg = parseS7(s7Bytes);
    if (msg == null) {
      return;
    }
    if (msg.header.rosctr != kS7RosctrJob) {
      return;
    }
    if (msg.parameter.isEmpty) {
      return;
    }
    if (msg.parameter[0] == kS7FunctionSetupCommunication) {
      final setup = parseSetupCommunication(msg.parameter);
      if (setup == null) {
        return;
      }
      _handleSetupCommunication(msg.header.pduReference, setup);
      return;
    }

    final PlcProject project;
    try {
      project = projectProvider();
    } catch (_) {
      return; // cannot read the project — drop rather than crash the socket
    }
    final reply = dispatchS7VarJob(
      project,
      _currentMap(project),
      msg,
      negotiatedPduLength: negotiatedPduLength,
    );
    if (reply == null) {
      return; // not a function this device serves, or a malformed request
    }
    socket.add(buildTpkt(buildCotpData(reply)));
  }

  /// The S7 area map currently configured for [project], or an EMPTY map if
  /// S7comm hosting has since been disabled/removed from the project out from
  /// under a still-open socket. An empty map exposes nothing: every byte then
  /// reads as a gap (`0x00`) and every write is discarded — never a
  /// null-deref, and never the previous project's tags.
  S7Map _currentMap(PlcProject project) => project.protocols?.s7?.map ?? S7Map(entries: []);

  /// Answers a Setup Communication job. Every negotiated value moves DOWN
  /// from the client's proposal, never up: the PDU length via
  /// [negotiatePduLength] (which also clamps a degenerate proposal up to the
  /// documented floor), and both AMQ counts via [_kMaxAmq].
  void _handleSetupCommunication(int pduReference, SetupComm setup) {
    final agreedPdu = negotiatePduLength(setup.pduLength);
    negotiatedPduLength = agreedPdu;
    final parameter = buildSetupCommunicationReply(
      maxAmqCalling: setup.maxAmqCalling < _kMaxAmq ? setup.maxAmqCalling : _kMaxAmq,
      maxAmqCalled: setup.maxAmqCalled < _kMaxAmq ? setup.maxAmqCalled : _kMaxAmq,
      pduLength: agreedPdu,
    );
    final reply = buildS7(
      rosctr: kS7RosctrAckData,
      pduReference: pduReference,
      parameter: parameter,
    );
    socket.add(buildTpkt(buildCotpData(reply)));
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
/// (`s7-tcp://<ip>:<port>`). Falls back to `localhost` if none can be found
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

/// The `dart:io` S7comm socket host. A [ChangeNotifier] so the Outbound
/// Protocols screen (Task 5) can reactively show status/client-count/
/// last-error.
///
/// Fully opt-in: until [start] is called, this class does nothing and the
/// app behaves exactly as it does today.
class S7Host extends ChangeNotifier {
  ServerSocket? _serverSocket;
  final List<_Connection> _connections = [];
  StreamSubscription<Socket>? _acceptSub;

  /// COTP source references are allocated from ONE monotonic counter shared
  /// by every connection this host ever accepts (never randomness, never the
  /// clock), so the handshake is deterministic and two live sockets never
  /// confirm with the same reference. Not reset by `stop()`/`start()` within
  /// one instance's lifetime.
  int _nextLocalRef = 1;

  S7HostStatus _status = S7HostStatus.stopped;
  S7HostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  int get clientCount => _connections.length;

  bool _disposed = false;

  void _setStatus(S7HostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  int _allocateLocalRef() {
    final ref = _nextLocalRef;
    // COTP references are 16-bit on the wire; wrap rather than overflow so a
    // very long-lived host keeps emitting a valid reference.
    _nextLocalRef = _nextLocalRef >= 0xFFFF ? 1 : _nextLocalRef + 1;
    return ref;
  }

  /// Starts hosting `projectProvider()`'s current project's S7comm
  /// configuration. Requires `protocols.s7` to be non-null AND `enabled`;
  /// otherwise moves to [S7HostStatus.error] with an explanatory message and
  /// returns without binding a socket.
  ///
  /// [projectProvider] is called fresh on every dispatched request, so a
  /// project swap while the server is running is safe — but the *port* and
  /// *enabled* flag are read once, at start time, since a bound socket
  /// cannot change port without a restart.
  ///
  /// *** BINDING THE DEFAULT PORT 102 REQUIRES PRIVILEGE ON Linux/macOS ***
  /// (it is below 1024). A `ServerSocket.bind` denial there is caught below
  /// and surfaced through [status]/[lastError] — this method NEVER reports
  /// running on a bind it did not get — so the Outbound Protocols card shows
  /// the failure instead of appearing to start. Editing the port to a value
  /// above 1023 is the unprivileged workaround.
  Future<void> start(PlcProject Function() projectProvider) async {
    if (_status == S7HostStatus.running) {
      return; // already running; caller should stop() first to change port
    }
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      _setStatus(S7HostStatus.error, error: 'Could not read the current project: $e');
      return;
    }

    final s7 = project.protocols?.s7;
    if (s7 == null || !s7.enabled) {
      _setStatus(S7HostStatus.error, error: 'S7comm is not enabled for this project.');
      return;
    }
    final port = s7.port;

    try {
      final serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _serverSocket = serverSocket;

      final host = await _bestDisplayHost();
      _endpointUrl = 's7-tcp://$host:${serverSocket.port}';

      _acceptSub = serverSocket.listen(
        (socket) => _acceptConnection(socket, projectProvider),
        onError: (Object e, StackTrace st) {
          _setStatus(S7HostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      _setStatus(S7HostStatus.running);
    } catch (e) {
      _serverSocket = null;
      _endpointUrl = null;
      _setStatus(S7HostStatus.error, error: e.toString());
    }
  }

  void _acceptConnection(Socket socket, PlcProject Function() projectProvider) {
    try {
      final conn = _Connection(socket, _allocateLocalRef());
      _connections.add(conn);
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
    _setStatus(S7HostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
