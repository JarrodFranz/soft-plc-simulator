import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';

void main() {
  test('autoGenerate folder-prefixes the metric; root stays bare; tag stays bare name', () {
    final p = PlcProject(
      id: 'x',
      name: 'x',
      controllerName: 'c',
      tags: [
        PlcTag(
          name: 'Root1',
          path: 'Root1',
          dataType: 'BOOL',
          value: false,
          ioType: 'Internal',
        ),
        PlcTag(
          name: 'R1',
          path: 'Ramp1/R1',
          dataType: 'FLOAT64',
          value: 0.0,
          ioType: 'SimulatedOutput',
          folder: 'Ramp1',
        ),
      ],
      structDefs: [],
      programs: [],
      tasks: [],
      hmis: [],
    );
    final map = MqttMap.autoGenerate(p);
    final root = map.entries.firstWhere((e) => e.tag == 'Root1');
    final r1 = map.entries.firstWhere((e) => e.tag == 'R1');
    expect(root.metric, 'Root1');
    expect(r1.metric, 'Ramp1/R1');
    expect(r1.tag, 'R1'); // resolver key stays bare
  });
}
