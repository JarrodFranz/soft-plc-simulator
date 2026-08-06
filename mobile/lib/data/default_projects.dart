// Barrel over `default_projects/` — one file per built-in project. This file's
// PATH and the `DefaultProjects.all()` signature are load-bearing: ~35 test
// files import `package:soft_plc_mobile/data/default_projects.dart`.
library;

import '../models/project_model.dart';
import 'default_projects/all_water_treatment.dart';
import 'default_projects/legacy_defaults.dart';

abstract class DefaultProjects {
  static List<PlcProject> all() => [
    legacyMotorProject(),
    legacyTankProject(),
    legacyStReactorProject(),
    legacyLdConveyorProject(),
    legacyFbdHvacProject(),
    legacySfcFillingProject(),
    legacySfcBatchMixProject(),
    allWaterTreatmentProject(),
    legacyFbdPidTankLevelProject(),
    legacyFbdBatchCounterProject(),
    legacyFbdPulseOutputProject(),
    legacyCascadeTanksProject(),
    legacyNoisyLevelProject(),
    legacyMimoTwoZoneProject(),
  ];
}
