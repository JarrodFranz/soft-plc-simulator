// Tests for the pure-Dart OPC UA address space + Browse/Read/Write services
// (mobile/lib/protocols/opcua/opcua_address_space.dart,
// mobile/lib/protocols/opcua/opcua_services.dart).
//
// Every request/response is built/decoded VIA THE TASK 1 CODEC
// (opcua_binary.dart) — no hand-rolled hex. Struct field orders verified
// against the vendored Rust `opcua` 0.12.0 reference at
// C:/Users/jarro/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/opcua-0.12.0/src/types/service_types/*.rs
// (browse_request.rs, browse_description.rs, browse_response.rs,
// browse_result.rs, reference_description.rs, read_request.rs,
// read_value_id.rs, read_response.rs, write_request.rs, write_value.rs,
// write_response.rs) and types/node_ids.rs / types/status_codes.rs /
// types/attribute.rs / types/service_types/enums.rs for the ids/enums cited
// inline below.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_address_space.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_services.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_session.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_transport.dart';

// --- Encoding ids, verified against types/node_ids.rs -----------------------
const _browseRequestId = 527;
const _browseResponseId = 530;
const _readRequestId = 631;
const _writeRequestId = 673;
const _writeResponseId = 676;
const _activateSessionRequestId = 467;
const _createSessionRequestId = 461;
const _openSecureChannelRequestId = 446;
const _serviceFaultId = 397; // node_ids.rs:1662

// --- StatusCodes, verified against types/status_codes.rs --------------------
const _statusGood = 0;
const _statusBadNodeIdUnknown = 0x80340000;
const _statusBadAttributeIdInvalid = 0x80350000;
const _statusBadIndexRangeInvalid = 0x80360000;
const _statusBadNotWritable = 0x803B0000;
const _statusBadUserAccessDenied = 0x801F0000;
const _statusBadTypeMismatch = 0x80740000;
const _statusBadNothingToDo = 0x800F0000;
// Bad_ResponseTooLarge: "The response message size exceeds limits set by the
// client." (status_codes.rs:246 / :762). NOTE the task brief's 0x80B80000 is
// Bad_RequestTooLarge; the semantically-correct code for a response overrunning
// the client's negotiated send buffer is 0x80B90000 (verified against the
// vendored opcua 0.12.0 reference).
const _statusBadResponseTooLarge = 0x80B90000;

// --- AttributeIds, verified against types/attribute.rs ----------------------
const _attrNodeClass = 2;
const _attrBrowseName = 3;
const _attrDisplayName = 4;
const _attrValue = 13;
const _attrDataType = 14;
const _attrAccessLevel = 17;
const _attrUserAccessLevel = 18;
const _attrDescription = 5; // not answered -> Bad_AttributeIdInvalid

// --- NodeClass enum (service_types/enums.rs) --------------------------------
const _nodeClassVariable = 2;
const _nodeClassObject = 1;

// --- Standard node ids (types/node_ids.rs) ----------------------------------
const _objectsFolderId = 85;

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

/// Builds a BrowseRequest BODY (already past the leading type-id NodeId,
/// matching what the handler's `body` reader is positioned at) — i.e. just
/// the ViewDescription + requestedMaxReferencesPerNode + nodesToBrowse[].
///
/// ViewDescription (view_description.rs): viewId NodeId, timestamp DateTime,
/// viewVersion UInt32.
/// BrowseDescription (browse_description.rs): nodeId, browseDirection Int32
/// enum, referenceTypeId NodeId, includeSubtypes bool, nodeClassMask UInt32,
/// resultMask UInt32.
OpcUaReader _browseRequestBody({
  required List<OpcNodeId> nodesToBrowse,
  int resultMask = 0x3F, // all defined bits (browse_result_mask, generous)
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
    w.nodeId(const OpcNodeId.numeric(0, 35)); // referenceTypeId: Organizes
    w.boolean(true); // includeSubtypes
    w.uint32(0); // nodeClassMask: all
    w.uint32(resultMask);
  }
  return OpcUaReader(w.take());
}

/// ReadValueId (read_value_id.rs): nodeId, attributeId UInt32, indexRange
/// String, dataEncoding QualifiedName.
/// ReadRequest (read_request.rs): requestHeader(consumed by session), maxAge
/// Double, timestampsToReturn Int32 enum, nodesToRead[].
OpcUaReader _readRequestBody({
  required List<({OpcNodeId nodeId, int attributeId, String? indexRange})>
      toRead,
}) {
  final w = OpcUaWriter();
  w.float64(0); // maxAge
  w.int32(2); // timestampsToReturn: Both (arbitrary, unused by v1)
  w.int32(toRead.length);
  for (final r in toRead) {
    w.nodeId(r.nodeId);
    w.uint32(r.attributeId);
    w.string(r.indexRange);
    w.qualifiedName(const OpcQualifiedName(ns: 0, name: null)); // dataEncoding
  }
  return OpcUaReader(w.take());
}

/// WriteValue (write_value.rs): nodeId, attributeId UInt32, indexRange
/// String, value DataValue.
/// WriteRequest (write_request.rs): requestHeader(consumed), nodesToWrite[].
OpcUaReader _writeRequestBody({
  required List<
      ({
        OpcNodeId nodeId,
        int attributeId,
        String? indexRange,
        OpcVariant value,
      })> toWrite,
}) {
  final w = OpcUaWriter();
  w.int32(toWrite.length);
  for (final wv in toWrite) {
    w.nodeId(wv.nodeId);
    w.uint32(wv.attributeId);
    w.string(wv.indexRange);
    w.dataValue(OpcDataValue(variant: wv.value));
  }
  return OpcUaReader(w.take());
}

/// Builds a small fixture project with 3 mapped tags (bool RW, float RO, int
/// RW) + one unmapped tag to prove non-exposure.
PlcProject _buildProject() {
  final project = PlcProject(
    id: 'proj1',
    name: 'Test Project',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'StartPB',
        path: 'StartPB',
        dataType: 'BOOL',
        value: false,
        ioType: 'Internal',
      ),
      PlcTag(
        name: 'Temperature',
        path: 'Temperature',
        dataType: 'FLOAT64',
        value: 21.5,
        ioType: 'SimulatedOutput',
      ),
      PlcTag(
        name: 'Counter',
        path: 'Counter',
        dataType: 'INT32',
        value: 42,
        ioType: 'Internal',
      ),
      PlcTag(
        name: 'Hidden',
        path: 'Hidden',
        dataType: 'BOOL',
        value: true,
        ioType: 'Internal',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings(
    opcua: OpcUaProtocolConfig(
      enabled: true,
      namespaceUri: 'urn:test:proj1',
      map: OpcuaMap(
        namespaceUri: 'urn:test:proj1',
        nodes: [
          OpcuaNode(nodeId: 'ns=1;s=StartPB', tag: 'StartPB', access: 'ReadWrite'),
          OpcuaNode(nodeId: 'ns=1;s=Temperature', tag: 'Temperature', access: 'ReadOnly'),
          OpcuaNode(nodeId: 'ns=1;s=Counter', tag: 'Counter', access: 'ReadWrite'),
          // 'Hidden' tag deliberately NOT mapped.
        ],
      ),
    ),
  );
  return project;
}

/// Builds a project whose OPC UA map exposes [tagCount] flat root-level
/// variables — the large-address-space shape the size audit flagged: a single
/// Browse of Objects must serialize one ReferenceDescription per tag, which for
/// ~1400 tags overruns a 65536-byte negotiated send buffer in one un-chunked
/// frame. All tags are plain Internal ReadWrite ints; only the COUNT matters
/// for the size bound under test.
PlcProject _buildLargeRootProject(int tagCount) {
  final tags = <PlcTag>[];
  final nodes = <OpcuaNode>[];
  for (var i = 0; i < tagCount; i++) {
    final name = 'Tag${i.toString().padLeft(4, '0')}';
    tags.add(PlcTag(
      name: name,
      path: name,
      dataType: 'INT32',
      value: 0,
      ioType: 'Internal',
    ));
    nodes.add(OpcuaNode(nodeId: 'ns=1;s=$name', tag: name, access: 'ReadWrite'));
  }
  final project = PlcProject(
    id: 'proj_large',
    name: 'Large Address Space',
    controllerName: 'PLC_LARGE',
    tags: tags,
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings(
    opcua: OpcUaProtocolConfig(
      enabled: true,
      namespaceUri: 'urn:test:large',
      map: OpcuaMap(
        namespaceUri: 'urn:test:large',
        nodes: nodes,
      ),
    ),
  );
  return project;
}

/// Task 2 hardening fixture project: kept SEPARATE from [_buildProject]
/// because several existing tests above pin exact Browse reference counts
/// against that fixture's tag set — adding tags there would silently shift
/// those counts. This one has its own reserved `System` tag (own `access`
/// deliberately 'ReadWrite', isolating the NAME-based backstop rule from the
/// ordinary access-field rule) and a `SimulatedOutput` tag with a
/// deliberately writable map node (the decision-1 override carve-out).
PlcProject _buildHardeningProject() {
  final project = PlcProject(
    id: 'proj_hardening',
    name: 'Hardening Test Project',
    controllerName: 'PLC_HARDEN',
    tags: [
      PlcTag(name: 'System', path: 'System', dataType: 'INT32', value: 0, ioType: 'Internal', access: 'ReadWrite'),
      PlcTag(
          name: 'SimOutOverride',
          path: 'SimOutOverride',
          dataType: 'INT32',
          value: 9,
          ioType: 'SimulatedOutput'),
      PlcTag(name: 'Plain', path: 'Plain', dataType: 'INT32', value: 5, ioType: 'Internal'),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings(
    opcua: OpcUaProtocolConfig(
      enabled: true,
      namespaceUri: 'urn:test:harden',
      map: OpcuaMap(
        namespaceUri: 'urn:test:harden',
        nodes: [
          OpcuaNode(nodeId: 'ns=1;s=System', tag: 'System', access: 'ReadWrite'),
          OpcuaNode(nodeId: 'ns=1;s=SimOutOverride', tag: 'SimOutOverride', access: 'ReadWrite'),
          OpcuaNode(nodeId: 'ns=1;s=Plain', tag: 'Plain', access: 'ReadWrite'),
        ],
      ),
    ),
  );
  return project;
}

void main() {
  group('OpcUaAddressSpace.build', () {
    test('one Variable entry per map node, Objects folder organizes them', () {
      final project = _buildProject();
      final space = OpcUaAddressSpace.build(project);
      expect(space.children(const OpcNodeId.numeric(0, _objectsFolderId)), hasLength(3));
      final names = space
          .children(const OpcNodeId.numeric(0, _objectsFolderId))
          .map((e) => e.browseName)
          .toSet();
      expect(names, {'StartPB', 'Temperature', 'Counter'});
      expect(names.contains('Hidden'), isFalse);
    });

    test('parses both string and numeric node id forms, skips malformed', () {
      final project = PlcProject(
        id: 'p2',
        name: 'Test Project 2',
        controllerName: 'PLC_01',
        tags: [
          PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'B', path: 'B', dataType: 'INT16', value: 1, ioType: 'Internal'),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );
      project.protocols = ProtocolSettings(
        opcua: OpcUaProtocolConfig(
          enabled: true,
          namespaceUri: 'urn:test:p2',
          map: OpcuaMap(
            namespaceUri: 'urn:test:p2',
            nodes: [
              OpcuaNode(nodeId: 'ns=1;s=A', tag: 'A'),
              OpcuaNode(nodeId: 'ns=1;i=1000', tag: 'B'),
              OpcuaNode(nodeId: 'not-a-valid-node-id', tag: 'A'), // malformed -> skipped
            ],
          ),
        ),
      );
      final space = OpcUaAddressSpace.build(project);
      final children = space.children(const OpcNodeId.numeric(0, _objectsFolderId));
      expect(children, hasLength(2));
      expect(space.byNodeId(const OpcNodeId.string(1, 'A')), isNotNull);
      expect(space.byNodeId(const OpcNodeId.numeric(1, 1000)), isNotNull);
    });

    test('a map node whose tag does not exist in project.tags is skipped (dangling reference)', () {
      final project = PlcProject(
        id: 'p3',
        name: 'Test Project 3',
        controllerName: 'PLC_01',
        tags: [
          PlcTag(name: 'Real', path: 'Real', dataType: 'BOOL', value: false, ioType: 'Internal'),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );
      project.protocols = ProtocolSettings(
        opcua: OpcUaProtocolConfig(
          enabled: true,
          namespaceUri: 'urn:test:p3',
          map: OpcuaMap(
            namespaceUri: 'urn:test:p3',
            nodes: [
              OpcuaNode(nodeId: 'ns=1;s=Real', tag: 'Real'),
              // 'Ghost' does not exist in project.tags — dangling reference.
              OpcuaNode(nodeId: 'ns=1;s=Ghost', tag: 'Ghost'),
            ],
          ),
        ),
      );
      final space = OpcUaAddressSpace.build(project);
      final children = space.children(const OpcNodeId.numeric(0, _objectsFolderId));
      expect(children, hasLength(1));
      expect(children.single.browseName, 'Real');
      expect(space.byNodeId(const OpcNodeId.string(1, 'Real')), isNotNull);
      expect(space.byNodeId(const OpcNodeId.string(1, 'Ghost')), isNull);
    });
  });

  group('OpcUaProjectServices — direct handler calls', () {
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

    test('Browse Objects returns the standard Server object plus the 3 variables with right BrowseNames', () {
      // Task 2 (discovery): Browsing Objects now ALSO surfaces the standard
      // Server object (i=2253) ahead of the flat tag list — see
      // opcua_discovery_test.dart for the dedicated discovery-fix coverage;
      // this test just confirms the existing tag references still come
      // through unchanged alongside it.
      final body = _browseRequestBody(
        nodesToBrowse: [const OpcNodeId.numeric(0, _objectsFolderId)],
      );
      final respBody = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(respBody);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _browseResponseId);
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusGood);

      final resultCount = reader.int32();
      expect(resultCount, 1);
      final statusCode = reader.statusCode();
      expect(statusCode, _statusGood);
      final continuationPoint = reader.byteString();
      expect(continuationPoint, isNull);
      final refCount = reader.int32();
      expect(refCount, 4); // Server + StartPB + Temperature + Counter
      final names = <String>[];
      for (var i = 0; i < refCount; i++) {
        reader.nodeId(); // referenceTypeId
        final isForward = reader.boolean();
        expect(isForward, isTrue);
        reader.expandedNodeId(); // nodeId
        final browseName = reader.qualifiedName();
        names.add(browseName.name!);
        reader.localizedText(); // displayName
        final nodeClass = reader.int32();
        expect(nodeClass, browseName.name == 'Server' ? _nodeClassObject : _nodeClassVariable);
        reader.expandedNodeId(); // typeDefinition
      }
      final diagCount = reader.int32();
      expect(diagCount, -1);
      expect(names.toSet(), {'Server', 'StartPB', 'Temperature', 'Counter'});
    });

    test('Browse of a variable node returns an empty Good result', () {
      final space = OpcUaAddressSpace.build(project);
      final varNodeId = space.byNodeId(const OpcNodeId.string(1, 'StartPB'))!.nodeId;
      final body = _browseRequestBody(nodesToBrowse: [varNodeId]);
      final respBody = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(respBody);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1); // resultCount
      expect(reader.statusCode(), _statusGood);
      expect(reader.byteString(), isNull);
      expect(reader.int32(), 0); // refCount: empty
    });

    test('Browse of an unknown NodeId -> per-result Bad_NodeIdUnknown', () {
      final body = _browseRequestBody(
        nodesToBrowse: [const OpcNodeId.string(1, 'DoesNotExist')],
      );
      final respBody = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(respBody);
      reader.nodeId();
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusGood); // response itself is Good
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadNodeIdUnknown);
      reader.byteString();
      final refCount = reader.int32();
      expect(refCount <= 0, isTrue); // no references for an unknown node
    });

    test('empty nodesToBrowse -> serviceResult Bad_NothingToDo', () {
      final body = _browseRequestBody(nodesToBrowse: []);
      final respBody = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(respBody);
      reader.nodeId();
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusBadNothingToDo);
    });

    test('a dangling map-tag node is absent from Browse Objects and Read/Write of its node id -> Bad_NodeIdUnknown', () {
      // Add a map entry whose tag doesn't exist in project.tags, on top of
      // the standard fixture project (which has no such entry by default).
      project.protocols!.opcua!.map.nodes.add(
        OpcuaNode(nodeId: 'ns=1;s=Ghost', tag: 'Ghost'),
      );
      const danglingNodeId = OpcNodeId.string(1, 'Ghost');

      // Browse Objects: still exactly the 3 real variables, no 'Ghost'.
      final browseBody = _browseRequestBody(
        nodesToBrowse: [const OpcNodeId.numeric(0, _objectsFolderId)],
      );
      final browseResp = callHandler(_browseRequestId, browseBody)!;
      final browseReader = OpcUaReader(browseResp);
      browseReader.nodeId();
      browseReader.responseHeader();
      expect(browseReader.int32(), 1);
      expect(browseReader.statusCode(), _statusGood);
      browseReader.byteString();
      final refCount = browseReader.int32();
      final names = <String>[];
      for (var i = 0; i < refCount; i++) {
        browseReader.nodeId();
        browseReader.boolean();
        browseReader.expandedNodeId();
        names.add(browseReader.qualifiedName().name!);
        browseReader.localizedText();
        browseReader.int32();
        browseReader.expandedNodeId();
      }
      // Task 2 (discovery): Browse of Objects now also includes the standard
      // Server object — irrelevant to this test's "dangling tag" concern, so
      // just excluded from the set under test.
      expect(names.toSet(), {'Server', 'StartPB', 'Temperature', 'Counter'});
      expect(names.contains('Ghost'), isFalse);

      // Read of the dangling node id -> Bad_NodeIdUnknown.
      final readBody = _readRequestBody(
        toRead: [(nodeId: danglingNodeId, attributeId: _attrValue, indexRange: null)],
      );
      final readResp = callHandler(_readRequestId, readBody)!;
      final readReader = OpcUaReader(readResp);
      readReader.nodeId();
      readReader.responseHeader();
      readReader.int32();
      expect(readReader.dataValue().status, _statusBadNodeIdUnknown);

      // Write of the dangling node id -> Bad_NodeIdUnknown.
      final writeBody = _writeRequestBody(toWrite: [
        (nodeId: danglingNodeId, attributeId: _attrValue, indexRange: null, value: const OpcVariant(typeId: 1, value: true)),
      ]);
      final writeResp = callHandler(_writeRequestId, writeBody)!;
      final writeReader = OpcUaReader(writeResp);
      writeReader.nodeId();
      writeReader.responseHeader();
      writeReader.int32();
      expect(writeReader.statusCode(), _statusBadNodeIdUnknown);
    });

    test('Read Value returns live value; mutating the tag then re-reading shows the NEW value', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Counter'))!.nodeId;

      Uint8List readOnce() {
        final body = _readRequestBody(
          toRead: [(nodeId: nodeId, attributeId: _attrValue, indexRange: null)],
        );
        return callHandler(_readRequestId, body)!;
      }

      final firstResp = readOnce();
      final firstReader = OpcUaReader(firstResp);
      firstReader.nodeId();
      firstReader.responseHeader();
      expect(firstReader.int32(), 1); // resultCount
      final firstDv = firstReader.dataValue();
      expect(firstDv.status, _statusGood);
      expect(firstDv.variant!.typeId, 6); // Int32
      expect(firstDv.variant!.value, 42);
      expect(firstDv.serverTs, isNotNull);

      writePath(project, 'Counter', 99);

      final secondResp = readOnce();
      final secondReader = OpcUaReader(secondResp);
      secondReader.nodeId();
      secondReader.responseHeader();
      expect(secondReader.int32(), 1);
      final secondDv = secondReader.dataValue();
      expect(secondDv.variant!.value, 99);
    });

    test('sample() returns the live value; mutating the tag between two calls gives two different values', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Counter'))!.nodeId;

      final first = services.sample(nodeId);
      expect(first.status, _statusGood);
      expect(first.variant!.value, 42);

      writePath(project, 'Counter', 777);

      final second = services.sample(nodeId);
      expect(second.variant!.value, 777);
      expect(second.variant!.value, isNot(first.variant!.value));
    });

    test('sample() result equals a Read of the same node', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Temperature'))!.nodeId;

      final sampled = services.sample(nodeId);

      final body = _readRequestBody(
        toRead: [(nodeId: nodeId, attributeId: _attrValue, indexRange: null)],
      );
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      final readDv = reader.dataValue();

      expect(sampled.status, readDv.status);
      expect(sampled.variant, readDv.variant);
    });

    test('Read maps each dataType to the right Variant type', () {
      final space = OpcUaAddressSpace.build(project);
      final boolNodeId = space.byNodeId(const OpcNodeId.string(1, 'StartPB'))!.nodeId;
      final floatNodeId = space.byNodeId(const OpcNodeId.string(1, 'Temperature'))!.nodeId;

      final body = _readRequestBody(toRead: [
        (nodeId: boolNodeId, attributeId: _attrValue, indexRange: null),
        (nodeId: floatNodeId, attributeId: _attrValue, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 2);
      final boolDv = reader.dataValue();
      expect(boolDv.variant!.typeId, 1); // Boolean
      expect(boolDv.variant!.value, false);
      final floatDv = reader.dataValue();
      expect(floatDv.variant!.typeId, 11); // Double
      expect(floatDv.variant!.value, 21.5);
    });

    test('Read DisplayName/DataType/AccessLevel attributes answered from the space', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'StartPB'))!.nodeId;
      final body = _readRequestBody(toRead: [
        (nodeId: nodeId, attributeId: _attrDisplayName, indexRange: null),
        (nodeId: nodeId, attributeId: _attrDataType, indexRange: null),
        (nodeId: nodeId, attributeId: _attrAccessLevel, indexRange: null),
        (nodeId: nodeId, attributeId: _attrUserAccessLevel, indexRange: null),
        (nodeId: nodeId, attributeId: _attrBrowseName, indexRange: null),
        (nodeId: nodeId, attributeId: _attrNodeClass, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 6);

      final displayNameDv = reader.dataValue();
      expect(displayNameDv.status, _statusGood);
      final displayNameText = displayNameDv.variant!.value as OpcLocalizedText;
      expect(displayNameText.text, 'StartPB');

      final dataTypeDv = reader.dataValue();
      final dataTypeNodeId = dataTypeDv.variant!.value as OpcNodeId;
      expect(dataTypeNodeId, const OpcNodeId.numeric(0, 1)); // Boolean DataType

      final accessLevelDv = reader.dataValue();
      expect(accessLevelDv.variant!.value, 3); // CurrentRead|CurrentWrite (ReadWrite)

      final userAccessLevelDv = reader.dataValue();
      expect(userAccessLevelDv.variant!.value, 3);

      final browseNameDv = reader.dataValue();
      final browseNameQn = browseNameDv.variant!.value as OpcQualifiedName;
      expect(browseNameQn.name, 'StartPB');

      final nodeClassDv = reader.dataValue();
      expect(nodeClassDv.variant!.value, _nodeClassVariable);
    });

    test('Read AccessLevel on a ReadOnly node reports CurrentRead only', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Temperature'))!.nodeId;
      final body = _readRequestBody(toRead: [
        (nodeId: nodeId, attributeId: _attrAccessLevel, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      final dv = reader.dataValue();
      expect(dv.variant!.value, 1); // CurrentRead only
    });

    test('Read of an unsupported attribute -> Bad_AttributeIdInvalid per-result', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'StartPB'))!.nodeId;
      final body = _readRequestBody(toRead: [
        (nodeId: nodeId, attributeId: _attrDescription, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      final dv = reader.dataValue();
      expect(dv.status, _statusBadAttributeIdInvalid);
    });

    test('Read of an unknown NodeId -> Bad_NodeIdUnknown per-result', () {
      final body = _readRequestBody(toRead: [
        (nodeId: const OpcNodeId.string(1, 'DoesNotExist'), attributeId: _attrValue, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      final dv = reader.dataValue();
      expect(dv.status, _statusBadNodeIdUnknown);
    });

    test('Read with non-null indexRange -> Bad_IndexRangeInvalid per-result', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'StartPB'))!.nodeId;
      final body = _readRequestBody(toRead: [
        (nodeId: nodeId, attributeId: _attrValue, indexRange: '0:1'),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      final dv = reader.dataValue();
      expect(dv.status, _statusBadIndexRangeInvalid);
    });

    test('empty nodesToRead -> serviceResult Bad_NothingToDo', () {
      final body = _readRequestBody(toRead: []);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusBadNothingToDo);
    });

    test('Write to the bool ReadWrite node succeeds; readPath shows the new value', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'StartPB'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: nodeId,
          attributeId: _attrValue,
          indexRange: null,
          value: const OpcVariant(typeId: 1, value: true),
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      final typeId = reader.nodeId();
      expect(typeId.numericId, _writeResponseId);
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusGood);
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      expect(readPath(project, 'StartPB'), isTrue);
    });

    test('Write to the ReadOnly float node -> Bad_NotWritable, value unchanged', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Temperature'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: nodeId,
          attributeId: _attrValue,
          indexRange: null,
          value: const OpcVariant(typeId: 11, value: 999.0),
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadNotWritable);
      expect(readPath(project, 'Temperature'), 21.5);
    });

    test('Write to a FORCED tag -> Bad_UserAccessDenied, value unchanged', () {
      final space = OpcUaAddressSpace.build(project);
      final counterTag = project.tags.firstWhere((t) => t.name == 'Counter');
      counterTag.isForced = true;
      counterTag.forcedValue = 42;

      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Counter'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: nodeId,
          attributeId: _attrValue,
          indexRange: null,
          value: const OpcVariant(typeId: 6, value: 123),
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadUserAccessDenied);
      expect(readPath(project, 'Counter'), 42);
    });

    test('Write a Double variant into an INT32 RW node succeeds via numeric coercion (truncates toward zero)', () {
      // Documented coercion rule: any non-Boolean, non-String numeric Variant
      // type (SByte/Byte/Int16/UInt16/Int32/UInt32/Int64/UInt64/Float/Double)
      // coerces into any numeric tag dataType (rounds toward zero into
      // integer targets). Boolean and String never cross-coerce with numerics
      // or each other.
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Counter'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: nodeId,
          attributeId: _attrValue,
          indexRange: null,
          // Double variant (typeId 11) into an INT32 tag: coerces via truncation.
          value: const OpcVariant(typeId: 11, value: 7.9),
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusGood);
      expect(readPath(project, 'Counter'), 7);
    });

    test('Write a Boolean variant into an INT32 RW node -> Bad_TypeMismatch (no coercion across kinds)', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Counter'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: nodeId,
          attributeId: _attrValue,
          indexRange: null,
          value: const OpcVariant(typeId: 1, value: true), // Boolean
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusBadTypeMismatch);
      expect(readPath(project, 'Counter'), 42); // unchanged
    });

    test('Write a String variant into the BOOL RW node -> Bad_TypeMismatch', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'StartPB'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: nodeId,
          attributeId: _attrValue,
          indexRange: null,
          value: const OpcVariant(typeId: 12, value: 'nope'), // String
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusBadTypeMismatch);
      expect(readPath(project, 'StartPB'), isFalse);
    });

    test('Write to an unknown NodeId -> Bad_NodeIdUnknown per-result', () {
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: const OpcNodeId.string(1, 'DoesNotExist'),
          attributeId: _attrValue,
          indexRange: null,
          value: const OpcVariant(typeId: 1, value: true),
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusBadNodeIdUnknown);
    });

    test('Write with a non-Value attribute -> Bad_AttributeIdInvalid per-result', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'StartPB'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: nodeId,
          attributeId: _attrDisplayName,
          indexRange: null,
          value: const OpcVariant(typeId: 1, value: true),
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusBadAttributeIdInvalid);
    });

    test('Write with non-null indexRange -> Bad_IndexRangeInvalid per-result, value unchanged', () {
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Counter'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (
          nodeId: nodeId,
          attributeId: _attrValue,
          indexRange: '0:1',
          value: const OpcVariant(typeId: 6, value: 7),
        ),
      ]);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      reader.int32();
      expect(reader.statusCode(), _statusBadIndexRangeInvalid);
      expect(readPath(project, 'Counter'), 42);
    });

    test('empty nodesToWrite -> serviceResult Bad_NothingToDo', () {
      final body = _writeRequestBody(toWrite: []);
      final resp = callHandler(_writeRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      final header = reader.responseHeader();
      expect(header.serviceResult, _statusBadNothingToDo);
    });

    test('projectProvider swap: a new project instance is used on the next call (live, not cached forever)', () {
      final project2 = _buildProject();
      writePath(project2, 'Counter', 12345);
      var current = project;
      final swappableServices = OpcUaProjectServices(projectProvider: () => current);
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Counter'))!.nodeId;

      Uint8List readOnce(OpcUaProjectServices svc) {
        final h = _reqHeader();
        final body = _readRequestBody(
          toRead: [(nodeId: nodeId, attributeId: _attrValue, indexRange: null)],
        );
        return svc.handle(_readRequestId, body, h, _respondBuilder(h))!;
      }

      final firstReader = OpcUaReader(readOnce(swappableServices));
      firstReader.nodeId();
      firstReader.responseHeader();
      firstReader.int32();
      expect(firstReader.dataValue().variant!.value, 42);

      current = project2;
      final secondReader = OpcUaReader(readOnce(swappableServices));
      secondReader.nodeId();
      secondReader.responseHeader();
      secondReader.int32();
      expect(secondReader.dataValue().variant!.value, 12345);
    });
  });

  group('Task 2 hardening: write-time backstop', () {
    test(
        'Write to a WRITABLE map node pointing at the System tag is refused with Bad_UserAccessDenied, '
        'value unchanged (the map node alone would otherwise allow this write)', () {
      final project = _buildHardeningProject();
      final services = OpcUaProjectServices(projectProvider: () => project);
      final systemTag = project.tags.firstWhere((t) => t.name == 'System');
      expect(systemTag.access, 'ReadWrite', reason: "the tag's OWN access is deliberately not ReadOnly");

      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'System'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (nodeId: nodeId, attributeId: _attrValue, indexRange: null, value: const OpcVariant(typeId: 6, value: 999)),
      ]);
      final h = _reqHeader();
      final resp = services.handle(_writeRequestId, body, h, _respondBuilder(h))!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusBadUserAccessDenied);
      expect(readPath(project, 'System'), 0);
    });

    test('Write to a WRITABLE map node pointing at a SimulatedOutput tag still succeeds '
        '(deliberate override survives)', () {
      final project = _buildHardeningProject();
      final services = OpcUaProjectServices(projectProvider: () => project);
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'SimOutOverride'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (nodeId: nodeId, attributeId: _attrValue, indexRange: null, value: const OpcVariant(typeId: 6, value: 321)),
      ]);
      final h = _reqHeader();
      final resp = services.handle(_writeRequestId, body, h, _respondBuilder(h))!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      expect(readPath(project, 'SimOutOverride'), 321);
    });

    test('a normal Internal ReadWrite tag still writes successfully — the backstop is not over-broad', () {
      final project = _buildHardeningProject();
      final services = OpcUaProjectServices(projectProvider: () => project);
      final space = OpcUaAddressSpace.build(project);
      final nodeId = space.byNodeId(const OpcNodeId.string(1, 'Plain'))!.nodeId;
      final body = _writeRequestBody(toWrite: [
        (nodeId: nodeId, attributeId: _attrValue, indexRange: null, value: const OpcVariant(typeId: 6, value: 77)),
      ]);
      final h = _reqHeader();
      final resp = services.handle(_writeRequestId, body, h, _respondBuilder(h))!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      expect(readPath(project, 'Plain'), 77);
    });
  });

  group('Full-stack through OpcUaServerSession', () {
    const info = OpcUaServerInfo(
      applicationName: 'Mobile Soft PLC',
      applicationUri: 'urn:mobile-soft-plc:server',
      endpointUrl: 'opc.tcp://127.0.0.1:4840',
      namespaceUri: 'urn:mobile-soft-plc:tags',
    );

    Uint8List buildTestHello() => const HelloMessage(
          protocolVersion: 0,
          receiveBufferSize: 65536,
          sendBufferSize: 65536,
          maxMessageSize: 0,
          maxChunkCount: 0,
          endpointUrl: 'opc.tcp://127.0.0.1:4840',
        ).build();

    Uint8List buildTestOpn(int seq, int reqId) {
      final w = OpcUaWriter();
      w.nodeId(const OpcNodeId.numeric(0, _openSecureChannelRequestId));
      w.requestHeader(_reqHeader());
      w.uint32(0); // clientProtocolVersion
      w.int32(0); // requestType: Issue
      w.int32(1); // securityMode: None
      w.byteString(null); // clientNonce
      w.uint32(60000); // requestedLifetime
      return buildOpnChunk(
        secureChannelId: 0,
        securityPolicyUri: kSecurityPolicyNoneUri,
        sequenceNumber: seq,
        requestId: reqId,
        body: w.take(),
      );
    }

    Uint8List buildTestCreateSession(int channelId, int tokenId, int seq, int reqId) {
      final w = OpcUaWriter();
      w.nodeId(const OpcNodeId.numeric(0, _createSessionRequestId));
      w.requestHeader(_reqHeader());
      w.string('urn:test:client');
      w.string('urn:test:client:product');
      w.localizedText(const OpcLocalizedText(text: 'Test Client'));
      w.int32(1);
      w.string(null);
      w.string(null);
      w.int32(-1);
      w.string(null);
      w.string('opc.tcp://127.0.0.1:4840');
      w.string('test-session');
      w.byteString(null);
      w.byteString(null);
      w.float64(1200000);
      w.uint32(0);
      return buildMsgChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: seq,
        requestId: reqId,
        body: w.take(),
      );
    }

    Uint8List buildTestActivateSession(
      int channelId,
      int tokenId,
      int seq,
      int reqId,
      OpcNodeId authToken,
    ) {
      final w = OpcUaWriter();
      w.nodeId(const OpcNodeId.numeric(0, _activateSessionRequestId));
      w.requestHeader(_reqHeader(authToken: authToken));
      w.string(null);
      w.byteString(null);
      w.int32(-1);
      w.int32(-1);
      final tokenWriter = OpcUaWriter();
      tokenWriter.string('anonymous');
      w.extensionObjectHeader(const OpcNodeId.numeric(0, 321), hasBody: true);
      w.byteString(tokenWriter.take());
      w.string(null);
      w.byteString(null);
      return buildMsgChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: seq,
        requestId: reqId,
        body: w.take(),
      );
    }

    Uint8List buildTestBrowseObjects(
      int channelId,
      int tokenId,
      int seq,
      int reqId,
      OpcNodeId authToken,
    ) {
      final w = OpcUaWriter();
      w.nodeId(const OpcNodeId.numeric(0, _browseRequestId));
      w.requestHeader(_reqHeader(authToken: authToken));
      final bodyReader = _browseRequestBody(
        nodesToBrowse: [const OpcNodeId.numeric(0, _objectsFolderId)],
      );
      // _browseRequestBody already produced fully-formed bytes for
      // everything after the type-id NodeId + RequestHeader — append them.
      final remaining = bodyReader._data();
      return buildMsgChunk(
        secureChannelId: channelId,
        tokenId: tokenId,
        sequenceNumber: seq,
        requestId: reqId,
        body: Uint8List.fromList([...w.take(), ...remaining]),
      );
    }

    test('after activation, a Browse via onBytes returns Server + the 3 variables (proves handler wiring)', () {
      final project = _buildProject();
      final services = OpcUaProjectServices(projectProvider: () => project);
      final session = OpcUaServerSession(info: info, services: services);

      session.onBytes(buildTestHello(), 0);
      final opnFrames = session.onBytes(buildTestOpn(1, 10), 0);
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final createFrames = session.onBytes(buildTestCreateSession(channelId, tokenId, 2, 11), 0);
      final createReader = OpcUaReader(parseChunk(createFrames.single).body);
      createReader.nodeId();
      createReader.responseHeader();
      final sessionId = createReader.nodeId();
      final authToken = createReader.nodeId();
      expect(sessionId, isNotNull);

      session.onBytes(buildTestActivateSession(channelId, tokenId, 3, 12, authToken), 0);

      final browseFrames =
          session.onBytes(buildTestBrowseObjects(channelId, tokenId, 4, 13, authToken), 0);
      expect(browseFrames, hasLength(1));
      final respChunk = parseChunk(browseFrames.single);
      final respReader = OpcUaReader(respChunk.body);
      final typeId = respReader.nodeId();
      expect(typeId.numericId, _browseResponseId);
      final header = respReader.responseHeader();
      expect(header.serviceResult, _statusGood);
      expect(respReader.int32(), 1); // resultCount
      expect(respReader.statusCode(), _statusGood);
      respReader.byteString();
      final refCount = respReader.int32();
      expect(refCount, 4); // Server + StartPB + Temperature + Counter (Task 2)
    });

    // --- Negotiated send-buffer ceiling (audit: an oversize Browse) ---------

    /// Drives a full HEL/OPN/CreateSession/ActivateSession handshake against a
    /// fresh session for [project], negotiating [clientReceiveBufferSize] as
    /// the client's receive buffer (which becomes the server's SEND ceiling),
    /// then issues a single Browse of the Objects folder and returns the raw
    /// response frame(s).
    List<Uint8List> runBrowseObjects(
      PlcProject project, {
      required int clientReceiveBufferSize,
    }) {
      final services = OpcUaProjectServices(projectProvider: () => project);
      final session = OpcUaServerSession(info: info, services: services);

      final hello = HelloMessage(
        protocolVersion: 0,
        receiveBufferSize: clientReceiveBufferSize,
        sendBufferSize: 65536,
        maxMessageSize: 0,
        maxChunkCount: 0,
        endpointUrl: 'opc.tcp://127.0.0.1:4840',
      ).build();
      session.onBytes(hello, 0);

      final opnFrames = session.onBytes(buildTestOpn(1, 10), 0);
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final createFrames =
          session.onBytes(buildTestCreateSession(channelId, tokenId, 2, 11), 0);
      final createReader = OpcUaReader(parseChunk(createFrames.single).body);
      createReader.nodeId();
      createReader.responseHeader();
      createReader.nodeId(); // sessionId
      final authToken = createReader.nodeId();

      session.onBytes(
          buildTestActivateSession(channelId, tokenId, 3, 12, authToken), 0);
      return session.onBytes(
          buildTestBrowseObjects(channelId, tokenId, 4, 13, authToken), 0);
    }

    test('a small Browse under the negotiated buffer is unchanged (Ignition path)', () {
      final frames = runBrowseObjects(_buildProject(), clientReceiveBufferSize: 65536);
      expect(frames, hasLength(1));
      final frame = frames.single;
      expect(frame.length, lessThanOrEqualTo(65536));
      final r = OpcUaReader(parseChunk(frame).body);
      expect(r.nodeId().numericId, _browseResponseId); // NOT a ServiceFault
      expect(r.responseHeader().serviceResult, _statusGood);
      expect(r.int32(), 1); // one BrowseResult
      expect(r.statusCode(), _statusGood);
    });

    test('Browse of a ~1400-tag address space over a 65536 buffer -> Bad_ResponseTooLarge, never an oversize frame', () {
      final frames =
          runBrowseObjects(_buildLargeRootProject(1400), clientReceiveBufferSize: 65536);
      expect(frames, hasLength(1));
      final frame = frames.single;
      // The invariant the audit demands: we NEVER put more bytes on the wire
      // than the client agreed to receive.
      expect(frame.length, lessThanOrEqualTo(65536));
      final r = OpcUaReader(parseChunk(frame).body);
      expect(r.nodeId().numericId, _serviceFaultId);
      final header = r.responseHeader();
      expect(header.serviceResult, _statusBadResponseTooLarge);
      expect(header.requestHandle, 1); // echoed from the request header
    });

    test('the ceiling is honored at byte granularity: fits at L, faults at L-1', () {
      final project = _buildLargeRootProject(1400);

      // With a 1 MB buffer the full Browse is emitted un-faulted; capture its
      // exact frame length L. This ALSO proves the dataset genuinely overruns
      // a 65536 buffer (so the fault test above is exercising a real overflow).
      final bigFrames = runBrowseObjects(project, clientReceiveBufferSize: 1048576);
      expect(bigFrames, hasLength(1));
      final l = bigFrames.single.length;
      expect(l, greaterThan(65536));
      expect(OpcUaReader(parseChunk(bigFrames.single).body).nodeId().numericId,
          _browseResponseId);

      // Negotiating exactly L: the frame fits (length == ceiling, not over) and
      // is emitted unchanged — the same L bytes, a real BrowseResponse.
      final atLimit = runBrowseObjects(project, clientReceiveBufferSize: l);
      expect(atLimit.single.length, l);
      expect(OpcUaReader(parseChunk(atLimit.single).body).nodeId().numericId,
          _browseResponseId);

      // One byte tighter and the same Browse must fail loud, not overrun.
      final overLimit = runBrowseObjects(project, clientReceiveBufferSize: l - 1);
      expect(overLimit.single.length, lessThanOrEqualTo(l - 1));
      final r = OpcUaReader(parseChunk(overLimit.single).body);
      expect(r.nodeId().numericId, _serviceFaultId);
      expect(r.responseHeader().serviceResult, _statusBadResponseTooLarge);
    });
  });
}

extension on OpcUaReader {
  /// Test-only helper: exposes the remaining unread bytes of this reader so
  /// the full-stack test can append an already-built request body (built via
  /// `_browseRequestBody`, which returns a reader over the WHOLE body) after
  /// its own type-id NodeId + RequestHeader when constructing a raw MSG
  /// chunk. Implemented by re-reading everything remaining as raw bytes.
  Uint8List _data() {
    final bytes = <int>[];
    while (!atEnd) {
      bytes.add(uint8());
    }
    return Uint8List.fromList(bytes);
  }
}
