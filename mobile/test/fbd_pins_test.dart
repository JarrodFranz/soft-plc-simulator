import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fbd_pins.dart';

void main() {
  group('fbdInputPins', () {
    test('TAG_INPUT / CONST have no inputs', () {
      expect(fbdInputPins('TAG_INPUT'), isEmpty);
      expect(fbdInputPins('CONST'), isEmpty);
    });

    test('TAG_OUTPUT has a single IN', () {
      expect(fbdInputPins('TAG_OUTPUT'), ['IN']);
    });

    test('NOT has a single IN', () {
      expect(fbdInputPins('NOT'), ['IN']);
    });

    test('AND/OR default to IN1, IN2', () {
      expect(fbdInputPins('AND'), ['IN1', 'IN2']);
      expect(fbdInputPins('OR'), ['IN1', 'IN2']);
    });

    test('AND with inputCount 3 -> IN1, IN2, IN3', () {
      expect(fbdInputPins('AND', inputCount: 3), ['IN1', 'IN2', 'IN3']);
    });

    test('ADD/MUL are extensible like AND/OR', () {
      expect(fbdInputPins('ADD', inputCount: 4), ['IN1', 'IN2', 'IN3', 'IN4']);
      expect(fbdInputPins('MUL'), ['IN1', 'IN2']);
    });

    test('SUB/DIV are fixed at IN1, IN2 regardless of inputCount', () {
      expect(fbdInputPins('SUB'), ['IN1', 'IN2']);
      expect(fbdInputPins('SUB', inputCount: 5), ['IN1', 'IN2']);
      expect(fbdInputPins('DIV'), ['IN1', 'IN2']);
    });

    test('comparators are IN1, IN2', () {
      for (final t in ['GT', 'LT', 'GE', 'LE', 'EQ', 'NE']) {
        expect(fbdInputPins(t), ['IN1', 'IN2'], reason: t);
      }
    });

    test('LIMIT is MN, IN, MX', () {
      expect(fbdInputPins('LIMIT'), ['MN', 'IN', 'MX']);
    });

    test('SEL is G, IN0, IN1', () {
      expect(fbdInputPins('SEL'), ['G', 'IN0', 'IN1']);
    });

    test('TON/TOF are IN, PT', () {
      expect(fbdInputPins('TON'), ['IN', 'PT']);
      expect(fbdInputPins('TOF'), ['IN', 'PT']);
    });

    test('PID is SP, PV, KP, KI, KD', () {
      expect(fbdInputPins('PID'), ['SP', 'PV', 'KP', 'KI', 'KD']);
    });

    test('CTU is CU, R, PV', () {
      expect(fbdInputPins('CTU'), ['CU', 'R', 'PV']);
    });

    test('CTD is CD, LD, PV', () {
      expect(fbdInputPins('CTD'), ['CD', 'LD', 'PV']);
    });

    test('CTUD is CU, CD, R, LD, PV', () {
      expect(fbdInputPins('CTUD'), ['CU', 'CD', 'R', 'LD', 'PV']);
    });

    test('unknown type -> empty, never throws', () {
      expect(fbdInputPins('NOT_A_REAL_TYPE'), isEmpty);
      expect(fbdInputPins(''), isEmpty);
    });
  });

  group('fbdOutputPins', () {
    test('TAG_INPUT / CONST -> OUT', () {
      expect(fbdOutputPins('TAG_INPUT'), ['OUT']);
      expect(fbdOutputPins('CONST'), ['OUT']);
    });

    test('TAG_OUTPUT has no outputs', () {
      expect(fbdOutputPins('TAG_OUTPUT'), isEmpty);
    });

    test('combinational blocks -> single OUT', () {
      for (final t in [
        'NOT', 'AND', 'OR', 'ADD', 'MUL', 'SUB', 'DIV',
        'GT', 'LT', 'GE', 'LE', 'EQ', 'NE', 'LIMIT', 'SEL',
      ]) {
        expect(fbdOutputPins(t), ['OUT'], reason: t);
      }
    });

    test('TON/TOF -> Q, ET', () {
      expect(fbdOutputPins('TON'), ['Q', 'ET']);
      expect(fbdOutputPins('TOF'), ['Q', 'ET']);
    });

    test('PID -> CV', () {
      expect(fbdOutputPins('PID'), ['CV']);
    });

    test('CTU -> Q, CV', () {
      expect(fbdOutputPins('CTU'), ['Q', 'CV']);
    });

    test('CTD -> Q, CV', () {
      expect(fbdOutputPins('CTD'), ['Q', 'CV']);
    });

    test('CTUD -> QU, QD, CV', () {
      expect(fbdOutputPins('CTUD'), ['QU', 'QD', 'CV']);
    });

    test('unknown type -> empty, never throws', () {
      expect(fbdOutputPins('NOT_A_REAL_TYPE'), isEmpty);
      expect(fbdOutputPins(''), isEmpty);
    });
  });
}
