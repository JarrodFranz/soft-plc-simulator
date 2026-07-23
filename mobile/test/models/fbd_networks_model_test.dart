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

  test(
      'a corrupt huge block network index (untrusted JSON) does not OOM/hang '
      'and is clamped into range', () {
    final json = {
      'name': 'Huge',
      'language': 'FunctionBlockDiagram',
      'fbd_blocks': [
        {'id': 'b0', 'type': 'AND', 'title': '', 'network': 0},
        {'id': 'bHuge', 'type': 'OR', 'title': '', 'network': 1000000000},
      ],
      'fbd_wires': [],
    };
    final sw = Stopwatch()..start();
    final p = PlcProgram.fromJson(json);
    sw.stop();
    // Bounded and fast: no ~1e9-element allocation loop.
    expect(sw.elapsedMilliseconds, lessThan(5000));
    expect(p.fbdNetworks.length, lessThanOrEqualTo(kMaxFbdNetworks));
    for (final b in p.fbdBlocks) {
      expect(b.network, greaterThanOrEqualTo(0));
      expect(b.network, lessThan(p.fbdNetworks.length));
    }
    // The legitimate block at 0 is untouched; only the huge one is clamped.
    expect(p.fbdBlocks.firstWhere((b) => b.id == 'b0').network, 0);
  });

  test('a legitimate 5-network program with blocks at 0..4 is unchanged', () {
    final json = {
      'name': 'Five',
      'language': 'FunctionBlockDiagram',
      'fbd_blocks': [
        for (var i = 0; i < 5; i++)
          {'id': 'b$i', 'type': 'AND', 'title': '', 'network': i},
      ],
      'fbd_wires': [],
    };
    final p = PlcProgram.fromJson(json);
    expect(p.fbdNetworks.length, 5);
    for (var i = 0; i < 5; i++) {
      expect(p.fbdBlocks[i].network, i);
    }
  });
}
