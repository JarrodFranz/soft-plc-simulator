import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/rll_compile.dart';

void main() {
  test('parses a simple series with a branch', () {
    final els = parseRllText('XIC(A)[XIC(B),XIC(C)]OTE(D);');
    expect(els, hasLength(3));
    expect((els[0] as RllInstruction).mnemonic, 'XIC');
    expect((els[0] as RllInstruction).operands, ['A']);
    final br = els[1] as RllBranch;
    expect(br.legs, hasLength(2));
    expect((br.legs[0].single as RllInstruction).operands, ['B']);
    expect((br.legs[1].single as RllInstruction).operands, ['C']);
    expect((els[2] as RllInstruction).mnemonic, 'OTE');
  });

  test('branch legs are multi-instruction; commas inside args and [] subscripts are respected', () {
    final els = parseRllText(
        '[N_ETHMACtoStr(inst,Sys.List[0].PhysicalAddress,0,Str) MOVE(Str,Str) , '
        'N_ETHMACtoStr(inst,Sys.List[0].PhysicalAddress,1,S1) MOVE(S1,S1)]');
    final br = els.single as RllBranch;
    expect(br.legs, hasLength(2));
    final leg0 = br.legs[0];
    expect(leg0, hasLength(2)); // AOI call + MOVE
    final aoi = leg0[0] as RllInstruction;
    expect(aoi.mnemonic, 'N_ETHMACtoStr');
    // 4 operands: instance, dotted/array path, literal 0, dest
    expect(aoi.operands, ['inst', 'Sys.List[0].PhysicalAddress', '0', 'Str']);
    expect((leg0[1] as RllInstruction).mnemonic, 'MOVE');
  });

  test('no-arg instruction', () {
    final els = parseRllText('NOP();');
    expect((els.single as RllInstruction).mnemonic, 'NOP');
    expect((els.single as RllInstruction).operands, isEmpty);
  });

  test('unbalanced bracket throws RllParseException', () {
    expect(() => parseRllText('XIC(A'), throwsA(isA<RllParseException>()));
    expect(() => parseRllText('[XIC(A)'), throwsA(isA<RllParseException>()));
  });
}
