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

import 'dart:typed_data';

import 'opcua_binary.dart';
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
}

/// MessageSecurityMode.None (enums.rs:856-861, Int32-encoded).
const int _securityModeNone = 1;

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

  _SessionState({required this.sessionId, required this.authToken});
}

/// One instance per connection. Feed it inbound bytes via [onBytes]; it
/// returns zero-or-more outbound frames (already-framed HEL/ACK/ERR or
/// OPN/MSG chunk bytes, ready to write to the socket). Never throws — any
/// decode failure degrades to an ERR frame + [shouldClose].
class OpcUaServerSession {
  final OpcUaServerInfo info;
  final OpcUaServiceHandler? services;
  final OpcDataValue Function(OpcNodeId)? sampler;

  bool _helloReceived = false;
  bool _shouldClose = false;

  _ChannelState? _channel;
  _SessionState? _session;

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

  OpcUaServerSession({required this.info, required this.services, this.sampler});

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
    final chunk = parseChunk(frame);
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
        return _handleGetEndpoints(chunk, header);
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

  Uint8List _wrapMsgResponse(OpcChunk requestChunk, Uint8List body) {
    return buildMsgChunk(
      secureChannelId: _channel!.channelId,
      tokenId: _channel!.tokenId,
      sequenceNumber: _nextSeq(),
      requestId: requestChunk.requestId,
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
    return buildMsgChunk(
      secureChannelId: _channel!.channelId,
      tokenId: _channel!.tokenId,
      sequenceNumber: _nextSeq(),
      requestId: requestId,
      body: body,
    );
  }

  List<Uint8List> _handleGetEndpoints(OpcChunk chunk, RequestHeader header) {
    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.getEndpointsResponse));
    w.responseHeader(_respond(header));
    w.int32(1); // endpoints: one EndpointDescription
    _writeEndpointDescription(w);
    return [_wrapMsgResponse(chunk, w.take())];
  }

  /// EndpointDescription (endpoint_description.rs): endpointUrl,
  /// server ApplicationDescription, serverCertificate ByteString,
  /// securityMode Int32 enum, securityPolicyUri, userIdentityTokens array,
  /// transportProfileUri, securityLevel Byte.
  void _writeEndpointDescription(OpcUaWriter w) {
    w.string(info.endpointUrl);
    _writeApplicationDescription(w);
    w.byteString(null); // serverCertificate
    w.int32(_securityModeNone);
    w.string(kSecurityPolicyNoneUri);
    w.int32(1); // userIdentityTokens: one UserTokenPolicy
    _writeAnonymousUserTokenPolicy(w);
    w.string(_transportProfileUriUaTcp);
    w.uint8(0); // securityLevel
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

  List<Uint8List> _handleCreateSession(
    OpcChunk chunk,
    OpcUaReader reader,
    RequestHeader header,
  ) {
    // We decode only what CreateSessionResponse needs to compute; the rest
    // of CreateSessionRequest (clientDescription, serverUri, endpointUrl,
    // sessionName, clientNonce, clientCertificate) is intentionally NOT
    // decoded — Task 2 v1 doesn't need any of it, and since the response is
    // built fresh (not derived from those fields) there is no alignment
    // requirement to keep reading. See report for this documented choice.
    // We DO need requestedSessionTimeout, which sits after all of the
    // above — so we must skip over them correctly to reach it.
    _skipApplicationDescription(reader); // clientDescription
    reader.string(); // serverUri
    reader.string(); // endpointUrl
    reader.string(); // sessionName
    reader.byteString(); // clientNonce
    reader.byteString(); // clientCertificate
    final requestedTimeout = reader.float64();
    reader.uint32(); // maxResponseMessageSize — ignored.

    final sessionId = OpcNodeId.numeric(1, _nextSessionNumericId++);
    final authToken = OpcNodeId.numeric(1, _nextAuthTokenNumericId++);
    _session = _SessionState(sessionId: sessionId, authToken: authToken);

    final revisedTimeout = _boundSessionTimeout(requestedTimeout);

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.createSessionResponse));
    w.responseHeader(_respond(header));
    w.nodeId(sessionId);
    w.nodeId(authToken);
    w.float64(revisedTimeout);
    w.byteString(null); // serverNonce
    w.byteString(null); // serverCertificate
    w.int32(1); // serverEndpoints: same one EndpointDescription
    _writeEndpointDescription(w);
    w.int32(-1); // serverSoftwareCertificates: null array
    // SignatureData (signature_data.rs): algorithm String, signature ByteString.
    w.string(null);
    w.byteString(null);
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

    // clientSignature: SignatureData.
    reader.string(); // algorithm
    reader.byteString(); // signature
    _skipArrayOfStrings(reader); // clientSoftwareCertificates (SignedSoftwareCertificate[])
    _skipArrayOfStrings(reader); // localeIds
    // userIdentityToken: ExtensionObject. Accept AnonymousIdentityToken or
    // an empty/null ExtensionObject as anonymous (lenient v1) — mirrors
    // server/identity_token.rs:22-27 ("if o.is_empty() { ... Treat as
    // anonymous }").
    final tokenTypeId = reader.extensionObjectHeader();
    if (reader.lastExtensionObjectHasBody) {
      reader.byteString(); // drain the body; we don't validate its contents.
    }
    final isKnownAnonymousToken = tokenTypeId.isNumeric &&
        (tokenTypeId.numericId == _Ids.anonymousIdentityToken ||
            (tokenTypeId.numericId == 0 && tokenTypeId.namespace == 0));
    if (!isKnownAnonymousToken) {
      return _fault(
        chunk,
        requestHandle: header.requestHandle,
        serviceResult: OpcUaStatusCodes.badServiceUnsupported,
      );
    }
    reader.string(); // userTokenSignature.algorithm
    reader.byteString(); // userTokenSignature.signature

    _session!.activated = true;

    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, _Ids.activateSessionResponse));
    w.responseHeader(_respond(header));
    w.byteString(null); // serverNonce
    w.int32(-1); // results: null array
    w.int32(-1); // diagnosticInfos: null array
    return [_wrapMsgResponse(chunk, w.take())];
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
