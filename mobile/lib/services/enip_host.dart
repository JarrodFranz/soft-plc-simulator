// The in-app EtherNet/IP + CIP explicit-messaging socket host: the ONLY
// file in this project allowed to import `dart:io` for EtherNet/IP (v1
// EtherNet/IP + CIP workstream, Task 5). Mirrors
// `mobile/lib/services/opcua_host.dart`'s `ServerSocket`/`_Connection`
// pattern exactly, but frames on the EtherNet/IP encapsulation header
// (`protocols/enip/enip_encap.dart`) instead of the OPC UA message header:
// once at least `kEnipHeaderLen` (24) bytes are buffered, the header's own
// `length` field (bytes 2-3, little-endian) tells us the total frame size
// is `kEnipHeaderLen + header.length`; once the buffer holds that many
// bytes the frame is sliced off, decoded, dispatched, and the response
// written back.
//
// Per-connection state (one per accepted socket): a session handle —
// allocated from this host's monotonic counter when the client sends
// `RegisterSession` (0x65) — and its own `CipConnectionManager` (Task 3),
// so two sockets never share Forward-Open connection ids. `SendRRData`
// (0x6F) carries UCMM (unconnected) traffic: a Forward Open/Close (service
// 0x54/0x4E) routes to the connection manager, anything else routes to
// `dispatchCipService` (Task 4). `SendUnitData` (0x70) carries *connected*
// traffic: the Connected Address CPF item's connection id resolves the
// open connection via `CipConnectionManager.byConnectionId`, the Connected
// Data item's leading sequence count is tracked/echoed, and the embedded
// CIP request is likewise dispatched via `dispatchCipService`.
//
// The app is byte-identical when hosting is stopped: nothing here runs
// unless [start] is called (an explicit, opt-in action from the Outbound
// Protocols screen).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/app_log.dart';
import '../models/cip_map.dart';
import '../models/project_model.dart';
import '../protocols/enip/cip.dart';
import '../protocols/enip/cip_connection.dart';
import '../protocols/enip/cip_tags.dart';
import '../protocols/enip/enip_encap.dart';
import 'app_logger.dart';
import 'drop_log_gate.dart';

/// Lifecycle status of the [EnipHost].
enum EnipHostStatus { stopped, running, error }

/// Encapsulation-layer status codes this host emits in a reply header's
/// `status` field (distinct from — and never to be confused with — a CIP
/// `generalStatus` byte carried *inside* a CPF item's data). Values match
/// the public EtherNet/IP encapsulation specification's status codes.
const int _kEncapStatusUnsupportedCommand = 0x01;
const int _kEncapStatusIncorrectData = 0x03;
const int _kEncapStatusInvalidSessionHandle = 0x64;

/// A hostile or malformed frame-size guard. The encapsulation header's own
/// `length` field is a 16-bit word (see `enip_encap.dart`), so a
/// well-formed frame can never exceed `kEnipHeaderLen + 0xFFFF` bytes —
/// this constant documents that bound explicitly (mirroring the other
/// hosts' `_maxFrameBytes` guards) rather than relying on it being merely
/// structurally true.
const int _maxFrameBytes = kEnipHeaderLen + 0xFFFF;

/// `0x1f`-style formatting for a wire code, so a dropped-request log entry
/// names the offending value in the same notation the specification (and
/// every client's own log) uses.
String _hex(int v) => '0x${v.toRadixString(16).padLeft(2, '0').toUpperCase()}';

/// One accepted TCP connection: owns the socket, the byte-accumulation
/// buffer used to reassemble whole encapsulation frames out of arbitrary
/// TCP chunking, the session handle registered on this connection (if
/// any), and this connection's own [CipConnectionManager] (so Forward-Open
/// connection ids allocated on one socket never collide with another's).
class _Connection {
  final Socket socket;
  final CipConnectionManager connMgr = CipConnectionManager();
  final List<int> _buffer = [];
  bool _closed = false;

  /// The session handle this connection registered via `RegisterSession`,
  /// or `null` before registration (or after `UnRegisterSession`). Any
  /// `SendRRData`/`SendUnitData` request must carry this exact value in its
  /// header's `sessionHandle` field or it is refused with
  /// [_kEncapStatusInvalidSessionHandle] — never a crash.
  int? sessionHandle;

  /// Optional diagnostics sink. Null (the default for a bare host) makes
  /// every log call in this class a no-op — instrumentation NEVER changes
  /// protocol behaviour, it only observes it.
  final AppLogger? logger;

  /// This connection's view of the host's first-occurrence WARN gate.
  final ConnectionDropLog dropLog;

  _Connection(this.socket, {required this.dropLog, this.logger});

  /// Records a request this connection PARSED but did not SERVE (or refused
  /// at the encapsulation layer).
  ///
  /// The FIRST drop of a given [reason] on this connection is a WARN, so a
  /// host refusing everything announces itself at the default level; every
  /// repeat is DEBUG (off by default) and lazy, because a mis-configured
  /// client can hit these paths on every scan cycle. See `drop_log_gate.dart`
  /// for the reconnect-loop bound on that first WARN.
  void _logDrop(String reason, String Function() build) {
    dropLog.drop(reason, build);
  }

  /// Feeds newly-arrived [data] into the reassembly buffer, then extracts
  /// and dispatches as many complete frames as are available. A single
  /// socket `data` event may contain a partial frame, exactly one frame, or
  /// several frames back-to-back — all three are handled here, exactly
  /// like `OpcUaHost`'s `_Connection.onData`.
  void onData(
    List<int> data,
    PlcProject Function() projectProvider,
    int Function() allocateSessionHandle,
  ) {
    if (_closed) {
      return;
    }
    _buffer.addAll(data);
    try {
      while (true) {
        if (_buffer.length < kEnipHeaderLen) {
          return; // not even a full header yet
        }
        final headerBytes = Uint8List.fromList(_buffer.sublist(0, kEnipHeaderLen));
        final header = parseEnipHeader(headerBytes);
        if (header == null) {
          // Cannot happen — `headerBytes` is always exactly kEnipHeaderLen
          // long — but never trust wire-derived control flow to be
          // unreachable; close only this connection rather than assume.
          logger?.log(
            kLogSourceEnip,
            LogLevel.warn,
            'Closing a client: its encapsulation header could not be parsed.',
          );
          close();
          return;
        }
        final total = kEnipHeaderLen + header.length;
        if (total > _maxFrameBytes) {
          // Hostile/garbage length field: close ONLY this connection.
          logger?.logLazy(
            kLogSourceEnip,
            LogLevel.warn,
            () => 'Closing a client: its encapsulation header declared an '
                'unusable length of ${header.length} bytes.',
          );
          close();
          return;
        }
        if (_buffer.length < total) {
          return; // wait for more bytes
        }
        final frame = Uint8List.fromList(_buffer.sublist(0, total));
        _buffer.removeRange(0, total);
        _handleFrame(frame, header, projectProvider, allocateSessionHandle);
      }
    } catch (e, st) {
      // A crash while reassembling/dispatching must never take down the
      // host — just drop this one connection. The BEHAVIOUR is unchanged;
      // only the record is new, so the operator no longer sees a bare
      // "Client disconnected" with no cause. Fires at most once per
      // connection, so an always-on WARN costs nothing.
      logger?.log(
        kLogSourceEnip,
        LogLevel.warn,
        'Dropping a client: an internal error occurred while reassembling or '
        'dispatching its data.',
        detail: '$e\n$st',
      );
      close();
    }
  }

  void _handleFrame(
    Uint8List frame,
    EnipHeader header,
    PlcProject Function() projectProvider,
    int Function() allocateSessionHandle,
  ) {
    final data = Uint8List.sublistView(frame, kEnipHeaderLen);
    logger?.logLazy(
      kLogSourceEnip,
      LogLevel.debug,
      () => 'Request: command ${_hex(header.command)}, '
          '${data.length} body bytes.',
    );
    switch (header.command) {
      case kEnipCommandNop:
        // NOP elicits no response, per spec.
        // Correct protocol behaviour, not a failure — never promoted to
        // WARN. See `ConnectionDropLog.specSilence`.
        dropLog.specSilence(() => 'No reply sent for a NOP command, as the '
            'specification requires.');
        return;
      case kEnipCommandRegisterSession:
        _handleRegisterSession(header, data, allocateSessionHandle);
        return;
      case kEnipCommandUnRegisterSession:
        _handleUnRegisterSession(header);
        return;
      case kEnipCommandSendRRData:
        _handleSendRRData(header, data, projectProvider);
        return;
      case kEnipCommandSendUnitData:
        _handleSendUnitData(header, data, projectProvider);
        return;
      default:
        _logDrop('enip-unsupported-command',
          () => 'Refused an unsupported encapsulation command '
            '${_hex(header.command)}.');
        socket.add(_reply(header, _kEncapStatusUnsupportedCommand, Uint8List(0)));
    }
  }

  void _handleRegisterSession(
    EnipHeader header,
    Uint8List data,
    int Function() allocateSessionHandle,
  ) {
    // A socket that already holds a session handle and issues
    // RegisterSession again is starting a fresh session on this connection:
    // release any CIP connections opened under the PREVIOUS handle first, so
    // they cannot outlive the session that created them — otherwise they'd
    // stay resolvable via `connMgr.byConnectionId` (and therefore servable by
    // `SendUnitData`) even though no client can reference the old session
    // anymore.
    if (sessionHandle != null) {
      connMgr.releaseAll();
    }
    final handle = allocateSessionHandle();
    sessionHandle = handle;
    final replyHeader = EnipHeader(
      command: kEnipCommandRegisterSession,
      // `length` here is purely documentary: `buildEnipFrame` is the sole
      // authority for the on-wire length field and always recomputes it
      // from the `data` actually passed to it, ignoring this value.
      length: data.length,
      sessionHandle: handle,
      status: 0,
      senderContext: header.senderContext,
      options: 0,
    );
    // Reply body echoes the request's own data (protocol version + options)
    // verbatim — the client only needs the allocated session handle, which
    // is carried in the header, not the body.
    socket.add(buildEnipFrame(replyHeader, data));
  }

  void _handleUnRegisterSession(EnipHeader header) {
    // No reply is sent for UnRegisterSession, per spec — the client is
    // expected to close the socket itself afterward. Only release this
    // connection's open CIP connections if the request actually names the
    // session currently registered here; a stale/foreign handle is simply
    // ignored rather than dropping a still-valid session.
    if (sessionHandle != null && header.sessionHandle == sessionHandle) {
      connMgr.releaseAll();
      sessionHandle = null;
      return;
    }
    _logDrop('enip-foreign-unregister',
          () => 'Ignored an UnRegisterSession naming session handle '
        '${header.sessionHandle}, which is not the one registered on this '
        'connection (${sessionHandle ?? 'none'}).');
  }

  void _handleSendRRData(
    EnipHeader header,
    Uint8List data,
    PlcProject Function() projectProvider,
  ) {
    if (sessionHandle == null || header.sessionHandle != sessionHandle) {
      _logDrop('enip-rr-bad-session',
          () => 'Refused a SendRRData: session handle '
          '${header.sessionHandle} is not the one registered on this '
          'connection (${sessionHandle ?? 'none'}).');
      socket.add(_reply(header, _kEncapStatusInvalidSessionHandle, Uint8List(0)));
      return;
    }
    // 4-byte Interface Handle + 2-byte Timeout precede the CPF item list in
    // both SendRRData and SendUnitData request/response bodies.
    if (data.length < 6) {
      _logDrop('enip-rr-short-body',
          () => 'Refused a SendRRData: its body is only ${data.length} '
          'bytes, too short for the interface handle and timeout fields.');
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    final items = parseCpf(Uint8List.sublistView(data, 6));
    if (items == null) {
      _logDrop('enip-rr-bad-cpf',
          () => 'Refused a SendRRData: its CPF item list could not be '
          'parsed.');
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    Uint8List? cipBytes;
    for (final item in items) {
      if (item.typeId == kCpfTypeUnconnectedData) {
        cipBytes = item.data;
        break;
      }
    }
    if (cipBytes == null) {
      _logDrop('enip-rr-no-uc-item',
          () => 'Refused a SendRRData: it carries no Unconnected Data '
          'CPF item (${items.length} item(s) present).');
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    final req = parseCipRequest(cipBytes);
    if (req == null) {
      _logDrop('enip-rr-bad-cip',
          () => 'Refused a SendRRData: its embedded CIP request '
          '(${cipBytes!.length} bytes) could not be parsed.');
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    logger?.logLazy(
      kLogSourceEnip,
      LogLevel.debug,
      () => 'Unconnected CIP service ${_hex(req.service)}, '
          '${cipBytes!.length} request bytes.',
    );

    final CipResponse resp;
    if (req.service == kCipServiceForwardOpen) {
      resp = connMgr.forwardOpen(req);
    } else if (req.service == kCipServiceForwardClose) {
      resp = connMgr.forwardClose(req);
    } else {
      final project = projectProvider();
      resp = dispatchCipService(project, _currentMap(project), req);
    }

    final replyCpfBytes = buildCpf([
      CpfItem(typeId: kCpfTypeNullAddress, data: Uint8List(0)),
      CpfItem(typeId: kCpfTypeUnconnectedData, data: buildCipResponse(resp)),
    ]);
    final replyData = Uint8List(6 + replyCpfBytes.length);
    replyData.setRange(6, replyData.length, replyCpfBytes);
    socket.add(_reply(header, 0, replyData));
  }

  void _handleSendUnitData(
    EnipHeader header,
    Uint8List data,
    PlcProject Function() projectProvider,
  ) {
    if (sessionHandle == null || header.sessionHandle != sessionHandle) {
      _logDrop('enip-unit-bad-session',
          () => 'Refused a SendUnitData: session handle '
          '${header.sessionHandle} is not the one registered on this '
          'connection (${sessionHandle ?? 'none'}).');
      socket.add(_reply(header, _kEncapStatusInvalidSessionHandle, Uint8List(0)));
      return;
    }
    if (data.length < 6) {
      _logDrop('enip-unit-short-body',
          () => 'Refused a SendUnitData: its body is only '
          '${data.length} bytes, too short for the interface handle and '
          'timeout fields.');
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }
    final items = parseCpf(Uint8List.sublistView(data, 6));
    if (items == null) {
      _logDrop('enip-unit-bad-cpf',
          () => 'Refused a SendUnitData: its CPF item list could not be '
          'parsed.');
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }

    int? connectionId;
    Uint8List? connectedData;
    for (final item in items) {
      if (item.typeId == kCpfTypeConnectedAddress && item.data.length >= 4) {
        connectionId = ByteData.sublistView(item.data, 0, 4).getUint32(0, Endian.little);
      } else if (item.typeId == kCpfTypeConnectedData) {
        connectedData = item.data;
      }
    }
    if (connectionId == null || connectedData == null || connectedData.length < 2) {
      _logDrop('enip-unit-no-conn-item',
          () => 'Refused a SendUnitData: it lacks a usable Connected '
          'Address and/or Connected Data CPF item.');
      socket.add(_reply(header, _kEncapStatusIncorrectData, Uint8List(0)));
      return;
    }

    final conn = connMgr.byConnectionId(connectionId);
    if (conn == null) {
      _logDrop('enip-unit-unknown-conn',
          () => 'Refused a SendUnitData: connection id $connectionId is '
          'not open on this connection.');
      // No open connection with this id on THIS socket's connection
      // manager — an unregistered/foreign/closed connection id. Refused at
      // the encapsulation layer, exactly like an invalid session handle,
      // rather than crashing on a null connection.
      socket.add(_reply(header, _kEncapStatusInvalidSessionHandle, Uint8List(0)));
      return;
    }

    // Connected Data = sequence count (u16 LE) + the embedded CIP request.
    // The reply echoes the same sequence count the request carried; it is
    // only ever needed locally for this one request/reply pair, so it is
    // tracked in the local `seq` variable below rather than on the
    // connection object.
    final seq = ByteData.sublistView(connectedData, 0, 2).getUint16(0, Endian.little);
    final cipBytes = Uint8List.sublistView(connectedData, 2);
    final req = parseCipRequest(cipBytes);

    final CipResponse resp;
    if (req == null) {
      _logDrop('enip-conn-bad-cip',
          () => 'Refused a connected request: its embedded CIP request '
          '(${cipBytes.length} bytes) could not be parsed.');
      resp = CipResponse(service: 0x00, generalStatus: kCipStatusServiceNotSupported, data: Uint8List(0));
    } else {
      logger?.logLazy(
        kLogSourceEnip,
        LogLevel.debug,
        () => 'Connected CIP service ${_hex(req.service)}, '
            '${cipBytes.length} request bytes.',
      );
      final project = projectProvider();
      resp = dispatchCipService(project, _currentMap(project), req);
    }

    final respBytes = buildCipResponse(resp);
    final connectedReplyData = Uint8List(2 + respBytes.length);
    ByteData.sublistView(connectedReplyData, 0, 2).setUint16(0, seq, Endian.little);
    connectedReplyData.setRange(2, connectedReplyData.length, respBytes);

    // Connected Address item on a target->originator (reply) message must
    // carry the id the ORIGINATOR allocated and consumes — the T->O id
    // (`conn.connectionIdTO`) — per the consumer-allocates rule documented
    // at cip_connection.dart:20-38. `connectionId` (the O->T id read off the
    // incoming request, above) is what THIS host allocated and consumes; it
    // is correct for `byConnectionId` lookups but wrong to echo back here.
    final addrItemData = Uint8List(4);
    ByteData.sublistView(addrItemData).setUint32(0, conn.connectionIdTO, Endian.little);

    final replyCpfBytes = buildCpf([
      CpfItem(typeId: kCpfTypeConnectedAddress, data: addrItemData),
      CpfItem(typeId: kCpfTypeConnectedData, data: connectedReplyData),
    ]);
    final replyData = Uint8List(6 + replyCpfBytes.length);
    replyData.setRange(6, replyData.length, replyCpfBytes);
    socket.add(_reply(header, 0, replyData));
  }

  /// The CIP tag-exposure map currently configured for [project], or an
  /// empty map if EtherNet/IP hosting has since been disabled/removed from
  /// the project out from under a still-open socket — never a null-deref.
  CipMap _currentMap(PlcProject project) => project.protocols?.ethernetIp?.map ?? CipMap(entries: []);

  Uint8List _reply(EnipHeader reqHeader, int status, Uint8List data) {
    final replyHeader = EnipHeader(
      command: reqHeader.command,
      // `length` here is purely documentary: `buildEnipFrame` is the sole
      // authority for the on-wire length field and always recomputes it
      // from the `data` actually passed to it, ignoring this value.
      length: data.length,
      sessionHandle: reqHeader.sessionHandle,
      status: status,
      senderContext: reqHeader.senderContext,
      options: 0,
    );
    return buildEnipFrame(replyHeader, data);
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    connMgr.releaseAll();
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
/// (`enip-tcp://<ip>:<port>`). Falls back to `localhost` if none can be
/// found (e.g. no network interfaces, or a platform that disallows the
/// lookup) — never throws. Mirrors the other hosts' `_bestDisplayHost`.
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

/// The `dart:io` EtherNet/IP + CIP explicit-messaging socket host. A
/// [ChangeNotifier] so the Outbound Protocols screen can reactively show
/// status/client-count/last-error.
///
/// Fully opt-in: until [start] is called, this class does nothing and the
/// app behaves exactly as it does today.
class EnipHost extends ChangeNotifier {
  /// Optional diagnostics sink. Deliberately NULLABLE: a host constructed
  /// without one behaves exactly as it did before this parameter existed.
  final AppLogger? logger;

  EnipHost({this.logger});

  /// Host-wide first-occurrence WARN policy for dropped requests, shared by
  /// every accepted connection so a client in a reconnect loop cannot re-arm
  /// the WARN on each new socket. See `drop_log_gate.dart`.
  late final DropLogGate _dropGate = DropLogGate(kLogSourceEnip, logger);

  ServerSocket? _serverSocket;
  final List<_Connection> _connections = [];
  StreamSubscription<Socket>? _acceptSub;

  /// Session handles are allocated from ONE monotonic counter shared by
  /// every connection this host ever accepts (never randomness, never the
  /// clock) — so handles are globally unique across sockets even though
  /// each socket's `CipConnectionManager` (and therefore its Forward-Open
  /// connection ids) is independent. Never reset by `stop()`/`start()`
  /// within a process lifetime's worth of hosting the same instance, so a
  /// restarted host never reissues a handle a still-connected (but
  /// forgotten) client might replay.
  int _nextSessionHandle = 1;

  EnipHostStatus _status = EnipHostStatus.stopped;
  EnipHostStatus get status => _status;

  String? _lastError;
  String? get lastError => _lastError;

  String? _endpointUrl;
  String? get endpointUrl => _endpointUrl;

  int get clientCount => _connections.length;

  bool _disposed = false;

  void _setStatus(EnipHostStatus s, {String? error}) {
    _status = s;
    _lastError = error;
    if (!_disposed) {
      notifyListeners();
    }
  }

  int _allocateSessionHandle() {
    final handle = _nextSessionHandle;
    _nextSessionHandle += 1;
    return handle;
  }

  /// Starts hosting `projectProvider()`'s current project's EtherNet/IP
  /// configuration. Requires `protocols.ethernetIp` to be non-null AND
  /// `enabled`; otherwise moves to [EnipHostStatus.error] with an
  /// explanatory message and returns without binding a socket.
  ///
  /// [projectProvider] is called fresh on every dispatched request, so a
  /// project swap while the server is running is safe — but the *port* and
  /// *enabled* flag are read once, at start time, since a bound socket
  /// can't change port without a restart.
  Future<void> start(PlcProject Function() projectProvider) async {
    if (_status == EnipHostStatus.running) {
      return; // already running; caller should stop() first to change port
    }
    final PlcProject project;
    try {
      project = projectProvider();
    } catch (e) {
      // Always-on: hosting did not start, and without this the operator gets
      // an error status with no recorded cause — while the "not enabled"
      // branch just below has been logged all along.
      logger?.log(
        kLogSourceEnip,
        LogLevel.error,
        'Not started: the current project could not be read.',
        detail: e.toString(),
      );
      _setStatus(EnipHostStatus.error, error: 'Could not read the current project: $e');
      return;
    }
    // A fresh run re-announces a still-broken configuration.
    _dropGate.reset();

    final enip = project.protocols?.ethernetIp;
    if (enip == null || !enip.enabled) {
      logger?.log(
        kLogSourceEnip,
        LogLevel.warn,
        'Not started: EtherNet/IP is not enabled for this project.',
      );
      _setStatus(EnipHostStatus.error, error: 'EtherNet/IP is not enabled for this project.');
      return;
    }
    final port = enip.port;

    try {
      final serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _serverSocket = serverSocket;

      final host = await _bestDisplayHost();
      _endpointUrl = 'enip-tcp://$host:${serverSocket.port}';

      _acceptSub = serverSocket.listen(
        (socket) => _acceptConnection(socket, projectProvider),
        onError: (Object e, StackTrace st) {
          logger?.log(
            kLogSourceEnip,
            LogLevel.error,
            'The listening socket reported an error.',
            detail: e.toString(),
          );
          _setStatus(EnipHostStatus.error, error: e.toString());
        },
        cancelOnError: false,
      );

      logger?.log(
        kLogSourceEnip,
        LogLevel.info,
        'Listening on port ${serverSocket.port}.',
        detail: _endpointUrl,
      );
      _setStatus(EnipHostStatus.running);
    } catch (e) {
      _serverSocket = null;
      final privileged = port > 0 && port < 1024;
      logger?.log(
        kLogSourceEnip,
        LogLevel.error,
        privileged
            ? 'Could not bind port $port. Ports below 1024 require elevated '
                'privileges on Linux/macOS — choose a port above 1023 to run '
                'unprivileged.'
            : 'Could not bind port $port.',
        detail: e.toString(),
      );
      _setStatus(EnipHostStatus.error, error: e.toString());
    }
  }

  void _acceptConnection(Socket socket, PlcProject Function() projectProvider) {
    try {
      final conn = _Connection(
        socket,
        dropLog: _dropGate.forConnection(),
        logger: logger,
      );
      _connections.add(conn);
      logger?.log(
        kLogSourceEnip,
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
            conn.onData(data, projectProvider, _allocateSessionHandle);
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
    // Releasing this socket's open Forward-Open connections on close is the
    // host's responsibility, not just `_Connection.close()`'s — a socket
    // can also die via `onError`/`onDone` without `close()` having run yet.
    conn.connMgr.releaseAll();
    conn.close();
    if (_connections.remove(conn)) {
      logger?.log(
        kLogSourceEnip,
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

  /// Stops hosting: closes every live connection (releasing each one's open
  /// CIP connections) and the listening socket. Safe to call when already
  /// stopped.
  Future<void> stop() async {
    try {
      await _acceptSub?.cancel();
    } catch (_) {
      // Ignore.
    }
    _acceptSub = null;

    for (final conn in List<_Connection>.from(_connections)) {
      conn.connMgr.releaseAll();
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
      logger?.log(kLogSourceEnip, LogLevel.info, 'Stopped hosting.');
    }
    _setStatus(EnipHostStatus.stopped);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
