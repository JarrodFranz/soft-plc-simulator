// Tests for Task 2 (serve folder nodes): browsing Objects lists folder
// Object nodes (FolderType) alongside root variables, browsing a folder node
// lists its variables, and Read of a folder node answers its
// NodeClass/BrowseName/DisplayName attributes — see
// mobile/lib/protocols/opcua/opcua_services.dart (_writeBrowseResult,
// _readAttribute) and mobile/lib/protocols/opcua/opcua_address_space.dart
// (childFolders/folderNodeId/isFolderNode/folderNameOf/children — Task 1).
//
// Harness (request/response codec helpers) copied from
// opcua_services_test.dart — same pattern, no hand-rolled hex.
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

// --- AttributeIds, verified against types/attribute.rs ----------------------
const _attrNodeClass = 2;
const _attrBrowseName = 3;
const _attrDisplayName = 4;

// --- NodeClass enum (service_types/enums.rs) --------------------------------
const _nodeClassObject = 1;
const _nodeClassVariable = 2;

// --- Standard node ids (types/node_ids.rs) -----------------------------------
const _objectsFolderId = 85; // node_ids.rs:1608
const _organizesId = 35; // node_ids.rs:849
const _folderTypeId = 61; // node_ids.rs:975

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

/// Builds a BrowseRequest BODY — see opcua_services_test.dart's identical
/// helper for the field-order doc.
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

/// Fixture project: one root (no-folder) tag `Root1` + one folder `Ramp1`
/// holding a single tag `R1`, per the brief.
PlcProject _buildProject() {
  final project = PlcProject(
    id: 'proj-folder',
    name: 'Folder Test Project',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(name: 'Root1', path: 'Root1', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(
        name: 'R1',
        path: 'R1',
        dataType: 'FLOAT64',
        value: 1.5,
        ioType: 'Internal',
        folder: 'Ramp1',
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
      namespaceUri: 'urn:test:folder',
      map: OpcuaMap(
        namespaceUri: 'urn:test:folder',
        nodes: [
          OpcuaNode(nodeId: 'ns=1;s=Root1', tag: 'Root1', access: 'ReadWrite'),
          OpcuaNode(nodeId: 'ns=1;s=R1', tag: 'R1', access: 'ReadWrite'),
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

  group('Browse Objects with a folder', () {
    test('returns Server + root variable Root1 + a FolderType Object ref for Ramp1', () {
      final body = _browseRequestBody(nodesToBrowse: [const OpcNodeId.numeric(0, _objectsFolderId)]);
      final resp = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1); // resultCount
      expect(reader.statusCode(), _statusGood);
      reader.byteString(); // continuationPoint
      final refCount = reader.int32();
      expect(refCount, 3); // Server + Root1 + Ramp1(folder)

      OpcNodeId? folderTarget;
      OpcQualifiedName? folderBrowseName;
      OpcLocalizedText? folderDisplayName;
      int? folderNodeClass;
      OpcNodeId? folderTypeDefinition;
      final rootVarNames = <String>[];

      for (var i = 0; i < refCount; i++) {
        reader.nodeId(); // referenceTypeId
        expect(reader.boolean(), isTrue); // isForward
        final target = reader.expandedNodeId();
        final browseName = reader.qualifiedName();
        final displayName = reader.localizedText();
        final nodeClass = reader.int32();
        final typeDefinition = reader.expandedNodeId();

        if (browseName.name == 'Ramp1') {
          folderTarget = target;
          folderBrowseName = browseName;
          folderDisplayName = displayName;
          folderNodeClass = nodeClass;
          folderTypeDefinition = typeDefinition;
        } else if (browseName.name == 'Root1') {
          rootVarNames.add(browseName.name!);
        }
      }

      expect(rootVarNames, ['Root1']);
      expect(folderBrowseName, isNotNull);
      expect(folderNodeClass, _nodeClassObject);
      expect(folderTypeDefinition, const OpcNodeId.numeric(0, _folderTypeId));
      expect(folderTarget, const OpcNodeId.string(1, '__folder__/Ramp1'));
      expect(folderDisplayName!.text, 'Ramp1');
    });
  });

  group('Browse the folder node itself', () {
    test('ns=1;s=__folder__/Ramp1 returns its variable R1 (NodeClass Variable)', () {
      const folderNodeId = OpcNodeId.string(1, '__folder__/Ramp1');
      final body = _browseRequestBody(nodesToBrowse: [folderNodeId]);
      final resp = callHandler(_browseRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 1);
      expect(reader.statusCode(), _statusGood);
      reader.byteString();
      final refCount = reader.int32();
      expect(refCount, 1); // just R1

      reader.nodeId(); // referenceTypeId
      expect(reader.boolean(), isTrue); // isForward
      final target = reader.expandedNodeId();
      final browseName = reader.qualifiedName();
      reader.localizedText(); // displayName
      final nodeClass = reader.int32();
      reader.expandedNodeId(); // typeDefinition

      expect(target, const OpcNodeId.string(1, 'R1'));
      expect(browseName.name, 'R1');
      expect(nodeClass, _nodeClassVariable);
    });
  });

  group('Read attributes of the folder node', () {
    test('NodeClass -> Int32 Object(1); BrowseName -> QualifiedName(ns:1,"Ramp1"); DisplayName -> LocalizedText("Ramp1")', () {
      const folderNodeId = OpcNodeId.string(1, '__folder__/Ramp1');
      final body = _readRequestBody(toRead: [
        (nodeId: folderNodeId, attributeId: _attrNodeClass, indexRange: null),
        (nodeId: folderNodeId, attributeId: _attrBrowseName, indexRange: null),
        (nodeId: folderNodeId, attributeId: _attrDisplayName, indexRange: null),
      ]);
      final resp = callHandler(_readRequestId, body)!;
      final reader = OpcUaReader(resp);
      reader.nodeId();
      reader.responseHeader();
      expect(reader.int32(), 3);

      final nodeClassDv = reader.dataValue();
      expect(nodeClassDv.status, _statusGood);
      expect(nodeClassDv.variant!.typeId, 6); // Int32
      expect(nodeClassDv.variant!.value, _nodeClassObject);

      final browseNameDv = reader.dataValue();
      expect(browseNameDv.status, _statusGood);
      final qn = browseNameDv.variant!.value as OpcQualifiedName;
      expect(qn.ns, 1);
      expect(qn.name, 'Ramp1');

      final displayNameDv = reader.dataValue();
      expect(displayNameDv.status, _statusGood);
      final lt = displayNameDv.variant!.value as OpcLocalizedText;
      expect(lt.text, 'Ramp1');
    });
  });
}
