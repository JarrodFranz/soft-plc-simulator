import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';

PlcProject _projWithSystem() {
  final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
  ensureSystemTag(p);
  return p;
}

void main() {
  test('OPC UA autoGenerate exposes System leaves incl. STRING', () {
    final map = OpcuaMap.autoGenerate(_projWithSystem());
    final tags = map.nodes.map((n) => n.tag).toSet();
    expect(tags.contains('System.Fault'), isTrue);
    expect(tags.contains('System.DateTime'), isTrue); // STRING allowed on OPC UA
    // Node id is the dotted path; System (SimulatedOutput) leaves are ReadOnly.
    final fault = map.nodes.firstWhere((n) => n.tag == 'System.Fault');
    expect(fault.nodeId, 'ns=1;s=System.Fault');
    expect(fault.access, 'ReadOnly');
  });

  test('MQTT autoGenerate exposes System leaves incl. STRING; not writable', () {
    final map = MqttMap.autoGenerate(_projWithSystem());
    final e = map.entries.firstWhere((e) => e.tag == 'System.DateTime');
    expect(e.metric, 'System.DateTime'); // root folder -> bare dotted path
    expect(e.writable, isFalse);
  });

  test('Modbus + DNP3 expose numeric/BOOL System leaves but SKIP STRING', () {
    final mb = ModbusMap.autoGenerate(_projWithSystem());
    final dnp = DnpMap.autoGenerate(_projWithSystem());
    expect(mb.entries.any((e) => e.tag == 'System.ScanTimeMs'), isTrue);
    expect(mb.entries.any((e) => e.tag == 'System.DateTime'), isFalse); // STRING skipped
    expect(dnp.entries.any((e) => e.tag == 'System.Fault'), isTrue);
    expect(dnp.entries.any((e) => e.tag == 'System.DateTime'), isFalse);
  });

  test('scalar-only project is unchanged (regression)', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [PlcTag(name: 'A', path: 'A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal')],
        structDefs: [], programs: [], tasks: [], hmis: []);
    expect(MqttMap.autoGenerate(p).entries.map((e) => e.tag), ['A']);
    expect(OpcuaMap.autoGenerate(p).nodes.map((n) => n.tag), ['A']);
  });

  test(
      'OPC UA nodeId preserves tag.path (folder-qualified browse path) for '
      'scalar tags, even when it differs from the resolver-key name '
      '(regression)', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [
          PlcTag(
              name: 'Start_PB',
              path: 'Inputs/Start_PB',
              dataType: 'BOOL',
              value: false,
              ioType: 'Internal'),
        ],
        structDefs: [], programs: [], tasks: [], hmis: []);
    final node = OpcuaMap.autoGenerate(p).nodes.single;
    // Old/shipped nodeId — must NOT change even though tag.name != tag.path.
    expect(node.nodeId, 'ns=1;s=Inputs/Start_PB');
    // Resolver key stays the dotted leaf path (== tag.name for a bare scalar).
    expect(node.tag, 'Start_PB');
  });

  test('OPC UA composite leaf System.Fault still resolves via dotted path '
      '(regression)', () {
    final map = OpcuaMap.autoGenerate(_projWithSystem());
    final fault = map.nodes.firstWhere((n) => n.tag == 'System.Fault');
    expect(fault.nodeId, 'ns=1;s=System.Fault');
    expect(fault.tag, 'System.Fault');
  });
}
