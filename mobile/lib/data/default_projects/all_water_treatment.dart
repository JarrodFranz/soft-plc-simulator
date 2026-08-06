/// **All Languages — Water Treatment Plant** (`proj_all_water`).
///
/// (a) Story: a municipal water treatment plant. The main pump is started with
/// a ladder seal-in; an FBD quality gate decides whether the water is in spec;
/// an ST supervisor raises alarms and the system-ready permissive; and an SFC
/// sequences a filter backwash whenever a 30 s ladder timer says turbidity has
/// been out of spec for too long.
///
/// (b) Showcase for: **all four IEC 61131-3 languages in one project**, a
/// multi-network FBD program whose networks hand data to each other through
/// tags (not wires), the three task types `Startup`/`Continuous`/`Periodic`,
/// an array tag (`Recipe_Steps`, INT16[8]), a DUT-typed tag (`Pump1_Status`)
/// and a `TIMER` composite (`BackwashTimer`).
///
/// (c) Falsifiable: zeroing `WaterQuality_FBD` pins `Quality_OK` false, which
/// makes `PumpControl_LD` dose forever and the backwash SFC cycle forever;
/// zeroing `Safety_ST` leaves `System_Ready` false with the pump running.
///
/// (d) Proof tests: `test/ld_exec_integration_test.dart`,
/// `test/fbd_exec_integration_test.dart`, `test/st_exec_integration_test.dart`,
/// `test/sfc_exec_integration_test.dart`, and the byte-identical data guard in
/// `test/defaults/all_water_test.dart`.
///
/// This project's DATA is byte-identical to the pre-split version (see the
/// snapshot guard above) — the split added only this comment.
library;

import '../../models/ld_graph.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'builders.dart';

  PlcProject allWaterTreatmentProject() {
    final structDefs = [
      PlcStructDef(name: 'PumpStatusDUT', fields: [
        StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
        StructFieldDef(name: 'Faulted', dataType: 'BOOL', defaultValue: false),
        StructFieldDef(name: 'RunHours', dataType: 'INT32', defaultValue: 0),
      ]),
    ];
    final scratchProj = PlcProject(
      id: '_scratch_water',
      name: '_scratch_water',
      controllerName: '_scratch',
      tags: [],
      structDefs: structDefs,
      programs: [],
      tasks: [],
      hmis: [],
    );
    return PlcProject(
      id: 'proj_all_water',
      name: 'All Languages — Water Treatment Plant',
      controllerName: 'PLC_WTP',
      scanPeriodMs: 100,
      tags: [
        // LD pump control
        PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Pump start pushbutton'),
        PlcTag(name: 'Stop_PB', path: 'Inputs/Stop_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Pump stop pushbutton'),
        PlcTag(name: 'EStop', path: 'Inputs/EStop', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Emergency stop healthy'),
        PlcTag(name: 'Pump_Latch', path: 'Internal/Pump_Latch', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Pump seal-in latch'),
        PlcTag(name: 'Pump_Motor', path: 'Outputs/Pump_Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Main pump motor contactor'),
        // Process values (FBD)
        PlcTag(name: 'Turbidity_PV', path: 'Inputs/Turbidity_PV', dataType: 'FLOAT64', value: 8.5, ioType: 'SimulatedInput', engineeringUnits: 'NTU', description: 'Raw water turbidity sensor'),
        PlcTag(name: 'Turbidity_SP', path: 'Internal/Turbidity_SP', dataType: 'FLOAT64', value: 5.0, ioType: 'Internal', engineeringUnits: 'NTU', description: 'Max turbidity setpoint'),
        PlcTag(name: 'Level_PV', path: 'Inputs/Level_PV', dataType: 'FLOAT64', value: 65.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Clear water reservoir level'),
        PlcTag(name: 'Flow_PV', path: 'Inputs/Flow_PV', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedInput', engineeringUnits: 'L/min', description: 'Treated water flow rate'),
        // Cross-network handoff tags: WaterQuality_FBD network 0 ("Thresholds")
        // writes these, network 1 ("Quality gate") reads them back the same
        // scan — the FBD demo's proof that data flows between networks via
        // tags rather than wires.
        PlcTag(name: 'Turbidity_Below_SP', path: 'Internal/Turbidity_Below_SP', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Turbidity within setpoint (network 0 result)'),
        PlcTag(name: 'Level_Above_Min', path: 'Internal/Level_Above_Min', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Reservoir level above minimum (network 0 result)'),
        PlcTag(name: 'Quality_OK', path: 'Internal/Quality_OK', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Water quality within spec'),
        // ST supervisor outputs
        PlcTag(name: 'Treat_Dosing', path: 'Outputs/Treat_Dosing', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Chemical dosing pump'),
        PlcTag(name: 'System_Ready', path: 'Internal/System_Ready', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'All permissives healthy'),
        PlcTag(name: 'Alarm_Active', path: 'Outputs/Alarm_Active', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'System alarm beacon'),
        // SFC backwash sequence
        PlcTag(name: 'Backwash_Active', path: 'Internal/Backwash_Active', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Filter backwash mode active'),
        PlcTag(name: 'Backwash_Valve', path: 'Outputs/Backwash_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Backwash header valve'),
        PlcTag(name: 'Backwash_Pump', path: 'Outputs/Backwash_Pump', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Backwash pump'),
        PlcTag(
          name: 'BackwashTimer',
          path: 'Timers/BackwashTimer',
          dataType: 'TIMER',
          value: defaultValueFor(emptyScratchProject, 'TIMER', 0)..['PRE'] = 30000,
          ioType: 'Internal',
          description: 'On-delay timer: 30s backwash cycle on sustained high turbidity',
        ),
        // Showcase array tag
        PlcTag(
          name: 'Recipe_Steps',
          path: 'Recipe/Steps',
          dataType: 'INT16',
          arrayLength: 8,
          value: defaultValueFor(emptyScratchProject, 'INT16', 8),
          ioType: 'Internal',
          description: '8-step recipe setpoints',
        ),
        // Showcase DUT-typed tag
        PlcTag(
          name: 'Pump1_Status',
          path: 'Status/Pump1',
          dataType: 'PumpStatusDUT',
          value: defaultValueFor(scratchProj, 'PumpStatusDUT', 0),
          ioType: 'Internal',
          description: 'Main pump status/telemetry struct instance',
        ),
      ],
      structDefs: structDefs,
      simRules: [
        // Turbidity clears while dosing (mirrors: dosing && turbidity>0.5 -> -0.12/scan)
        SimRule(id: 'sim0', name: 'Dosing clears turbidity', targetPath: 'Turbidity_PV',
            behavior: 'integrate', ratePerSec: -0.24, minValue: 0.5, maxValue: 20,
            condition: [SimClause(leftPath: 'Treat_Dosing', comparator: '==', operand: 'true')]),
        // Turbidity creeps up only while pumping with good water, capped near
        // turbSP * 1.5 at the default 5.0 NTU setpoint (mirrors: pumpRun && !dosing
        // && turbidity < turbSP*1.5 -> +0.04/scan). The engine has no dynamic
        // (tag*const) comparator, so the ceiling is pinned to the default setpoint.
        SimRule(id: 'sim1', name: 'Turbidity creeps up', targetPath: 'Turbidity_PV',
            behavior: 'integrate', ratePerSec: 0.08, minValue: 0, maxValue: 7.5,
            condition: [
              SimClause(leftPath: 'Pump_Motor', comparator: '==', operand: 'true'),
              SimClause(leftPath: 'Treat_Dosing', comparator: '==', operand: 'false'),
            ]),
        // Reservoir level drops while pumping (mirrors: pumpRun && level>0 -> -0.15/scan)
        SimRule(id: 'sim2', name: 'Level drops while pumping', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: -0.3, minValue: 0, maxValue: 100,
            condition: [SimClause(leftPath: 'Pump_Motor', comparator: '==', operand: 'true')]),
        // Reservoir level refills while idle (mirrors: !pumpRun && level<100 -> +0.08/scan)
        SimRule(id: 'sim3', name: 'Level refills while idle', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: 0.16, minValue: 0, maxValue: 100,
            condition: [SimClause(leftPath: 'Pump_Motor', comparator: '==', operand: 'false')]),
        // Flow follows pump state (mirrors: pumpRun ? ~42 : 0 — the ± noise term
        // cannot be reproduced by the rule engine, so this ramps to a steady 42).
        SimRule(id: 'sim4', name: 'Flow rises while pumping', targetPath: 'Flow_PV',
            behavior: 'ramp', ratePerSec: 84.0, targetValue: 42.0, minValue: 0, maxValue: 150,
            condition: [SimClause(leftPath: 'Pump_Motor', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim5', name: 'Flow drops to zero while stopped', targetPath: 'Flow_PV',
            behavior: 'ramp', ratePerSec: 84.0, targetValue: 0.0, minValue: 0, maxValue: 150,
            condition: [SimClause(leftPath: 'Pump_Motor', comparator: '==', operand: 'false')]),
      ],
      programs: [
      // ST: Safety supervisor — runs every scan
      PlcProgram(
        name: 'Safety_ST',
        language: 'StructuredText',
        description: 'Safety supervisor: permissive checks, alarms, quality assessment',
        stSource: r'''// IEC 61131-3 Structured Text — WTP Safety Supervisor
// Runs every scan — supervisory alarms and system-ready permissive.
// (Quality_OK is computed by WaterQuality_FBD; Treat_Dosing by PumpControl_LD.)

Alarm_Active := (NOT EStop) OR (Level_PV < 5.0) OR (Turbidity_PV > (Turbidity_SP + 5.0));
System_Ready := Pump_Motor AND Quality_OK AND NOT Alarm_Active;''',
      ),
      // LD: Pump start/stop seal-in rungs
      PlcProgram(
        name: 'PumpControl_LD',
        language: 'LadderLogic',
        description: 'Main pump start/stop seal-in with E-Stop and quality interlock',
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Pump Start/Stop — E-Stop and Quality Interlocks',
            main: [
              ldXic('Start_PB', 'Start NO'),
              ldXio('Stop_PB', 'Stop NC'),
              ldXic('EStop', 'E-Stop NC healthy'),
              ldXio('Alarm_Active', 'Alarm NC interlock'),
              ldOte('Pump_Motor', 'Main pump contactor'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Pump_Latch', 'Seal-in')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Pump Running Seal-In Latch',
            main: [ldXic('Pump_Motor', 'Motor aux'), ldOtl('Pump_Latch', 'Latch set')],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: Chemical Dosing Interlock — Dose When Quality Fails',
            main: [
              ldXic('Pump_Motor', 'Pump running'),
              ldXio('Quality_OK', 'Quality not OK NC'),
              ldOte('Treat_Dosing', 'Dosing pump output'),
            ],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: Backwash TON — High Turbidity Triggers Backwash Timer',
            main: [
              ldXio('Quality_OK', 'Quality not OK NC'),
              ldXic('Pump_Motor', 'Pump running'),
              ldTon('BackwashTimer', 30000, '30s backwash timer'),
            ],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Backwash Active Output',
            main: [ldXic('BackwashTimer.DN', 'Timer done'), ldOte('Backwash_Active', 'Backwash active')],
          ),
        ],
      ),
      // FBD: Water quality gate logic — split across 2 networks to showcase
      // multi-network authoring + top-to-bottom execution ordering. Network 0
      // ("Thresholds") evaluates the turbidity and level comparisons and
      // hands its two BOOL results to network 1 via tags (Turbidity_Below_SP,
      // Level_Above_Min) rather than wires — wires never cross a network
      // boundary. Network 1 ("Quality gate & output") reads those tags back
      // the same scan, ANDs them, and writes Quality_OK — byte-identical
      // behavior to the prior single-network diagram.
      PlcProgram(
        name: 'WaterQuality_FBD',
        language: 'FunctionBlockDiagram',
        description: 'Water quality gate logic using LT/GT/AND signal flow gates, across 2 networks',
        fbdNetworks: [
          FbdNetwork(comment: 'Thresholds — turbidity vs. setpoint, level vs. minimum'),
          FbdNetwork(comment: 'Quality gate & output — AND the threshold results, write Quality_OK'),
        ],
        fbdBlocks: [
          // Network 0: Thresholds.
          FbdBlock(id: 'wf_i1', type: 'TAG_INPUT', title: 'Turbidity PV', tagBinding: 'Turbidity_PV', x: 50, y: 80, network: 0),
          FbdBlock(id: 'wf_i2', type: 'TAG_INPUT', title: 'Turbidity SP', tagBinding: 'Turbidity_SP', x: 50, y: 190, network: 0),
          FbdBlock(id: 'wf_lt', type: 'LT', title: 'Turbidity < SP', tagBinding: '', x: 260, y: 130, network: 0),
          FbdBlock(id: 'wf_i3', type: 'TAG_INPUT', title: 'Level PV', tagBinding: 'Level_PV', x: 50, y: 320, network: 0),
          FbdBlock(id: 'wf_c1', type: 'CONST', title: 'Min Level', tagBinding: '10.0', x: 50, y: 430, network: 0),
          FbdBlock(id: 'wf_gt', type: 'GT', title: 'Level > 10', tagBinding: '', x: 260, y: 360, network: 0),
          FbdBlock(id: 'wf_o_lt', type: 'TAG_OUTPUT', title: 'Turbidity OK', tagBinding: 'Turbidity_Below_SP', x: 460, y: 130, network: 0),
          FbdBlock(id: 'wf_o_gt', type: 'TAG_OUTPUT', title: 'Level OK', tagBinding: 'Level_Above_Min', x: 460, y: 360, network: 0),
          // Network 1: Quality gate & output.
          FbdBlock(id: 'wf_i4', type: 'TAG_INPUT', title: 'Turbidity OK', tagBinding: 'Turbidity_Below_SP', x: 50, y: 130, network: 1),
          FbdBlock(id: 'wf_i5', type: 'TAG_INPUT', title: 'Level OK', tagBinding: 'Level_Above_Min', x: 50, y: 240, network: 1),
          FbdBlock(id: 'wf_a1', type: 'AND', title: 'Quality OK', tagBinding: '', x: 260, y: 185, network: 1),
          FbdBlock(id: 'wf_o1', type: 'TAG_OUTPUT', title: 'Quality OK', tagBinding: 'Quality_OK', x: 460, y: 185, network: 1),
        ],
        fbdWires: [
          // Network 0.
          FbdWire(fromBlockId: 'wf_i1', fromPin: 'OUT', toBlockId: 'wf_lt', toPin: 'IN1'), // Turbidity_PV
          FbdWire(fromBlockId: 'wf_i2', fromPin: 'OUT', toBlockId: 'wf_lt', toPin: 'IN2'), // Turbidity_SP
          FbdWire(fromBlockId: 'wf_i3', fromPin: 'OUT', toBlockId: 'wf_gt', toPin: 'IN1'), // Level_PV
          FbdWire(fromBlockId: 'wf_c1', fromPin: 'OUT', toBlockId: 'wf_gt', toPin: 'IN2'), // 10.0
          FbdWire(fromBlockId: 'wf_lt', fromPin: 'OUT', toBlockId: 'wf_o_lt', toPin: 'IN'),
          FbdWire(fromBlockId: 'wf_gt', fromPin: 'OUT', toBlockId: 'wf_o_gt', toPin: 'IN'),
          // Network 1 (wf_i4/wf_i5 read the tags network 0 just wrote).
          FbdWire(fromBlockId: 'wf_i4', fromPin: 'OUT', toBlockId: 'wf_a1', toPin: 'IN1'),
          FbdWire(fromBlockId: 'wf_i5', fromPin: 'OUT', toBlockId: 'wf_a1', toPin: 'IN2'),
          FbdWire(fromBlockId: 'wf_a1', fromPin: 'OUT', toBlockId: 'wf_o1', toPin: 'IN'),
        ],
      ),
      // SFC: Filter backwash sequence
      PlcProgram(
        name: 'FilterBackwash_SFC',
        language: 'SequentialFunctionChart',
        description: 'Automated filter backwash sequence on high turbidity',
        sfcSteps: [
          SfcStep(id: 'bw0', name: 'STANDBY', isInitial: true,
            actionSt: 'Backwash_Valve := FALSE;\nBackwash_Pump := FALSE;'),
          SfcStep(id: 'bw1', name: 'OPEN_BACKWASH_VALVE',
            actionSt: 'Backwash_Valve := TRUE;\n// Allow 5s for valve to open'),
          SfcStep(id: 'bw2', name: 'BACKWASH_PUMPING',
            actionSt: 'Backwash_Pump := TRUE;\n// Flush filter for 30s'),
          SfcStep(id: 'bw3', name: 'RINSE',
            actionSt: 'Backwash_Pump := FALSE;\n// Rinse cycle 10s'),
          SfcStep(id: 'bw4', name: 'CLOSE_BACKWASH',
            actionSt: 'Backwash_Valve := FALSE;\n// Return to service'),
        ],
        sfcTransitions: [
          SfcTransition(id: 'bt0', fromStepId: 'bw0', toStepId: 'bw1', conditionSt: 'Backwash_Active'),
          SfcTransition(id: 'bt1', fromStepId: 'bw1', toStepId: 'bw2', conditionSt: 'STEP_T >= 5000  (* valve open dwell *)'),
          SfcTransition(id: 'bt2', fromStepId: 'bw2', toStepId: 'bw3', conditionSt: 'Quality_OK OR STEP_T >= 30000  (* quality recovers, else 30s flush cap *)'),
          SfcTransition(id: 'bt3', fromStepId: 'bw3', toStepId: 'bw4', conditionSt: 'STEP_T >= 10000  (* rinse cycle *)'),
          SfcTransition(id: 'bt4', fromStepId: 'bw4', toStepId: 'bw0', conditionSt: 'NOT Backwash_Active'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'SafetyTask', type: 'Startup', periodMs: 100, programNames: ['Safety_ST']),
      PlcTask(name: 'ContinuousTask', type: 'Continuous', periodMs: 100, programNames: ['Safety_ST', 'PumpControl_LD', 'WaterQuality_FBD']),
      PlcTask(name: 'BackwashTask', type: 'Periodic', periodMs: 1000, programNames: ['FilterBackwash_SFC']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_all_water',
        title: 'Water Treatment Plant Dashboard',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'wt1', title: 'START Pump (NO)', type: 'PushbuttonSwitch', tagBinding: 'Start_PB', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'wt2', title: 'STOP Pump (NC)', type: 'PushbuttonSwitch', tagBinding: 'Stop_PB', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'wt3', title: 'E-Stop Healthy', type: 'ToggleSwitch', tagBinding: 'EStop', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'wt4', title: 'Pump Running', type: 'LedIndicatorLight', tagBinding: 'Pump_Motor', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'wt5', title: 'Reservoir Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Level_PV', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'wt6', title: 'Turbidity Setpoint', type: 'NumericSliderInput', tagBinding: 'Turbidity_SP', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'wt7', title: 'Turbidity (NTU)', type: 'DigitalGaugeDisplay', tagBinding: 'Turbidity_PV', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'wt8', title: 'Flow Rate (L/min)', type: 'DigitalGaugeDisplay', tagBinding: 'Flow_PV', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'wt9', title: 'Water Quality OK', type: 'LedIndicatorLight', tagBinding: 'Quality_OK', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'wt10', title: 'Dosing Pump', type: 'LedIndicatorLight', tagBinding: 'Treat_Dosing', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'wt11', title: 'Backwash Active', type: 'LedIndicatorLight', tagBinding: 'Backwash_Active', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'wt12', title: 'System Ready', type: 'LedIndicatorLight', tagBinding: 'System_Ready', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'wt13', title: 'SYSTEM ALARM', type: 'StatusPillDisplay', tagBinding: 'Alarm_Active', gridSpanWidth: 4, accentColor: 'red'),
        ],
      ),
    ],
    );
  }
