import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('LD monitor / online state add nothing to serialized JSON', () {
    for (final proj in DefaultProjects.all()) {
      final json = proj.toJson();
      final round = PlcProject.fromJson(json);
      // Serialization is unchanged by this feature — a re-serialize is stable
      // and contains no monitor/online keys.
      expect(round.toJson().toString(), json.toString());
      expect(json.toString().contains('nodePower'), isFalse);
      expect(json.toString().contains('online'), isFalse);
    }
  });
}
