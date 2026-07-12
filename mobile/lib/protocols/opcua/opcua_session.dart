// OPC UA secure-channel(None) + session state machine — pure Dart, no
// dart:io / Flutter imports. A socketless state machine: each inbound
// framed message (HEL, or a parsed OPN/MSG/CLO chunk's raw bytes) yields
// zero-or-more outbound frames. One instance per connection.
//
// Behaviour is per OPC UA Part 4 (Services) / Part 6 (transport), restricted
// to `SecurityPolicy#None` + anonymous authentication (v1 scope — see
// docs/superpowers/specs/2026-07-06-in-app-opcua-server-design.md).
//
// Every encoding id / struct layout / StatusCode used here is cross-checked
// against the Rust `opcua` crate (v0.12.0), vendored locally at:
//   C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/
// Specific files cited inline next to each constant/decision.
library opcua_session;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'opcua_binary.dart';
import 'opcua_crypto.dart' show secureRandomBytes;
import 'opcua_secure_channel.dart';
import 'opcua_subscriptions.dart';
import 'opcua_transport.dart';

// ---------------------------------------------------------------------------
// Encoding ids (the "DefaultBinary" ObjectId values used as the request/
// response NodeId at the start of every OPN/MSG chunk body — see
// core/comms/chunker.rs:238-264: "the extension object prefix is just the
// node id... decode the payload using the node id"). Verified one-by-one
// against types/node_ids.rs.
// ---------------------------------------------------------------------------
class _Ids {
  static const openSecureChannelRequest = 446; // node_ids.rs:1671
  static const openSecureChannelResponse = 449; // node_ids.rs:1672
  static const closeSecureChannelRequest = 452; // node_ids.rs:1673
  static const getEndpointsRequest = 428; // node_ids.rs:1665
  static const getEndpointsResponse = 431; // node_ids.rs:1666
  static const createSessionRequest = 461; // node_ids.rs:1676
  static const createSessionResponse = 464; // node_ids.rs:1677
  static const activateSessionRequest = 467; // node_ids.rs:1678
  static const activateSessionResponse = 470; // node_ids.rs:1679
  static const closeSessionRequest = 473; // node_ids.rs:1680
  static const closeSessionResponse = 476; // node_ids.rs:1681
  static const serviceFault = 397; // node_ids.rs:1662
  static const anonymousIdentityToken = 321; // node_ids.rs:1641
  static const userNameIdentityToken = 324; // node_ids.rs:1642
}

/// StatusCodes used by this state machine. Verified one-by-one against
/// types/status_codes.rs.
class OpcUaStatusCodes {
  static const good = 0;
  static const badServiceUnsupported = 0x800B0000; // status_codes.rs:96
  static const badSecureChannelIdInvalid = 0x80220000; // status_codes.rs:119
  static const badSessionIdInvalid = 0x80250000; // status_codes.rs:122
  static const badSessionNotActivated = 0x80270000; // status_codes.rs:124
  static const badTcpMessageTypeInvalid = 0x807E0000; // status_codes.rs:205
  static const badCommunicationError = 0x80050000; // status_codes.rs:90
  static const badUserAccessDenied = 0x801F0000; // status_codes.rs:116
  static const badIdentityTokenRejected = 0x80210000; // status_codes.rs:118
  static const badSecurityChecksFailed = 0x80130000; // status_codes.rs:110
  static const badApplicationSignatureInvalid = 0x80590000; // status_codes.rs:361
}

/// MessageSecurityMode enum values (enums.rs:856-861, Int32-encoded):
/// None = 1, Sign = 2, SignAndEncrypt = 3.
const int _securityModeNone = 1;
const int _securityModeSign = 2;
const int _securityModeSignAndEncrypt = 3;

/// UserTokenType.UserName (enums.rs:888-893, Int32-encoded).
const int _userTokenTypeUserName = 1;

/// SecurityTokenRequestType (channel_security_token.rs:920-923,
/// Int32-encoded): Issue = 0, Renew = 1.
const int _requestTypeIssue = 0;

/// ApplicationType.Server (enums.rs:824-829, Int32-encoded).
const int _applicationTypeServer = 0;

/// UserTokenType.Anonymous (enums.rs:888-893, Int32-encoded).
const int _userTokenTypeAnonymous = 0;

/// The uatcp binary transport profile URI. Verified against
/// types/mod.rs:19 (`TRANSPORT_PROFILE_URI_SOAP_...` sibling const) —
/// exact string confirmed by grep of the vendored source.
const String _transportProfileUriUaTcp =
    'http://opcfoundation.org/UA-Profile/Transport/uatcp-uasc-uabinary';

/// The floor/ceiling values this server negotiates. Not part of the spec
/// itself, just sane v1 bounds (documented in the task brief).
const int _maxNegotiatedBufferSize = 1048576; // 1 MB
const int _minNegotiatedBufferSize = 8192;
const int _maxChannelLifetimeMs = 3600000; // 1 hour
const int _minChannelLifetimeMs = 60000; // 1 minute floor
const int _maxSessionTimeoutMs = 3600000; // 1 hour
const int _minSessionTimeoutMs = 10000; // 10s floor

/// Minimal description of the server, as consumed by GetEndpoints /
/// CreateSession responses. `port` is folded into [endpointUrl] by the
/// caller (Task 4's host) — this class only needs the fully-formed URL.
class OpcUaServerInfo {
  final String applicationName;
  final String applicationUri;
  final String endpointUrl;
  final String namespaceUri;

  const OpcUaServerInfo({
    required this.applicationName,
    required this.applicationUri,
    required this.endpointUrl,
    required this.namespaceUri,
  });
}

/// Builds a [ResponseHeader] pre-filled with the current server timestamp
/// and the request's handle; the handler only needs to supply the
/// serviceResult (defaults to Good).
typedef ResponseBuilder = ResponseHeader Function({int serviceResult});

/// The Task 3 callback contract: given a decoded service request (identified
/// by its `requestTypeId`, i.e. the DefaultBinary encoding id read off the
/// chunk body), the still-positioned-after-the-header [body] reader, the
/// already-decoded [header], and a [respond] helper for building a
/// ResponseHeader, return the fully-encoded response BODY (response type id
/// NodeId + the response struct's fields) as bytes — or `null` if this
/// implementation does not support the given service (the session then
/// emits a ServiceFault with Bad_ServiceUnsupported).
///
/// The handler is only ever invoked for requests that are NOT recognized as
/// one of this session's own services (HEL/OPN/GetEndpoints/CreateSession/
/// ActivateSession/CloseSession/CloseSecureChannel), and only once the
/// session is activated with a matching authentication token — the session
/// itself enforces Bad_SessionNotActivated / Bad_SessionIdInvalid before
/// ever calling [handle].
///
/// Implementations MUST NOT throw; if something goes wrong, return `null`
/// (unsupported) or build a ServiceFault-shaped body yourself — actually,
/// simplest: just return `null` and let the session fault it, or catch your
/// own errors and encode a Good/Bad response body as appropriate. The
/// session wraps the call in the same catch-all as everything else, so an
/// uncaught throw from the handler still degrades to ERR + close rather than
/// crashing the app, but a clean `null`/response is strongly preferred.
abstract class OpcUaServiceHandler {
  Uint8List? handle(
    int requestTypeId,
    OpcUaReader body,
    RequestHeader header,
    ResponseBuilder respond,
  );
}

/// One advertised (policy, mode) endpoint, resolved from a `securityModes`
/// token.
class _EndpointSpec {
  final String policyUri;
  final int securityMode;
  final bool secure;

  const _EndpointSpec({
    required this.policyUri,
    required this.securityMode,
    required this.secure,
  });
}

class _ChannelState {
  int channelId;
  int tokenId;
  int lifetimeMs;

  _ChannelState({
    required this.channelId,
    required this.tokenId,
    required this.lifetimeMs,
  });
}

class _SessionState {
  final OpcNodeId sessionId;
  final OpcNodeId authToken;
  bool activated = false;
  bool closed = false;

  /// The server nonce issued in this session's CreateSessionResponse (the
  /// secure channel's own server nonce, or null on a None channel). Task 3's
  /// ActivateSession `clientSignature` verification signs over
  /// `serverCertificateDer ++ serverNonce` using exactly this value.
  final Uint8List? createSessionServerNonce;

  _SessionState({
    required this.sessionId,
    required this.authToken,
    this.createSessionServerNonce,
  });
}

/// One instance per connection. Feed it inbound bytes via [onBytes]; it
/// returns zero-or-more outbound frames (already-framed HEL/ACK/ERR or
/// OPN/MSG chunk bytes, ready to write to the socket). Never throws — any
/// decode failure degrades to an ERR frame + [shouldClose].
class OpcUaServerSession {
  final OpcUaServerInfo info;
  final OpcUaServiceHandler? services;
  final OpcDataValue Function(OpcNodeId)? sampler;

  /// The `Policy/Mode` tokens this session advertises as EndpointDescriptions
  /// (see [OpcUaProtocolConfig.securityModes] for the recognized values).
  /// Defaults to `['None']` so an un-configured session behaves exactly like the
  /// pre-security host (a single None+Anonymous endpoint).
  final List<String> securityModes;

  /// The server's application-instance certificate DER, advertised as the
  /// `serverCertificate` ByteString on secure endpoints. Null for a None-only
  /// host. Injected by the host (Task 6).
  final Uint8List? serverCertificateDer;

  /// Accepted username -> password credentials for UserNameIdentityToken auth.
  /// Empty when no username auth is configured.
  final Map<String, String> credentials;

  /// Whether anonymous authentication is accepted. Default `true`
  /// (pre-security behavior).
  final bool allowAnonymous;

  /// The per-connection secure channel (Task 4/5). Non-null enables the secured
  /// OPN/MSG path; a client that opens a `SecurityPolicy#None` channel still
  /// takes the byte-identical None path even when this is non-null. Null =
  /// None-only / back-compat.
  final OpcSecureChannel? _secureChannel;

  /// Injected 32-byte nonce generator (server nonce per OPN). Defaults to a
  /// cryptographically-strong random; tests inject a deterministic one.
  final Uint8List Function() _serverNonceGen;

  bool _helloReceived = false;
  bool _shouldClose = false;

  /// True once a NON-None OPN has been processed on this connection — gates the
  /// symmetric MSG in/out path. A None OPN leaves this false so the None path
  /// stays byte-identical even when a channel is injected.
  bool _channelSecured = false;

  _ChannelState? _channel;
  _SessionState? _session;

  /// Task 2 (discovery/endpoint-echo): the most recently observed
  /// client-supplied `endpointUrl` (from Hello, then possibly overwritten by
  /// GetEndpointsRequest, then possibly overwritten by CreateSessionRequest —
  /// "last non-empty wins", so whichever of these the client actually sent
  /// most recently is what gets echoed back). A client may reach this server
  /// at an address our own best-effort guess (`OpcUaHost._bestDisplayHost()`)
  /// can't reproduce (different NIC, NAT, container hostname, etc.) — since
  /// the client just told us what it dialed, echoing that HOST back in
  /// EndpointDescription.endpointUrl is more likely to be reachable than our
  /// guess. `null` until the client sends one.
  String? _clientEndpointUrl;

  int _nextChannelId = 1;
  int _nextTokenId = 1;
  int _nextSessionNumericId = 1;
  int _nextAuthTokenNumericId = 1;

  /// The server's own outbound sequence-number counter — independent of
  /// whatever the client sends. Starts at 1 per Part 6 (a fresh channel's
  /// first sequence number is 1).
  int _serverSequenceNumber = 1;

  /// Lazily created the first time a subscription-service request arrives
  /// AND [sampler] is non-null (a `sampler: null` session always faults
  /// subscription services with Bad_ServiceUnsupported, preserving pre-Task-3
  /// behavior for tests/hosts that don't wire one up).
  SubscriptionManager? _subscriptionManager;

  OpcUaServerSession({
    required this.info,
    required this.services,
    this.sampler,
    List<String>? securityModes,
    this.serverCertificateDer,
    Map<String, String>? credentials,
    this.allowAnonymous = true,
    OpcSecureChannel? secureChannel,
    Uint8List Function()? serverNonceGenerator,
  })  : securityModes = securityModes ?? const <String>['None'],
        credentials = credentials ?? const <String, String>{},
        _secureChannel = secureChannel,
        _serverNonceGen = serverNonceGenerator ??
            (() => secureRandomBytes(kSecureChannelNonceLength));

  bool get shouldClose => _shouldClose;

  /// 0 when no subscriptions have ever been created (including when
  /// [sampler] is null, so no manager was ever instantiated).
  int get subscriptionCount => _subscriptionManager?.subscriptionCount ?? 0;

  /// 0 when no monitored items exist (including when [sampler] is null).
  int get monitoredItemCount => _subscriptionManager?.monitoredItemCount ?? 0;

  int _nextSeq() => _serverSequenceNumber++;

  /// Feeds one inbound framed message (a full HEL/ACK/ERR frame, or a full
  /// OPN/MSG/CLO chunk) and returns the frames to send back. [nowMs] is the
  /// monotonic clock reading (ms) used for subscription/monitored-item
  /// scheduling — irrelevant to every non-subscription service, so tests
  /// that don't exercise subscriptions may pass 0. Never throws.
  List<Uint8List> onBytes(Uint8List frame, int nowMs) {
    try {
      return _onBytesInner(frame, nowMs);
    } catch (_) {
      // Catch-all: any decode failure/format exception/cast error anywhere
      // below degrades to a clean ERR frame + close, never an uncaught
      // throw out of onBytes.
      _shouldClose = true;
      return [
        const ErrorMessage(
          error: OpcUaStatusCodes.badCommunicationError,
          reason: 'malformed or unsupported input',
        ).build(),
      ];
    }
  }

  /// Clock-tick entry point: drives the [SubscriptionManager]'s time-based
  /// publish engine (keep-alives, sampling, retransmission, lifetime
  /// timeouts) and returns any resulting MSG frames to push to the socket
  /// NOW (unsolicited — no matching inbound request this tick). Returns
  /// `const []` when there is no channel yet, no session, no activated
  /// session, no manager (sampler-less session), or no subscriptions ready
  /// to publish. NEVER throws — unlike [onBytes]'s ERR+close degrade path,
  /// a tick failure is swallowed silently and the connection stays open
  /// (a single misbehaving tick must not tear down an otherwise-healthy
  /// connection).
  List<Uint8List> onClockTick(int nowMs) {
    try {
      final manager = _subscriptionManager;
      if (_channel == null || _session == null || !_session!.activated || manager == null) {
        return const [];
      }
      final outs = manager.onTick(nowMs);
      if (outs.isEmpty) return const [];
      return [for (final out in outs) _wrapMsgResponseForRequestId(out.requestId, out.body)];
    } catch (_) {
      return const [];
    }
  }

  List<Uint8List> _onBytesInner(Uint8List frame, int nowMs) {
    if (frame.length < kMessageHeaderLen) {
      return _err(OpcUaStatusCodes.badTcpMessageTypeInvalid, 'frame too short');
    }
    final peekType = String.fromCharCodes(frame.sublist(0, 3));

    if (!_helloReceived) {
      if (peekType != 'HEL') {
        return _err(
          OpcUaStatusCodes.badTcpMessageTypeInvalid,
          'expected HEL as first message, got $peekType',
        );
      }
      return _handleHello(frame);
    }

    switch (peekType) {
      case 'OPN':
        return _handleOpn(frame);
      case 'MSG':
        return _handleMsg(frame, nowMs);
      case 'CLO':
        return _handleClo(frame);
      default:
        return _err(
          OpcUaStatusCodes.badTcpMessageTypeInvalid,
          'unexpected message type $peekType',
        );
    }
  }

  List<Uint8List> _err(int code, String reason) {
    _shouldClose = true;
    return [ErrorMessage(error: code, reason: reason).build()];
  }

  // --- HEL/ACK ---------------------------------------------------------

  List<Uint8List> _handleHello(Uint8List frame) {
    final hello = HelloMessage.parse(frame);
    if (hello.protocolVersion != 0) {
      return _err(
        OpcUaStatusCodes.badTcpMessageTypeInvalid,
        'unsupported protocol version ${hello.protocolVersion}',
      );
    }

    int negotiate(int requested) {
      final wanted = requested <= 0 ? _maxNegotiatedBufferSize : requested;
      final capped = wanted < _maxNegotiatedBufferSize ? wanted : _maxNegotiatedBufferSize;
      return capped < _minNegotiatedBufferSize ? _minNegotiatedBufferSize : capped;
    }

    final recvSize = negotiate(hello.sendBufferSize); // our receive <= their send
    final sendSize = negotiate(hello.receiveBufferSize); // our send <= their receive

    if (hello.endpointUrl.isNotEmpty) {
      _clientEndpointUrl = hello.endpointUrl;
    }
    _helloReceived = true;
    final ack = AcknowledgeMessage(
      protocolVersion: 0,
      receiveBufferSize: recvSize,
      sendBufferSize: sendSize,
      maxMessageSize: 0,
      maxChunkCount: 0,
    );
    return [ack.build()];
  }

  // --- OPN (OpenSecureChannel) ------------------------------------------

  List<Uint8List> _handleOpn(Uint8List frame) {
    // Peek the (plaintext) security header to decide None vs secured. The None
    // path below is byte-identical to the pre-security host; the secured path
    // routes through the injected [OpcSecureChannel].
    final chunkHeader = parseChunkHeader(frame);
    final policyUri = chunkHeader.securityPolicyUri ?? kSecurityPolicyNoneUri;
    if (policyUri != kSecurityPolicyNoneUri) {
      final channel = _secureChannel;
      if (channel == null) {
        return _err(
          OpcUaStatusCodes.badSecurityChecksFailed,
          'secured OPN requested but no secure channel is configured',
        );
      }
      return _handleSecuredOpn(frame, chunkHeader, channel);
    }

    final chunk = parseChunk(frame);
    if (!chunk.isFinal) {
      return _err(
        OpcUaStatusCodes.badTcpMessageTypeInvalid,
        'multi-chunk (non-final) messages are not supported',
      );
    }

    final reader = OpcUaReader(chunk.body);
    final requestTypeId = reader.nodeId();
    if (!requestTypeId.isNumeric ||
        requestTypeId.numericId != _Ids.openSecureChannelRequest) {
      return _err(
        OpcUaStatusCodes.badTcpMessageTypeInvalid,
        'expected OpenSecureChannelRequest in OPN chunk',
      );
    }
    final header = reader.requestHeader();
    reader.uint32(); // clientProtocolVersion — ignored (we only speak 0).
    final requestType = reader.int32(); // SecurityTokenRequestType
    reader.int32(); // securityMode — ignored (None is the only mode we run).
    reader.byteString(); // clientNonce — ignored (None has no crypto material).
    final requestedLifetime = reader.uint32();

    final isRenew = requestType != _requestTypeIssue;
    if (isRenew) {
      if (_channel == null || chunk.secureChannelId != _channel!.channelId) {
        return _err(
          OpcUaStatusCodes.badSecureChannelIdInvalid,
          'Renew on an unknown secure channel',
        );
      }
      _channel!.tokenId = _nextTokenId++;
      _channel!.lifetimeMs = _boundLifetime(requestedLifetime);
    } else {
      _channel = _ChannelState(
        channelId: _nextChannelId++,
        tokenId: _nextTokenId++,
        lifetimeMs: _boundLifetime(requestedLifetime),
      );
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.openSecureChannelResponse));
    w.responseHeader(ResponseHeader(
      timestamp: DateTime.now().toUtc(),
      requestHandle: header.requestHandle,
      serviceResult: OpcUaStatusCodes.good,
    ));
    w.uint32(0); // serverProtocolVersion
    // ChannelSecurityToken (channel_security_token.rs): channelId, tokenId,
    // createdAt, revisedLifetime.
    w.uint32(_channel!.channelId);
    w.uint32(_channel!.tokenId);
    w.dateTime(DateTime.now().toUtc());
    w.uint32(_channel!.lifetimeMs);
    w.byteString(null); // serverNonce — null for SecurityPolicy#None.

    final body = w.take();
    final responseChunk = buildOpnChunk(
      secureChannelId: _channel!.channelId,
      securityPolicyUri: kSecurityPolicyNoneUri,
      sequenceNumber: _nextSeq(),
      requestId: chunk.requestId,
      body: body,
    );
    return [responseChunk];
  }

  /// Secured (Basic256Sha256) OpenSecureChannel: verify+decrypt the client OPN
  /// through the injected [channel], parse the real clientNonce, derive the
  /// symmetric key set for the new/renewed token, and return a signed+encrypted
  /// OPN response carrying a non-null serverNonce. Mirrors the None [_handleOpn]
  /// body but with the crypto envelope; a decrypt/verify failure degrades to a
  /// clean ERR (never an uncaught throw).
  List<Uint8List> _handleSecuredOpn(
    Uint8List frame,
    OpcChunkHeader header,
    OpcSecureChannel channel,
  ) {
    if (!header.isFinal) {
      return _err(
        OpcUaStatusCodes.badTcpMessageTypeInvalid,
        'multi-chunk (non-final) messages are not supported',
      );
    }

    final rawHeader = Uint8List.sublistView(frame, 0, header.securityHeaderEnd);
    final rawAfter =
        Uint8List.sublistView(frame, header.securityHeaderEnd, header.size);
    final serverNonce = _serverNonceGen();

    final Uint8List plaintext;
    try {
      plaintext = channel.openFromClient(
        policyUri: header.securityPolicyUri!,
        senderCertificate: header.senderCertificate == null
            ? null
            : Uint8List.fromList(header.senderCertificate!),
        rawHeader: rawHeader,
        rawAfterSecurityHeader: rawAfter,
        serverNonce: serverNonce,
        clientNonce: Uint8List(0), // real nonce parsed from the plaintext below
        receiverCertificateThumbprint:
            header.receiverCertificateThumbprint == null
                ? null
                : Uint8List.fromList(header.receiverCertificateThumbprint!),
        deriveKeys: false,
      );
    } on OpcSecurityException {
      return _err(
        OpcUaStatusCodes.badSecurityChecksFailed,
        'secure channel OPN verification/decryption failed',
      );
    }

    // plaintext = sequenceHeader(8) ++ OpenSecureChannelRequest body.
    if (plaintext.length < 8) {
      return _err(
        OpcUaStatusCodes.badTcpMessageTypeInvalid,
        'secured OPN plaintext shorter than its sequence header',
      );
    }
    final requestId = ByteData.sublistView(plaintext, 4, 8)
        .getUint32(0, Endian.little);

    final reader = OpcUaReader(Uint8List.sublistView(plaintext, 8));
    final requestTypeId = reader.nodeId();
    if (!requestTypeId.isNumeric ||
        requestTypeId.numericId != _Ids.openSecureChannelRequest) {
      return _err(
        OpcUaStatusCodes.badTcpMessageTypeInvalid,
        'expected OpenSecureChannelRequest in secured OPN chunk',
      );
    }
    final reqHeader = reader.requestHeader();
    reader.uint32(); // clientProtocolVersion — ignored.
    final requestType = reader.int32(); // SecurityTokenRequestType
    final securityMode = reader.int32(); // MessageSecurityMode
    final clientNonce = reader.byteString(); // the REAL client nonce
    final requestedLifetime = reader.uint32();

    // The requested MessageSecurityMode governs the subsequent symmetric MSGs.
    channel.messageSecurityMode = securityMode == _securityModeSign
        ? OpcSecurityMode.sign
        : OpcSecurityMode.signAndEncrypt;

    final isRenew = requestType != _requestTypeIssue;
    if (isRenew) {
      if (_channel == null || header.secureChannelId != _channel!.channelId) {
        return _err(
          OpcUaStatusCodes.badSecureChannelIdInvalid,
          'Renew on an unknown secure channel',
        );
      }
      _channel!.tokenId = _nextTokenId++;
      _channel!.lifetimeMs = _boundLifetime(requestedLifetime);
    } else {
      _channel = _ChannelState(
        channelId: _nextChannelId++,
        tokenId: _nextTokenId++,
        lifetimeMs: _boundLifetime(requestedLifetime),
      );
    }
    _channelSecured = true;

    // Derive the symmetric key set for the (new/renewed) token. On Renew the
    // channel retains the previous token's keys within its lifetime.
    channel.deriveSymmetricKeys(
      tokenId: _channel!.tokenId,
      clientNonce:
          clientNonce == null ? Uint8List(0) : Uint8List.fromList(clientNonce),
      serverNonce: serverNonce,
    );

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.openSecureChannelResponse));
    w.responseHeader(ResponseHeader(
      timestamp: DateTime.now().toUtc(),
      requestHandle: reqHeader.requestHandle,
      serviceResult: OpcUaStatusCodes.good,
    ));
    w.uint32(0); // serverProtocolVersion
    w.uint32(_channel!.channelId);
    w.uint32(_channel!.tokenId);
    w.dateTime(DateTime.now().toUtc());
    w.uint32(_channel!.lifetimeMs);
    w.byteString(serverNonce); // non-null for a secured channel
    final body = w.take();

    final seqNum = _nextSeq();
    final seqBody = BytesBuilder(copy: true)
      ..add(_sequenceHeader(seqNum, requestId))
      ..add(body);
    final respFrame = channel.buildSecuredOpnResponse(
      secureChannelId: _channel!.channelId,
      sequenceNumber: seqNum,
      requestId: requestId,
      plaintextSequenceAndBody: seqBody.takeBytes(),
    );
    return [respFrame];
  }

  /// Encodes an 8-byte sequence header (sequenceNumber, requestId) — used to
  /// prefix a plaintext body handed to the secure channel's chunk builders.
  Uint8List _sequenceHeader(int sequenceNumber, int requestId) {
    final b = ByteData(8)
      ..setUint32(0, sequenceNumber, Endian.little)
      ..setUint32(4, requestId, Endian.little);
    return b.buffer.asUint8List();
  }

  int _boundLifetime(int requested) {
    final wanted = requested <= 0 ? _maxChannelLifetimeMs : requested;
    final capped = wanted < _maxChannelLifetimeMs ? wanted : _maxChannelLifetimeMs;
    return capped < _minChannelLifetimeMs ? _minChannelLifetimeMs : capped;
  }

  // --- CLO (CloseSecureChannel) ------------------------------------------

  List<Uint8List> _handleClo(Uint8List frame) {
    final chunk = parseChunk(frame);
    // Best-effort: validate the channel/token if we can, but a CloseSecureChannel
    // is inherently the last thing we'll process on this connection, so we
    // don't bother decoding the body beyond confirming the chunk parses.
    if (_channel == null || chunk.secureChannelId != _channel!.channelId) {
      // Nothing meaningful to close; still shut the connection down cleanly.
      _shouldClose = true;
      return const [];
    }
    _shouldClose = true;
    // Per OPC UA Part 6, CloseSecureChannel does not solicit a response.
    return const [];
  }

  // --- MSG (service dispatch) --------------------------------------------

  List<Uint8List> _handleMsg(Uint8List frame, int nowMs) {
    final OpcChunk chunk;
    if (_channelSecured) {
      final secured = _decryptSecuredMsg(frame);
      if (secured == null) {
        return _err(
          OpcUaStatusCodes.badSecurityChecksFailed,
          'secured MSG verification/decryption failed',
        );
      }
      chunk = secured;
    } else {
      chunk = parseChunk(frame);
    }
    if (!chunk.isFinal) {
      return _err(
        OpcUaStatusCodes.badTcpMessageTypeInvalid,
        'multi-chunk (non-final) messages are not supported',
      );
    }
    if (_channel == null ||
        chunk.secureChannelId != _channel!.channelId ||
        chunk.tokenId != _channel!.tokenId) {
      // Defense-in-depth: validate the channel id as well as the token id,
      // consistent with the OPN (renew) and CLO paths in this file.
      return _err(
        OpcUaStatusCodes.badSecureChannelIdInvalid,
        'unknown or stale secure channel token',
      );
    }

    final reader = OpcUaReader(chunk.body);
    final requestTypeId = reader.nodeId();
    if (!requestTypeId.isNumeric) {
      return _fault(
        chunk,
        requestHandle: 0,
        serviceResult: OpcUaStatusCodes.badServiceUnsupported,
      );
    }
    final id = requestTypeId.numericId!;
    final header = reader.requestHeader();

    switch (id) {
      case _Ids.getEndpointsRequest:
        return _handleGetEndpoints(chunk, reader, header);
      case _Ids.createSessionRequest:
        return _handleCreateSession(chunk, reader, header);
      case _Ids.activateSessionRequest:
        return _handleActivateSession(chunk, reader, header);
      case _Ids.closeSessionRequest:
        return _handleCloseSession(chunk, header);
      case _Ids.closeSecureChannelRequest:
        _shouldClose = true;
        return const [];
      default:
        if (SubscriptionManager.serviceIds.contains(id)) {
          return _dispatchToSubscriptionManager(chunk, id, reader, header, nowMs);
        }
        return _dispatchToServiceHandler(chunk, id, reader, header);
    }
  }

  ResponseHeader _respond(RequestHeader header, {int serviceResult = OpcUaStatusCodes.good}) {
    return ResponseHeader(
      timestamp: DateTime.now().toUtc(),
      requestHandle: header.requestHandle,
      serviceResult: serviceResult,
    );
  }

  List<Uint8List> _fault(
    OpcChunk requestChunk, {
    required int requestHandle,
    required int serviceResult,
  }) {
    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.serviceFault));
    w.responseHeader(ResponseHeader(
      timestamp: DateTime.now().toUtc(),
      requestHandle: requestHandle,
      serviceResult: serviceResult,
    ));
    return [_wrapMsgResponse(requestChunk, w.take())];
  }

  /// Verifies+decrypts a secured inbound MSG/CLO chunk into a plaintext
  /// [OpcChunk] (as [parseChunk] would yield for None). Returns null on any
  /// MAC/decrypt/format failure so the caller degrades to a clean error. A
  /// non-final chunk is returned undecrypted so the caller's `isFinal` guard
  /// reports the multi-chunk error unchanged.
  OpcChunk? _decryptSecuredMsg(Uint8List frame) {
    final channel = _secureChannel;
    if (channel == null) {
      return null;
    }
    try {
      final header = parseChunkHeader(frame);
      if (!header.isFinal) {
        return OpcChunk(
          messageType: header.messageType,
          chunkType: header.chunkType,
          secureChannelId: header.secureChannelId,
          tokenId: header.tokenId,
          sequenceNumber: 0,
          requestId: 0,
          body: Uint8List(0),
        );
      }
      final rawHeader =
          Uint8List.sublistView(frame, 0, header.securityHeaderEnd);
      final rawAfter =
          Uint8List.sublistView(frame, header.securityHeaderEnd, header.size);
      final tokenId = header.tokenId ?? 0;
      final plaintext = channel.openSymmetric(
        tokenId: tokenId,
        rawHeader: rawHeader,
        rawAfterSecurityHeader: rawAfter,
      );
      // plaintext = sequenceHeader(8) ++ body.
      if (plaintext.length < 8) {
        return null;
      }
      final view = ByteData.sublistView(plaintext, 0, 8);
      final sequenceNumber = view.getUint32(0, Endian.little);
      final requestId = view.getUint32(4, Endian.little);
      return OpcChunk(
        messageType: header.messageType,
        chunkType: header.chunkType,
        secureChannelId: header.secureChannelId,
        tokenId: tokenId,
        sequenceNumber: sequenceNumber,
        requestId: requestId,
        body: Uint8List.fromList(Uint8List.sublistView(plaintext, 8)),
      );
    } catch (_) {
      return null;
    }
  }

  Uint8List _wrapMsgResponse(OpcChunk requestChunk, Uint8List body) {
    return _buildMsgOut(requestChunk.requestId, body);
  }

  /// Frames one outbound MSG body — secured via [OpcSecureChannel.buildSecuredMsg]
  /// on a secured channel, or a plain [buildMsgChunk] otherwise (byte-identical
  /// to the pre-security host). Uses the current channel/token ids and the
  /// server's own next sequence number.
  Uint8List _buildMsgOut(int requestId, Uint8List body) {
    final channel = _secureChannel;
    if (_channelSecured && channel != null) {
      return channel.buildSecuredMsg(
        secureChannelId: _channel!.channelId,
        tokenId: _channel!.tokenId,
        sequenceNumber: _nextSeq(),
        requestId: requestId,
        body: body,
      );
    }
    return buildMsgChunk(
      secureChannelId: _channel!.channelId,
      tokenId: _channel!.tokenId,
      sequenceNumber: _nextSeq(),
      requestId: requestId,
      body: body,
    );
  }

  /// Same as [_wrapMsgResponse] but for a [PublishOut] whose `requestId` is
  /// NOT the chunk currently being processed — used both for
  /// [SubscriptionManager] responses (which may resolve an EARLIER parked
  /// Publish, not necessarily the just-arrived request) and for
  /// [onClockTick] (no inbound chunk at all). Uses the CURRENT channel/token
  /// ids and the server's own next sequence number, same as every other
  /// outbound frame.
  Uint8List _wrapMsgResponseForRequestId(int requestId, Uint8List body) {
    return _buildMsgOut(requestId, body);
  }

  /// GetEndpointsRequest (get_endpoints_request.rs): requestHeader(consumed
  /// by `_handleMsg`), endpointUrl String, localeIds array (unused), profileUris
  /// array (unused). The endpointUrl is the address the CLIENT dialed to
  /// reach us — captured into [_clientEndpointUrl] (Task 2 endpoint echo) so
  /// [_writeEndpointDescription] can advertise a host the client already
  /// knows works, instead of only ever our own best-effort guess.
  List<Uint8List> _handleGetEndpoints(OpcChunk chunk, OpcUaReader reader, RequestHeader header) {
    final endpointUrl = reader.string();
    _skipArrayOfStrings(reader); // localeIds
    _skipArrayOfStrings(reader); // profileUris
    if (endpointUrl != null && endpointUrl.isNotEmpty) {
      _clientEndpointUrl = endpointUrl;
    }

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.getEndpointsResponse));
    w.responseHeader(_respond(header));
    _writeEndpoints(w);
    return [_wrapMsgResponse(chunk, w.take())];
  }

  /// Writes the EndpointDescription[] array: `Int32 count` + one
  /// EndpointDescription per enabled (policy, mode) in [securityModes]. For the
  /// default `['None']` (+ allowAnonymous, no credentials) this emits exactly
  /// one None/Anonymous endpoint — byte-identical to the pre-security host.
  void _writeEndpoints(OpcUaWriter w) {
    final specs = _enabledEndpoints();
    w.int32(specs.length);
    for (final spec in specs) {
      _writeEndpointDescription(w, spec);
    }
  }

  /// Parses [securityModes] into the concrete (policyUri, securityMode int,
  /// secure) endpoint set. Unrecognized tokens are skipped; if nothing is
  /// recognized, a single None endpoint is advertised so the server is never
  /// endpoint-less.
  List<_EndpointSpec> _enabledEndpoints() {
    final specs = <_EndpointSpec>[];
    for (final token in securityModes) {
      switch (token) {
        case 'None':
          specs.add(const _EndpointSpec(
            policyUri: kSecurityPolicyNoneUri,
            securityMode: _securityModeNone,
            secure: false,
          ));
          break;
        case 'Basic256Sha256/Sign':
          specs.add(const _EndpointSpec(
            policyUri: kSecurityPolicyBasic256Sha256Uri,
            securityMode: _securityModeSign,
            secure: true,
          ));
          break;
        case 'Basic256Sha256/SignAndEncrypt':
          specs.add(const _EndpointSpec(
            policyUri: kSecurityPolicyBasic256Sha256Uri,
            securityMode: _securityModeSignAndEncrypt,
            secure: true,
          ));
          break;
        default:
          // Unknown token — skip.
          break;
      }
    }
    if (specs.isEmpty) {
      specs.add(const _EndpointSpec(
        policyUri: kSecurityPolicyNoneUri,
        securityMode: _securityModeNone,
        secure: false,
      ));
    }
    return specs;
  }

  /// EndpointDescription (endpoint_description.rs): endpointUrl,
  /// server ApplicationDescription, serverCertificate ByteString,
  /// securityMode Int32 enum, securityPolicyUri, userIdentityTokens array,
  /// transportProfileUri, securityLevel Byte. Secure endpoints carry the
  /// server certificate DER; the None endpoint carries a null certificate and
  /// securityLevel 0 (byte-identical to the pre-security host).
  void _writeEndpointDescription(OpcUaWriter w, _EndpointSpec spec) {
    w.string(_advertisedEndpointUrl());
    _writeApplicationDescription(w);
    w.byteString(spec.secure ? serverCertificateDer : null);
    w.int32(spec.securityMode);
    w.string(spec.policyUri);
    _writeUserTokenPolicies(w, secure: spec.secure);
    w.string(_transportProfileUriUaTcp);
    w.uint8(spec.secure ? 1 : 0); // securityLevel (0 for None, unchanged)
  }

  /// Writes the UserTokenPolicy[] for one endpoint: an anonymous policy when
  /// [allowAnonymous], plus a username policy when [credentials] are
  /// configured. For the default (allowAnonymous, no credentials) this is
  /// exactly one anonymous policy — byte-identical to the pre-security host.
  void _writeUserTokenPolicies(OpcUaWriter w, {required bool secure}) {
    final writeAnonymous = allowAnonymous;
    final writeUserName = credentials.isNotEmpty;
    var count = 0;
    if (writeAnonymous) count++;
    if (writeUserName) count++;
    // Never advertise an endpoint with zero token policies.
    if (count == 0) {
      w.int32(1);
      _writeAnonymousUserTokenPolicy(w);
      return;
    }
    w.int32(count);
    if (writeAnonymous) {
      _writeAnonymousUserTokenPolicy(w);
    }
    if (writeUserName) {
      _writeUserNameUserTokenPolicy(w, secure: secure);
    }
  }

  /// Task 2 (discovery/endpoint-echo): the endpointUrl to advertise in
  /// EndpointDescription — [info.endpointUrl]'s own host/port (our own
  /// best-effort `opc.tcp://<bestDisplayHost>:<port>` guess, from
  /// `OpcUaHost._bestDisplayHost()`) with the HOST swapped for whatever host
  /// the CLIENT most recently told us it dialed ([_clientEndpointUrl] — see
  /// its doc for precedence). Falls back to [info.endpointUrl] verbatim when
  /// the client hasn't supplied a usable `opc.tcp://` URL yet (empty,
  /// unparseable, or missing a host) — never worse than pre-Task-2 behavior.
  /// This does NOT touch [info.endpointUrl] itself or the UI-displayed
  /// endpoint (`OpcUaHost._endpointUrl`) — only what THIS response advertises.
  String _advertisedEndpointUrl() {
    final client = _clientEndpointUrl;
    if (client == null || client.isEmpty) {
      return info.endpointUrl;
    }
    final clientUri = Uri.tryParse(client);
    if (clientUri == null || clientUri.host.isEmpty) {
      return info.endpointUrl;
    }
    final serverUri = Uri.tryParse(info.endpointUrl);
    if (serverUri == null) {
      return info.endpointUrl;
    }
    final portSuffix = serverUri.hasPort ? ':${serverUri.port}' : '';
    return 'opc.tcp://${clientUri.host}$portSuffix';
  }

  /// ApplicationDescription (application_description.rs): applicationUri,
  /// productUri, applicationName LocalizedText, applicationType Int32 enum,
  /// gatewayServerUri, discoveryProfileUri, discoveryUrls array.
  void _writeApplicationDescription(OpcUaWriter w) {
    w.string(info.applicationUri);
    w.string(info.applicationUri);
    w.localizedText(OpcLocalizedText(text: info.applicationName));
    w.int32(_applicationTypeServer);
    w.string(null); // gatewayServerUri
    w.string(null); // discoveryProfileUri
    w.int32(-1); // discoveryUrls: null array
  }

  /// UserTokenPolicy (user_token_policy.rs): policyId, tokenType Int32 enum,
  /// issuedTokenType, issuerEndpointUrl, securityPolicyUri.
  void _writeAnonymousUserTokenPolicy(OpcUaWriter w) {
    w.string('anonymous');
    w.int32(_userTokenTypeAnonymous);
    w.string(null); // issuedTokenType
    w.string(null); // issuerEndpointUrl
    w.string(null); // securityPolicyUri
  }

  /// UserTokenPolicy for username/password auth (tokenType UserName=1). On a
  /// secure endpoint the password is encrypted with Basic256Sha256; on a None
  /// endpoint the policy carries a null securityPolicyUri (plaintext password).
  void _writeUserNameUserTokenPolicy(OpcUaWriter w, {required bool secure}) {
    w.string('username');
    w.int32(_userTokenTypeUserName);
    w.string(null); // issuedTokenType
    w.string(null); // issuerEndpointUrl
    w.string(secure ? kSecurityPolicyBasic256Sha256Uri : null);
  }

  List<Uint8List> _handleCreateSession(
    OpcChunk chunk,
    OpcUaReader reader,
    RequestHeader header,
  ) {
    // We decode only what CreateSessionResponse needs to compute; most of
    // CreateSessionRequest (clientDescription, serverUri, sessionName,
    // clientNonce, clientCertificate) is intentionally NOT decoded further —
    // v1 doesn't need any of it, and since the response is built fresh (not
    // derived from those fields) there is no alignment requirement to keep
    // reading. See report for this documented choice.
    // We DO need endpointUrl (Task 2 endpoint echo — see [_clientEndpointUrl])
    // and requestedSessionTimeout, both of which sit after clientDescription
    // — so we must skip over it correctly to reach them.
    _skipApplicationDescription(reader); // clientDescription
    reader.string(); // serverUri
    final endpointUrl = reader.string();
    reader.string(); // sessionName
    final clientNonce = reader.byteString(); // clientNonce
    final clientCertDer = reader.byteString(); // clientCertificate
    final requestedTimeout = reader.float64();
    reader.uint32(); // maxResponseMessageSize — ignored.

    if (endpointUrl != null && endpointUrl.isNotEmpty) {
      _clientEndpointUrl = endpointUrl;
    }

    final sessionId = OpcNodeId.numeric(1, _nextSessionNumericId++);
    final authToken = OpcNodeId.numeric(1, _nextAuthTokenNumericId++);
    final secureChannel = _channelSecured ? _secureChannel : null;
    _session = _SessionState(
      sessionId: sessionId,
      authToken: authToken,
      createSessionServerNonce: secureChannel?.serverNonce,
    );

    final revisedTimeout = _boundSessionTimeout(requestedTimeout);

    // On a SECURED channel the CreateSessionResponse MUST carry the server's
    // application-instance certificate and a server nonce; a strict OPC UA
    // client (e.g. the Rust `opcua` crate) rejects the session with
    // Bad_CertificateInvalid if `serverCertificate` is null, and — critically —
    // it overwrites its own secure-channel nonce with THIS `serverNonce` and
    // then uses that nonce to OAEP-encrypt the UserNameIdentityToken password
    // on ActivateSession. Our own [OpcSecureChannel.decryptUserPassword]
    // verifies that trailing nonce against the same channel's server nonce, so
    // the two only agree if we echo the channel's server nonce here. A None
    // channel keeps both null exactly as before (the pre-security byte layout).
    //
    // The `serverSignature` is a SignatureData proving this server holds the
    // private key for the certificate it advertised: on a SECURED channel with
    // a client-supplied clientCertificate + clientNonce it is the server key's
    // RSA-PKCS1-SHA256 signature over `clientCertificateDer ++ clientNonce`
    // (algorithm [kRsaSha256SignatureUri]) — the value a strict client (and the
    // Task 3 ActivateSession path) checks. On a None channel — or when the
    // request omits the clientCertificate/clientNonce — both SignatureData
    // fields stay null, byte-identical to the pre-security layout.
    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.createSessionResponse));
    w.responseHeader(_respond(header));
    w.nodeId(sessionId);
    w.nodeId(authToken);
    w.float64(revisedTimeout);
    w.byteString(secureChannel?.serverNonce); // serverNonce (null on None)
    w.byteString(secureChannel != null ? serverCertificateDer : null); // serverCertificate
    _writeEndpoints(w); // serverEndpoints
    w.int32(-1); // serverSoftwareCertificates: null array
    // SignatureData (signature_data.rs): algorithm String, signature ByteString.
    if (secureChannel != null && clientCertDer != null && clientNonce != null) {
      final signed = Uint8List.fromList(<int>[...clientCertDer, ...clientNonce]);
      w.string(kRsaSha256SignatureUri);
      w.byteString(secureChannel.signApplicationData(signed));
    } else {
      w.string(null);
      w.byteString(null);
    }
    w.uint32(0); // maxRequestMessageSize
    return [_wrapMsgResponse(chunk, w.take())];
  }

  double _boundSessionTimeout(double requested) {
    final wanted = requested <= 0 ? _maxSessionTimeoutMs.toDouble() : requested;
    final capped = wanted < _maxSessionTimeoutMs ? wanted : _maxSessionTimeoutMs.toDouble();
    return capped < _minSessionTimeoutMs ? _minSessionTimeoutMs.toDouble() : capped;
  }

  void _skipApplicationDescription(OpcUaReader reader) {
    reader.string(); // applicationUri
    reader.string(); // productUri
    reader.localizedText(); // applicationName
    reader.int32(); // applicationType
    reader.string(); // gatewayServerUri
    reader.string(); // discoveryProfileUri
    final len = reader.int32(); // discoveryUrls
    if (len > 0) {
      for (var i = 0; i < len; i++) {
        reader.string();
      }
    }
  }

  List<Uint8List> _handleActivateSession(
    OpcChunk chunk,
    OpcUaReader reader,
    RequestHeader header,
  ) {
    if (_session == null || _session!.closed) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionIdInvalid,
      );
    }
    if (header.authToken != _session!.authToken) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionIdInvalid,
      );
    }

    // clientSignature: SignatureData. On a SECURED channel the client MUST
    // sign `serverCertificate ++ serverNonce` (the values it received in
    // CreateSessionResponse) with its own certificate's private key, proving
    // possession of that key. Verify it before the identity-token auth.
    reader.string(); // clientSignature.algorithm
    final clientSig = reader.byteString(); // clientSignature.signature
    if (_channelSecured) {
      final nonce = _session!.createSessionServerNonce;
      final chan = _secureChannel;
      final serverCert = serverCertificateDer;
      if (clientSig == null ||
          clientSig.isEmpty ||
          nonce == null ||
          chan == null ||
          serverCert == null ||
          !chan.verifyClientSignature(
              Uint8List.fromList(<int>[...serverCert, ...nonce]),
              Uint8List.fromList(clientSig))) {
        return _fault(
          chunk,
          requestHandle: header.requestHandle,
          serviceResult: OpcUaStatusCodes.badApplicationSignatureInvalid,
        );
      }
    }
    _skipArrayOfStrings(reader); // clientSoftwareCertificates (SignedSoftwareCertificate[])
    _skipArrayOfStrings(reader); // localeIds
    // userIdentityToken: ExtensionObject. Recognize AnonymousIdentityToken
    // (or an empty/null ExtensionObject — server/identity_token.rs:22-27) and
    // UserNameIdentityToken; anything else is rejected.
    final tokenTypeId = reader.extensionObjectHeader();
    final tokenBody =
        reader.lastExtensionObjectHasBody ? reader.byteString() : null;
    reader.string(); // userTokenSignature.algorithm
    reader.byteString(); // userTokenSignature.signature

    final isAnonymous = tokenTypeId.isNumeric &&
        (tokenTypeId.numericId == _Ids.anonymousIdentityToken ||
            (tokenTypeId.numericId == 0 && tokenTypeId.namespace == 0));
    final isUserName = tokenTypeId.isNumeric &&
        tokenTypeId.numericId == _Ids.userNameIdentityToken;

    final int authResult;
    if (isUserName) {
      authResult = _validateUserNameToken(tokenBody);
    } else if (isAnonymous) {
      authResult = allowAnonymous
          ? OpcUaStatusCodes.good
          : OpcUaStatusCodes.badIdentityTokenRejected;
    } else {
      authResult = OpcUaStatusCodes.badIdentityTokenRejected;
    }
    if (authResult != OpcUaStatusCodes.good) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: authResult,
      );
    }

    _session!.activated = true;

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.activateSessionResponse));
    w.responseHeader(_respond(header));
    w.byteString(null); // serverNonce
    w.int32(-1); // results: null array
    w.int32(-1); // diagnosticInfos: null array
    return [_wrapMsgResponse(chunk, w.take())];
  }

  /// Validates a UserNameIdentityToken body (policyId String, userName String,
  /// password ByteString, encryptionAlgorithm String — user_name_identity_token.rs)
  /// against the configured [credentials]. On a secured channel the password is
  /// OAEP-decrypted via the secure channel (which also verifies the trailing
  /// server nonce); on a None channel it is the plaintext bytes. Returns
  /// Good on a match, else Bad_UserAccessDenied (wrong password / unknown user)
  /// or Bad_IdentityTokenRejected (unusable token).
  int _validateUserNameToken(List<int>? tokenBody) {
    if (tokenBody == null) {
      return OpcUaStatusCodes.badIdentityTokenRejected;
    }
    if (credentials.isEmpty) {
      // No username auth configured — reject username tokens.
      return OpcUaStatusCodes.badIdentityTokenRejected;
    }
    final String? userName;
    final List<int>? passwordBytes;
    final String? encryptionAlgorithm;
    try {
      final r = OpcUaReader(Uint8List.fromList(tokenBody));
      r.string(); // policyId — not used for authz here.
      userName = r.string();
      passwordBytes = r.byteString();
      encryptionAlgorithm = r.string();
    } catch (_) {
      return OpcUaStatusCodes.badIdentityTokenRejected;
    }
    if (userName == null || passwordBytes == null) {
      return OpcUaStatusCodes.badIdentityTokenRejected;
    }

    final String? password;
    final channel = _secureChannel;
    final hasEncryption =
        encryptionAlgorithm != null && encryptionAlgorithm.isNotEmpty;
    if (hasEncryption) {
      // Encrypted password — requires the secure channel to decrypt.
      if (channel == null) {
        return OpcUaStatusCodes.badIdentityTokenRejected;
      }
      password = channel.decryptUserPassword(Uint8List.fromList(passwordBytes));
      if (password == null) {
        // Decrypt / nonce-verification failed.
        return OpcUaStatusCodes.badIdentityTokenRejected;
      }
    } else {
      // Plaintext password (None-policy user token).
      try {
        password = utf8.decode(passwordBytes);
      } catch (_) {
        return OpcUaStatusCodes.badIdentityTokenRejected;
      }
    }

    final expected = credentials[userName];
    // Fail closed: never authenticate on an empty client password or an empty
    // expected password. Passwords are never persisted, so post-reload a
    // configured credential has a blank expected value; treating that as a
    // valid match would let any known username in with an empty password
    // (over a None endpoint this needs no crypto at all).
    if (password.isEmpty || expected == null || expected.isEmpty) {
      return OpcUaStatusCodes.badUserAccessDenied;
    }
    if (_constantTimeEquals(expected, password)) {
      return OpcUaStatusCodes.good;
    }
    return OpcUaStatusCodes.badUserAccessDenied;
  }

  /// Length-independent constant-time-ish string comparison for credential
  /// checking (avoids early-out timing leaks on the matching prefix).
  bool _constantTimeEquals(String a, String b) {
    final ab = utf8.encode(a);
    final bb = utf8.encode(b);
    var diff = ab.length ^ bb.length;
    final n = ab.length < bb.length ? ab.length : bb.length;
    for (var i = 0; i < n; i++) {
      diff |= ab[i] ^ bb[i];
    }
    return diff == 0;
  }

  void _skipArrayOfStrings(OpcUaReader reader) {
    // Used only for arrays of complex types we don't decode structurally
    // (SignedSoftwareCertificate[], locale id String[]) — since we never
    // populate these ourselves and the request always sends them null in
    // our tests/expected clients, treat any non-null length as "nothing
    // further to skip precisely"; the only shape v1 clients are expected to
    // send is the null (-1) array, which this reads correctly. A non-null
    // array here would misalign the reader for genuinely exotic clients,
    // but v1 does not support client software certificates or locale
    // negotiation, so this is an accepted, documented limitation.
    reader.int32();
  }

  List<Uint8List> _handleCloseSession(OpcChunk chunk, RequestHeader header) {
    if (_session == null || _session!.closed) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionIdInvalid,
      );
    }
    if (header.authToken != _session!.authToken) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionIdInvalid,
      );
    }
    _session!.closed = true;

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.closeSessionResponse));
    w.responseHeader(_respond(header));
    return [_wrapMsgResponse(chunk, w.take())];
  }

  List<Uint8List> _dispatchToServiceHandler(
    OpcChunk chunk,
    int requestTypeId,
    OpcUaReader reader,
    RequestHeader header,
  ) {
    // No session has EVER been created on this channel: there is no
    // meaningful "not activated"/"wrong session" state to report, and (per
    // the brief) a request id this session doesn't recognize as one of its
    // own services is unconditionally unsupported until a session exists
    // to potentially route it through a handler. This also covers the
    // "truly unknown NodeId" case (e.g. a bogus/unassigned encoding id).
    if (_session == null) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badServiceUnsupported,
      );
    }
    if (_session!.closed) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionIdInvalid,
      );
    }
    if (header.authToken != _session!.authToken) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionIdInvalid,
      );
    }
    if (!_session!.activated) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionNotActivated,
      );
    }
    final handler = services;
    if (handler == null) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badServiceUnsupported,
      );
    }
    ResponseHeader respond({int serviceResult = OpcUaStatusCodes.good}) =>
        _respond(header, serviceResult: serviceResult);
    final responseBody = handler.handle(requestTypeId, reader, header, respond);
    if (responseBody == null) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badServiceUnsupported,
      );
    }
    return [_wrapMsgResponse(chunk, responseBody)];
  }

  /// Routes one of the nine [SubscriptionManager.serviceIds] requests.
  /// Applies EXACTLY the same activation guards as
  /// [_dispatchToServiceHandler] (no session -> Bad_ServiceUnsupported;
  /// closed/wrong authToken -> Bad_SessionIdInvalid; not activated ->
  /// Bad_SessionNotActivated) before ever touching the manager, then lazily
  /// creates the ONE [SubscriptionManager] for this session (only when
  /// [sampler] is non-null — a sampler-less session faults
  /// Bad_ServiceUnsupported, same as an unrecognized service). A parked
  /// Publish yields an empty `handleService` result, which this method
  /// turns into `const []` — i.e. sending nothing back for this chunk is
  /// the deferral mechanism, not an error.
  List<Uint8List> _dispatchToSubscriptionManager(
    OpcChunk chunk,
    int requestTypeId,
    OpcUaReader reader,
    RequestHeader header,
    int nowMs,
  ) {
    if (_session == null) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badServiceUnsupported,
      );
    }
    if (_session!.closed) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionIdInvalid,
      );
    }
    if (header.authToken != _session!.authToken) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionIdInvalid,
      );
    }
    if (!_session!.activated) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badSessionNotActivated,
      );
    }
    final samplerFn = sampler;
    if (samplerFn == null) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badServiceUnsupported,
      );
    }
    final manager = _subscriptionManager ??= SubscriptionManager(sampler: samplerFn);

    final outs = manager.handleService(requestTypeId, reader, header, chunk.requestId, nowMs);
    if (outs.isEmpty) {
      // Parked Publish: the deferral IS the behavior — send nothing now.
      return const [];
    }
    return [for (final out in outs) _wrapMsgResponseForRequestId(out.requestId, out.body)];
  }
}
