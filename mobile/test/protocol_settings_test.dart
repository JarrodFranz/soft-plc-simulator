// Tests for the per-project ProtocolSettings model (WS17 Task 1):
// - OpcUaProtocolConfig / ProtocolSettings toJson<->fromJson round-trips.
// - Back-compat migration of the old top-level `opcua_map` field into
//   `protocols.opcua`.
// - PlcProject.protocols round-trips losslessly.
// - ProtocolSettings.defaults(project) builds sane defaults.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';

void main() {
  group('OpcUaProtocolConfig.toJson / fromJson', () {
    test('round-trips enabled=true with namespaceUri and nodes', () {
      final cfg = OpcUaProtocolConfig(
        enabled: true,
        namespaceUri: 'urn:softplc:test',
        map: OpcuaMap(
          namespaceUri: 'urn:softplc:test',
          nodes: [
            OpcuaNode(nodeId: 'ns=1;s=Start_PB', tag: 'Start_PB', access: 'ReadWrite'),
            OpcuaNode(nodeId: 'ns=1;s=Motor_Run', tag: 'Motor_Run', access: 'ReadOnly'),
          ],
        ),
      );

      final rt = OpcUaProtocolConfig.fromJson(cfg.toJson());

      expect(rt.enabled, isTrue);
      expect(rt.namespaceUri, 'urn:softplc:test');
      expect(rt.map.namespaceUri, cfg.map.namespaceUri);
      expect(rt.map.nodes.length, 2);
      expect(rt.map.nodes[0].nodeId, 'ns=1;s=Start_PB');
      expect(rt.map.nodes[0].tag, 'Start_PB');
      expect(rt.map.nodes[0].access, 'ReadWrite');
      expect(rt.map.nodes[1].nodeId, 'ns=1;s=Motor_Run');
      expect(rt.map.nodes[1].tag, 'Motor_Run');
      expect(rt.map.nodes[1].access, 'ReadOnly');
    });

    test('round-trips enabled=false with an empty map', () {
      final cfg = OpcUaProtocolConfig(
        enabled: false,
        namespaceUri: '',
        map: OpcuaMap(namespaceUri: '', nodes: []),
      );

      final rt = OpcUaProtocolConfig.fromJson(cfg.toJson());

      expect(rt.enabled, isFalse);
      expect(rt.namespaceUri, '');
      expect(rt.map.nodes, isEmpty);
    });

    test('fromJson tolerates a missing map key', () {
      final cfg = OpcUaProtocolConfig.fromJson({'enabled': true, 'namespace_uri': 'urn:x'});
      expect(cfg.enabled, isTrue);
      expect(cfg.namespaceUri, 'urn:x');
      expect(cfg.map.nodes, isEmpty);
    });
  });

  group('ProtocolSettings.toJson / fromJson', () {
    test('round-trips gatewayUrl and opcua config', () {
      final settings = ProtocolSettings(
        gatewayUrl: 'ws://localhost:9999',
        opcua: OpcUaProtocolConfig(
          enabled: true,
          namespaceUri: 'urn:softplc:test',
          map: OpcuaMap(namespaceUri: 'urn:softplc:test', nodes: [
            OpcuaNode(nodeId: 'ns=1;s=Tag1', tag: 'Tag1', access: 'ReadWrite'),
          ]),
        ),
      );

      final rt = ProtocolSettings.fromJson(settings.toJson());

      expect(rt.gatewayUrl, 'ws://localhost:9999');
      expect(rt.opcua, isNotNull);
      expect(rt.opcua!.enabled, isTrue);
      expect(rt.opcua!.map.nodes.length, 1);
    });

    test('fromJson defaults gatewayUrl when missing', () {
      final settings = ProtocolSettings.fromJson({});
      expect(settings.gatewayUrl, kDefaultGatewayUrl);
      expect(settings.opcua, isNull);
    });

    test('kDefaultGatewayUrl is the expected default endpoint', () {
      expect(kDefaultGatewayUrl, 'ws://localhost:4855');
    });
  });

  group('PlcProject.fromJson migration of legacy top-level opcua_map', () {
    PlcProject buildProject() => PlcProject(
          id: 'migrate_proj',
          name: 'Migrate Project',
          controllerName: 'PLC_MIGRATE',
          tags: [],
          structDefs: [],
          programs: [],
          tasks: [],
          hmis: [],
        );

    test('legacy opcua_map with no protocols migrates into protocols.opcua', () {
      final legacyJson = {
        'project': {
          'id': 'legacy_proj',
          'name': 'Legacy Project',
          'controller': {'name': 'PLC_01', 'scan_period_ms': 100},
          'tags': [],
          'struct_defs': [],
          'programs': [],
          'tasks': [],
          'hmis': [],
          'opcua_map': {
            'namespace_uri': 'urn:softplc:legacy_proj',
            'nodes': [
              {'node_id': 'ns=1;s=Start_PB', 'tag': 'Start_PB', 'access': 'ReadWrite'},
              {'node_id': 'ns=1;s=Stop_PB', 'tag': 'Stop_PB', 'access': 'ReadWrite'},
              {'node_id': 'ns=1;s=Motor_Run', 'tag': 'Motor_Run', 'access': 'ReadOnly'},
            ],
          },
        },
      };

      final project = PlcProject.fromJson(legacyJson);

      expect(project.protocols, isNotNull);
      expect(project.protocols!.opcua, isNotNull);
      expect(project.protocols!.opcua!.enabled, isTrue);
      expect(project.protocols!.opcua!.namespaceUri, 'urn:softplc:legacy_proj');
      expect(project.protocols!.opcua!.map.nodes.length, 3);
      expect(project.protocols!.opcua!.map.nodes[0].tag, 'Start_PB');
      expect(project.protocols!.opcua!.map.nodes[2].access, 'ReadOnly');
    });

    test('neither protocols nor opcua_map present -> protocols is null', () {
      final project = buildProject();
      final restored = PlcProject.fromJson(jsonDecode(jsonEncode(project.toJson())));
      expect(restored.protocols, isNull);
    });

    test('project with protocols already present parses as-is (no migration)', () {
      final json = {
        'project': {
          'id': 'proto_proj',
          'name': 'Protocols Project',
          'controller': {'name': 'PLC_01', 'scan_period_ms': 100},
          'tags': [],
          'struct_defs': [],
          'programs': [],
          'tasks': [],
          'hmis': [],
          'protocols': {
            'gateway_url': 'ws://localhost:1234',
            'opcua': {
              'enabled': false,
              'namespace_uri': 'urn:softplc:proto_proj',
              'map': {
                'opcua_map': {'namespace_uri': 'urn:softplc:proto_proj', 'nodes': []},
              },
            },
          },
        },
      };

      final project = PlcProject.fromJson(json);

      expect(project.protocols, isNotNull);
      expect(project.protocols!.gatewayUrl, 'ws://localhost:1234');
      expect(project.protocols!.opcua!.enabled, isFalse);
    });
  });

  group('PlcProject.protocols round-trip', () {
    PlcProject buildProject() => PlcProject(
          id: 'rt_proj',
          name: 'Round Trip Project',
          controllerName: 'PLC_RT',
          tags: [
            PlcTag(
              name: 'Start_PB',
              path: 'Inputs/Start_PB',
              dataType: 'BOOL',
              value: false,
              ioType: 'SimulatedInput',
            ),
            PlcTag(
              name: 'Motor_Run',
              path: 'Outputs/Motor_Run',
              dataType: 'BOOL',
              value: false,
              ioType: 'SimulatedOutput',
            ),
          ],
          structDefs: [],
          programs: [],
          tasks: [],
          hmis: [],
        );

    test('populated protocols round-trips losslessly through jsonEncode/decode', () {
      final project = buildProject();
      project.protocols = ProtocolSettings(
        gatewayUrl: 'ws://localhost:4855',
        opcua: OpcUaProtocolConfig(
          enabled: true,
          namespaceUri: 'urn:softplc:rt_proj',
          map: OpcuaMap.autoGenerate(project),
        ),
      );

      final restored = PlcProject.fromJson(jsonDecode(jsonEncode(project.toJson())));

      expect(restored.protocols, isNotNull);
      expect(restored.protocols!.gatewayUrl, project.protocols!.gatewayUrl);
      expect(restored.protocols!.opcua!.enabled, project.protocols!.opcua!.enabled);
      expect(restored.protocols!.opcua!.map.nodes.length, project.protocols!.opcua!.map.nodes.length);
    });

    test('protocols == null round-trips to null and omits the key (back-compat)', () {
      final project = buildProject();
      expect(project.protocols, isNull);

      final json = project.toJson();
      expect((json['project'] as Map).containsKey('protocols'), isFalse);
      expect((json['project'] as Map).containsKey('opcua_map'), isFalse);

      final restored = PlcProject.fromJson(jsonDecode(jsonEncode(json)));
      expect(restored.protocols, isNull);
    });
  });

  group('ProtocolSettings.defaults', () {
    test('builds disabled opcua config with urn namespace and non-empty map', () {
      final project = PlcProject(
        id: 'def_proj',
        name: 'Defaults Project',
        controllerName: 'PLC_DEF',
        tags: [
          PlcTag(
            name: 'Start_PB',
            path: 'Inputs/Start_PB',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedInput',
          ),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );

      final settings = ProtocolSettings.defaults(project);

      expect(settings.gatewayUrl, kDefaultGatewayUrl);
      expect(settings.opcua, isNotNull);
      expect(settings.opcua!.enabled, isFalse);
      expect(settings.opcua!.namespaceUri, 'urn:softplc:def_proj');
      expect(settings.opcua!.map.nodes, isNotEmpty);
    });
  });
}
