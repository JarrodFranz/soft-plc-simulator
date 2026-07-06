import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  // Mirrors examples/protocol-maps/opcua_map_example.json.
  final exampleJson = {
    'opcua_map': {
      'namespace_uri': 'urn:softplc:motor-example',
      'nodes': [
        {'node_id': 'ns=1;s=Inputs.Start_PB', 'tag': 'Start_PB', 'access': 'ReadWrite'},
        {'node_id': 'ns=1;s=Inputs.Stop_PB', 'tag': 'Stop_PB', 'access': 'ReadWrite'},
        {'node_id': 'ns=1;s=Outputs.Motor_Run', 'tag': 'Motor_Run', 'access': 'ReadOnly'},
      ],
    },
  };

  group('OpcuaMap.fromJson / toJson', () {
    test('fromJson parses the example map shape', () {
      final map = OpcuaMap.fromJson(exampleJson);
      expect(map.namespaceUri, 'urn:softplc:motor-example');
      expect(map.nodes.length, 3);
      expect(map.nodes[0].nodeId, 'ns=1;s=Inputs.Start_PB');
      expect(map.nodes[0].tag, 'Start_PB');
      expect(map.nodes[0].access, 'ReadWrite');
      expect(map.nodes[1].nodeId, 'ns=1;s=Inputs.Stop_PB');
      expect(map.nodes[1].tag, 'Stop_PB');
      expect(map.nodes[1].access, 'ReadWrite');
      expect(map.nodes[2].nodeId, 'ns=1;s=Outputs.Motor_Run');
      expect(map.nodes[2].tag, 'Motor_Run');
      expect(map.nodes[2].access, 'ReadOnly');
    });

    test('toJson round-trips losslessly', () {
      final map = OpcuaMap.fromJson(exampleJson);
      final rt = OpcuaMap.fromJson(map.toJson());
      expect(rt.namespaceUri, map.namespaceUri);
      expect(rt.nodes.length, map.nodes.length);
      for (var i = 0; i < map.nodes.length; i++) {
        expect(rt.nodes[i].nodeId, map.nodes[i].nodeId);
        expect(rt.nodes[i].tag, map.nodes[i].tag);
        expect(rt.nodes[i].access, map.nodes[i].access);
      }
      expect(map.toJson(), exampleJson);
    });
  });

  group('OpcuaMap.autoGenerate', () {
    test('generates ReadWrite for input, ReadOnly for output, skips struct tag', () {
      final project = PlcProject(
        id: 'test_proj',
        name: 'Test Project',
        controllerName: 'PLC_TEST',
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
          PlcTag(
            name: 'Pump1_Status',
            path: 'Status/Pump1',
            dataType: 'PumpStatusDUT',
            value: {'Run': false, 'Fault': false, 'Speed': 0},
            ioType: 'Internal',
          ),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );

      final map = OpcuaMap.autoGenerate(project);

      expect(map.namespaceUri, 'urn:softplc:test_proj');
      expect(map.nodes.length, 2, reason: 'struct/array-valued tag must be skipped in v1');

      final start = map.nodes.firstWhere((n) => n.tag == 'Start_PB');
      expect(start.nodeId, 'ns=1;s=Inputs/Start_PB');
      expect(start.access, 'ReadWrite');

      final motor = map.nodes.firstWhere((n) => n.tag == 'Motor_Run');
      expect(motor.nodeId, 'ns=1;s=Outputs/Motor_Run');
      expect(motor.access, 'ReadOnly');

      expect(map.nodes.any((n) => n.tag == 'Pump1_Status'), isFalse);
    });

    test('List-valued (array) tags are also skipped', () {
      final project = PlcProject(
        id: 'arr_proj',
        name: 'Array Project',
        controllerName: 'PLC_ARR',
        tags: [
          PlcTag(
            name: 'Recipe_Steps',
            path: 'Recipe/Steps',
            dataType: 'INT16',
            arrayLength: 8,
            value: List<dynamic>.generate(8, (_) => 0),
            ioType: 'Internal',
          ),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );

      final map = OpcuaMap.autoGenerate(project);
      expect(map.nodes, isEmpty);
    });
  });
}
