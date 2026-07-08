// Tests for the Task 2 OPC UA discovery fixes: the standard NamespaceArray
// (ns=0;i=2255) and Server (ns=0;i=2253) nodes, and top-down Browse
// (Root i=84 -> Objects i=85 -> tags) — see
// mobile/lib/protocols/opcua/opcua_address_space.dart and
// mobile/lib/protocols/opcua/opcua_services.dart.
//
// Harness (request/response codec helpers) is copied from
// opcua_services_test.dart — same pattern, no hand-rolled hex. Struct field
// orders / ids verified against the vendored Rust `opcua` 0.12.0 reference at
// C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/
// (node_ids.rs, service_types/*.rs, status_codes.rs, attribute.rs).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_services.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_session.dart';

// --- Encoding ids, verified against types/node_ids.rs -----------------------
const _browseRequestId = 527;
const _readRequestId = 631;

// --- StatusCodes, verified against types/status_codes.rs --------------------
const _statusGood = 0;
const _statusBadNodeIdUnknown = 0x80340000;
const _statusBadAttributeIdInvalid = 0x80350000;

// --- AttributeIds, verified against types/attribute.rs ----------------------
const _attrNodeClass = 2;
const _attrBrowseName = 3;
const _attrDisplayName = 4;
const _attrValue = 13;

// --- NodeClass enum (service_types/enums.rs) --------------------------------
const _nodeClassObject = 1;

// --- Standard node ids (types/node_ids.rs) -----------------------------------
const _rootFolderId = 84; // node_ids.rs:1607
const _objectsFolderId = 85; // node_ids.rs:1608
const _organizesId = 35; // node_ids.rs:849
const _serverId = 2253; // node_ids.rs:1827
const _namespaceArrayId = 2255; // node_ids.rs:3936

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

ResponseBuilder _respondBuilder(RequestHeader header) {
  return ({int serviceResult = _statusGood}) => ResponseHeader(
        timestamp: DateTime.utc(2026, 7, 6),
        requestHandle: header.requestHandle,
        serviceResult: serviceResult,
      );
}

/// Builds a BrowseRequest BODY (already past the leading type-id NodeId) —
/// see opcua_services_test.dart's identical helper for the field-order doc.
OpcUaReader _browseRequestBody({
  required List<OpcNodeId> nodesToBrowse,
  int resultMask = 0x3F,
}) {
  final w = OpcUaWriter();
  w.nodeId(const OpcNodeId.numeric(0, 0)); // view.viewId: null view
  w.dateTime(null); // view.timestamp
  w.uint32(0); // view.viewVersion
  w.uint32(0); // requestedMaxReferencesPerNode: no limit
  w.int32(nodesToBrowse.length);
  for (final n in nodesToBrowse) {
    w.nodeId(n);
    w.int32(0); // browseDirection: Forward
    w.nodeId(const OpcNodeId.numeric(0, _organizesId)); // referenceTypeId
    w.boolean(true); // includeSubtypes
    w.uint32(0); // nodeClassMask: all
    w.uint32(resultMask);
  }
  return OpcUaReader(w.take());
}

/// Builds a ReadRequest BODY — see opcua_services_test.dart's identical
/// helper for the field-order doc.
OpcUaReader _readRequestBody({
  required List<({OpcNodeId nodeId, int attributeId, String? indexRange})>
      toRead,
}) {
  final w = OpcUaWriter();
  w.float64(0); // maxAge
  w.int32(2); // timestampsToReturn: Both (unused by v1)
  w.int32(toRead.length);
  for (final r in toRead) {
    w.nodeId(r.nodeId);
    w.uint32(r.attributeId);
    w.string(r.indexRange);
    w.qualifiedName(const OpcQualifiedName(ns: 0, name: null)); // dataEncoding
  }
  return OpcUaReader(w.take());
}

/// A small fixture project with 2 mapped tags under namespace index 1 (the
/// namespace whose URI the NamespaceArray's index-1 entry must equal).
PlcProject _buildProject() {
  final project = PlcProject(
    id: 'proj-discovery',
    name: 'Discovery Test Project',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(name: 'StartPB', path: 'StartPB', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'Counter', path: 'Counter', dataType: 'INT32', value: 42, ioType: 'Internal'),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings(
    opcua: OpcUaProtocolConfig(
      enabled: true,
      namespaceUri: 'urn:test:discovery',
      map: OpcuaMap(
        namespaceUri: 'urn:test:discovery',
        nodes: [
          OpcuaNode(nodeId: 'ns=1;s=StartPB', tag: 'StartPB', access: 'ReadWrite'),
          OpcuaNode(nodeId: 'ns=1;s=Counter', tag: 'Counter', access: 'ReadWrite'),
        ],
      ),
    ),
  );
  return project;
}

void main() {
  late PlcProject project;
  late OpcUaProjectServices services;

  setUp(() {
    project = _buildProject();
    services = OpcUaProjectServices(projectProvider: () => project);
  });

  Uint8List? callHandler(int requestTypeId, OpcUaReader body, {RequestHeader? header}) {
    final h = header ?? _reqHeader();
    return services.handle(requestTypeId, body, h, _respondBuilder(h));
  }

  group('NamespaceArray (ns=0;i=2255)', () {
    test('Read of Value returns a String array Variant [OPC-UA-URI, project namespaceUri]', () {
      final body = _readRequestBody(toRead: [
        (nodeId: const OpcNodeId.numeric(0, _namespaceArrayId), attributeId: _attrValue, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      final dv = reader.dataValue();
      expect(dv.status, _statusGood);
      expect(dv.variant, isNotNull);
      expect(dv.variant!.typeId, 12); // String
      expect(dv.variant!.isArray, isTrue);
      final array = dv.variant!.value as List;
      expect(array, hasLength(2));
      expect(array[0], 'http://opcfoundation.org/UA/');
      expect(array[1], 'urn:test:discovery');
    });

    test('Read of NodeClass/BrowseName/DisplayName answered (Variable, "NamespaceArray")', () {
      final body = _readRequestBody(toRead: [
        (nodeId: const OpcNodeId.numeric(0, _namespaceArrayId), attributeId: _attrNodeClass, indexRange: null),
        (nodeId: const OpcNodeId.numeric(0, _namespaceArrayId), attributeId: _attrBrowseName, indexRange: null),
        (nodeId: const OpcNodeId.numeric(0, _namespaceArrayId), attributeId: _attrDisplayName, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 3);
      final nodeClassDv = reader.dataValue();
      expect(nodeClassDv.status, _statusGood);
      expect(nodeClassDv.variant!.value, 2); // NodeClass.Variable
      final browseNameDv = reader.dataValue();
      expect((browseNameDv.variant!.value as OpcQualifiedName).name, 'NamespaceArray');
      final displayNameDv = reader.dataValue();
      expect((displayNameDv.variant!.value as OpcLocalizedText).text, 'NamespaceArray');
    });
  });

  group('Browse from Root (top-down discovery)', () {
    test('Browse of ns=0;i=84 (Root) returns exactly one Organizes reference to ns=0;i=85 (Objects)', () {
      final body = _browseRequestBody(nodesToBrowse: [const OpcNodeId.numeric(0, _rootFolderId)]);
      final resp = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1); // resultCount
      expect(reader.statusCode(), _statusGood);
      reader.byteString(); // continuationPoint
      final refCount = reader.int32();
      expect(refCount, 1);

      final referenceTypeId = reader.nodeId();
      expect(referenceTypeId, const OpcNodeId.numeric(0, _organizesId));
      expect(reader.boolean(), isTrue); // isForward
      final target = reader.expandedNodeId();
      expect(target, const OpcNodeId.numeric(0, _objectsFolderId));
      reader.qualifiedName(); // browseName
      reader.localizedText(); // displayName
      final nodeClass = reader.int32();
      expect(nodeClass, _nodeClassObject); // Objects is an Object node
      reader.expandedNodeId(); // typeDefinition: FolderType
    });

    test('Browse of ns=0;i=85 (Objects) includes the Server object AND one reference per mapped tag', () {
      final body = _browseRequestBody(nodesToBrowse: [const OpcNodeId.numeric(0, _objectsFolderId)]);
      final resp = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      reader.byteString();
      final refCount = reader.int32();
      expect(refCount, 3); // Server + StartPB + Counter

      final targets = <OpcNodeId>[];
      for (var i = 0; i < refCount; i++) {
        reader.nodeId(); // referenceTypeId
        expect(reader.boolean(), isTrue); // isForward
        targets.add(reader.expandedNodeId());
        reader.qualifiedName();
        reader.localizedText();
        reader.int32(); // nodeClass
        reader.expandedNodeId(); // typeDefinition
      }
      expect(targets, contains(const OpcNodeId.numeric(0, _serverId)));
      expect(targets, contains(const OpcNodeId.string(1, 'StartPB')));
      expect(targets, contains(const OpcNodeId.string(1, 'Counter')));
    });

    test('Browse of the Server node itself is Good with zero references (not modeled further)', () {
      final body = _browseRequestBody(nodesToBrowse: [const OpcNodeId.numeric(0, _serverId)]);
      final resp = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusGood);
      reader.byteString();
      expect(reader.int32(), 0);
    });
  });

  group('Server node (ns=0;i=2253)', () {
    test('Read of NodeClass -> Object; BrowseName/DisplayName -> "Server"', () {
      final body = _readRequestBody(toRead: [
        (nodeId: const OpcNodeId.numeric(0, _serverId), attributeId: _attrNodeClass, indexRange: null),
        (nodeId: const OpcNodeId.numeric(0, _serverId), attributeId: _attrBrowseName, indexRange: null),
        (nodeId: const OpcNodeId.numeric(0, _serverId), attributeId: _attrDisplayName, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 3);
      final nodeClassDv = reader.dataValue();
      expect(nodeClassDv.status, _statusGood);
      expect(nodeClassDv.variant!.value, _nodeClassObject);
      final browseNameDv = reader.dataValue();
      expect((browseNameDv.variant!.value as OpcQualifiedName).name, 'Server');
      final displayNameDv = reader.dataValue();
      expect((displayNameDv.variant!.value as OpcLocalizedText).text, 'Server');
    });

    test('Read of Value on the Server node -> Bad_AttributeIdInvalid (not applicable to an Object)', () {
      final body = _readRequestBody(toRead: [
        (nodeId: const OpcNodeId.numeric(0, _serverId), attributeId: _attrValue, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      final dv = reader.dataValue();
      expect(dv.status, _statusBadAttributeIdInvalid);
    });
  });

  group('Regression: unmapped/malformed node ids still behave as before', () {
    test('Browse of a totally unknown node id -> Bad_NodeIdUnknown', () {
      final body = _browseRequestBody(nodesToBrowse: [const OpcNodeId.string(1, 'DoesNotExist')]);
      final resp = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusBadNodeIdUnknown);
    });

    test('Read of a totally unknown node id -> Bad_NodeIdUnknown', () {
      final body = _readRequestBody(toRead: [
        (nodeId: const OpcNodeId.string(1, 'DoesNotExist'), attributeId: _attrValue, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      final dv = reader.dataValue();
      expect(dv.status, _statusBadNodeIdUnknown);
    });
  });
}
