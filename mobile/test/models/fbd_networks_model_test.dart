import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('FbdBlock.network defaults to 0 and round-trips', () {
    final b = FbdBlock(id: 'b1', type: 'ADD', title: 'Sum', network: 2);
    expect(b.network, 2);
    expect(FbdBlock.fromJson(b.toJson()).network, 2);
    // default
    expect(FbdBlock(id: 'b2', type: 'AND', title: '').network, 0);
  });

  test('legacy FBD program (no network keys) migrates to one network', () {
    final legacy = {
      'name': 'Old', 'language': 'FunctionBlockDiagram',
      'fbd_blocks': [
        {'id': 'b1', 'type': 'TAG_INPUT', 'title': 'A'},
        {'id': 'b2', 'type': 'AND', 'title': ''},
      ],
      'fbd_wires': [],
    };
    final p = PlcProgram.fromJson(legacy);
    expect(p.fbdBlocks.every((b) => b.network == 0), isTrue);
    expect(p.fbdNetworks.length, 1);
    expect(p.fbdNetworks.first.comment, '');
  });

  test('fbdNetworks is extended to cover the highest block network index', () {
    final json = {
      'name': 'Multi', 'language': 'FunctionBlockDiagram',
      'fbd_blocks': [
        {'id': 'b1', 'type': 'AND', 'title': '', 'network': 0},
        {'id': 'b2', 'type': 'OR', 'title': '', 'network': 2},
      ],
      'fbd_wires': [],
      'fbd_networks': [{'comment': 'first'}],
    };
    final p = PlcProgram.fromJson(json);
    expect(p.fbdNetworks.length, 3); // indices 0,1,2 all exist
    expect(p.fbdNetworks[0].comment, 'first');
    // round-trip preserves networks
    final rt = PlcProgram.fromJson(p.toJson());
    expect(rt.fbdNetworks.length, 3);
    expect(rt.fbdBlocks.firstWhere((b) => b.id == 'b2').network, 2);
  });
}
