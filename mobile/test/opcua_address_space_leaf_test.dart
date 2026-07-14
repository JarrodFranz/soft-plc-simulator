import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/system_tags.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_address_space.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';

void main() {
  test('address space resolves a System dotted leaf node (dataType/value/browseName)', () {
    final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    ensureSystemTag(p);
    p.protocols = ProtocolSettings(
      gatewayUrl: '',
      opcua: OpcUaProtocolConfig(enabled: true, namespaceUri: 'urn:t',
        map: OpcuaMap.autoGenerate(p)),
    );
    final space = OpcUaAddressSpace.build(p);
    final entry = space.byNodeId(const OpcNodeId.string(1, 'System.Fault'));
    expect(entry, isNotNull);
    expect(entry!.browseName, 'System.Fault');
    expect(entry.dataType, 'BOOL');
    // Live value reads through the resolver.
    final variant = entry.readVariant(p);
    expect(variant, isNotNull);
    expect(variant!.value, false);
  });
}
