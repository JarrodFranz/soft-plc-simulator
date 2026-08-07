// Barrel over `default_projects/` — one file per built-in project. This file's
// PATH and the `DefaultProjects.all()` signature are load-bearing: ~35 test
// files import `package:soft_plc_mobile/data/default_projects.dart`.
//
// ORDER IS LOAD-BEARING:
//  - all()[0] is the boot-active project (`workspace_shell.dart` activates
//    `catalog.first`). It must be a LadderLogic project whose FIRST tag is
//    `Start_PB` (persistence_integration_test.dart L96/L210).
//  - all().last is used by project_repository_test.dart:150 and
//    persistence_integration_test.dart:226 as "a default the catalog is
//    missing"; any project works, this just fixes which one.
library;

import '../models/project_model.dart';
import 'default_projects/all_water_treatment.dart';
import 'default_projects/fbd_hvac_zone.dart';
import 'default_projects/flagship_production_line.dart';
import 'default_projects/ladder_conveyor_line.dart';
import 'default_projects/process_control_lab.dart';
import 'default_projects/sfc_batch_production.dart';
import 'default_projects/st_reactor_control.dart';

abstract class DefaultProjects {
  static List<PlcProject> all() => [
    ladderConveyorLineProject(),
    fbdHvacZoneProject(),
    sfcBatchProductionProject(),
    stReactorControlProject(),
    allWaterTreatmentProject(),
    flagshipProductionLineProject(),
    processControlLabProject(),
  ];
}
