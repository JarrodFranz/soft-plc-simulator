// Tests for the pure-Dart OPC UA secure-channel(None) + session state
// machine (mobile/lib/protocols/opcua/opcua_session.dart).
//
// Every request frame here is built VIA THE TASK 1 CODEC
// (opcua_binary.dart / opcua_transport.dart) — no hand-rolled hex. A chunk
// body is: NodeId(ns:0, i:<encoding id>) followed directly by the struct's
// fields (no ExtensionObject wrapper) — verified against
// core/comms/chunker.rs:238-264 ("The extension object prefix is just the
// node id... Read node id from stream... decode the payload using the node
// id") in the vendored Rust `opcua` 0.12.0 reference at
// C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/.
//
// Encoding ids verified against types/node_ids.rs; StatusCodes against
// types/status_codes.rs; struct field orders against
// types/service_types/*.rs (all cited inline below and in the task report).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_certificate.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_crypto.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_secure_channel.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_session.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_transport.dart';

// --- Subscription service encoding ids, verified against types/node_ids.rs -
const _createSubscriptionRequestId = 787;
const _createSubscriptionResponseId = 790;
const _createMonitoredItemsRequestId = 751;
const _createMonitoredItemsResponseId = 754;
const _publishRequestId = 826;
const _publishResponseId = 829;

// --- Encoding ids, verified against types/node_ids.rs -----------------------
const _openSecureChannelRequestId = 446;
const _getEndpointsRequestId = 428;
const _getEndpointsResponseId = 431;
const _createSessionRequestId = 461;
const _createSessionResponseId = 464;
const _activateSessionRequestId = 467;
const _activateSessionResponseId = 470;
const _closeSessionRequestId = 473;
const _closeSessionResponseId = 476;
const _serviceFaultId = 397;
const _openSecureChannelResponseId = 449;

// --- StatusCodes, verified against types/status_codes.rs --------------------
const _statusGood = 0;
const _statusBadServiceUnsupported = 0x800B0000;
const _statusBadSessionNotActivated = 0x80270000;
const _statusBadSessionIdInvalid = 0x80250000;

RequestHeader _reqHeader({
  OpcNodeId authToken = const OpcNodeId.numeric(0, 0),
  int requestHandle = 1,
}) {
  return RequestHeader(
    authToken: authToken,
    timestamp: DateTime.utc(2026, 7, 6),
    requestHandle: requestHandle,
  );
}

Uint8List _buildHello({
  int protocolVersion = 0,
  int receiveBufferSize = 65536,
  int sendBufferSize = 65536,
  int maxMessageSize = 0,
  int maxChunkCount = 0,
  String endpointUrl = 'opc.tcp://127.0.0.1:4840',
}) {
  return HelloMessage(
    protocolVersion: protocolVersion,
    receiveBufferSize: receiveBufferSize,
    sendBufferSize: sendBufferSize,
    maxMessageSize: maxMessageSize,
    maxChunkCount: maxChunkCount,
    endpointUrl: endpointUrl,
  ).build();
}

/// OpenSecureChannelRequest body (open_secure_channel_request.rs field
/// order): requestHeader, clientProtocolVersion UInt32, requestType Int32
/// enum (Issue=0/Renew=1 — channel_security_token.rs:920-923), securityMode
/// Int32 enum (None=1 — enums.rs:856-861), clientNonce ByteString,
/// requestedLifetime UInt32.
Uint8List _buildOpenSecureChannelRequestChunk({
  required int secureChannelId,
  required int sequenceNumber,
  required int requestId,
  int requestType = 0, // Issue
  int requestedLifetime = 60000,
  RequestHeader? header,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _openSecureChannelRequestId));
  w.requestHeader(header ?? _reqHeader());
  w.uint32(0); // clientProtocolVersion
  w.int32(requestType);
  w.int32(1); // securityMode: None
  w.byteString(null); // clientNonce
  w.uint32(requestedLifetime);
  return buildOpnChunk(
    secureChannelId: secureChannelId,
    securityPolicyUri: kSecurityPolicyNoneUri,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// GetEndpointsRequest body (get_endpoints_request.rs): requestHeader,
/// endpointUrl String, localeIds array (null), profileUris array (null).
Uint8List _buildGetEndpointsRequestChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required OpcNodeId authToken,
  int requestHandle = 2,
  String endpointUrl = 'opc.tcp://127.0.0.1:4840',
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _getEndpointsRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: requestHandle));
  w.string(endpointUrl);
  w.int32(-1); // localeIds: null array
  w.int32(-1); // profileUris: null array
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// CreateSessionRequest body (create_session_request.rs): requestHeader,
/// clientDescription ApplicationDescription, serverUri String, endpointUrl
/// String, sessionName String, clientNonce ByteString, clientCertificate
/// ByteString, requestedSessionTimeout Double, maxResponseMessageSize UInt32.
/// ApplicationDescription (application_description.rs): applicationUri,
/// productUri, applicationName LocalizedText, applicationType Int32 enum,
/// gatewayServerUri, discoveryProfileUri, discoveryUrls array.
Uint8List _buildCreateSessionRequestChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  double requestedSessionTimeout = 1200000,
  int requestHandle = 3,
  String endpointUrl = 'opc.tcp://127.0.0.1:4840',
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _createSessionRequestId));
  w.requestHeader(_reqHeader(requestHandle: requestHandle));
  // clientDescription: ApplicationDescription
  w.string('urn:test:client');
  w.string('urn:test:client:product');
  w.localizedText(const OpcLocalizedText(text: 'Test Client'));
  w.int32(1); // ApplicationType.Client
  w.string(null); // gatewayServerUri
  w.string(null); // discoveryProfileUri
  w.int32(-1); // discoveryUrls: null array
  w.string(null); // serverUri
  w.string(endpointUrl); // endpointUrl
  w.string('test-session'); // sessionName
  w.byteString(null); // clientNonce
  w.byteString(null); // clientCertificate
  w.float64(requestedSessionTimeout);
  w.uint32(0); // maxResponseMessageSize
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// ActivateSessionRequest body (activate_session_request.rs): requestHeader,
/// clientSignature SignatureData{algorithm String, signature ByteString},
/// clientSoftwareCertificates array (null), localeIds array (null),
/// userIdentityToken ExtensionObject, userTokenSignature SignatureData.
/// Passing an empty/null ExtensionObject for userIdentityToken is treated as
/// anonymous per server/identity_token.rs:22-27 ("if o.is_empty() { ...
/// Treat as anonymous }").
Uint8List _buildActivateSessionRequestChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required OpcNodeId authToken,
  int requestHandle = 4,
  bool includeAnonymousToken = true,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _activateSessionRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: requestHandle));
  // clientSignature: SignatureData
  w.string(null); // algorithm
  w.byteString(null); // signature
  w.int32(-1); // clientSoftwareCertificates: null array
  w.int32(-1); // localeIds: null array
  // userIdentityToken: ExtensionObject
  if (includeAnonymousToken) {
    // AnonymousIdentityToken (anonymous_identity_token.rs): policy_id String.
    final tokenWriter = OpcUaWriter();
    tokenWriter.string('anonymous');
    final tokenBytes = tokenWriter.take();
    w.extensionObjectHeader(const OpcNodeId.numeric(0, 321), hasBody: true);
    w.byteString(tokenBytes);
  } else {
    w.extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false);
  }
  // userTokenSignature: SignatureData
  w.string(null);
  w.byteString(null);
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// CloseSessionRequest body (close_session_request.rs): requestHeader,
/// deleteSubscriptions Boolean.
Uint8List _buildCloseSessionRequestChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required OpcNodeId authToken,
  int requestHandle = 5,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _closeSessionRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: requestHandle));
  w.boolean(false);
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// A generic MSG chunk carrying an arbitrary request encoding-id NodeId +
/// RequestHeader — used for the "unknown service id" and "Task-3 style
/// service before activation" tests, where the body content beyond the
/// header doesn't matter (the session dispatches on the NodeId first).
Uint8List _buildGenericServiceRequestChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required int serviceEncodingId,
  required OpcNodeId authToken,
  int requestHandle = 6,
}) {
  final w = OpcUaWriter();
  w.nodeId(OpcNodeId.numeric(0, serviceEncodingId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: requestHandle));
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// CreateSubscriptionRequest body (create_subscription_request.rs):
/// requestHeader(consumed), requestedPublishingInterval f64,
/// requestedLifetimeCount u32, requestedMaxKeepAliveCount u32,
/// maxNotificationsPerPublish u32, publishingEnabled bool, priority u8.
Uint8List _buildCreateSubscriptionRequestChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required OpcNodeId authToken,
  double requestedPublishingInterval = 100,
  int requestedLifetimeCount = 100,
  int requestedMaxKeepAliveCount = 10,
  int maxNotificationsPerPublish = 0,
  bool publishingEnabled = true,
  int requestHandle = 20,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _createSubscriptionRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: requestHandle));
  w.float64(requestedPublishingInterval);
  w.uint32(requestedLifetimeCount);
  w.uint32(requestedMaxKeepAliveCount);
  w.uint32(maxNotificationsPerPublish);
  w.boolean(publishingEnabled);
  w.uint8(0); // priority
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// CreateMonitoredItemsRequest body (create_monitored_items_request.rs):
/// requestHeader(consumed), subscriptionId u32, timestampsToReturn Int32
/// enum, itemsToCreate[] MonitoredItemCreateRequest{itemToMonitor
/// ReadValueId{nodeId, attributeId u32, indexRange String, dataEncoding
/// QualifiedName}, monitoringMode Int32 enum, requestedParameters
/// MonitoringParameters{clientHandle u32, samplingInterval f64, filter
/// ExtensionObject, queueSize u32, discardOldest bool}}.
Uint8List _buildCreateMonitoredItemsRequestChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required OpcNodeId authToken,
  required int subscriptionId,
  required OpcNodeId nodeId,
  int clientHandle = 1,
  double samplingInterval = 0,
  int queueSize = 1,
  int requestHandle = 21,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _createMonitoredItemsRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: requestHandle));
  w.uint32(subscriptionId);
  w.int32(2); // timestampsToReturn: Both (unused by v1)
  w.int32(1); // itemsToCreate: one entry
  w.nodeId(nodeId);
  w.uint32(13); // attributeId: Value
  w.string(null); // indexRange
  w.qualifiedName(const OpcQualifiedName(ns: 0, name: null)); // dataEncoding
  w.int32(2); // monitoringMode: Reporting
  w.uint32(clientHandle);
  w.float64(samplingInterval);
  w.extensionObjectHeader(const OpcNodeId.numeric(0, 0), hasBody: false); // filter: none
  w.uint32(queueSize);
  w.boolean(true); // discardOldest
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// PublishRequest body (publish_request.rs): requestHeader(consumed),
/// subscriptionAcknowledgements Option<Vec<SubscriptionAcknowledgement>>
/// (null here — no prior notifications to acknowledge in these tests).
Uint8List _buildPublishRequestChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required OpcNodeId authToken,
  int requestHandle = 22,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _publishRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: requestHandle));
  w.int32(-1); // subscriptionAcknowledgements: null array
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}

/// Reads the response envelope from a MSG/OPN chunk: NodeId encoding id +
/// ResponseHeader, returning the id and a reader positioned right after the
/// ResponseHeader (at the start of the response-specific fields).
({int encodingId, ResponseHeader header, OpcUaReader reader}) _decodeResponseChunk(
  Uint8List frame,
) {
  final chunk = parseChunk(frame);
  final reader = OpcUaReader(chunk.body);
  final typeId = reader.nodeId();
  final encodingId = typeId.numericId!;
  final header = reader.responseHeader();
  return (encodingId: encodingId, header: header, reader: reader);
}

const _info = OpcUaServerInfo(
  applicationName: 'Mobile Soft PLC',
  applicationUri: 'urn:mobile-soft-plc:server',
  endpointUrl: 'opc.tcp://127.0.0.1:4840',
  namespaceUri: 'urn:mobile-soft-plc:tags',
);

/// A stub Task-3-style service handler used by the "delegate to handler once
/// activated" test.
class _StubServiceHandler implements OpcUaServiceHandler {
  int callCount = 0;
  int? lastRequestTypeId;

  @override
  Uint8List? handle(
    int requestTypeId,
    OpcUaReader body,
    RequestHeader header,
    ResponseBuilder respond,
  ) {
    callCount++;
    lastRequestTypeId = requestTypeId;
    // Arbitrary made-up "response": a ResponseHeader wrapped in a fake type
    // id (99998) followed by a single UInt32 marker (0xABCDEF01), just to
    // prove the session plumbs the handler's bytes straight through.
    final w = OpcUaWriter();
    w.nodeId(const OpcNodeId.numeric(0, 99998));
    w.responseHeader(respond(serviceResult: _statusGood));
    w.uint32(0xABCDEF01);
    return w.take();
  }
}

void main() {
  group('HEL/ACK handshake', () {
    test('HEL -> ACK happy path negotiates buffer sizes', () {
      final session = OpcUaServerSession(info: _info, services: null);
      final outFrames = session.onBytes(_buildHello(
        receiveBufferSize: 65536,
        sendBufferSize: 65536,
      ), 0);
      expect(outFrames, hasLength(1));
      final ack = AcknowledgeMessage.parse(outFrames.single);
      expect(ack.protocolVersion, 0);
      expect(ack.sendBufferSize, lessThanOrEqualTo(1048576));
      expect(ack.receiveBufferSize, lessThanOrEqualTo(1048576));
      expect(ack.sendBufferSize, greaterThan(0));
      expect(ack.receiveBufferSize, greaterThan(0));
      expect(session.shouldClose, isFalse);
    });

    test('client requesting oversized buffers gets negotiated down to <= 1MB', () {
      final session = OpcUaServerSession(info: _info, services: null);
      final outFrames = session.onBytes(_buildHello(
        receiveBufferSize: 100 * 1024 * 1024,
        sendBufferSize: 100 * 1024 * 1024,
      ), 0);
      final ack = AcknowledgeMessage.parse(outFrames.single);
      expect(ack.receiveBufferSize, lessThanOrEqualTo(1048576));
      expect(ack.sendBufferSize, lessThanOrEqualTo(1048576));
    });

    test('non-HEL first frame -> ERR and shouldClose', () {
      final session = OpcUaServerSession(info: _info, services: null);
      final chunk = _buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 1,
      );
      final outFrames = session.onBytes(chunk, 0);
      expect(outFrames, hasLength(1));
      final header = MessageHeader.parse(outFrames.single);
      expect(header.messageType, 'ERR');
      expect(session.shouldClose, isTrue);
    });
  });

  group('OpenSecureChannel (None)', () {
    late OpcUaServerSession session;

    setUp(() {
      session = OpcUaServerSession(info: _info, services: null);
      session.onBytes(_buildHello(), 0);
    });

    test('Issue allocates a non-zero channelId + tokenId, bounded lifetime', () {
      final outFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
        requestedLifetime: 60000,
      ), 0);
      expect(outFrames, hasLength(1));
      final chunk = parseChunk(outFrames.single);
      expect(chunk.messageType, 'OPN');
      final reader = OpcUaReader(chunk.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _openSecureChannelResponseId);
      final respHeader = reader.responseHeader();
      expect(respHeader.serviceResult, _statusGood);
      final serverProtocolVersion = reader.uint32();
      expect(serverProtocolVersion, 0);
      final channelId = reader.uint32();
      final tokenId = reader.uint32();
      reader.dateTime(); // createdAt
      final revisedLifetime = reader.uint32();
      final serverNonce = reader.byteString();

      expect(channelId, greaterThan(0));
      expect(tokenId, greaterThan(0));
      expect(revisedLifetime, lessThanOrEqualTo(3600000));
      expect(revisedLifetime, greaterThan(0));
      expect(serverNonce, isNull);
      expect(chunk.secureChannelId, channelId);
    });

    test('Renew on the same channel yields a NEW tokenId, same channelId', () {
      final issueFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
      ), 0);
      final issueChunk = parseChunk(issueFrames.single);
      final issueReader = OpcUaReader(issueChunk.body);
      issueReader.nodeId();
      issueReader.responseHeader();
      issueReader.uint32(); // serverProtocolVersion
      final channelId = issueReader.uint32();
      final firstTokenId = issueReader.uint32();

      final renewFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: channelId,
        sequenceNumber: 2,
        requestId: 11,
        requestType: 1, // Renew
      ), 0);
      final renewChunk = parseChunk(renewFrames.single);
      final renewReader = OpcUaReader(renewChunk.body);
      renewReader.nodeId();
      renewReader.responseHeader();
      renewReader.uint32(); // serverProtocolVersion
      final renewChannelId = renewReader.uint32();
      final renewTokenId = renewReader.uint32();

      expect(renewChannelId, channelId);
      expect(renewTokenId, isNot(firstTokenId));
      expect(renewTokenId, greaterThan(0));
    });

    test('MSG with a wrong secureChannelId (but valid tokenId) -> ERR + close', () {
      // Defense-in-depth regression: _handleMsg must validate the channel id,
      // not only the token id (consistent with the OPN/CLO paths).
      final opnFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
      ), 0);
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32(); // serverProtocolVersion
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final outFrames = session.onBytes(_buildGetEndpointsRequestChunk(
        secureChannelId: channelId + 999, // wrong channel, correct token
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        authToken: const OpcNodeId.numeric(0, 0),
      ), 0);
      expect(outFrames, hasLength(1));
      final header = MessageHeader.parse(outFrames.single);
      expect(header.messageType, 'ERR');
      expect(session.shouldClose, isTrue);
    });
  });

  group('GetEndpoints', () {
    test('returns exactly one endpoint with None policy + anonymous token', () {
      final session = OpcUaServerSession(info: _info, services: null);
      session.onBytes(_buildHello(), 0);
      final opnFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
      ), 0);
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final geFrames = session.onBytes(_buildGetEndpointsRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        authToken: const OpcNodeId.numeric(0, 0),
      ), 0);
      expect(geFrames, hasLength(1));
      final decoded = _decodeResponseChunk(geFrames.single);
      expect(decoded.encodingId, _getEndpointsResponseId);
      expect(decoded.header.serviceResult, _statusGood);

      final reader = decoded.reader;
      final endpointCount = reader.int32();
      expect(endpointCount, 1);

      final endpointUrl = reader.string();
      expect(endpointUrl, _info.endpointUrl);
      // ApplicationDescription
      reader.string(); // applicationUri
      reader.string(); // productUri
      reader.localizedText(); // applicationName
      reader.int32(); // applicationType
      reader.string(); // gatewayServerUri
      reader.string(); // discoveryProfileUri
      final discoveryUrlsLen = reader.int32();
      if (discoveryUrlsLen > 0) {
        for (var i = 0; i < discoveryUrlsLen; i++) {
          reader.string();
        }
      }
      final serverCertificate = reader.byteString();
      expect(serverCertificate, isNull);
      final securityMode = reader.int32();
      expect(securityMode, 1); // None
      final securityPolicyUri = reader.string();
      expect(securityPolicyUri, kSecurityPolicyNoneUri);
      final tokenCount = reader.int32();
      expect(tokenCount, 1);
      final policyId = reader.string();
      expect(policyId, 'anonymous');
      final tokenType = reader.int32();
      expect(tokenType, 0); // Anonymous
      reader.string(); // issuedTokenType
      reader.string(); // issuerEndpointUrl
      reader.string(); // securityPolicyUri (token-level)
      final transportProfileUri = reader.string();
      expect(
        transportProfileUri,
        'http://opcfoundation.org/UA-Profile/Transport/uatcp-uasc-uabinary',
      );
      final securityLevel = reader.uint8();
      expect(securityLevel, 0);
      expect(reader.atEnd, isTrue);
    });

    test('Task 2 endpoint echo: advertises the CLIENT-dialed host, keeping our own port', () {
      final session = OpcUaServerSession(info: _info, services: null);
      session.onBytes(_buildHello(), 0);
      final opnFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
      ), 0);
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      // The client dialed a DIFFERENT host than our own best-effort guess
      // (_info.endpointUrl == 'opc.tcp://127.0.0.1:4840') — e.g. a LAN IP our
      // own NetworkInterface.list() guess didn't produce.
      final geFrames = session.onBytes(_buildGetEndpointsRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        authToken: const OpcNodeId.numeric(0, 0),
        endpointUrl: 'opc.tcp://192.168.50.7:4840',
      ), 0);
      final decoded = _decodeResponseChunk(geFrames.single);
      expect(decoded.header.serviceResult, _statusGood);
      expect(decoded.reader.int32(), 1); // endpoints count
      final endpointUrl = decoded.reader.string();
      // Host echoed back from the client's request; port kept from our info.
      expect(endpointUrl, 'opc.tcp://192.168.50.7:4840');
    });

    test('Task 2 endpoint echo: empty/unparseable client endpointUrl falls back to the server\'s own guess', () {
      final session = OpcUaServerSession(info: _info, services: null);
      session.onBytes(_buildHello(endpointUrl: 'opc.tcp://127.0.0.1:4840'), 0);
      final opnFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
      ), 0);
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final geFrames = session.onBytes(_buildGetEndpointsRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        authToken: const OpcNodeId.numeric(0, 0),
        endpointUrl: '', // client sent nothing usable
      ), 0);
      final decoded = _decodeResponseChunk(geFrames.single);
      expect(decoded.reader.int32(), 1); // endpoints count
      final endpointUrl = decoded.reader.string();
      expect(endpointUrl, _info.endpointUrl); // unchanged fallback
    });
  });

  group('CreateSession / ActivateSession / CloseSession', () {
    late OpcUaServerSession session;
    late int channelId;
    late int tokenId;

    setUp(() {
      session = OpcUaServerSession(info: _info, services: null);
      session.onBytes(_buildHello(), 0);
      final opnFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
      ), 0);
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      channelId = opnReader.uint32();
      tokenId = opnReader.uint32();
    });

    test('CreateSession returns non-null sessionId/authToken, bounded timeout', () {
      final frames = session.onBytes(_buildCreateSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        requestedSessionTimeout: 100 * 60 * 60 * 1000, // way over 1hr cap
      ), 0);
      final decoded = _decodeResponseChunk(frames.single);
      expect(decoded.encodingId, _createSessionResponseId);
      expect(decoded.header.serviceResult, _statusGood);

      final reader = decoded.reader;
      final sessionId = reader.nodeId();
      final authToken = reader.nodeId();
      final revisedTimeout = reader.float64();
      // Task 7 regression guard: on a None channel BOTH must stay null —
      // the byte-identical pre-security layout.
      final serverNonce = reader.byteString();
      final serverCertificate = reader.byteString();

      expect(sessionId, isNotNull);
      expect(authToken, isNotNull);
      expect(revisedTimeout, lessThanOrEqualTo(3600000));
      expect(revisedTimeout, greaterThanOrEqualTo(10000));
      expect(serverNonce, isNull);
      expect(serverCertificate, isNull);
    });

    test('Task 2 endpoint echo: CreateSessionResponse advertises the CLIENT-dialed host', () {
      final frames = session.onBytes(_buildCreateSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        endpointUrl: 'opc.tcp://10.0.0.42:4840',
      ), 0);
      final decoded = _decodeResponseChunk(frames.single);
      final reader = decoded.reader;
      reader.nodeId(); // sessionId
      reader.nodeId(); // authToken
      reader.float64(); // revisedSessionTimeout
      reader.byteString(); // serverNonce
      reader.byteString(); // serverCertificate
      final endpointCount = reader.int32();
      expect(endpointCount, 1);
      final endpointUrl = reader.string();
      expect(endpointUrl, 'opc.tcp://10.0.0.42:4840');
    });

    test('full CreateSession -> ActivateSession -> CloseSession happy path', () {
      final createFrames = session.onBytes(_buildCreateSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
      ), 0);
      final createDecoded = _decodeResponseChunk(createFrames.single);
      final authToken = createDecoded.reader.nodeId();

      final activateFrames = session.onBytes(_buildActivateSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 3,
        requestId: 12,
        authToken: authToken,
      ), 0);
      final activateDecoded = _decodeResponseChunk(activateFrames.single);
      expect(activateDecoded.encodingId, _activateSessionResponseId);
      expect(activateDecoded.header.serviceResult, _statusGood);

      final closeFrames = session.onBytes(_buildCloseSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 4,
        requestId: 13,
        authToken: authToken,
      ), 0);
      final closeDecoded = _decodeResponseChunk(closeFrames.single);
      expect(closeDecoded.encodingId, _closeSessionResponseId);
      expect(closeDecoded.header.serviceResult, _statusGood);
    });

    test('Task-3 service call BEFORE ActivateSession -> Bad_SessionNotActivated fault', () {
      final createFrames = session.onBytes(_buildCreateSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
      ), 0);
      final createDecoded = _decodeResponseChunk(createFrames.single);
      final authToken = createDecoded.reader.nodeId();

      final serviceFrames = session.onBytes(_buildGenericServiceRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 3,
        requestId: 12,
        serviceEncodingId: 527, // BrowseRequest_Encoding_DefaultBinary (Task 3's domain)
        authToken: authToken,
        requestHandle: 42,
      ), 0);
      final decoded = _decodeResponseChunk(serviceFrames.single);
      expect(decoded.encodingId, _serviceFaultId);
      expect(decoded.header.serviceResult, _statusBadSessionNotActivated);
      expect(decoded.header.requestHandle, 42);
    });

    test('Task-3 service call AFTER activation with a stub handler -> handler response', () {
      final handler = _StubServiceHandler();
      final activatedSession = OpcUaServerSession(info: _info, services: handler);
      activatedSession.onBytes(_buildHello(), 0);
      final opnFrames = activatedSession.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
      ), 0);
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final chId = opnReader.uint32();
      final tkId = opnReader.uint32();

      final createFrames = activatedSession.onBytes(_buildCreateSessionRequestChunk(
        secureChannelId: chId,
        tokenId: tkId,
        sequenceNumber: 2,
        requestId: 11,
      ), 0);
      final authToken = _decodeResponseChunk(createFrames.single).reader.nodeId();

      activatedSession.onBytes(_buildActivateSessionRequestChunk(
        secureChannelId: chId,
        tokenId: tkId,
        sequenceNumber: 3,
        requestId: 12,
        authToken: authToken,
      ), 0);

      final serviceFrames = activatedSession.onBytes(_buildGenericServiceRequestChunk(
        secureChannelId: chId,
        tokenId: tkId,
        sequenceNumber: 4,
        requestId: 13,
        serviceEncodingId: 527,
        authToken: authToken,
        requestHandle: 77,
      ), 0);
      expect(handler.callCount, 1);
      expect(handler.lastRequestTypeId, 527);

      final respChunk = parseChunk(serviceFrames.single);
      expect(respChunk.requestId, 13);
      final reader = OpcUaReader(respChunk.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, 99998);
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusGood);
      expect(header.requestHandle, 77);
      final marker = reader.uint32();
      expect(marker, 0xABCDEF01);
    });

    test('unknown service NodeId -> Bad_ServiceUnsupported ServiceFault echoing requestHandle', () {
      final frames = session.onBytes(_buildGenericServiceRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        serviceEncodingId: 999999,
        authToken: const OpcNodeId.numeric(0, 0),
        requestHandle: 123,
      ), 0);
      final decoded = _decodeResponseChunk(frames.single);
      expect(decoded.encodingId, _serviceFaultId);
      expect(decoded.header.serviceResult, _statusBadServiceUnsupported);
      expect(decoded.header.requestHandle, 123);
    });

    test('CloseSession then a further service call -> Bad_SessionIdInvalid fault', () {
      final createFrames = session.onBytes(_buildCreateSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
      ), 0);
      final authToken = _decodeResponseChunk(createFrames.single).reader.nodeId();

      session.onBytes(_buildActivateSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 3,
        requestId: 12,
        authToken: authToken,
      ), 0);

      session.onBytes(_buildCloseSessionRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 4,
        requestId: 13,
        authToken: authToken,
      ), 0);

      final frames = session.onBytes(_buildGenericServiceRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 5,
        requestId: 14,
        serviceEncodingId: 527,
        authToken: authToken,
        requestHandle: 200,
      ), 0);
      final decoded = _decodeResponseChunk(frames.single);
      expect(decoded.encodingId, _serviceFaultId);
      expect(decoded.header.serviceResult, _statusBadSessionIdInvalid);
      expect(decoded.header.requestHandle, 200);
    });
  });

  group('Malformed input', () {
    test('garbage bytes -> ERR + shouldClose, never a throw', () {
      final session = OpcUaServerSession(info: _info, services: null);
      session.onBytes(_buildHello(), 0);
      final garbage = Uint8List.fromList(List<int>.filled(20, 0xFF));
      List<Uint8List> outFrames = [];
      expect(() {
        outFrames = session.onBytes(garbage, 0);
      }, returnsNormally);
      expect(outFrames, hasLength(1));
      final header = MessageHeader.parse(outFrames.single);
      expect(header.messageType, 'ERR');
      expect(session.shouldClose, isTrue);
    });

    test('truncated chunk -> ERR + shouldClose, never a throw', () {
      final session = OpcUaServerSession(info: _info, services: null);
      session.onBytes(_buildHello(), 0);
      final full = _buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 1,
      );
      final truncated = Uint8List.sublistView(full, 0, full.length ~/ 2);
      List<Uint8List> outFrames = [];
      expect(() {
        outFrames = session.onBytes(truncated, 0);
      }, returnsNormally);
      expect(outFrames, hasLength(1));
      final header = MessageHeader.parse(outFrames.single);
      expect(header.messageType, 'ERR');
      expect(session.shouldClose, isTrue);
    });
  });

  group('Sequence numbers', () {
    test('server response sequence numbers strictly increase across responses', () {
      final session = OpcUaServerSession(info: _info, services: null);
      session.onBytes(_buildHello(), 0);

      final opnFrames = session.onBytes(_buildOpenSecureChannelRequestChunk(
        secureChannelId: 0,
        sequenceNumber: 1,
        requestId: 10,
      ), 0);
      final opnSeq = parseChunk(opnFrames.single).sequenceNumber;

      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final geFrames = session.onBytes(_buildGetEndpointsRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        authToken: const OpcNodeId.numeric(0, 0),
      ), 0);
      final geSeq = parseChunk(geFrames.single).sequenceNumber;

      final ge2Frames = session.onBytes(_buildGetEndpointsRequestChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 3,
        requestId: 12,
        authToken: const OpcNodeId.numeric(0, 0),
      ), 0);
      final ge2Seq = parseChunk(ge2Frames.single).sequenceNumber;

      expect(geSeq, greaterThan(opnSeq));
      expect(ge2Seq, greaterThan(geSeq));
    });
  });

  group('Subscription routing (Task 3)', () {
    /// Drives HEL -> OPN(Issue) -> CreateSession -> ActivateSession on a
    /// fresh [session] and returns the channel/token/authToken needed to
    /// build further MSG requests.
    ({int channelId, int tokenId, OpcNodeId authToken}) activate(OpcUaServerSession session) {
      session.onBytes(_buildHello(), 0);
      final opnFrames = session.onBytes(
        _buildOpenSecureChannelRequestChunk(secureChannelId: 0, sequenceNumber: 1, requestId: 10),
        0,
      );
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final createFrames = session.onBytes(
        _buildCreateSessionRequestChunk(
          secureChannelId: channelId,
          tokenId: tokenId,
          sequenceNumber: 2,
          requestId: 11,
        ),
        0,
      );
      final authToken = _decodeResponseChunk(createFrames.single).reader.nodeId();

      session.onBytes(
        _buildActivateSessionRequestChunk(
          secureChannelId: channelId,
          tokenId: tokenId,
          sequenceNumber: 3,
          requestId: 12,
          authToken: authToken,
        ),
        0,
      );
      return (channelId: channelId, tokenId: tokenId, authToken: authToken);
    }

    const monitoredNodeId = OpcNodeId.string(1, 'Counter');

    OpcUaServerSession sessionWithSampler(Map<OpcNodeId, OpcDataValue> values) {
      return OpcUaServerSession(
        info: _info,
        services: null,
        sampler: (nodeId) => values[nodeId] ?? const OpcDataValue(status: 0x80340000),
      );
    }

    test('full handshake then CreateSubscription via a real MSG frame -> revised values sane', () {
      final values = {monitoredNodeId: const OpcDataValue(variant: OpcVariant(typeId: 6, value: 1))};
      final session = sessionWithSampler(values);
      final ch = activate(session);

      final frames = session.onBytes(
        _buildCreateSubscriptionRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 4,
          requestId: 13,
          authToken: ch.authToken,
        ),
        0,
      );
      expect(frames, hasLength(1));
      final decoded = _decodeResponseChunk(frames.single);
      expect(decoded.encodingId, _createSubscriptionResponseId);
      expect(decoded.header.serviceResult, _statusGood);

      final subscriptionId = decoded.reader.uint32();
      final revisedPublishingInterval = decoded.reader.float64();
      final revisedLifetimeCount = decoded.reader.uint32();
      final revisedMaxKeepAliveCount = decoded.reader.uint32();

      expect(subscriptionId, greaterThanOrEqualTo(1));
      expect(revisedPublishingInterval, greaterThanOrEqualTo(100));
      expect(revisedLifetimeCount, greaterThanOrEqualTo(30));
      expect(revisedMaxKeepAliveCount, greaterThanOrEqualTo(1));
      expect(session.subscriptionCount, 1);
    });

    test('CreateMonitoredItems on a fake-sampler node -> Good result', () {
      final values = {monitoredNodeId: const OpcDataValue(variant: OpcVariant(typeId: 6, value: 1))};
      final session = sessionWithSampler(values);
      final ch = activate(session);

      final subFrames = session.onBytes(
        _buildCreateSubscriptionRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 4,
          requestId: 13,
          authToken: ch.authToken,
        ),
        0,
      );
      final subscriptionId = _decodeResponseChunk(subFrames.single).reader.uint32();

      final cmiFrames = session.onBytes(
        _buildCreateMonitoredItemsRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 5,
          requestId: 14,
          authToken: ch.authToken,
          subscriptionId: subscriptionId,
          nodeId: monitoredNodeId,
        ),
        0,
      );
      final decoded = _decodeResponseChunk(cmiFrames.single);
      expect(decoded.encodingId, _createMonitoredItemsResponseId);
      expect(decoded.header.serviceResult, _statusGood);
      final resultCount = decoded.reader.int32();
      expect(resultCount, 1);
      final statusCode = decoded.reader.statusCode();
      expect(statusCode, _statusGood);
      expect(session.monitoredItemCount, 1);
    });

    test('Publish is parked (onBytes returns empty); onClockTick past the publishing interval delivers it', () {
      final values = {monitoredNodeId: const OpcDataValue(variant: OpcVariant(typeId: 6, value: 1))};
      final session = sessionWithSampler(values);
      final ch = activate(session);

      final subFrames = session.onBytes(
        _buildCreateSubscriptionRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 4,
          requestId: 13,
          authToken: ch.authToken,
          requestedPublishingInterval: 100,
        ),
        0,
      );
      final subDecoded = _decodeResponseChunk(subFrames.single);
      final subscriptionId = subDecoded.reader.uint32();
      final revisedPublishingInterval = subDecoded.reader.float64();

      session.onBytes(
        _buildCreateMonitoredItemsRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 5,
          requestId: 14,
          authToken: ch.authToken,
          subscriptionId: subscriptionId,
          nodeId: monitoredNodeId,
        ),
        0,
      );

      // Park a Publish: onBytes must return NOTHING (the deferral).
      final publishFrames = session.onBytes(
        _buildPublishRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 6,
          requestId: 15,
          authToken: ch.authToken,
        ),
        0,
      );
      expect(publishFrames, isEmpty);

      // Mutate the fake sampler's value.
      values[monitoredNodeId] = const OpcDataValue(variant: OpcVariant(typeId: 6, value: 42));

      // Advance the clock past the publishing interval (revised >= 100ms;
      // sampling interval defaults to the subscription's interval too).
      final tickFrames = session.onClockTick((revisedPublishingInterval * 3).round());
      expect(tickFrames, hasLength(1));

      final chunk = parseChunk(tickFrames.single);
      expect(chunk.requestId, 15); // echoes the parked Publish's requestId
      final reader = OpcUaReader(chunk.body);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _publishResponseId);
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusGood);
      final respSubId = reader.uint32();
      expect(respSubId, subscriptionId);
    });

    test('subscription service before ActivateSession -> Bad_SessionNotActivated fault', () {
      final values = {monitoredNodeId: const OpcDataValue(variant: OpcVariant(typeId: 6, value: 1))};
      final session = sessionWithSampler(values);
      session.onBytes(_buildHello(), 0);
      final opnFrames = session.onBytes(
        _buildOpenSecureChannelRequestChunk(secureChannelId: 0, sequenceNumber: 1, requestId: 10),
        0,
      );
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final createFrames = session.onBytes(
        _buildCreateSessionRequestChunk(
          secureChannelId: channelId,
          tokenId: tokenId,
          sequenceNumber: 2,
          requestId: 11,
        ),
        0,
      );
      final authToken = _decodeResponseChunk(createFrames.single).reader.nodeId();

      // No ActivateSession call — go straight to CreateSubscription.
      final frames = session.onBytes(
        _buildCreateSubscriptionRequestChunk(
          secureChannelId: channelId,
          tokenId: tokenId,
          sequenceNumber: 3,
          requestId: 12,
          authToken: authToken,
        ),
        0,
      );
      final decoded = _decodeResponseChunk(frames.single);
      expect(decoded.encodingId, _serviceFaultId);
      expect(decoded.header.serviceResult, _statusBadSessionNotActivated);
    });

    test('session WITHOUT sampler -> Bad_ServiceUnsupported for subscription services', () {
      final session = OpcUaServerSession(info: _info, services: null); // sampler: null (default)
      final ch = activate(session);

      final frames = session.onBytes(
        _buildCreateSubscriptionRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 4,
          requestId: 13,
          authToken: ch.authToken,
        ),
        0,
      );
      final decoded = _decodeResponseChunk(frames.single);
      expect(decoded.encodingId, _serviceFaultId);
      expect(decoded.header.serviceResult, _statusBadServiceUnsupported);
      expect(session.subscriptionCount, 0);
      expect(session.monitoredItemCount, 0);
    });

    test('onClockTick with no subscriptions ever created -> empty list', () {
      final session = OpcUaServerSession(
        info: _info,
        services: null,
        sampler: (nodeId) => const OpcDataValue(status: 0x80340000),
      );
      activate(session);
      expect(session.onClockTick(100000), isEmpty);
    });

    test('onClockTick before any channel/session exists -> empty list, never throws', () {
      final session = OpcUaServerSession(
        info: _info,
        services: null,
        sampler: (nodeId) => const OpcDataValue(status: 0x80340000),
      );
      expect(() => session.onClockTick(100000), returnsNormally);
      expect(session.onClockTick(100000), isEmpty);
    });

    test('subscriptionCount/monitoredItemCount track create/delete lifecycle', () {
      final values = {monitoredNodeId: const OpcDataValue(variant: OpcVariant(typeId: 6, value: 1))};
      final session = sessionWithSampler(values);
      final ch = activate(session);
      expect(session.subscriptionCount, 0);
      expect(session.monitoredItemCount, 0);

      final subFrames = session.onBytes(
        _buildCreateSubscriptionRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 4,
          requestId: 13,
          authToken: ch.authToken,
        ),
        0,
      );
      final subscriptionId = _decodeResponseChunk(subFrames.single).reader.uint32();
      expect(session.subscriptionCount, 1);

      session.onBytes(
        _buildCreateMonitoredItemsRequestChunk(
          secureChannelId: ch.channelId,
          tokenId: ch.tokenId,
          sequenceNumber: 5,
          requestId: 14,
          authToken: ch.authToken,
          subscriptionId: subscriptionId,
          nodeId: monitoredNodeId,
        ),
        0,
      );
      expect(session.monitoredItemCount, 1);
    });
  });

  group('Task 5: endpoint advertisement + username/password auth', () {
    test('EndpointDescription advertises exactly the enabled (policy,mode) set',
        () {
      final serverCert = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final session = OpcUaServerSession(
        info: _info,
        services: null,
        securityModes: const ['None', 'Basic256Sha256/SignAndEncrypt'],
        serverCertificateDer: serverCert,
      );
      session.onBytes(_buildHello(), 0);
      final opn = session.onBytes(
        _buildOpenSecureChannelRequestChunk(
            secureChannelId: 0, sequenceNumber: 1, requestId: 10),
        0,
      );
      final opnReader = OpcUaReader(parseChunk(opn.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final frames = session.onBytes(
        _buildGetEndpointsRequestChunk(
          secureChannelId: channelId,
          tokenId: tokenId,
          sequenceNumber: 2,
          requestId: 11,
          authToken: const OpcNodeId.numeric(0, 0),
        ),
        0,
      );
      final decoded = _decodeResponseChunk(frames.single);
      expect(decoded.encodingId, _getEndpointsResponseId);
      final endpoints = _readEndpoints(decoded.reader);
      expect(endpoints, hasLength(2));

      // Endpoint 0: None -> securityMode 1, None URI, null certificate.
      expect(endpoints[0].securityMode, 1);
      expect(endpoints[0].policyUri, kSecurityPolicyNoneUri);
      expect(endpoints[0].serverCertificate, isNull);

      // Endpoint 1: Basic256Sha256/SignAndEncrypt -> securityMode 3, cert present.
      expect(endpoints[1].securityMode, 3);
      expect(endpoints[1].policyUri,
          'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256');
      expect(endpoints[1].serverCertificate, equals(serverCert));
    });

    test('username/password activate succeeds with correct creds and is '
        'rejected with a wrong password', () {
      OpcUaServerSession freshSession() {
        final s = OpcUaServerSession(
          info: _info,
          services: null,
          credentials: const {'operator': 's3cret'},
          allowAnonymous: false,
        );
        s.onBytes(_buildHello(), 0);
        return s;
      }

      ({int channelId, int tokenId, OpcNodeId authToken}) openAndCreate(
          OpcUaServerSession s) {
        final opn = s.onBytes(
          _buildOpenSecureChannelRequestChunk(
              secureChannelId: 0, sequenceNumber: 1, requestId: 10),
          0,
        );
        final r = OpcUaReader(parseChunk(opn.single).body);
        r.nodeId();
        r.responseHeader();
        r.uint32();
        final channelId = r.uint32();
        final tokenId = r.uint32();
        final create = s.onBytes(
          _buildCreateSessionRequestChunk(
            secureChannelId: channelId,
            tokenId: tokenId,
            sequenceNumber: 2,
            requestId: 11,
          ),
          0,
        );
        final authToken = _decodeResponseChunk(create.single).reader.nodeId();
        return (channelId: channelId, tokenId: tokenId, authToken: authToken);
      }

      // Correct credentials -> Good.
      final good = freshSession();
      final gc = openAndCreate(good);
      final okFrames = good.onBytes(
        _buildActivateSessionUserNameChunk(
          secureChannelId: gc.channelId,
          tokenId: gc.tokenId,
          sequenceNumber: 3,
          requestId: 12,
          authToken: gc.authToken,
          userName: 'operator',
          password: 's3cret',
        ),
        0,
      );
      final okDecoded = _decodeResponseChunk(okFrames.single);
      expect(okDecoded.encodingId, _activateSessionResponseId);
      expect(okDecoded.header.serviceResult, _statusGood);

      // Wrong password -> Bad_UserAccessDenied (a ServiceFault).
      final bad = freshSession();
      final bc = openAndCreate(bad);
      final badFrames = bad.onBytes(
        _buildActivateSessionUserNameChunk(
          secureChannelId: bc.channelId,
          tokenId: bc.tokenId,
          sequenceNumber: 3,
          requestId: 12,
          authToken: bc.authToken,
          userName: 'operator',
          password: 'wrong',
        ),
        0,
      );
      final badDecoded = _decodeResponseChunk(badFrames.single);
      expect(badDecoded.encodingId, _serviceFaultId);
      expect(badDecoded.header.serviceResult, 0x801F0000); // Bad_UserAccessDenied
    });

    test('anonymous refused when allowAnonymous=false', () {
      final session = OpcUaServerSession(
        info: _info,
        services: null,
        credentials: const {'operator': 's3cret'},
        allowAnonymous: false,
      );
      session.onBytes(_buildHello(), 0);
      final opn = session.onBytes(
        _buildOpenSecureChannelRequestChunk(
            secureChannelId: 0, sequenceNumber: 1, requestId: 10),
        0,
      );
      final r = OpcUaReader(parseChunk(opn.single).body);
      r.nodeId();
      r.responseHeader();
      r.uint32();
      final channelId = r.uint32();
      final tokenId = r.uint32();
      final create = session.onBytes(
        _buildCreateSessionRequestChunk(
          secureChannelId: channelId,
          tokenId: tokenId,
          sequenceNumber: 2,
          requestId: 11,
        ),
        0,
      );
      final authToken = _decodeResponseChunk(create.single).reader.nodeId();

      final frames = session.onBytes(
        _buildActivateSessionRequestChunk(
          secureChannelId: channelId,
          tokenId: tokenId,
          sequenceNumber: 3,
          requestId: 12,
          authToken: authToken,
          includeAnonymousToken: true,
        ),
        0,
      );
      final decoded = _decodeResponseChunk(frames.single);
      expect(decoded.encodingId, _serviceFaultId);
      expect(decoded.header.serviceResult, 0x80210000); // Bad_IdentityTokenRejected
    });

    test('full secured channel: OPN + symmetric CreateSession/ActivateSession '
        'with an ENCRYPTED username token', () {
      final serverKp = generateRsa2048(fortunaRandom(List<int>.filled(32, 7)));
      final clientKp = generateRsa2048(fortunaRandom(List<int>.filled(32, 11)));
      final serverCertDer = buildSelfSignedCertificate(
        keyPair: serverKp,
        applicationUri: 'urn:server',
        commonName: 'S',
        notBefore: DateTime.utc(2020),
        notAfter: DateTime.utc(2040),
      );
      final clientCertDer = buildSelfSignedCertificate(
        keyPair: clientKp,
        applicationUri: 'urn:client',
        commonName: 'C',
        notBefore: DateTime.utc(2020),
        notAfter: DateTime.utc(2040),
      );
      final serverNonce = Uint8List.fromList(
          List<int>.generate(kSecureChannelNonceLength, (i) => 200 - i));
      final clientNonce = Uint8List.fromList(
          List<int>.generate(kSecureChannelNonceLength, (i) => i + 1));

      final channel =
          OpcSecureChannel(keyPair: serverKp, certificateDer: serverCertDer);
      final session = OpcUaServerSession(
        info: _info,
        services: null,
        securityModes: const ['Basic256Sha256/SignAndEncrypt'],
        serverCertificateDer: serverCertDer,
        credentials: const {'operator': 's3cret'},
        allowAnonymous: false,
        secureChannel: channel,
        serverNonceGenerator: () => serverNonce,
      );

      session.onBytes(_buildHello(), 0);

      // --- Secured OPN (Issue, SignAndEncrypt) ---
      final opnBody = OpcUaWriter();
      opnBody.nodeId(const OpcNodeId.numeric(0, _openSecureChannelRequestId));
      opnBody.requestHeader(_reqHeader());
      opnBody.uint32(0); // clientProtocolVersion
      opnBody.int32(0); // requestType Issue
      opnBody.int32(3); // securityMode SignAndEncrypt
      opnBody.byteString(clientNonce);
      opnBody.uint32(3600000); // requestedLifetime
      final opnSeqBody = Uint8List.fromList(
          <int>[..._seqHeader(1, 1), ...opnBody.take()]);
      final opnFrame = _asymSignEncryptOpn(
        signKey: clientKp.privateKey,
        encKey: serverKp.publicKey,
        senderCertDer: clientCertDer,
        receiverThumbprint: sha1(serverCertDer),
        plainSeqBody: opnSeqBody,
      );
      final opnOut = session.onBytes(opnFrame, 0);
      expect(opnOut, hasLength(1));
      // The response is a secured OPN carrying the fixed serverNonce.
      final respPlain = _asymDecryptVerifyOpn(
        decKey: clientKp.privateKey,
        verifyKey: serverKp.publicKey,
        frame: opnOut.single,
      );
      final respReader = OpcUaReader(Uint8List.sublistView(respPlain, 8));
      respReader.nodeId();
      respReader.responseHeader();
      respReader.uint32(); // serverProtocolVersion
      final channelId = respReader.uint32();
      final tokenId = respReader.uint32();
      respReader.dateTime();
      respReader.uint32(); // revisedLifetime
      final gotServerNonce = respReader.byteString();
      expect(gotServerNonce, equals(serverNonce));

      // The session derived the same symmetric keys we can now mirror with.
      final clientKeys = channel.clientKeys!;
      final serverKeys = channel.serverKeys!;

      // --- Secured CreateSession ---
      final csBody = OpcUaWriter();
      csBody.nodeId(const OpcNodeId.numeric(0, _createSessionRequestId));
      csBody.requestHeader(_reqHeader(requestHandle: 3));
      csBody.string('urn:test:client');
      csBody.string('urn:test:client:product');
      csBody.localizedText(const OpcLocalizedText(text: 'C'));
      csBody.int32(1);
      csBody.string(null);
      csBody.string(null);
      csBody.int32(-1);
      csBody.string(null); // serverUri
      csBody.string('opc.tcp://127.0.0.1:4840'); // endpointUrl
      csBody.string('sess'); // sessionName
      csBody.byteString(null); // clientNonce
      csBody.byteString(clientCertDer); // clientCertificate
      csBody.float64(1200000);
      csBody.uint32(0);
      final csFrame = _symBuildSession(
        keys: clientKeys,
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 2,
        requestId: 11,
        body: csBody.take(),
      );
      final csOut = session.onBytes(csFrame, 0);
      final csRespBody = _symOpenSessionBody(keys: serverKeys, frame: csOut.single);
      final csReader = OpcUaReader(csRespBody);
      csReader.nodeId();
      csReader.responseHeader();
      csReader.nodeId(); // sessionId
      final authToken = csReader.nodeId();
      csReader.float64(); // revisedSessionTimeout
      // Task 7 regression guard: on a SECURED channel the response MUST echo
      // a non-null serverNonce (== the secure channel's OWN server nonce —
      // the same value [OpcSecureChannel.decryptUserPassword] verifies
      // against below) and a non-null serverCertificate (== the app cert DER
      // injected into the session). Reverting the fix to null/null here
      // would leave everything else in this test green — only these two
      // field-level assertions (and the nonce actually being used, right
      // below) catch that regression.
      final echoedServerNonce = csReader.byteString();
      final echoedServerCertificate = csReader.byteString();
      expect(echoedServerNonce, isNotNull);
      expect(echoedServerNonce, isNotEmpty);
      expect(echoedServerNonce, equals(channel.serverNonce));
      expect(echoedServerNonce, equals(serverNonce));
      expect(echoedServerCertificate, isNotNull);
      expect(echoedServerCertificate, equals(serverCertDer));

      // --- Secured ActivateSession with an ENCRYPTED UserNameIdentityToken ---
      // Encrypt the password using the nonce READ FROM THE RESPONSE (not the
      // pre-known [serverNonce] constant) — proving the end-to-end nonce
      // echo is what actually authenticates, not a coincidental match.
      final encPassword = _legacyPasswordEncryptSession(
        serverPub: serverKp.publicKey,
        password: 's3cret',
        serverNonce: Uint8List.fromList(echoedServerNonce!),
      );
      final tokenWriter = OpcUaWriter();
      tokenWriter.string('username');
      tokenWriter.string('operator');
      tokenWriter.byteString(encPassword);
      tokenWriter.string(
          'http://www.w3.org/2001/04/xmlenc#rsa-oaep'); // OAEP-SHA1
      final asBody = OpcUaWriter();
      asBody.nodeId(const OpcNodeId.numeric(0, _activateSessionRequestId));
      asBody.requestHeader(_reqHeader(authToken: authToken, requestHandle: 4));
      asBody.string(null);
      asBody.byteString(null);
      asBody.int32(-1);
      asBody.int32(-1);
      asBody.extensionObjectHeader(const OpcNodeId.numeric(0, 324),
          hasBody: true);
      asBody.byteString(tokenWriter.take());
      asBody.string(null);
      asBody.byteString(null);
      final asFrame = _symBuildSession(
        keys: clientKeys,
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: 3,
        requestId: 12,
        body: asBody.take(),
      );
      final asOut = session.onBytes(asFrame, 0);
      final asRespBody =
          _symOpenSessionBody(keys: serverKeys, frame: asOut.single);
      final asReader = OpcUaReader(asRespBody);
      final asTypeId = asReader.nodeId();
      final asHeader = asReader.responseHeader();
      expect(asTypeId.numericId, _activateSessionResponseId);
      expect(asHeader.serviceResult, _statusGood);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

Uint8List _seqHeader(int seq, int req) {
  final b = ByteData(8)
    ..setUint32(0, seq, Endian.little)
    ..setUint32(4, req, Endian.little);
  return b.buffer.asUint8List();
}

// --- Client-side asymmetric OPN mirror (Basic256Sha256) --------------------
Uint8List _asymSignEncryptOpn({
  required RSAPrivateKey signKey,
  required RSAPublicKey encKey,
  required Uint8List senderCertDer,
  required Uint8List receiverThumbprint,
  required Uint8List plainSeqBody,
}) {
  const plainBlock = 214;
  const cipherBlock = 256;
  const sigSize = 256;
  final body = Uint8List.sublistView(plainSeqBody, 8);
  final plainFrame = buildOpnChunk(
    secureChannelId: 0,
    securityPolicyUri: kSecurityPolicyBasic256Sha256Uri,
    senderCertificate: senderCertDer,
    receiverCertificateThumbprint: receiverThumbprint,
    sequenceNumber: 1,
    requestId: 1,
    body: body,
  );
  final headerSize = plainFrame.length - plainSeqBody.length;
  final encryptSize = 8 + body.length + sigSize + 1;
  final rem = encryptSize % plainBlock;
  final pInner = rem == 0 ? 0 : plainBlock - rem;
  final padTotal = 1 + pInner;
  final pad = Uint8List(padTotal)..fillRange(0, padTotal, pInner & 0xff);
  final encPlainLen = plainSeqBody.length + padTotal + sigSize;
  final tmp = Uint8List(headerSize + encPlainLen);
  tmp.setRange(0, plainFrame.length, plainFrame);
  tmp.setRange(plainFrame.length, plainFrame.length + padTotal, pad);
  final cipherTextSize = (encPlainLen ~/ plainBlock) * cipherBlock;
  ByteData.sublistView(tmp, 4, 8)
      .setUint32(0, headerSize + cipherTextSize, Endian.little);
  final signedEnd = tmp.length - sigSize;
  var sig =
      rsaPkcs1Sha256Sign(signKey, Uint8List.sublistView(tmp, 0, signedEnd));
  if (sig.length < sigSize) {
    final padded = Uint8List(sigSize);
    padded.setRange(sigSize - sig.length, sigSize, sig);
    sig = padded;
  }
  tmp.setRange(signedEnd, tmp.length, sig);
  final out = BytesBuilder(copy: true);
  out.add(Uint8List.sublistView(tmp, 0, headerSize));
  for (var i = headerSize; i < tmp.length; i += plainBlock) {
    out.add(rsaOaepSha1Encrypt(
        encKey, Uint8List.sublistView(tmp, i, i + plainBlock)));
  }
  return out.takeBytes();
}

Uint8List _asymDecryptVerifyOpn({
  required RSAPrivateKey decKey,
  required RSAPublicKey verifyKey,
  required Uint8List frame,
}) {
  const cipherBlock = 256;
  const sigSize = 256;
  final hdr = parseChunkHeader(frame);
  final rawHeader = Uint8List.sublistView(frame, 0, hdr.securityHeaderEnd);
  final enc = Uint8List.sublistView(frame, hdr.securityHeaderEnd, hdr.size);
  final dec = BytesBuilder(copy: true);
  for (var i = 0; i < enc.length; i += cipherBlock) {
    dec.add(rsaOaepSha1Decrypt(
        decKey, Uint8List.sublistView(enc, i, i + cipherBlock)));
  }
  final plain = dec.takeBytes();
  final signedEnd = plain.length - sigSize;
  final sig = Uint8List.sublistView(plain, signedEnd);
  final signed = Uint8List(rawHeader.length + signedEnd);
  signed.setRange(0, rawHeader.length, rawHeader);
  signed.setRange(rawHeader.length, signed.length, plain);
  expect(rsaPkcs1Sha256Verify(verifyKey, signed, sig), isTrue);
  final padByte = plain[signedEnd - 1];
  final bodyEnd = signedEnd - (padByte + 1);
  return Uint8List.fromList(Uint8List.sublistView(plain, 0, bodyEnd));
}

// --- Client-side symmetric MSG mirror --------------------------------------
Uint8List _symBuildSession({
  required OpcChannelKeys keys,
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required Uint8List body,
}) {
  const headerSize = 16;
  const sig = 32;
  const block = 16;
  final plainFrame = buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
  final encryptSize = 8 + body.length + sig + 1;
  final rem = encryptSize % block;
  final inner = rem == 0 ? 0 : block - rem;
  final padTotal = 1 + inner;
  final pad = Uint8List(padTotal)..fillRange(0, padTotal, inner & 0xff);
  final tmp = Uint8List(headerSize + 8 + body.length + padTotal + sig);
  tmp.setRange(0, plainFrame.length, plainFrame);
  tmp.setRange(plainFrame.length, plainFrame.length + padTotal, pad);
  ByteData.sublistView(tmp, 4, 8).setUint32(0, tmp.length, Endian.little);
  final signedEnd = tmp.length - sig;
  final signature =
      hmacSha256(keys.signingKey, Uint8List.sublistView(tmp, 0, signedEnd));
  tmp.setRange(signedEnd, tmp.length, signature);
  final cipher = aes256CbcEncrypt(
      keys.encryptingKey, keys.iv, Uint8List.sublistView(tmp, headerSize, tmp.length));
  final out = Uint8List(tmp.length);
  out.setRange(0, headerSize, tmp);
  out.setRange(headerSize, out.length, cipher);
  return out;
}

Uint8List _symOpenSessionBody({
  required OpcChannelKeys keys,
  required Uint8List frame,
}) {
  const sig = 32;
  final hdr = parseChunkHeader(frame);
  final rawHeader = Uint8List.sublistView(frame, 0, hdr.securityHeaderEnd);
  final rawAfter = Uint8List.sublistView(frame, hdr.securityHeaderEnd, hdr.size);
  final dec = aes256CbcDecrypt(keys.encryptingKey, keys.iv, rawAfter);
  final signedEnd = dec.length - sig;
  final signed = Uint8List(rawHeader.length + signedEnd);
  signed.setRange(0, rawHeader.length, rawHeader);
  signed.setRange(
      rawHeader.length, signed.length, Uint8List.sublistView(dec, 0, signedEnd));
  expect(Uint8List.sublistView(dec, signedEnd),
      equals(hmacSha256(keys.signingKey, signed)));
  final padByte = dec[signedEnd - 1];
  final bodyEnd = signedEnd - (padByte + 1);
  return Uint8List.fromList(Uint8List.sublistView(dec, 8, bodyEnd));
}

Uint8List _legacyPasswordEncryptSession({
  required RSAPublicKey serverPub,
  required String password,
  required Uint8List serverNonce,
}) {
  final passBytes = Uint8List.fromList(utf8.encode(password));
  final plaintextLen = 4 + passBytes.length + serverNonce.length;
  final src = Uint8List(plaintextLen);
  ByteData.sublistView(src, 0, 4).setUint32(0, plaintextLen - 4, Endian.little);
  src.setRange(4, 4 + passBytes.length, passBytes);
  src.setRange(4 + passBytes.length, plaintextLen, serverNonce);
  return rsaOaepSha1Encrypt(serverPub, src);
}

/// One decoded EndpointDescription's fields the Task 5 advertisement test asserts.
class _EndpointView {
  final int securityMode;
  final String? policyUri;
  final List<int>? serverCertificate;
  _EndpointView(this.securityMode, this.policyUri, this.serverCertificate);
}

/// Reads the EndpointDescription[] array (Int32 count + each description) from
/// a reader positioned at the array, per endpoint_description.rs field order.
List<_EndpointView> _readEndpoints(OpcUaReader r) {
  final count = r.int32();
  final out = <_EndpointView>[];
  for (var i = 0; i < count; i++) {
    r.string(); // endpointUrl
    // ApplicationDescription
    r.string(); // applicationUri
    r.string(); // productUri
    r.localizedText(); // applicationName
    r.int32(); // applicationType
    r.string(); // gatewayServerUri
    r.string(); // discoveryProfileUri
    final discCount = r.int32(); // discoveryUrls
    if (discCount > 0) {
      for (var d = 0; d < discCount; d++) {
        r.string();
      }
    }
    final serverCertificate = r.byteString();
    final securityMode = r.int32();
    final policyUri = r.string();
    // userIdentityTokens
    final tokenCount = r.int32();
    for (var t = 0; t < tokenCount; t++) {
      r.string(); // policyId
      r.int32(); // tokenType
      r.string(); // issuedTokenType
      r.string(); // issuerEndpointUrl
      r.string(); // securityPolicyUri
    }
    r.string(); // transportProfileUri
    r.uint8(); // securityLevel
    out.add(_EndpointView(securityMode, policyUri, serverCertificate));
  }
  return out;
}

/// ActivateSessionRequest carrying a UserNameIdentityToken (node id 324) with a
/// PLAINTEXT password (encryptionAlgorithm null) — used to exercise the
/// session's credential matching over a None channel.
Uint8List _buildActivateSessionUserNameChunk({
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required OpcNodeId authToken,
  required String userName,
  required String password,
  int requestHandle = 4,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, _activateSessionRequestId));
  w.requestHeader(_reqHeader(authToken: authToken, requestHandle: requestHandle));
  w.string(null); // clientSignature.algorithm
  w.byteString(null); // clientSignature.signature
  w.int32(-1); // clientSoftwareCertificates
  w.int32(-1); // localeIds
  // userIdentityToken: ExtensionObject{ UserNameIdentityToken }
  final tokenWriter = OpcUaWriter();
  tokenWriter.string('username'); // policyId
  tokenWriter.string(userName);
  tokenWriter.byteString(utf8.encode(password)); // plaintext password
  tokenWriter.string(null); // encryptionAlgorithm (empty -> plaintext)
  w.extensionObjectHeader(const OpcNodeId.numeric(0, 324), hasBody: true);
  w.byteString(tokenWriter.take());
  // userTokenSignature
  w.string(null);
  w.byteString(null);
  return buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: w.take(),
  );
}
