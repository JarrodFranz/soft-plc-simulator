/// **Flagship — Production Line** (`proj_flagship_line`).
///
/// (a) Story: a four-area plant with lots of moving parts. Two infeed conveyors
/// run under a seal-in with jam detection and part counting (LD); a blending
/// station holds tank level with a PID against a constant draw, picks a recipe
/// ratio and scales the level to a 4-20 mA transmitter signal (FBD); a batch
/// sequencer charges, then heats and agitates in parallel, holds, discharges
/// and counts (SFC); and a supervisor aggregates permissives, alarms,
/// `System`-derived health and run hours (ST).
///
/// (b) Showcase for everything no other default covers at once: **all three
/// task types** (`Startup` / `Continuous` / `Periodic`); **both custom-FB body
/// kinds** (`Scale` ST-bodied, `ZoneStarter` ladder-bodied with a scoped `TIMER`
/// var); seven of the eight sim behaviours — `integrate` (with a NON-LINEAR
/// `equalPercentage` valve curve), `firstOrderLag`, `deadTime`, `noise`
/// (gaussian + drift), `pulse`, **`setWhileCondition`** and **`delayedSet`**
/// (the last two showcased nowhere else); the reserved **`System` tag bound on
/// an HMI**; the **`TrendChartDisplay`** widget with project `TrendPen`s
/// (analog pens plus BOOL step lanes); the **`TextInputField`** widget; and
/// **pre-configured Modbus + OPC UA maps** so the Gateway screen shows live
/// content out of the box.
///
/// (c) Falsifiable: zeroing the PID gains pins `Blend_Valve` shut and the tank
/// drains to empty under the constant draw; deleting the `deadTime` rule makes
/// `Line_Transfer` track `Blend_Level` instantly; removing the `ZoneStarter`
/// body leaves `Conv2_Motor` dead; removing the `System.FirstScan` guard
/// re-initialises the counters every scan.
///
/// PID tuning (`bl_kp` / `bl_ki` / `bl_kd`, network 0): Kp 2.0, Ki 0.5,
/// Kd 0.05 at a 100 ms scan. The plant is `+6.0 %/s * equalPercentage(CV/100)`
/// in (rule `fl0`) against a flat `-1.0 %/s` draw (rule `fl1`), so the
/// steady-state balance needs `(50^f - 1)/49 == 1/6`. Measured over a 6000-scan
/// (10 min) run these gains settle at **Blend_Level 60.00 %, Blend_Valve
/// 56.63 %** (spread over the last 3000 scans: 56.6349–56.6350 %) — dead on
/// setpoint and comfortably off both end stops, which is what makes the "not
/// shut / not wide open" assertions in the proof test meaningful. No retune was
/// needed; raising Ki/Kp is the lever if the plant rates ever change.
///
/// (d) Proof test: `test/defaults/flagship_line_test.dart`.
///
/// NOTE on `enabled: true` protocols: nothing in `workspace_shell.dart` starts a
/// protocol host on project load — `start()` is only reached from the Gateway
/// screen's toggle. Task 8 re-confirms this by test (`flagship_gateway_no_
/// autostart_test.dart`). If that ever changes, ship these configs with
/// `enabled: false` and record the finding in `docs/DEFERRED.md`.
library;

import '../../models/ld_graph.dart';
import '../../models/modbus_map.dart';
import '../../models/noise_model.dart';
import '../../models/opcua_map.dart';
import '../../models/project_model.dart';
import '../../models/protocol_settings.dart';
import '../../models/system_tags.dart';
import '../../models/tag_resolver.dart';
import '../../models/valve_curve.dart';
import 'builders.dart';

PlcProject flagshipProductionLineProject() {
  // ── Custom function blocks — one of each body kind ──────────────────────
  final scaleFb = FbDefinition(
    name: 'Scale',
    stSource: 'Out := (In - InLo) * (OutHi - OutLo) / (InHi - InLo) + OutLo;',
    vars: [
      FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(
          name: 'InLo',
          dataType: 'FLOAT64',
          direction: FbVarDir.input,
          initialValue: 0.0),
      FbVar(
          name: 'InHi',
          dataType: 'FLOAT64',
          direction: FbVarDir.input,
          initialValue: 100.0),
      FbVar(
          name: 'OutLo',
          dataType: 'FLOAT64',
          direction: FbVarDir.input,
          initialValue: 4.0),
      FbVar(
          name: 'OutHi',
          dataType: 'FLOAT64',
          direction: FbVarDir.input,
          initialValue: 20.0),
      FbVar(
          name: 'Out',
          dataType: 'FLOAT64',
          direction: FbVarDir.output,
          initialValue: 4.0),
    ],
  );

  // Ladder-bodied: the seal-in AND the 2 s start delay live inside the
  // instance — `T` is a TIMER var, so `T.ACC`/`T.PRE` resolve to
  // `<instance>.T.ACC` / `<instance>.T.PRE`, never to a global tag.
  final zoneStarterFb = FbDefinition(
    name: 'ZoneStarter',
    vars: [
      FbVar(name: 'Run', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Permit', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Seal', dataType: 'BOOL', direction: FbVarDir.internal),
      FbVar(name: 'T', dataType: 'TIMER', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ],
    ladderRungs: [
      buildRung(
        index: 0,
        comment: 'FB rung 0: seal in the run request while the permit holds',
        main: [
          ldXic('Run', 'Run request'),
          ldXic('Permit', 'Permit'),
          ldOte('Seal', 'Instance seal'),
        ],
        branches: [
          BranchSpec(
              startIndex: 0, endIndex: 0, nodes: [ldXic('Seal', 'Seal-in aux')]),
        ],
      ),
      buildRung(
        index: 1,
        comment:
            'FB rung 1: 2 s start delay inside the instance, then drive the output',
        main: [
          ldXic('Seal', 'Sealed'),
          ldTon('T', 2000, 'Instance start delay'),
          ldOte('Out', 'Zone output'),
        ],
      ),
    ],
  );

  final scaleScratch = scratchProjectFor(fbDefinitions: [scaleFb]);
  final zoneScratch = scratchProjectFor(fbDefinitions: [zoneStarterFb]);

  final project = PlcProject(
    id: 'proj_flagship_line',
    name: 'Flagship — Production Line',
    controllerName: 'PLC_LINE01',
    scanPeriodMs: 100,
    fbDefinitions: [scaleFb, zoneStarterFb],
    tags: [
      // ── Area 1: infeed conveyors (LD) ─────────────────────────────────
      PlcTag(
          name: 'Line_Start',
          path: 'Inputs/Line_Start',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput',
          description: 'Line start pushbutton'),
      PlcTag(
          name: 'Line_Stop',
          path: 'Inputs/Line_Stop',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput',
          description: 'Line stop pushbutton (NC)'),
      PlcTag(
          name: 'EStop_OK',
          path: 'Inputs/EStop_OK',
          dataType: 'BOOL',
          value: true,
          ioType: 'SimulatedInput',
          description: 'Line emergency stop healthy'),
      PlcTag(
          name: 'Line_Run',
          path: 'Internal/Line_Run',
          dataType: 'BOOL',
          value: false,
          ioType: 'Internal',
          description: 'Line seal-in latch'),
      PlcTag(
          name: 'Conv1_Motor',
          path: 'Outputs/Conv1_Motor',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Infeed conveyor 1 contactor'),
      PlcTag(
          name: 'Conv2_Motor',
          path: 'Outputs/Conv2_Motor',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Infeed conveyor 2 contactor (ZoneStarter FB output)'),
      PlcTag(
          name: 'Conv2_Request',
          path: 'Internal/Conv2_Request',
          dataType: 'BOOL',
          value: false,
          ioType: 'Internal',
          description: 'Run request into the ZoneStarter FB'),
      PlcTag(
          name: 'Photo1',
          path: 'Inputs/Photo1',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput',
          description: 'Conveyor 1 part photo eye'),
      PlcTag(
          name: 'Photo2',
          path: 'Inputs/Photo2',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput',
          description: 'Conveyor 2 part photo eye'),
      PlcTag(
          name: 'Conv1_Jam',
          path: 'Outputs/Conv1_Jam',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Conveyor 1 jam alarm (latched)'),
      PlcTag(
          name: 'JamTimer1',
          path: 'Timers/JamTimer1',
          dataType: 'TIMER',
          value: defaultValueFor(emptyScratchProject, 'TIMER', 0),
          ioType: 'Internal',
          description:
              'On-delay timer: 6 s with no part trips the conveyor 1 jam'),
      PlcTag(
          name: 'PartCtu',
          path: 'Counters/PartCtu',
          dataType: 'COUNTER',
          value: defaultValueFor(emptyScratchProject, 'COUNTER', 0),
          ioType: 'Internal',
          description: 'Count-up counter: parts per pallet (preset 5)'),
      PlcTag(
          name: 'Part_Count',
          path: 'Internal/Part_Count',
          dataType: 'INT32',
          value: 0,
          ioType: 'Internal',
          description: 'Parts fed into the line'),
      PlcTag(
          name: 'Zone2Start',
          path: 'Internal/Zone2Start',
          dataType: 'ZoneStarter',
          value: defaultValueFor(zoneScratch, 'ZoneStarter', 0),
          ioType: 'Internal',
          description:
              'Ladder-bodied ZoneStarter FB instance (seal-in + scoped start-delay TIMER)'),
      // ── Area 2: blending (FBD) ────────────────────────────────────────
      PlcTag(
          name: 'Blend_Level',
          path: 'Inputs/Blend_Level',
          dataType: 'FLOAT64',
          value: 10.0,
          ioType: 'SimulatedInput',
          engineeringUnits: '%',
          description: 'Blend tank level'),
      PlcTag(
          name: 'Blend_SP',
          path: 'Internal/Blend_SP',
          dataType: 'FLOAT64',
          value: 60.0,
          ioType: 'Internal',
          engineeringUnits: '%',
          description: 'Blend tank level setpoint'),
      PlcTag(
          name: 'Blend_Valve',
          path: 'Outputs/Blend_Valve',
          dataType: 'FLOAT64',
          value: 0.0,
          ioType: 'SimulatedOutput',
          engineeringUnits: '%',
          description:
              'Blend trim valve (PID output, equal-percentage characteristic)'),
      PlcTag(
          name: 'Blend_Temp',
          path: 'Inputs/Blend_Temp',
          dataType: 'FLOAT64',
          value: 20.0,
          ioType: 'SimulatedInput',
          engineeringUnits: '°C',
          description:
              'Blend tank temperature (first-order lag toward Steam_Temp)'),
      PlcTag(
          name: 'Steam_Temp',
          path: 'Internal/Steam_Temp',
          dataType: 'FLOAT64',
          value: 85.0,
          ioType: 'Internal',
          engineeringUnits: '°C',
          description: 'Jacket steam temperature the tank lags toward'),
      PlcTag(
          name: 'Line_Transfer',
          path: 'Internal/Line_Transfer',
          dataType: 'FLOAT64',
          value: 10.0,
          ioType: 'Internal',
          engineeringUnits: '%',
          description:
              'Downstream transport signal — Blend_Level delayed by 4 s (deadTime)'),
      PlcTag(
          name: 'Level_Meas',
          path: 'Inputs/Level_Meas',
          dataType: 'FLOAT64',
          value: 10.0,
          ioType: 'SimulatedInput',
          engineeringUnits: '%',
          description:
              'Level transmitter reading — Blend_Level plus gaussian noise and slow drift'),
      PlcTag(
          name: 'Recipe_Select',
          path: 'Inputs/Recipe_Select',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput',
          description: 'Recipe A / B selector'),
      PlcTag(
          name: 'Recipe_A_Ratio',
          path: 'Internal/Recipe_A_Ratio',
          dataType: 'FLOAT64',
          value: 60.0,
          ioType: 'Internal',
          engineeringUnits: '%',
          description: 'Recipe A blend ratio'),
      PlcTag(
          name: 'Recipe_B_Ratio',
          path: 'Internal/Recipe_B_Ratio',
          dataType: 'FLOAT64',
          value: 40.0,
          ioType: 'Internal',
          engineeringUnits: '%',
          description: 'Recipe B blend ratio'),
      PlcTag(
          name: 'Ratio_SP',
          path: 'Internal/Ratio_SP',
          dataType: 'FLOAT64',
          value: 60.0,
          ioType: 'Internal',
          engineeringUnits: '%',
          description: 'Active blend ratio (SEL output)'),
      PlcTag(
          name: 'Blend_Rate',
          path: 'Internal/Blend_Rate',
          dataType: 'FLOAT64',
          value: 0.0,
          ioType: 'Internal',
          engineeringUnits: '%',
          description:
              'Ratio_SP * Blend_Valve / 100 — the actual component feed rate'),
      PlcTag(
          name: 'Blend_mA',
          path: 'Internal/Blend_mA',
          dataType: 'FLOAT64',
          value: 4.0,
          ioType: 'Internal',
          engineeringUnits: 'mA',
          description: 'Blend_Level scaled to 4-20 mA by the Scale FB'),
      PlcTag(
          name: 'Blend_Scale',
          path: 'Internal/Blend_Scale',
          dataType: 'Scale',
          value: defaultValueFor(scaleScratch, 'Scale', 0),
          ioType: 'Internal',
          description: 'ST-bodied Scale FB instance (0-100 % -> 4-20 mA)'),
      // ── Area 3: batch sequencing (SFC) ────────────────────────────────
      PlcTag(
          name: 'Batch_Start',
          path: 'Inputs/Batch_Start',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput',
          description: 'Batch start command'),
      PlcTag(
          name: 'Batch_Running',
          path: 'Internal/Batch_Running',
          dataType: 'BOOL',
          value: false,
          ioType: 'Internal',
          description: 'Batch sequence active (trended as a BOOL step lane)'),
      PlcTag(
          name: 'Batch_Step',
          path: 'Internal/Batch_Step',
          dataType: 'INT32',
          value: 0,
          ioType: 'Internal',
          description: 'Current batch SFC step index (0–8)'),
      PlcTag(
          name: 'Charge_Level',
          path: 'Inputs/Charge_Level',
          dataType: 'FLOAT64',
          value: 0.0,
          ioType: 'SimulatedInput',
          engineeringUnits: '%',
          description: 'Batch vessel charge level'),
      PlcTag(
          name: 'Charge_Valve',
          path: 'Outputs/Charge_Valve',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Batch charge valve'),
      PlcTag(
          name: 'Heater',
          path: 'Outputs/Heater',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Batch vessel heater'),
      PlcTag(
          name: 'Agitator',
          path: 'Outputs/Agitator',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Batch vessel agitator'),
      PlcTag(
          name: 'Discharge_Pump',
          path: 'Outputs/Discharge_Pump',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Batch discharge pump'),
      PlcTag(
          name: 'Batch_Count',
          path: 'Internal/Batch_Count',
          dataType: 'INT32',
          value: 0,
          ioType: 'Internal',
          description: 'Completed batches this run'),
      // ── Area 4: safety / supervision (ST) ─────────────────────────────
      PlcTag(
          name: 'Guard_Closed',
          path: 'Inputs/Guard_Closed',
          dataType: 'BOOL',
          value: true,
          ioType: 'SimulatedInput',
          description: 'Guard door closed sensor'),
      PlcTag(
          name: 'Guard_Locked',
          path: 'Inputs/Guard_Locked',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput',
          description:
              'Guard interlock engaged 2 s after the door closes (delayedSet)'),
      PlcTag(
          name: 'Compressor_On',
          path: 'Internal/Compressor_On',
          dataType: 'BOOL',
          value: true,
          ioType: 'Internal',
          description: 'Instrument-air compressor running'),
      PlcTag(
          name: 'Air_Pressure_OK',
          path: 'Inputs/Air_Pressure_OK',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput',
          description:
              'Instrument air healthy while the compressor runs (setWhileCondition)'),
      PlcTag(
          name: 'Permissives_OK',
          path: 'Internal/Permissives_OK',
          dataType: 'BOOL',
          value: false,
          ioType: 'Internal',
          description: 'All supervisory permissives healthy'),
      PlcTag(
          name: 'Health_OK',
          path: 'Internal/Health_OK',
          dataType: 'BOOL',
          value: false,
          ioType: 'Internal',
          description: 'Controller health derived from the reserved System tag'),
      PlcTag(
          name: 'Alarm_Active',
          path: 'Outputs/Alarm_Active',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Plant alarm beacon (trended as a BOOL step lane)'),
      PlcTag(
          name: 'Run_Hours',
          path: 'Internal/Run_Hours',
          dataType: 'FLOAT64',
          value: 0.0,
          ioType: 'Internal',
          engineeringUnits: 'h',
          description: 'Accumulated line run hours'),
      PlcTag(
          name: 'Recipe_Name',
          path: 'Internal/Recipe_Name',
          dataType: 'STRING',
          value: 'BLEND-A',
          ioType: 'Internal',
          description: 'Recipe identifier (edited from the diagnostics dashboard)'),
      PlcTag(
          name: 'Batch_Target',
          path: 'Internal/Batch_Target',
          dataType: 'INT32',
          value: 5,
          ioType: 'Internal',
          description:
              'Batches planned for this run (edited from the diagnostics dashboard, read by Safety_ST)'),
      PlcTag(
          name: 'Batch_Done',
          path: 'Outputs/Batch_Done',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput',
          description: 'Planned batch count reached (Batch_Count >= Batch_Target)'),
    ],
    structDefs: [],
    simRules: [
      SimRule(
          id: 'fl0',
          name: 'Blend inflow (equal-percentage valve)',
          targetPath: 'Blend_Level',
          behavior: 'integrate',
          ratePerSec: 6.0,
          sourcePath: 'Blend_Valve',
          refValue: 100.0,
          valveCurve: kValveEqualPercentage,
          minValue: 0,
          maxValue: 100),
      SimRule(
          id: 'fl1',
          name: 'Blend outflow (constant draw)',
          targetPath: 'Blend_Level',
          behavior: 'integrate',
          ratePerSec: -1.0,
          minValue: 0,
          maxValue: 100),
      SimRule(
          id: 'fl2',
          name: 'Tank thermal lag toward steam',
          targetPath: 'Blend_Temp',
          behavior: 'firstOrderLag',
          sourcePath: 'Steam_Temp',
          tauSec: 20.0,
          minValue: 0,
          maxValue: 150),
      SimRule(
          id: 'fl3',
          name: 'Downstream transport delay',
          targetPath: 'Line_Transfer',
          behavior: 'deadTime',
          sourcePath: 'Blend_Level',
          tauSec: 4.0,
          minValue: 0,
          maxValue: 100),
      SimRule(
          id: 'fl4',
          name: 'Level transmitter noise + drift',
          targetPath: 'Level_Meas',
          behavior: 'noise',
          sourcePath: 'Blend_Level',
          targetValue: 1.5,
          noiseDistribution: kNoiseGaussian,
          driftAmplitude: 0.5,
          driftPeriodSec: 90.0,
          minValue: 0,
          maxValue: 100),
      SimRule(
          id: 'fl5',
          name: 'Conveyor 1 photo eye',
          targetPath: 'Photo1',
          behavior: 'pulse',
          onMs: 1500,
          offMs: 2000,
          condition: [
            SimClause(leftPath: 'Conv1_Motor', comparator: '==', operand: 'true')
          ]),
      SimRule(
          id: 'fl6',
          name: 'Conveyor 2 photo eye',
          targetPath: 'Photo2',
          behavior: 'pulse',
          onMs: 1500,
          offMs: 2000,
          condition: [
            SimClause(leftPath: 'Conv2_Motor', comparator: '==', operand: 'true')
          ]),
      SimRule(
          id: 'fl7',
          name: 'Instrument air healthy while the compressor runs',
          targetPath: 'Air_Pressure_OK',
          behavior: 'setWhileCondition',
          condition: [
            SimClause(
                leftPath: 'Compressor_On', comparator: '==', operand: 'true')
          ]),
      SimRule(
          id: 'fl8',
          name: 'Guard interlock engages 2 s after the door closes',
          targetPath: 'Guard_Locked',
          behavior: 'delayedSet',
          delayMs: 2000,
          condition: [
            SimClause(leftPath: 'Guard_Closed', comparator: '==', operand: 'true')
          ]),
      SimRule(
          id: 'fl9',
          name: 'Batch vessel charges',
          targetPath: 'Charge_Level',
          behavior: 'integrate',
          ratePerSec: 20.0,
          minValue: 0,
          maxValue: 100,
          condition: [
            SimClause(
                leftPath: 'Charge_Valve', comparator: '==', operand: 'true')
          ]),
      SimRule(
          id: 'fl10',
          name: 'Batch vessel discharges',
          targetPath: 'Charge_Level',
          behavior: 'integrate',
          ratePerSec: -25.0,
          minValue: 0,
          maxValue: 100,
          condition: [
            SimClause(
                leftPath: 'Discharge_Pump', comparator: '==', operand: 'true')
          ]),
    ],
    trends: [
      TrendPen(
          tagPath: 'Blend_Level',
          color: 'cyan',
          sampleIntervalMs: 250,
          retentionMode: 'time',
          windowMs: 300000),
      TrendPen(
          tagPath: 'Blend_Valve',
          color: 'amber',
          sampleIntervalMs: 250,
          retentionMode: 'time',
          windowMs: 300000),
      TrendPen(
          tagPath: 'Blend_Temp',
          color: 'teal',
          sampleIntervalMs: 250,
          retentionMode: 'time',
          windowMs: 300000),
      TrendPen(
          tagPath: 'Batch_Running',
          color: 'green',
          sampleIntervalMs: 250,
          retentionMode: 'time',
          windowMs: 300000),
      TrendPen(
          tagPath: 'Alarm_Active',
          color: 'red',
          sampleIntervalMs: 250,
          retentionMode: 'time',
          windowMs: 300000),
    ],
    programs: [
      // ── Infeed (LD) ───────────────────────────────────────────────────
      PlcProgram(
        name: 'Infeed_LD',
        language: 'LadderLogic',
        description:
            'Two infeed conveyors: seal-in, jam TON, part CTU, and a ladder-bodied '
            'ZoneStarter FB call for conveyor 2',
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Line Seal-In',
            main: [
              ldXic('Line_Start', 'Start NO'),
              ldXio('Line_Stop', 'Stop NC'),
              ldXic('EStop_OK', 'E-Stop healthy'),
              ldOte('Line_Run', 'Line latch'),
            ],
            branches: [
              BranchSpec(
                  startIndex: 0,
                  endIndex: 0,
                  nodes: [ldXic('Line_Run', 'Seal-in aux')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Conveyor 1 Motor',
            main: [
              ldXic('Line_Run', 'Line running'),
              ldOte('Conv1_Motor', 'Conveyor 1'),
            ],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: Conveyor 2 Run Request (blocked by a conveyor 1 jam)',
            main: [
              ldXic('Line_Run', 'Line running'),
              ldXio('Conv1_Jam', 'No jam NC'),
              ldOte('Conv2_Request', 'Zone 2 request'),
            ],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: Count Parts per Pallet (CTU)',
            main: [
              ldXicRising('Photo1', 'Part edge'),
              ldCtu('PartCtu', 5, 'Parts per pallet'),
            ],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Total Parts Fed (ADD)',
            main: [
              ldXicRising('Photo1', 'Part edge'),
              ldMath('ADD', 'Part_Count', 'Part_Count', '1', 'Part_Count + 1'),
            ],
          ),
          buildRung(
            index: 5,
            comment: 'Rung 5: Conveyor 1 Jam Detection (TON, 6 s with no part)',
            main: [
              ldXic('Conv1_Motor', 'Conveyor 1 running'),
              ldXio('Photo1', 'No part NC'),
              ldTon('JamTimer1', 6000, '6s jam timer'),
            ],
          ),
          buildRung(
            index: 6,
            comment: 'Rung 6: Latch the Conveyor 1 Jam',
            main: [
              ldXic('JamTimer1.DN', 'Timer done'),
              ldOtl('Conv1_Jam', 'Latch jam'),
            ],
          ),
          buildRung(
            index: 7,
            comment: 'Rung 7: A Part Clears the Jam',
            main: [
              ldXic('Photo1', 'Part seen'),
              ldOtu('Conv1_Jam', 'Unlatch jam'),
            ],
          ),
          buildRung(
            index: 8,
            comment: 'Rung 8: Conveyor 2 Starter — LADDER-BODIED custom FB call. '
                'Unconditional (straight off the left rail) so the FB keeps evaluating '
                'its own Permit and can drop its seal when the request or permit goes away.',
            main: [
              ldFbCall('ZoneStarter', 'Zone2Start', {
                'Run': 'Conv2_Request',
                'Permit': 'EStop_OK',
                'Out': 'Conv2_Motor',
              }, 'Conveyor 2 starter instance'),
            ],
          ),
        ],
      ),
      // ── Blending (FBD) ────────────────────────────────────────────────
      PlcProgram(
        name: 'Blend_FBD',
        language: 'FunctionBlockDiagram',
        description:
            'PID level control with a LIMIT clamp, a SEL recipe pick with MUL/DIV '
            'ratio maths, and an ST-bodied Scale FB producing a 4-20 mA transmitter signal',
        fbdNetworks: [
          FbdNetwork(comment: 'Blend tank level PID + output clamp'),
          FbdNetwork(comment: 'Recipe selection and ratio maths'),
          FbdNetwork(comment: 'Level to 4-20 mA transmitter scaling (Scale FB)'),
        ],
        fbdBlocks: [
          // Network 0.
          FbdBlock(
              id: 'bl_sp',
              type: 'TAG_INPUT',
              title: 'Blend SP',
              tagBinding: 'Blend_SP',
              x: 50,
              y: 80,
              network: 0),
          FbdBlock(
              id: 'bl_pv',
              type: 'TAG_INPUT',
              title: 'Blend Level',
              tagBinding: 'Blend_Level',
              x: 50,
              y: 190,
              network: 0),
          FbdBlock(
              id: 'bl_kp',
              type: 'CONST',
              title: 'Kp',
              tagBinding: '2.0',
              x: 50,
              y: 300,
              network: 0),
          FbdBlock(
              id: 'bl_ki',
              type: 'CONST',
              title: 'Ki',
              tagBinding: '0.5',
              x: 50,
              y: 380,
              network: 0),
          FbdBlock(
              id: 'bl_kd',
              type: 'CONST',
              title: 'Kd',
              tagBinding: '0.05',
              x: 50,
              y: 460,
              network: 0),
          FbdBlock(
              id: 'bl_pid',
              type: 'PID',
              title: 'Blend Level PID',
              x: 320,
              y: 240,
              network: 0),
          FbdBlock(
              id: 'bl_lo',
              type: 'CONST',
              title: 'Valve Min',
              tagBinding: '0.0',
              x: 320,
              y: 460,
              network: 0),
          FbdBlock(
              id: 'bl_hi',
              type: 'CONST',
              title: 'Valve Max',
              tagBinding: '100.0',
              x: 320,
              y: 540,
              network: 0),
          FbdBlock(
              id: 'bl_lim',
              type: 'LIMIT',
              title: 'Clamp 0..100',
              x: 560,
              y: 300,
              network: 0),
          FbdBlock(
              id: 'bl_cv',
              type: 'TAG_OUTPUT',
              title: 'Blend Valve',
              tagBinding: 'Blend_Valve',
              x: 800,
              y: 300,
              network: 0),
          // Network 1.
          FbdBlock(
              id: 'bl_rsel',
              type: 'TAG_INPUT',
              title: 'Recipe Select',
              tagBinding: 'Recipe_Select',
              x: 50,
              y: 80,
              network: 1),
          FbdBlock(
              id: 'bl_ra',
              type: 'TAG_INPUT',
              title: 'Recipe A Ratio',
              tagBinding: 'Recipe_A_Ratio',
              x: 50,
              y: 190,
              network: 1),
          FbdBlock(
              id: 'bl_rb',
              type: 'TAG_INPUT',
              title: 'Recipe B Ratio',
              tagBinding: 'Recipe_B_Ratio',
              x: 50,
              y: 300,
              network: 1),
          FbdBlock(
              id: 'bl_sel',
              type: 'SEL',
              title: 'Recipe Pick',
              x: 280,
              y: 190,
              network: 1),
          FbdBlock(
              id: 'bl_ratio',
              type: 'TAG_OUTPUT',
              title: 'Ratio SP',
              tagBinding: 'Ratio_SP',
              x: 520,
              y: 130,
              network: 1),
          FbdBlock(
              id: 'bl_v',
              type: 'TAG_INPUT',
              title: 'Blend Valve',
              tagBinding: 'Blend_Valve',
              x: 50,
              y: 420,
              network: 1),
          FbdBlock(
              id: 'bl_mul',
              type: 'MUL',
              title: 'Ratio * Valve',
              x: 520,
              y: 330,
              network: 1),
          FbdBlock(
              id: 'bl_c100',
              type: 'CONST',
              title: 'Percent Base',
              tagBinding: '100.0',
              x: 520,
              y: 470,
              network: 1),
          FbdBlock(
              id: 'bl_div',
              type: 'DIV',
              title: '/ 100',
              x: 760,
              y: 380,
              network: 1),
          FbdBlock(
              id: 'bl_rate',
              type: 'TAG_OUTPUT',
              title: 'Blend Rate',
              tagBinding: 'Blend_Rate',
              x: 1000,
              y: 380,
              network: 1),
          // Network 2.
          FbdBlock(
              id: 'bl_in',
              type: 'TAG_INPUT',
              title: 'Blend Level',
              tagBinding: 'Blend_Level',
              x: 50,
              y: 80,
              network: 2),
          FbdBlock(
              id: 'bl_inlo',
              type: 'CONST',
              title: 'In Lo',
              tagBinding: '0.0',
              x: 50,
              y: 190,
              network: 2),
          FbdBlock(
              id: 'bl_inhi',
              type: 'CONST',
              title: 'In Hi',
              tagBinding: '100.0',
              x: 50,
              y: 270,
              network: 2),
          FbdBlock(
              id: 'bl_outlo',
              type: 'CONST',
              title: 'Out Lo (mA)',
              tagBinding: '4.0',
              x: 50,
              y: 350,
              network: 2),
          FbdBlock(
              id: 'bl_outhi',
              type: 'CONST',
              title: 'Out Hi (mA)',
              tagBinding: '20.0',
              x: 50,
              y: 430,
              network: 2),
          FbdBlock(
              id: 'bl_scale',
              type: 'Scale',
              title: 'Level -> 4-20 mA',
              tagBinding: 'Blend_Scale',
              x: 320,
              y: 250,
              network: 2),
          FbdBlock(
              id: 'bl_ma',
              type: 'TAG_OUTPUT',
              title: 'Blend mA',
              tagBinding: 'Blend_mA',
              x: 600,
              y: 250,
              network: 2),
        ],
        fbdWires: [
          // Network 0.
          FbdWire(
              fromBlockId: 'bl_sp',
              fromPin: 'OUT',
              toBlockId: 'bl_pid',
              toPin: 'SP'),
          FbdWire(
              fromBlockId: 'bl_pv',
              fromPin: 'OUT',
              toBlockId: 'bl_pid',
              toPin: 'PV'),
          FbdWire(
              fromBlockId: 'bl_kp',
              fromPin: 'OUT',
              toBlockId: 'bl_pid',
              toPin: 'KP'),
          FbdWire(
              fromBlockId: 'bl_ki',
              fromPin: 'OUT',
              toBlockId: 'bl_pid',
              toPin: 'KI'),
          FbdWire(
              fromBlockId: 'bl_kd',
              fromPin: 'OUT',
              toBlockId: 'bl_pid',
              toPin: 'KD'),
          FbdWire(
              fromBlockId: 'bl_lo',
              fromPin: 'OUT',
              toBlockId: 'bl_lim',
              toPin: 'MN'),
          FbdWire(
              fromBlockId: 'bl_pid',
              fromPin: 'CV',
              toBlockId: 'bl_lim',
              toPin: 'IN'),
          FbdWire(
              fromBlockId: 'bl_hi',
              fromPin: 'OUT',
              toBlockId: 'bl_lim',
              toPin: 'MX'),
          FbdWire(
              fromBlockId: 'bl_lim',
              fromPin: 'OUT',
              toBlockId: 'bl_cv',
              toPin: 'IN'),
          // Network 1.
          FbdWire(
              fromBlockId: 'bl_rsel',
              fromPin: 'OUT',
              toBlockId: 'bl_sel',
              toPin: 'G'),
          FbdWire(
              fromBlockId: 'bl_ra',
              fromPin: 'OUT',
              toBlockId: 'bl_sel',
              toPin: 'IN0'),
          FbdWire(
              fromBlockId: 'bl_rb',
              fromPin: 'OUT',
              toBlockId: 'bl_sel',
              toPin: 'IN1'),
          FbdWire(
              fromBlockId: 'bl_sel',
              fromPin: 'OUT',
              toBlockId: 'bl_ratio',
              toPin: 'IN'),
          FbdWire(
              fromBlockId: 'bl_sel',
              fromPin: 'OUT',
              toBlockId: 'bl_mul',
              toPin: 'IN1'),
          FbdWire(
              fromBlockId: 'bl_v',
              fromPin: 'OUT',
              toBlockId: 'bl_mul',
              toPin: 'IN2'),
          FbdWire(
              fromBlockId: 'bl_mul',
              fromPin: 'OUT',
              toBlockId: 'bl_div',
              toPin: 'IN1'),
          FbdWire(
              fromBlockId: 'bl_c100',
              fromPin: 'OUT',
              toBlockId: 'bl_div',
              toPin: 'IN2'),
          FbdWire(
              fromBlockId: 'bl_div',
              fromPin: 'OUT',
              toBlockId: 'bl_rate',
              toPin: 'IN'),
          // Network 2.
          FbdWire(
              fromBlockId: 'bl_in',
              fromPin: 'OUT',
              toBlockId: 'bl_scale',
              toPin: 'In'),
          FbdWire(
              fromBlockId: 'bl_inlo',
              fromPin: 'OUT',
              toBlockId: 'bl_scale',
              toPin: 'InLo'),
          FbdWire(
              fromBlockId: 'bl_inhi',
              fromPin: 'OUT',
              toBlockId: 'bl_scale',
              toPin: 'InHi'),
          FbdWire(
              fromBlockId: 'bl_outlo',
              fromPin: 'OUT',
              toBlockId: 'bl_scale',
              toPin: 'OutLo'),
          FbdWire(
              fromBlockId: 'bl_outhi',
              fromPin: 'OUT',
              toBlockId: 'bl_scale',
              toPin: 'OutHi'),
          FbdWire(
              fromBlockId: 'bl_scale',
              fromPin: 'Out',
              toBlockId: 'bl_ma',
              toPin: 'IN'),
        ],
      ),
      // ── Batch sequencing (SFC) ────────────────────────────────────────
      PlcProgram(
        name: 'Batch_SFC',
        language: 'SequentialFunctionChart',
        description:
            'Charge, then heat and agitate in parallel, join, hold, discharge and count',
        sfcSteps: [
          SfcStep(
              id: 'f_idle',
              name: 'IDLE',
              isInitial: true,
              actionSt:
                  'Batch_Step := 0;\nBatch_Running := FALSE;\nCharge_Valve := FALSE;\n'
                  'Heater := FALSE;\nAgitator := FALSE;\nDischarge_Pump := FALSE;\nCharge_Level := 0.0;'),
          SfcStep(
              id: 'f_charge',
              name: 'CHARGE',
              actionSt:
                  'Batch_Step := 1;\nBatch_Running := TRUE;\nCharge_Valve := TRUE;'),
          SfcStep(
              id: 'f_heat',
              name: 'HEAT',
              actionSt: 'Batch_Step := 2;\nCharge_Valve := FALSE;\nHeater := TRUE;'),
          SfcStep(
              id: 'f_heat_done',
              name: 'HEAT_DONE',
              actionSt: 'Batch_Step := 3;\nHeater := FALSE;'),
          SfcStep(
              id: 'f_agitate',
              name: 'AGITATE',
              actionSt: 'Batch_Step := 4;\nAgitator := TRUE;'),
          SfcStep(
              id: 'f_agit_done',
              name: 'AGIT_DONE',
              actionSt: 'Batch_Step := 5;\nAgitator := FALSE;'),
          SfcStep(
              id: 'f_hold',
              name: 'HOLD',
              actionSt: 'Batch_Step := 6;\n// 2s soak dwell'),
          SfcStep(
              id: 'f_discharge',
              name: 'DISCHARGE',
              actionSt: 'Batch_Step := 7;\nDischarge_Pump := TRUE;'),
          SfcStep(
              id: 'f_count',
              name: 'COUNT',
              actionSt:
                  'Batch_Step := 8;\nDischarge_Pump := FALSE;\nBatch_Running := FALSE;\n'
                  'Batch_Count := Batch_Count + 1;'),
        ],
        sfcTransitions: [
          SfcTransition(
              id: 'ft0',
              fromStepId: 'f_idle',
              toStepId: 'f_charge',
              conditionSt: 'Batch_Start'),
          SfcTransition(
              id: 'ft1',
              fromStepId: 'f_charge',
              toStepId: '',
              conditionSt: 'Charge_Level >= 80.0',
              kind: 'parallelFork',
              toStepIds: ['f_heat', 'f_agitate']),
          SfcTransition(
              id: 'ft2',
              fromStepId: 'f_heat',
              toStepId: 'f_heat_done',
              conditionSt: 'STEP_T >= 3000'),
          SfcTransition(
              id: 'ft3',
              fromStepId: 'f_agitate',
              toStepId: 'f_agit_done',
              conditionSt: 'STEP_T >= 2000'),
          SfcTransition(
              id: 'ftj',
              fromStepId: '',
              toStepId: 'f_hold',
              conditionSt: 'TRUE',
              kind: 'parallelJoin',
              fromStepIds: ['f_heat_done', 'f_agit_done']),
          SfcTransition(
              id: 'ft4',
              fromStepId: 'f_hold',
              toStepId: 'f_discharge',
              conditionSt: 'STEP_T >= 2000'),
          SfcTransition(
              id: 'ft5',
              fromStepId: 'f_discharge',
              toStepId: 'f_count',
              conditionSt: 'Charge_Level <= 5.0'),
          SfcTransition(
              id: 'ft6',
              fromStepId: 'f_count',
              toStepId: 'f_idle',
              conditionSt: 'TRUE'),
        ],
      ),
      // ── Safety / supervision (ST) ─────────────────────────────────────
      PlcProgram(
        name: 'Safety_ST',
        language: 'StructuredText',
        description: 'Startup initialisation (System.FirstScan guarded), supervisory '
            'permissives, alarm aggregation, System-derived health and run-hour accumulation',
        stSource: r'''// IEC 61131-3 Structured Text — Line Supervisor
// Runs from BOTH the Startup task (once) and the Continuous task (every scan).
// The System.FirstScan guard is what makes the initialisation block one-shot.

// NOTE: every tag initialised here must have NO other writer, or the assertion
// that the block ran exactly once is unfalsifiable. `Ratio_SP` is deliberately
// NOT initialised here — Blend_FBD's `bl_ratio` TAG_OUTPUT rewrites it every
// scan, so a first-scan value would be indistinguishable from the steady state.
IF System.FirstScan THEN
    Batch_Target := 5;
    Batch_Count := 0;
    Part_Count := 0;
    Run_Hours := 0.0;
END_IF;

Permissives_OK := EStop_OK AND Guard_Closed AND Guard_Locked AND Air_Pressure_OK;
Health_OK      := System.Running AND NOT System.Fault;
Alarm_Active   := (NOT Permissives_OK) OR Conv1_Jam OR (Blend_Level > 95.0);
Batch_Done     := Batch_Count >= Batch_Target;

// 100 ms of run time is 0.0000278 h.
IF Line_Run THEN
    Run_Hours := Run_Hours + 0.0000278;
END_IF;''',
      ),
    ],
    tasks: [
      PlcTask(
          name: 'StartupTask',
          type: 'Startup',
          periodMs: 100,
          programNames: ['Safety_ST']),
      PlcTask(
          name: 'MainTask',
          type: 'Continuous',
          periodMs: 100,
          programNames: ['Infeed_LD', 'Blend_FBD', 'Safety_ST']),
      PlcTask(
          name: 'BatchTask',
          type: 'Periodic',
          periodMs: 250,
          programNames: ['Batch_SFC']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_flagship_overview',
        title: 'Production Line Overview',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(
              id: 'fo1',
              title: 'START Line',
              type: 'PushbuttonSwitch',
              tagBinding: 'Line_Start',
              gridSpanWidth: 1,
              accentColor: 'green'),
          HmiComponent(
              id: 'fo2',
              title: 'STOP Line',
              type: 'PushbuttonSwitch',
              tagBinding: 'Line_Stop',
              gridSpanWidth: 1,
              accentColor: 'red'),
          HmiComponent(
              id: 'fo3',
              title: 'E-Stop Healthy',
              type: 'ToggleSwitch',
              tagBinding: 'EStop_OK',
              gridSpanWidth: 1,
              accentColor: 'cyan'),
          HmiComponent(
              id: 'fo4',
              title: 'START Batch',
              type: 'PushbuttonSwitch',
              tagBinding: 'Batch_Start',
              gridSpanWidth: 1,
              accentColor: 'green'),
          HmiComponent(
              id: 'fo5',
              title: 'Conveyor 1',
              type: 'LedIndicatorLight',
              tagBinding: 'Conv1_Motor',
              gridSpanWidth: 1,
              accentColor: 'green'),
          HmiComponent(
              id: 'fo6',
              title: 'Conveyor 2',
              type: 'LedIndicatorLight',
              tagBinding: 'Conv2_Motor',
              gridSpanWidth: 1,
              accentColor: 'green'),
          HmiComponent(
              id: 'fo7',
              title: 'Batch Running',
              type: 'LedIndicatorLight',
              tagBinding: 'Batch_Running',
              gridSpanWidth: 1,
              accentColor: 'teal'),
          HmiComponent(
              id: 'fo8',
              title: 'Permissives OK',
              type: 'LedIndicatorLight',
              tagBinding: 'Permissives_OK',
              gridSpanWidth: 1,
              accentColor: 'green'),
          HmiComponent(
              id: 'fo9',
              title: 'Blend Tank Level',
              type: 'TankGraphicDisplay',
              tagBinding: 'Blend_Level',
              gridSpanWidth: 2,
              accentColor: 'cyan'),
          HmiComponent(
              id: 'fo10',
              title: 'Blend Setpoint',
              type: 'NumericSliderInput',
              tagBinding: 'Blend_SP',
              gridSpanWidth: 2,
              accentColor: 'teal'),
          HmiComponent(
              id: 'fo11',
              title: 'Blend Valve (%)',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'Blend_Valve',
              gridSpanWidth: 2,
              accentColor: 'amber'),
          HmiComponent(
              id: 'fo12',
              title: 'Blend Temp (°C)',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'Blend_Temp',
              gridSpanWidth: 2,
              accentColor: 'red'),
          HmiComponent(
              id: 'fo13',
              title: 'Transmitter (mA)',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'Blend_mA',
              gridSpanWidth: 2,
              accentColor: 'cyan'),
          HmiComponent(
              id: 'fo14',
              title: 'Parts Fed',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'Part_Count',
              gridSpanWidth: 2,
              accentColor: 'teal'),
          HmiComponent(
              id: 'fo15',
              title: 'Batches Complete',
              type: 'StatusPillDisplay',
              tagBinding: 'Batch_Count',
              gridSpanWidth: 2,
              accentColor: 'green'),
          HmiComponent(
              id: 'fo16',
              title: 'PLANT ALARM',
              type: 'StatusPillDisplay',
              tagBinding: 'Alarm_Active',
              gridSpanWidth: 2,
              accentColor: 'red'),
          // The noise rule (fl4) writes Level_Meas; without a display it would
          // be a behaviour nothing in the app ever surfaces.
          HmiComponent(
              id: 'fo17',
              title: 'Level Transmitter (%)',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'Level_Meas',
              gridSpanWidth: 2,
              accentColor: 'amber'),
          HmiComponent(
              id: 'fo18',
              title: 'Batch Target Reached',
              type: 'LedIndicatorLight',
              tagBinding: 'Batch_Done',
              gridSpanWidth: 1,
              accentColor: 'green'),
        ],
      ),
      HmiScreenDef(
        id: 'hmi_flagship_trends',
        title: 'Production Line Trends',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(
            id: 'ft_analog',
            title: 'Blend Loop (analog pens)',
            type: kTrendChartDisplay,
            tagBinding: '',
            gridSpanWidth: 4,
            accentColor: 'cyan',
            windowMs: 120000,
            trendPens: [
              TrendPenRef(penTagPath: 'Blend_Level'),
              TrendPenRef(penTagPath: 'Blend_Valve'),
              TrendPenRef(penTagPath: 'Blend_Temp'),
            ],
          ),
          HmiComponent(
            id: 'ft_bool',
            title: 'Line State (BOOL step lanes)',
            type: kTrendChartDisplay,
            tagBinding: '',
            gridSpanWidth: 4,
            accentColor: 'green',
            windowMs: 120000,
            trendPens: [
              TrendPenRef(penTagPath: 'Batch_Running'),
              TrendPenRef(penTagPath: 'Alarm_Active'),
            ],
          ),
        ],
      ),
      HmiScreenDef(
        id: 'hmi_flagship_diagnostics',
        title: 'Production Line Diagnostics',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(
              id: 'fd1',
              title: 'Recipe Name',
              type: 'TextInputField',
              tagBinding: 'Recipe_Name',
              gridSpanWidth: 2,
              accentColor: 'teal'),
          HmiComponent(
              id: 'fd2',
              title: 'Batch Target',
              type: 'TextInputField',
              tagBinding: 'Batch_Target',
              gridSpanWidth: 2,
              accentColor: 'teal'),
          HmiComponent(
              id: 'fd3',
              title: 'Scan Count',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'System.ScanCount',
              gridSpanWidth: 2,
              accentColor: 'cyan'),
          HmiComponent(
              id: 'fd4',
              title: 'Scan Time (ms)',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'System.ScanTimeMs',
              gridSpanWidth: 1,
              accentColor: 'cyan'),
          HmiComponent(
              id: 'fd5',
              title: 'Max Scan (ms)',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'System.MaxScanTimeMs',
              gridSpanWidth: 1,
              accentColor: 'amber'),
          HmiComponent(
              id: 'fd6',
              title: 'Uptime (ms)',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'System.UptimeMs',
              gridSpanWidth: 2,
              accentColor: 'teal'),
          HmiComponent(
              id: 'fd7',
              title: 'Run Hours',
              type: 'DigitalGaugeDisplay',
              tagBinding: 'Run_Hours',
              gridSpanWidth: 2,
              accentColor: 'teal'),
          HmiComponent(
              id: 'fd8',
              title: 'PLC Running',
              type: 'LedIndicatorLight',
              tagBinding: 'System.Running',
              gridSpanWidth: 1,
              accentColor: 'green'),
          HmiComponent(
              id: 'fd9',
              title: 'First Scan',
              type: 'LedIndicatorLight',
              tagBinding: 'System.FirstScan',
              gridSpanWidth: 1,
              accentColor: 'cyan'),
          HmiComponent(
              id: 'fd10',
              title: 'Health OK',
              type: 'LedIndicatorLight',
              tagBinding: 'Health_OK',
              gridSpanWidth: 1,
              accentColor: 'green'),
          HmiComponent(
              id: 'fd11',
              title: 'Guard Locked',
              type: 'LedIndicatorLight',
              tagBinding: 'Guard_Locked',
              gridSpanWidth: 1,
              accentColor: 'amber'),
          HmiComponent(
              id: 'fd12',
              title: 'Air Pressure OK',
              type: 'LedIndicatorLight',
              tagBinding: 'Air_Pressure_OK',
              gridSpanWidth: 1,
              accentColor: 'cyan'),
          HmiComponent(
              id: 'fd13',
              title: 'CONVEYOR 1 JAM',
              type: 'StatusPillDisplay',
              tagBinding: 'Conv1_Jam',
              gridSpanWidth: 2,
              accentColor: 'red'),
          HmiComponent(
              id: 'fd14',
              title: 'CONTROLLER FAULT',
              type: 'StatusPillDisplay',
              tagBinding: 'System.Fault',
              gridSpanWidth: 2,
              accentColor: 'red'),
        ],
      ),
    ],
  );

  // The reserved System tag must exist BEFORE the maps are generated so its 19
  // leaves land in both maps (marked ReadOnly by the generators' reserved-tag
  // special case) and so the diagnostics dashboard binds in headless tests.
  ensureSystemTag(project);

  // Two-phase: the autoGenerate helpers take the finished project.
  project.protocols = ProtocolSettings(
    gatewayUrl: kDefaultGatewayUrl,
    modbus: ModbusProtocolConfig(
      enabled: true,
      port: 502,
      map: ModbusMap.autoGenerate(project),
      wordSwap: false,
      byteSwap: false,
      unitId: 255,
      framing: 'tcp',
    ),
    opcua: OpcUaProtocolConfig(
      enabled: true,
      port: 4840,
      namespaceUri: 'urn:softplc:${project.id}',
      map: OpcuaMap.autoGenerate(project),
      securityModes: ['None'],
      credentials: [],
      allowAnonymous: true,
    ),
  );

  return project;
}
