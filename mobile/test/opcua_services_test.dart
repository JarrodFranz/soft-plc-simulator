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

// --- StatusCodes, verified against types/status_codes.rs --------------------
const _statusGood = 0;
const _statusBadNodeIdUnknown = 0x80340000;
const _statusBadAttributeIdInvalid = 0x80350000;
const _statusBadIndexRangeInvalid = 0x80360000;
const _statusBadNotWritable = 0x803B0000;
const _statusBadUserAccessDenied = 0x801F0000;
const _statusBadTypeMismatch = 0x80740000;
const _statusBadNothingToDo = 0x800F0000;

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

    test('Browse Objects returns exactly the 3 variables with right BrowseNames', () {
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
      expect(refCount, 3);
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
        expect(nodeClass, _nodeClassVariable);
        reader.expandedNodeId(); // typeDefinition
      }
      final diagCount = reader.int32();
      expect(diagCount, -1);
      expect(names.toSet(), {'StartPB', 'Temperature', 'Counter'});
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

    test('Write an Int32 variant into the FLOAT64 RO... (type coercion group): '
        'coercible numeric variant into an INT32 RW node succeeds via numeric coercion', () {
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

    test('after activation, a Browse via onBytes returns the 3 variables (proves handler wiring)', () {
      final project = _buildProject();
      final services = OpcUaProjectServices(projectProvider: () => project);
      final session = OpcUaServerSession(info: info, services: services);

      session.onBytes(buildTestHello());
      final opnFrames = session.onBytes(buildTestOpn(1, 10));
      final opnReader = OpcUaReader(parseChunk(opnFrames.single).body);
      opnReader.nodeId();
      opnReader.responseHeader();
      opnReader.uint32();
      final channelId = opnReader.uint32();
      final tokenId = opnReader.uint32();

      final createFrames = session.onBytes(buildTestCreateSession(channelId, tokenId, 2, 11));
      final createReader = OpcUaReader(parseChunk(createFrames.single).body);
      createReader.nodeId();
      createReader.responseHeader();
      final sessionId = createReader.nodeId();
      final authToken = createReader.nodeId();
      expect(sessionId, isNotNull);

      session.onBytes(buildTestActivateSession(channelId, tokenId, 3, 12, authToken));

      final browseFrames =
          session.onBytes(buildTestBrowseObjects(channelId, tokenId, 4, 13, authToken));
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
      expect(refCount, 3);
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
