import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_address_space.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';

PlcProject _proj(List<PlcTag> tags) {
  final p = PlcProject(
      id: 'x', name: 'x', controllerName: 'c',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: []);
  p.protocols = ProtocolSettings(
    gatewayUrl: '',
    opcua: OpcUaProtocolConfig(
      enabled: true,
      namespaceUri: 'urn:test',
      map: OpcuaMap(namespaceUri: 'urn:test', nodes: [
        for (final t in tags) OpcuaNode(nodeId: 'ns=1;s=${t.name}', tag: t.name, access: 'ReadOnly'),
      ]),
    ),
  );
  return p;
}

PlcTag _t(String name, {String folder = ''}) =>
    PlcTag(name: name, path: name, dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', folder: folder);

void main() {
  test('entry carries its tag folder', () {
    final space = OpcUaAddressSpace.build(_proj([_t('R1', folder: 'Ramp1')]));
    expect(space.entries.single.folder, 'Ramp1');
  });

  test('distinct folders synthesized, alphabetically; root-only has none', () {
    final space = OpcUaAddressSpace.build(_proj([
      _t('Root1'), _t('R1', folder: 'Ramp1'), _t('S1', folder: 'Sine1'), _t('R2', folder: 'Ramp1'),
    ]));
    expect(space.folders, ['Ramp1', 'Sine1']);
    final flat = OpcUaAddressSpace.build(_proj([_t('A'), _t('B')]));
    expect(flat.folders, isEmpty);
  });

  test('Objects children = root variables only; folders hold the rest', () {
    final space = OpcUaAddressSpace.build(_proj([
      _t('Root1'), _t('R1', folder: 'Ramp1'), _t('R2', folder: 'Ramp1'),
    ]));
    expect(space.rootVariables().map((e) => e.browseName), ['Root1']);
    expect(space.childFolders(OpcUaStandardNodeIds.objectsFolder), ['Ramp1']);
    expect(space.folderVariables('Ramp1').map((e) => e.browseName), ['R1', 'R2']);
    // Backward-compat children(): Objects -> root vars only.
    expect(space.children(OpcUaStandardNodeIds.objectsFolder).map((e) => e.browseName), ['Root1']);
  });

  test('folder node id uses the reserved prefix and round-trips', () {
    final space = OpcUaAddressSpace.build(_proj([_t('R1', folder: 'Ramp1')]));
    final fid = space.folderNodeId('Ramp1');
    expect(fid, const OpcNodeId.string(1, '__folder__/Ramp1'));
    expect(space.isFolderNode(fid), isTrue);
    expect(space.folderNameOf(fid), 'Ramp1');
    // A tag node id is NOT a folder node.
    expect(space.isFolderNode(const OpcNodeId.string(1, 'R1')), isFalse);
    // children() of a folder node returns its variables.
    expect(space.children(fid).map((e) => e.browseName), ['R1']);
  });

  test('root-only project: children(Objects) identical to entries (flat preserved)', () {
    final space = OpcUaAddressSpace.build(_proj([_t('A'), _t('B')]));
    expect(space.children(OpcUaStandardNodeIds.objectsFolder).map((e) => e.browseName),
        space.entries.map((e) => e.browseName));
    expect(space.childFolders(OpcUaStandardNodeIds.objectsFolder), isEmpty);
  });
}
