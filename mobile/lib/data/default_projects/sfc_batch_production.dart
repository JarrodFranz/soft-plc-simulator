/// **SFC — Batch Production** (`proj_sfc_batch_production`).
///
/// (a) Story: one packaging-and-batching line, merging the two retired SFC
/// demos into a single chart. A container is filled, capped and ejected on a
/// LINEAR segment with `STEP_T` dwells (from "Batch Bottle Filling"); the
/// product for the next container is then prepared by a PARALLEL fork that
/// heats and charges the mix tank at the same time and rejoins when both are
/// done (from "Batch Mix & Dispatch"); finally a quality gate splits the chart
/// into two ALTERNATIVE arms — dispatch or reject — each ending in its own
/// one-shot count step before returning to IDLE.
///
/// (b) Showcase for: SFC `'single'` transitions, `isInitial`, `STEP_T` dwell
/// conditions, `'parallelFork'` / `'parallelJoin'`, alternative divergence
/// (first-true-wins), one-shot counting steps, and a `Periodic` task.
///
/// (c) Falsifiable: removing the join lets MIXING start before both branches
/// finish; making both alternative conditions identical routes every batch the
/// same way regardless of `Quality_OK`; turning a count step's action into a
/// level assignment makes `Batch_Count` climb every scan instead of once per
/// batch.
///
/// (d) Proof test: `test/defaults/sfc_batch_production_test.dart` (plus the
/// re-pointed `test/sfc_exec_integration_test.dart` and
/// `test/sfc_batch_production_showcase_test.dart`).
library;

import '../../models/project_model.dart';

PlcProject sfcBatchProductionProject() => PlcProject(
      id: 'proj_sfc_batch_production',
      name: 'SFC — Batch Production',
      controllerName: 'PLC_BATCH',
      scanPeriodMs: 200,
      tags: [
        PlcTag(name: 'Start_Cmd', path: 'Inputs/Start_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Operator start command'),
        PlcTag(name: 'Quality_OK', path: 'Inputs/Quality_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Batch quality accept (true = dispatch, false = reject)'),
        PlcTag(name: 'Container_Present', path: 'Inputs/Container_Present', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Container presence sensor'),
        PlcTag(name: 'Temp_PV', path: 'Inputs/Temp_PV', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Mix tank temperature'),
        PlcTag(name: 'Fill_Level', path: 'Inputs/Fill_Level', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Container / mix tank fill level'),
        PlcTag(name: 'Temp_SP', path: 'Internal/Temp_SP', dataType: 'FLOAT64', value: 70.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Target mix temperature'),
        PlcTag(name: 'Fill_Target', path: 'Internal/Fill_Target', dataType: 'FLOAT64', value: 90.0, ioType: 'Internal', engineeringUnits: '%', description: 'Target charge level'),
        PlcTag(name: 'Sfc_Step', path: 'Internal/Sfc_Step', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Current SFC step index (0–15)'),
        PlcTag(name: 'Batch_Count', path: 'Internal/Batch_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Dispatched batches'),
        PlcTag(name: 'Reject_Count', path: 'Internal/Reject_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Rejected batches'),
        PlcTag(name: 'Filled_Count', path: 'Internal/Filled_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Containers filled, capped and ejected'),
        PlcTag(name: 'Sequence_Running', path: 'Internal/Sequence_Running', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Sequence active flag'),
        PlcTag(name: 'Heater', path: 'Outputs/Heater', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Mix tank heater'),
        PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Filler / charge valve'),
        PlcTag(name: 'Agitator', path: 'Outputs/Agitator', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Mixer agitator'),
        PlcTag(name: 'Cap_Solenoid', path: 'Outputs/Cap_Solenoid', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Capping solenoid'),
        PlcTag(name: 'Eject_Cyl', path: 'Outputs/Eject_Cyl', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Ejection cylinder'),
        PlcTag(name: 'Dispatch_Pump', path: 'Outputs/Dispatch_Pump', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Dispatch transfer pump'),
        PlcTag(name: 'Drain_Valve', path: 'Outputs/Drain_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Reject drain valve'),
      ],
      structDefs: [],
      simRules: [
        // 30 %/s keeps a whole merged cycle inside ~19 s of simulated time, so
        // the re-pointed linear-segment test still completes two containers
        // well inside its scan budget.
        SimRule(id: 'sim0', name: 'Filling raises level', targetPath: 'Fill_Level',
            behavior: 'integrate', ratePerSec: 30.0, minValue: 0, maxValue: 100,
            condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim1', name: 'Heating raises temp', targetPath: 'Temp_PV',
            behavior: 'integrate', ratePerSec: 12.0, minValue: 20, maxValue: 95,
            condition: [SimClause(leftPath: 'Heater', comparator: '==', operand: 'true')]),
      ],
      programs: [
        PlcProgram(
          name: 'BatchProduction_SFC',
          language: 'SequentialFunctionChart',
          description: 'Linear fill/cap/eject segment with STEP_T dwells, then a parallel '
              'heat/charge fork-join, then a quality-gated dispatch/reject divergence',
          sfcSteps: [
            SfcStep(id: 'b_idle', name: 'IDLE', isInitial: true,
                actionSt: 'Sfc_Step := 0;\nSequence_Running := FALSE;\nFill_Valve := FALSE;\n'
                    'Cap_Solenoid := FALSE;\nEject_Cyl := FALSE;\nHeater := FALSE;\n'
                    'Agitator := FALSE;\nDispatch_Pump := FALSE;\nDrain_Valve := FALSE;\n'
                    'Fill_Level := 0.0;\nTemp_PV := 20.0;'),
            SfcStep(id: 'b_wait', name: 'WAIT_CONTAINER',
                actionSt: 'Sfc_Step := 1;\nSequence_Running := TRUE;\nFill_Valve := FALSE;\n'
                    'Eject_Cyl := FALSE;\nFill_Level := 0.0;'),
            SfcStep(id: 'b_filling', name: 'FILLING',
                actionSt: 'Sfc_Step := 2;\nFill_Valve := TRUE;\n// Fill_Level rises until >= 95%'),
            SfcStep(id: 'b_capping', name: 'CAPPING',
                actionSt: 'Sfc_Step := 3;\nFill_Valve := FALSE;\nCap_Solenoid := TRUE;\n// 3s cap press dwell'),
            SfcStep(id: 'b_ejecting', name: 'EJECTING',
                actionSt: 'Sfc_Step := 4;\nCap_Solenoid := FALSE;\nEject_Cyl := TRUE;\n// 2s eject stroke'),
            SfcStep(id: 'b_count', name: 'COUNT',
                actionSt: 'Sfc_Step := 5;\nEject_Cyl := FALSE;\nFilled_Count := Filled_Count + 1;'),
            SfcStep(id: 'b_prep', name: 'PREP',
                actionSt: 'Sfc_Step := 6;\nFill_Level := 0.0;\nTemp_PV := 20.0;'),
            SfcStep(id: 'b_heating', name: 'HEATING', actionSt: 'Sfc_Step := 7;\nHeater := TRUE;'),
            SfcStep(id: 'b_heat_done', name: 'HEAT_DONE', actionSt: 'Sfc_Step := 8;\nHeater := FALSE;'),
            SfcStep(id: 'b_charging', name: 'CHARGING', actionSt: 'Sfc_Step := 9;\nFill_Valve := TRUE;'),
            SfcStep(id: 'b_charge_done', name: 'CHARGE_DONE', actionSt: 'Sfc_Step := 10;\nFill_Valve := FALSE;'),
            SfcStep(id: 'b_mixing', name: 'MIXING',
                actionSt: 'Sfc_Step := 11;\nAgitator := TRUE;\n// 3s mix dwell, then the quality gate'),
            SfcStep(id: 'b_dispatch', name: 'DISPATCH', actionSt: 'Sfc_Step := 12;\nAgitator := FALSE;\nDispatch_Pump := TRUE;'),
            SfcStep(id: 'b_reject', name: 'REJECT', actionSt: 'Sfc_Step := 13;\nAgitator := FALSE;\nDrain_Valve := TRUE;'),
            SfcStep(id: 'b_count_ok', name: 'COUNT_OK', actionSt: 'Sfc_Step := 14;\nDispatch_Pump := FALSE;\nBatch_Count := Batch_Count + 1;'),
            SfcStep(id: 'b_count_rej', name: 'COUNT_REJ', actionSt: 'Sfc_Step := 15;\nDrain_Valve := FALSE;\nReject_Count := Reject_Count + 1;'),
          ],
          sfcTransitions: [
            SfcTransition(id: 'bt0', fromStepId: 'b_idle', toStepId: 'b_wait', conditionSt: 'Start_Cmd'),
            SfcTransition(id: 'bt1', fromStepId: 'b_wait', toStepId: 'b_filling', conditionSt: 'Container_Present'),
            SfcTransition(id: 'bt2', fromStepId: 'b_filling', toStepId: 'b_capping', conditionSt: 'Fill_Level >= 95.0'),
            SfcTransition(id: 'bt3', fromStepId: 'b_capping', toStepId: 'b_ejecting', conditionSt: 'STEP_T >= 3000  (* cap press dwell *)'),
            SfcTransition(id: 'bt4', fromStepId: 'b_ejecting', toStepId: 'b_count', conditionSt: 'STEP_T >= 2000  (* eject stroke *)'),
            SfcTransition(id: 'bt5', fromStepId: 'b_count', toStepId: 'b_prep', conditionSt: 'TRUE'),
            // Parallel fork: heat and charge the next batch at the same time.
            SfcTransition(id: 'bt6', fromStepId: 'b_prep', toStepId: '', conditionSt: 'TRUE',
                kind: 'parallelFork', toStepIds: ['b_heating', 'b_charging']),
            SfcTransition(id: 'bt7', fromStepId: 'b_heating', toStepId: 'b_heat_done', conditionSt: 'Temp_PV >= Temp_SP'),
            SfcTransition(id: 'bt8', fromStepId: 'b_charging', toStepId: 'b_charge_done', conditionSt: 'Fill_Level >= Fill_Target'),
            SfcTransition(id: 'btj', fromStepId: '', toStepId: 'b_mixing', conditionSt: 'TRUE',
                kind: 'parallelJoin', fromStepIds: ['b_heat_done', 'b_charge_done']),
            // Alternative divergence: first-true-wins on the quality gate.
            SfcTransition(id: 'bt9', fromStepId: 'b_mixing', toStepId: 'b_dispatch', conditionSt: 'STEP_T >= 3000 AND Quality_OK'),
            SfcTransition(id: 'bt10', fromStepId: 'b_mixing', toStepId: 'b_reject', conditionSt: 'STEP_T >= 3000 AND NOT Quality_OK'),
            SfcTransition(id: 'bt11', fromStepId: 'b_dispatch', toStepId: 'b_count_ok', conditionSt: 'STEP_T >= 2000'),
            SfcTransition(id: 'bt12', fromStepId: 'b_reject', toStepId: 'b_count_rej', conditionSt: 'STEP_T >= 2000'),
            SfcTransition(id: 'bt13', fromStepId: 'b_count_ok', toStepId: 'b_idle', conditionSt: 'TRUE'),
            SfcTransition(id: 'bt14', fromStepId: 'b_count_rej', toStepId: 'b_idle', conditionSt: 'TRUE'),
          ],
        ),
      ],
      tasks: [
        PlcTask(name: 'BatchSequenceTask', type: 'Periodic', periodMs: 200, programNames: ['BatchProduction_SFC']),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_sfc_batch_production',
          title: 'Batch Production Sequence HMI',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'bp1', title: 'START Sequence', type: 'PushbuttonSwitch', tagBinding: 'Start_Cmd', gridSpanWidth: 2, accentColor: 'green'),
            HmiComponent(id: 'bp2', title: 'Quality OK', type: 'ToggleSwitch', tagBinding: 'Quality_OK', gridSpanWidth: 1, accentColor: 'cyan'),
            HmiComponent(id: 'bp3', title: 'Container Present', type: 'ToggleSwitch', tagBinding: 'Container_Present', gridSpanWidth: 1, accentColor: 'cyan'),
            HmiComponent(id: 'bp4', title: 'Mix Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_PV', gridSpanWidth: 2, accentColor: 'amber'),
            HmiComponent(id: 'bp5', title: 'Fill Level (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Fill_Level', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 'bp6', title: 'Heater', type: 'LedIndicatorLight', tagBinding: 'Heater', gridSpanWidth: 1, accentColor: 'amber'),
            HmiComponent(id: 'bp7', title: 'Fill Valve', type: 'LedIndicatorLight', tagBinding: 'Fill_Valve', gridSpanWidth: 1, accentColor: 'cyan'),
            HmiComponent(id: 'bp8', title: 'Agitator', type: 'LedIndicatorLight', tagBinding: 'Agitator', gridSpanWidth: 1, accentColor: 'teal'),
            HmiComponent(id: 'bp9', title: 'Cap Solenoid', type: 'LedIndicatorLight', tagBinding: 'Cap_Solenoid', gridSpanWidth: 1, accentColor: 'amber'),
            HmiComponent(id: 'bp10', title: 'Eject Cylinder', type: 'LedIndicatorLight', tagBinding: 'Eject_Cyl', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 'bp11', title: 'Dispatch Pump', type: 'LedIndicatorLight', tagBinding: 'Dispatch_Pump', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'bp12', title: 'Drain Valve', type: 'LedIndicatorLight', tagBinding: 'Drain_Valve', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 'bp13', title: 'Sequence Running', type: 'LedIndicatorLight', tagBinding: 'Sequence_Running', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'bp14', title: 'Containers Filled', type: 'StatusPillDisplay', tagBinding: 'Filled_Count', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 'bp15', title: 'Dispatched', type: 'StatusPillDisplay', tagBinding: 'Batch_Count', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'bp16', title: 'Rejected', type: 'StatusPillDisplay', tagBinding: 'Reject_Count', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 'bp17', title: 'CURRENT STEP', type: 'StatusPillDisplay', tagBinding: 'Sfc_Step', gridSpanWidth: 4, accentColor: 'teal'),
          ],
        ),
      ],
    );
