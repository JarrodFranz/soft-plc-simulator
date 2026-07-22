// Pin-identity capture for PLCopen graphical (FBD) blocks.
//
// Per TC6, a connection's destination pin is the `formalParameter` of the
// <inputVariables><variable> wrapping its <connectionPointIn>, and its source
// pin is the optional `formalParameter` on the <connection> element. Without
// capturing these, a multi-input block (IN1 vs IN2) is ambiguous in the IR.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';

void main() {
  final xml = File('test/fixtures/plcopen/fbd_pins.xml').readAsStringSync();

  test('captures block input/output pin identity on connections', () {
    final ir = parsePlcOpen(xml);
    final pou = ir.pous.firstWhere((p) => p.name == 'FbdPins');
    final body = pou.body as GraphBody;

    // The AND block (localId 3) has two incoming edges — disambiguated by pin.
    final in1 =
        body.connections.firstWhere((c) => c.toLocalId == 3 && c.fromLocalId == 1);
    final in2 =
        body.connections.firstWhere((c) => c.toLocalId == 3 && c.fromLocalId == 2);
    expect(in1.toPin, 'IN1', reason: 'edge 1->3 feeds the IN1 pin');
    expect(in2.toPin, 'IN2', reason: 'edge 2->3 feeds the IN2 pin');
    // Sources here are plain inVariables — no source pin name.
    expect(in1.fromPin, isNull);
    expect(in2.fromPin, isNull);

    // The output var (localId 4) is wired to the block's OUT pin.
    final out =
        body.connections.firstWhere((c) => c.toLocalId == 4 && c.fromLocalId == 3);
    expect(out.fromPin, 'OUT', reason: 'source pin comes from <connection formalParameter>');
    expect(out.toPin, isNull, reason: 'outVariable has a single implicit input pin');

    // Exactly the three edges, no over/under capture.
    expect(body.connections, hasLength(3));
  });
}
