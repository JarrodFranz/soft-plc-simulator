import '../models/project_model.dart';
import '../models/ld_graph.dart';
import '../models/tag_resolver.dart';

abstract class DefaultProjects {
  static LdNode _xic(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'normal', comment: c);
  static LdNode _xio(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'negated', comment: c);
  static LdNode _ote(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'normal', comment: c);
  static LdNode _otl(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'set', comment: c);
  static LdNode _otu(String v, [String c = '']) =>
      LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'reset', comment: c);
  static LdNode _ton(String v, int ms, [String c = '']) =>
      LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: v, presetMs: ms, comment: c);

  /// Throwaway project used only to resolve built-in composite (e.g. TIMER)
  /// and scalar-array default values, which do not depend on a project's
  /// own structDefs.
  static final PlcProject _emptyProject = PlcProject(
    id: '_scratch',
    name: '_scratch',
    controllerName: '_scratch',
    tags: [],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );

  static List<PlcProject> all() => [
    _motorProject(),
    _tankProject(),
    _stReactorProject(),
    _ldConveyorProject(),
    _fbdHvacProject(),
    _sfcFillingProject(),
    _sfcBatchMixProject(),
    _allWaterProject(),
    _fbdPidTankLevelProject(),
    _fbdBatchCounterProject(),
    _fbdPulseOutputProject(),
    _cascadeTanksProject(),
    _noisyLevelProject(),
  ];

  // ── 1. Basic Motor Start/Stop (LD) ──────────────────────────────────────

  static PlcProject _motorProject() {
    final structDefs = [
      PlcStructDef(name: 'Motor_DUT', fields: [
        StructFieldDef(name: 'Run', dataType: 'BOOL', defaultValue: false),
        StructFieldDef(name: 'Fault', dataType: 'BOOL', defaultValue: false),
        StructFieldDef(name: 'Speed', dataType: 'INT32', defaultValue: 0),
      ]),
    ];
    return PlcProject(
      id: 'proj_motor',
      name: 'Basic Motor Start Stop',
      controllerName: 'PLC_01',
      scanPeriodMs: 100,
      tags: [
        PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Start pushbutton NO'),
        PlcTag(name: 'Stop_PB', path: 'Inputs/Stop_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Stop pushbutton NC'),
        PlcTag(name: 'EStop_OK', path: 'Inputs/EStop_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Emergency Stop healthy'),
        PlcTag(name: 'Overload_OK', path: 'Inputs/Overload_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Thermal overload healthy'),
        PlcTag(name: 'Motor_Latch', path: 'Internal/Motor_Latch', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Internal seal-in latch'),
        PlcTag(name: 'Motor_Run', path: 'Outputs/Motor_Run', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Motor contactor output'),
        PlcTag(
          name: 'DB_Motor1',
          path: 'Data/DB_Motor1',
          dataType: 'Motor_DUT',
          value: {'Run': false, 'Fault': false, 'Speed': 1450},
          ioType: 'Internal',
          description: 'Motor status/telemetry struct instance',
        ),
      ],
      structDefs: structDefs,
      programs: [
        PlcProgram(
          name: 'MotorControl_LD',
          language: 'LadderLogic',
          description: 'Motor start/stop seal-in rungs in Ladder Logic (LD)',
          rungs: [
            buildRung(
              index: 0,
              comment: 'Rung 0: Motor Latch Seal-In',
              main: [
                _xic('Start_PB', 'Start NO'),
                _xio('Stop_PB', 'Stop NC'),
                _xic('EStop_OK', 'E-Stop healthy'),
                _xic('Overload_OK', 'Overload healthy'),
                _ote('Motor_Latch', 'Seal-in latch'),
              ],
              branches: [
                BranchSpec(startIndex: 0, endIndex: 0, nodes: [_xic('Motor_Latch', 'Seal-in aux')]),
              ],
            ),
            buildRung(
              index: 1,
              comment: 'Rung 1: Motor Run Permissives',
              main: [
                _xic('Motor_Latch', 'Latched'),
                _xic('EStop_OK', 'E-Stop healthy'),
                _xic('Overload_OK', 'Overload healthy'),
                _ote('Motor_Run', 'Starter coil'),
              ],
            ),
          ],
        ),
      ],
      tasks: [
        PlcTask(name: 'MainContinuousTask', type: 'Continuous', periodMs: 100, programNames: ['MotorControl_LD']),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_motor',
          title: 'Motor Control HMI Dashboard',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'c1', title: 'START Motor (NO)', type: 'PushbuttonSwitch', tagBinding: 'Start_PB', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'c2', title: 'STOP Motor (NC)', type: 'PushbuttonSwitch', tagBinding: 'Stop_PB', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 'c3', title: 'Motor Running LED', type: 'LedIndicatorLight', tagBinding: 'Motor_Run', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'c4', title: 'E-Stop Healthy', type: 'ToggleSwitch', tagBinding: 'EStop_OK', gridSpanWidth: 1, accentColor: 'cyan'),
            HmiComponent(id: 'c5', title: 'Overload Healthy', type: 'ToggleSwitch', tagBinding: 'Overload_OK', gridSpanWidth: 1, accentColor: 'amber'),
            HmiComponent(id: 'c6', title: 'Motor Status', type: 'StatusPillDisplay', tagBinding: 'Motor_Run', gridSpanWidth: 2, accentColor: 'teal'),
          ],
        ),
      ],
    );
  }

  // ── 2. Tank Level Simulation (ST + FBD + SFC) ────────────────────────────

  static PlcProject _tankProject() => PlcProject(
    id: 'proj_tank',
    name: 'Tank Level Simulation',
    controllerName: 'PLC_02',
    scanPeriodMs: 100,
    tags: [
      PlcTag(name: 'Level_PV', path: 'Inputs/Level_PV', dataType: 'FLOAT64', value: 42.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Tank level sensor'),
      PlcTag(name: 'Level_SP', path: 'Internal/Level_SP', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal', engineeringUnits: '%', description: 'Level setpoint'),
      PlcTag(name: 'Auto_Mode', path: 'Inputs/Auto_Mode', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Auto/Manual switch'),
      PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Fill valve solenoid'),
      PlcTag(name: 'Drain_Valve', path: 'Outputs/Drain_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Drain valve solenoid'),
      PlcTag(name: 'High_Alarm', path: 'Outputs/High_Alarm', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'High level alarm'),
    ],
    structDefs: [],
    simRules: [
      SimRule(id: 'sim0', name: 'Tank fills while filling', targetPath: 'Level_PV',
          behavior: 'integrate', ratePerSec: 1.0, minValue: 0, maxValue: 100,
          condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim1', name: 'Tank drains while draining', targetPath: 'Level_PV',
          behavior: 'integrate', ratePerSec: -1.0, minValue: 0, maxValue: 100,
          condition: [SimClause(leftPath: 'Drain_Valve', comparator: '==', operand: 'true')]),
    ],
    programs: [
      PlcProgram(
        name: 'TankLevel_FBD',
        language: 'FunctionBlockDiagram',
        description: 'Tank level on/off fill/drain control',
        fbdBlocks: [
          FbdBlock(id: 't_auto', type: 'TAG_INPUT', title: 'Auto Mode', tagBinding: 'Auto_Mode', x: 50, y: 80),
          FbdBlock(id: 't_pv', type: 'TAG_INPUT', title: 'Level PV', tagBinding: 'Level_PV', x: 50, y: 200),
          FbdBlock(id: 't_sp', type: 'TAG_INPUT', title: 'Level SP', tagBinding: 'Level_SP', x: 50, y: 320),
          FbdBlock(id: 't_db', type: 'CONST', title: 'Deadband', tagBinding: '5.0', x: 50, y: 440),
          // Fill: Auto AND Level_PV < (Level_SP - 5.0)
          FbdBlock(id: 't_sub', type: 'SUB', title: 'SP - 5', tagBinding: '', x: 240, y: 360),
          FbdBlock(id: 't_lt', type: 'LT', title: 'PV < SP-5', tagBinding: '', x: 420, y: 220),
          FbdBlock(id: 't_af', type: 'AND', title: 'Fill Enable', tagBinding: '', x: 600, y: 160),
          FbdBlock(id: 't_of', type: 'TAG_OUTPUT', title: 'Fill Valve', tagBinding: 'Fill_Valve', x: 790, y: 160),
          // Drain: Auto AND Level_PV > (Level_SP + 5.0)
          FbdBlock(id: 't_add', type: 'ADD', title: 'SP + 5', tagBinding: '', x: 240, y: 500),
          FbdBlock(id: 't_gt', type: 'GT', title: 'PV > SP+5', tagBinding: '', x: 420, y: 380),
          FbdBlock(id: 't_ad', type: 'AND', title: 'Drain Enable', tagBinding: '', x: 600, y: 340),
          FbdBlock(id: 't_od', type: 'TAG_OUTPUT', title: 'Drain Valve', tagBinding: 'Drain_Valve', x: 790, y: 340),
          // High alarm: Level_PV > 85.0
          FbdBlock(id: 't_hi', type: 'CONST', title: 'High Limit', tagBinding: '85.0', x: 420, y: 540),
          FbdBlock(id: 't_ga', type: 'GT', title: 'PV > 85', tagBinding: '', x: 600, y: 520),
          FbdBlock(id: 't_oa', type: 'TAG_OUTPUT', title: 'High Alarm', tagBinding: 'High_Alarm', x: 790, y: 520),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 't_sp', fromPin: 'OUT', toBlockId: 't_sub', toPin: 'IN1'),  // Level_SP
          FbdWire(fromBlockId: 't_db', fromPin: 'OUT', toBlockId: 't_sub', toPin: 'IN2'),  // 5.0 -> SP-5
          FbdWire(fromBlockId: 't_pv', fromPin: 'OUT', toBlockId: 't_lt', toPin: 'IN1'),   // Level_PV
          FbdWire(fromBlockId: 't_sub', fromPin: 'OUT', toBlockId: 't_lt', toPin: 'IN2'),  // SP-5 -> PV < SP-5
          FbdWire(fromBlockId: 't_auto', fromPin: 'OUT', toBlockId: 't_af', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_lt', fromPin: 'OUT', toBlockId: 't_af', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_af', fromPin: 'OUT', toBlockId: 't_of', toPin: 'IN'),
          FbdWire(fromBlockId: 't_sp', fromPin: 'OUT', toBlockId: 't_add', toPin: 'IN1'),  // Level_SP
          FbdWire(fromBlockId: 't_db', fromPin: 'OUT', toBlockId: 't_add', toPin: 'IN2'),  // 5.0 -> SP+5
          FbdWire(fromBlockId: 't_pv', fromPin: 'OUT', toBlockId: 't_gt', toPin: 'IN1'),   // Level_PV
          FbdWire(fromBlockId: 't_add', fromPin: 'OUT', toBlockId: 't_gt', toPin: 'IN2'),  // SP+5 -> PV > SP+5
          FbdWire(fromBlockId: 't_auto', fromPin: 'OUT', toBlockId: 't_ad', toPin: 'IN1'),
          FbdWire(fromBlockId: 't_gt', fromPin: 'OUT', toBlockId: 't_ad', toPin: 'IN2'),
          FbdWire(fromBlockId: 't_ad', fromPin: 'OUT', toBlockId: 't_od', toPin: 'IN'),
          FbdWire(fromBlockId: 't_pv', fromPin: 'OUT', toBlockId: 't_ga', toPin: 'IN1'),   // Level_PV
          FbdWire(fromBlockId: 't_hi', fromPin: 'OUT', toBlockId: 't_ga', toPin: 'IN2'),   // 85.0 -> PV > 85
          FbdWire(fromBlockId: 't_ga', fromPin: 'OUT', toBlockId: 't_oa', toPin: 'IN'),
        ],
      ),
      PlcProgram(name: 'TankSequence_SFC', language: 'SequentialFunctionChart', description: 'Tank fill/drain sequence state machine'),
    ],
    tasks: [
      PlcTask(name: 'ProcessLoopTask', type: 'Continuous', periodMs: 100, programNames: ['TankLevel_FBD', 'TankSequence_SFC']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_tank',
        title: 'Tank Level Process Dashboard',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 't1', title: 'Tank Graphic', type: 'TankGraphicDisplay', tagBinding: 'Level_PV', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 't2', title: 'Level Setpoint', type: 'NumericSliderInput', tagBinding: 'Level_SP', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 't3', title: 'Auto Mode', type: 'ToggleSwitch', tagBinding: 'Auto_Mode', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 't4', title: 'Fill Valve LED', type: 'LedIndicatorLight', tagBinding: 'Fill_Valve', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 't5', title: 'Drain Valve LED', type: 'LedIndicatorLight', tagBinding: 'Drain_Valve', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 't6', title: 'High Alarm LED', type: 'LedIndicatorLight', tagBinding: 'High_Alarm', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 't7', title: 'Level Gauge', type: 'DigitalGaugeDisplay', tagBinding: 'Level_PV', gridSpanWidth: 4, accentColor: 'cyan'),
        ],
      ),
    ],
  );

  // ── 3. ST — Reactor Temperature Controller ──────────────────────────────

  static PlcProject _stReactorProject() => PlcProject(
    id: 'proj_st_reactor',
    name: 'ST — Reactor Temperature Controller',
    controllerName: 'PLC_ST',
    scanPeriodMs: 100,
    tags: [
      PlcTag(name: 'Temp_PV', path: 'Inputs/Temp_PV', dataType: 'FLOAT64', value: 22.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Reactor temperature process value'),
      PlcTag(name: 'Temp_SP', path: 'Internal/Temp_SP', dataType: 'FLOAT64', value: 75.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Temperature setpoint'),
      PlcTag(name: 'Temp_Ambient', path: 'Internal/Temp_Ambient', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Ambient temperature the reactor drifts toward with no actuation'),
      PlcTag(name: 'Auto_Mode', path: 'Inputs/Auto_Mode', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Auto / Manual selector switch'),
      PlcTag(name: 'Heat_Cmd', path: 'Outputs/Heat_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Heater element contactor'),
      PlcTag(name: 'Cool_Cmd', path: 'Outputs/Cool_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Cooling water valve'),
      PlcTag(name: 'Alarm_High', path: 'Outputs/Alarm_High', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'High temperature alarm (>95°C)'),
      PlcTag(name: 'Alarm_Low', path: 'Outputs/Alarm_Low', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Low temperature alarm (<5°C)'),
      PlcTag(name: 'Reactor_Ready', path: 'Outputs/Reactor_Ready', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Reactor at setpoint ±2°C'),
    ],
    structDefs: [],
    simRules: [
      // First-order thermal process: ambient pull always acts (the loss
      // term), heating/cooling add/remove energy while their contactors are
      // closed. The deadband ST controller (below) closes the loop, cycling
      // Heat_Cmd/Cool_Cmd to hold Temp_PV near Temp_SP.
      SimRule(id: 'sim0', name: 'Heating raises temp', targetPath: 'Temp_PV',
          behavior: 'integrate', ratePerSec: 3.0, minValue: 0, maxValue: 150,
          condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim1', name: 'Cooling lowers temp', targetPath: 'Temp_PV',
          behavior: 'integrate', ratePerSec: -3.0, minValue: 0, maxValue: 150,
          condition: [SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim2', name: 'Ambient pull (first-order lag)', targetPath: 'Temp_PV',
          behavior: 'firstOrderLag', sourcePath: 'Temp_Ambient', tauSec: 30, minValue: 0, maxValue: 150),
    ],
    programs: [
      PlcProgram(
        name: 'ReactorTemp_ST',
        language: 'StructuredText',
        description: 'Reactor temperature on/off deadband control with alarms',
        stSource: r'''// IEC 61131-3 Structured Text — Reactor Temperature Controller
// ±2°C deadband on/off control with high/low trip alarms

IF Auto_Mode THEN
    IF Temp_PV < (Temp_SP - 2.0) THEN
        Heat_Cmd := TRUE;
        Cool_Cmd := FALSE;
    ELSIF Temp_PV > (Temp_SP + 2.0) THEN
        Heat_Cmd := FALSE;
        Cool_Cmd := TRUE;
    ELSE
        Heat_Cmd := FALSE;
        Cool_Cmd := FALSE;
    END_IF;
ELSE
    Heat_Cmd := FALSE;
    Cool_Cmd := FALSE;
END_IF;

Alarm_High    := Temp_PV > 95.0;
Alarm_Low     := Temp_PV < 5.0;
Reactor_Ready := NOT Alarm_High
             AND NOT Alarm_Low
             AND (Temp_PV >= Temp_SP - 2.0)
             AND (Temp_PV <= Temp_SP + 2.0);''',
      ),
    ],
    tasks: [
      PlcTask(name: 'TempControlTask', type: 'Continuous', periodMs: 100, programNames: ['ReactorTemp_ST']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_st_reactor',
        title: 'Reactor Temperature HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'sr1', title: 'Reactor Temperature (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_PV', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'sr2', title: 'Temperature Setpoint', type: 'NumericSliderInput', tagBinding: 'Temp_SP', gridSpanWidth: 4, accentColor: 'teal'),
          HmiComponent(id: 'sr3', title: 'Auto Mode', type: 'ToggleSwitch', tagBinding: 'Auto_Mode', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'sr4', title: 'Heater ON', type: 'LedIndicatorLight', tagBinding: 'Heat_Cmd', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'sr5', title: 'Cooler ON', type: 'LedIndicatorLight', tagBinding: 'Cool_Cmd', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'sr6', title: 'Reactor Ready', type: 'LedIndicatorLight', tagBinding: 'Reactor_Ready', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'sr7', title: 'HIGH TEMP ALARM', type: 'StatusPillDisplay', tagBinding: 'Alarm_High', gridSpanWidth: 2, accentColor: 'red'),
          HmiComponent(id: 'sr8', title: 'LOW TEMP ALARM', type: 'StatusPillDisplay', tagBinding: 'Alarm_Low', gridSpanWidth: 2, accentColor: 'amber'),
        ],
      ),
    ],
  );

  // ── 4. LD — Conveyor Belt Control ────────────────────────────────────────

  static PlcProject _ldConveyorProject() => PlcProject(
    id: 'proj_ld_conveyor',
    name: 'LD — Conveyor Belt Control',
    controllerName: 'PLC_LD',
    scanPeriodMs: 100,
    tags: [
      PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Start pushbutton NO'),
      PlcTag(name: 'Stop_PB', path: 'Inputs/Stop_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Stop pushbutton NC'),
      PlcTag(name: 'EStop', path: 'Inputs/EStop', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'E-Stop healthy NC contact (TRUE = healthy)'),
      PlcTag(name: 'Manual_Jog', path: 'Inputs/Manual_Jog', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Manual jog pushbutton'),
      PlcTag(name: 'Belt_Latch', path: 'Internal/Belt_Latch', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Belt motor seal-in latch'),
      PlcTag(name: 'Belt_Motor', path: 'Outputs/Belt_Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Belt drive motor contactor'),
      PlcTag(name: 'Photo_Eye', path: 'Inputs/Photo_Eye', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Part detection photo eye'),
      PlcTag(name: 'Belt_Jammed', path: 'Outputs/Belt_Jammed', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Belt jam alarm output'),
      PlcTag(name: 'Part_Present', path: 'Internal/Part_Present', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Part present internal flag'),
      PlcTag(
        name: 'JamTimer',
        path: 'Timers/JamTimer',
        dataType: 'TIMER',
        value: defaultValueFor(_emptyProject, 'TIMER', 0),
        ioType: 'Internal',
        description: 'On-delay timer: belt running with no part for 5s trips jam alarm',
      ),
    ],
    structDefs: [],
    simRules: [
      SimRule(id: 'sim0', name: 'Photo eye blips while belt runs', targetPath: 'Photo_Eye',
          behavior: 'pulse', onMs: 2000, offMs: 2500,
          // parts every ~4.5s; the 5s no-part jam threshold only trips when parts stop
          condition: [SimClause(leftPath: 'Belt_Motor', comparator: '==', operand: 'true')]),
    ],
    programs: [
      PlcProgram(
        name: 'ConveyorBelt_LD',
        language: 'LadderLogic',
        description: 'Conveyor belt start/stop with E-Stop interlock and jam detection',
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Belt Start/Stop — E-Stop and Jam Alarm Interlocks',
            main: [
              _xic('Start_PB', 'Start NO'),
              _xio('Stop_PB', 'Stop NC'),
              _xic('EStop', 'E-Stop healthy NC'),
              _xio('Belt_Jammed', 'Jam interlock NC'),
              _ote('Belt_Motor', 'Belt drive contactor'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [_xic('Belt_Latch', 'Seal-in aux')]),
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [_xic('Manual_Jog', 'Manual jog')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Belt Motor Running — Set Seal-In Latch',
            main: [_xic('Belt_Motor', 'Motor aux'), _otl('Belt_Latch', 'Latch set')],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: Part Detection — Photo Eye Signal',
            main: [_xic('Photo_Eye', 'Part detected NO'), _ote('Part_Present', 'Part present flag')],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: Jam Detection — Belt Running With No Parts for 5 Seconds',
            main: [
              _xic('Belt_Motor', 'Belt running'),
              _xio('Part_Present', 'No part NC'),
              _ton('JamTimer', 5000, '5s jam timer'),
            ],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Belt Jammed Alarm Latch',
            main: [_xic('JamTimer.DN', 'Timer done'), _otl('Belt_Jammed', 'Latch jam alarm')],
          ),
          // Intentional: once a part is seen the jam unlatches and the belt
          // auto-resumes (the seal-in latch was never dropped). A jam is a
          // transient blockage, unlike the motor's E-Stop fault-latch, which
          // deliberately requires a fresh Start press after clearing.
          buildRung(
            index: 5,
            comment: 'Rung 5: Photo Eye Clears the Jam Alarm',
            main: [_xic('Photo_Eye', 'Part seen'), _otu('Belt_Jammed', 'Unlatch jam alarm')],
          ),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'ConveyorTask', type: 'Continuous', periodMs: 100, programNames: ['ConveyorBelt_LD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_ld_conveyor',
        title: 'Conveyor Belt Control HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'lc1', title: 'START Belt (NO)', type: 'PushbuttonSwitch', tagBinding: 'Start_PB', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'lc2', title: 'STOP Belt (NC)', type: 'PushbuttonSwitch', tagBinding: 'Stop_PB', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'lc3', title: 'Manual JOG', type: 'PushbuttonSwitch', tagBinding: 'Manual_Jog', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'lc4', title: 'E-Stop Healthy', type: 'ToggleSwitch', tagBinding: 'EStop', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'lc5', title: 'Belt Motor Running', type: 'LedIndicatorLight', tagBinding: 'Belt_Motor', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'lc6', title: 'Part Detected', type: 'LedIndicatorLight', tagBinding: 'Photo_Eye', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'lc7', title: 'JAM ALARM', type: 'StatusPillDisplay', tagBinding: 'Belt_Jammed', gridSpanWidth: 2, accentColor: 'red'),
          HmiComponent(id: 'lc8', title: 'Belt Status', type: 'StatusPillDisplay', tagBinding: 'Belt_Motor', gridSpanWidth: 2, accentColor: 'teal'),
        ],
      ),
    ],
  );

  // ── 5. FBD — HVAC Zone Controller ───────────────────────────────────────

  static PlcProject _fbdHvacProject() => PlcProject(
    id: 'proj_fbd_hvac',
    name: 'FBD — HVAC Zone Controller',
    controllerName: 'PLC_FBD',
    scanPeriodMs: 100,
    tags: [
      PlcTag(name: 'Room_Temp', path: 'Inputs/Room_Temp', dataType: 'FLOAT64', value: 18.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Zone temperature sensor'),
      PlcTag(name: 'Setpoint', path: 'Internal/Setpoint', dataType: 'FLOAT64', value: 22.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Comfort temperature setpoint'),
      PlcTag(name: 'Occupied', path: 'Inputs/Occupied', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Zone occupancy sensor'),
      PlcTag(name: 'Window_Open', path: 'Inputs/Window_Open', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Window contact switch'),
      PlcTag(name: 'Fan_Cmd', path: 'Outputs/Fan_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Zone fan motor command'),
      PlcTag(name: 'Heat_Cmd', path: 'Outputs/Heat_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Heating coil valve'),
      PlcTag(name: 'Cool_Cmd', path: 'Outputs/Cool_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Cooling coil valve'),
      PlcTag(name: 'Hvac_Active', path: 'Internal/Hvac_Active', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'HVAC system enabled'),
    ],
    structDefs: [],
    simRules: [
      SimRule(id: 'sim0', name: 'Heating warms room', targetPath: 'Room_Temp',
          behavior: 'integrate', ratePerSec: 0.16, minValue: 0, maxValue: 40,
          condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim1', name: 'Cooling cools room', targetPath: 'Room_Temp',
          behavior: 'integrate', ratePerSec: -0.16, minValue: 0, maxValue: 40,
          condition: [SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim2', name: 'Ambient drift', targetPath: 'Room_Temp',
          behavior: 'integrate', ratePerSec: -0.02, minValue: 15, maxValue: 40,
          condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'false'), SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'false')]),
    ],
    programs: [
      PlcProgram(
        name: 'HvacZone_FBD',
        language: 'FunctionBlockDiagram',
        description: 'HVAC zone control using AND/NOT/SUB/ADD/LT/GT signal flow gates',
        fbdBlocks: [
          // Occupancy & window chain → enable HVAC
          FbdBlock(id: 'f_i1', type: 'TAG_INPUT', title: 'Occupied', tagBinding: 'Occupied', x: 50, y: 80),
          FbdBlock(id: 'f_i2', type: 'TAG_INPUT', title: 'Window Open', tagBinding: 'Window_Open', x: 50, y: 200),
          FbdBlock(id: 'f_n1', type: 'NOT', title: 'Window Closed', tagBinding: '', x: 240, y: 200),
          FbdBlock(id: 'f_a1', type: 'AND', title: 'HVAC Enable', tagBinding: '', x: 420, y: 130),
          FbdBlock(id: 'f_o1', type: 'TAG_OUTPUT', title: 'Fan Cmd', tagBinding: 'Fan_Cmd', x: 620, y: 80),
          FbdBlock(id: 'f_o2', type: 'TAG_OUTPUT', title: 'HVAC Active', tagBinding: 'Hvac_Active', x: 620, y: 200),
          // Temperature comparison chain → heating / cooling (±1.0 deadband)
          FbdBlock(id: 'f_i3', type: 'TAG_INPUT', title: 'Room Temp', tagBinding: 'Room_Temp', x: 50, y: 360),
          FbdBlock(id: 'f_i4', type: 'TAG_INPUT', title: 'Setpoint', tagBinding: 'Setpoint', x: 50, y: 470),
          FbdBlock(id: 'f_c1', type: 'CONST', title: 'Deadband', tagBinding: '1.0', x: 50, y: 580),
          FbdBlock(id: 'f_s1', type: 'SUB', title: 'SP - 1', tagBinding: '', x: 240, y: 520),
          FbdBlock(id: 'f_lt', type: 'LT', title: 'Temp < SP-1', tagBinding: '', x: 420, y: 380),
          FbdBlock(id: 'f_a2', type: 'AND', title: 'Heat Enable', tagBinding: '', x: 600, y: 360),
          FbdBlock(id: 'f_o3', type: 'TAG_OUTPUT', title: 'Heat Cmd', tagBinding: 'Heat_Cmd', x: 790, y: 360),
          FbdBlock(id: 'f_a3', type: 'ADD', title: 'SP + 1', tagBinding: '', x: 240, y: 650),
          FbdBlock(id: 'f_gt', type: 'GT', title: 'Temp > SP+1', tagBinding: '', x: 420, y: 610),
          FbdBlock(id: 'f_a4', type: 'AND', title: 'Cool Enable', tagBinding: '', x: 600, y: 590),
          FbdBlock(id: 'f_o4', type: 'TAG_OUTPUT', title: 'Cool Cmd', tagBinding: 'Cool_Cmd', x: 790, y: 590),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'f_i2', fromPin: 'OUT', toBlockId: 'f_n1', toPin: 'IN'),
          FbdWire(fromBlockId: 'f_i1', fromPin: 'OUT', toBlockId: 'f_a1', toPin: 'IN1'),
          FbdWire(fromBlockId: 'f_n1', fromPin: 'OUT', toBlockId: 'f_a1', toPin: 'IN2'),
          FbdWire(fromBlockId: 'f_a1', fromPin: 'OUT', toBlockId: 'f_o1', toPin: 'IN'),
          FbdWire(fromBlockId: 'f_a1', fromPin: 'OUT', toBlockId: 'f_o2', toPin: 'IN'),
          // Heat: Room_Temp < (Setpoint - 1.0)
          FbdWire(fromBlockId: 'f_i4', fromPin: 'OUT', toBlockId: 'f_s1', toPin: 'IN1'), // Setpoint
          FbdWire(fromBlockId: 'f_c1', fromPin: 'OUT', toBlockId: 'f_s1', toPin: 'IN2'), // 1.0
          FbdWire(fromBlockId: 'f_i3', fromPin: 'OUT', toBlockId: 'f_lt', toPin: 'IN1'), // Room_Temp
          FbdWire(fromBlockId: 'f_s1', fromPin: 'OUT', toBlockId: 'f_lt', toPin: 'IN2'), // SP-1
          FbdWire(fromBlockId: 'f_a1', fromPin: 'OUT', toBlockId: 'f_a2', toPin: 'IN1'),
          FbdWire(fromBlockId: 'f_lt', fromPin: 'OUT', toBlockId: 'f_a2', toPin: 'IN2'),
          FbdWire(fromBlockId: 'f_a2', fromPin: 'OUT', toBlockId: 'f_o3', toPin: 'IN'),
          // Cool: Room_Temp > (Setpoint + 1.0)
          FbdWire(fromBlockId: 'f_i4', fromPin: 'OUT', toBlockId: 'f_a3', toPin: 'IN1'), // Setpoint
          FbdWire(fromBlockId: 'f_c1', fromPin: 'OUT', toBlockId: 'f_a3', toPin: 'IN2'), // 1.0
          FbdWire(fromBlockId: 'f_i3', fromPin: 'OUT', toBlockId: 'f_gt', toPin: 'IN1'), // Room_Temp
          FbdWire(fromBlockId: 'f_a3', fromPin: 'OUT', toBlockId: 'f_gt', toPin: 'IN2'), // SP+1
          FbdWire(fromBlockId: 'f_a1', fromPin: 'OUT', toBlockId: 'f_a4', toPin: 'IN1'),
          FbdWire(fromBlockId: 'f_gt', fromPin: 'OUT', toBlockId: 'f_a4', toPin: 'IN2'),
          FbdWire(fromBlockId: 'f_a4', fromPin: 'OUT', toBlockId: 'f_o4', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'HvacControlTask', type: 'Continuous', periodMs: 100, programNames: ['HvacZone_FBD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_fbd_hvac',
        title: 'HVAC Zone Controller HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'hv1', title: 'Zone Temperature (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Room_Temp', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'hv2', title: 'Comfort Setpoint', type: 'NumericSliderInput', tagBinding: 'Setpoint', gridSpanWidth: 4, accentColor: 'teal'),
          HmiComponent(id: 'hv3', title: 'Zone Occupied', type: 'ToggleSwitch', tagBinding: 'Occupied', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'hv4', title: 'Window Open', type: 'ToggleSwitch', tagBinding: 'Window_Open', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'hv5', title: 'Fan Running', type: 'LedIndicatorLight', tagBinding: 'Fan_Cmd', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'hv6', title: 'Heating ON', type: 'LedIndicatorLight', tagBinding: 'Heat_Cmd', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'hv7', title: 'Cooling ON', type: 'LedIndicatorLight', tagBinding: 'Cool_Cmd', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'hv8', title: 'HVAC Active', type: 'StatusPillDisplay', tagBinding: 'Hvac_Active', gridSpanWidth: 2, accentColor: 'teal'),
        ],
      ),
    ],
  );

  // ── 6. SFC — Batch Bottle Filling Sequence ───────────────────────────────

  static PlcProject _sfcFillingProject() => PlcProject(
    id: 'proj_sfc_filling',
    name: 'SFC — Batch Bottle Filling',
    controllerName: 'PLC_SFC',
    scanPeriodMs: 200,
    tags: [
      PlcTag(name: 'Start_Cmd', path: 'Inputs/Start_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Operator start command'),
      PlcTag(name: 'Bottle_Present', path: 'Inputs/Bottle_Present', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Bottle presence sensor'),
      PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Filler valve solenoid'),
      PlcTag(name: 'Cap_Solenoid', path: 'Outputs/Cap_Solenoid', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Capping solenoid'),
      PlcTag(name: 'Eject_Cyl', path: 'Outputs/Eject_Cyl', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Ejection cylinder'),
      PlcTag(name: 'Fill_Level', path: 'Inputs/Fill_Level', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Bottle fill level sensor'),
      PlcTag(name: 'Filled_Count', path: 'Internal/Filled_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Bottles filled counter'),
      PlcTag(name: 'Sequence_Running', path: 'Internal/Sequence_Running', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Sequence active flag'),
      PlcTag(name: 'Sfc_Step', path: 'Internal/Sfc_Step', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Current SFC step index (0–5)'),
      PlcTag(name: 'Step_Delay', path: 'Internal/Step_Delay', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Step hold-time scan counter'),
    ],
    structDefs: [],
    simRules: [
      SimRule(id: 'sim0', name: 'Bottle fills while valve open', targetPath: 'Fill_Level',
          behavior: 'integrate', ratePerSec: 8.0, minValue: 0, maxValue: 100,
          condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
    ],
    programs: [
      PlcProgram(
        name: 'BottleFill_SFC',
        language: 'SequentialFunctionChart',
        description: 'Automated bottle fill-cap-eject sequence controller',
        sfcSteps: [
          SfcStep(id: 's0', name: 'IDLE', isInitial: true,
            actionSt: 'Sfc_Step := 0;\nFill_Valve := FALSE;\nCap_Solenoid := FALSE;\nEject_Cyl := FALSE;\nSequence_Running := FALSE;\nFill_Level := 0.0;'),
          SfcStep(id: 's1', name: 'WAIT_BOTTLE',
            actionSt: 'Sfc_Step := 1;\nSequence_Running := TRUE;\nFill_Valve := FALSE;\nEject_Cyl := FALSE;\nFill_Level := 0.0;'),
          SfcStep(id: 's2', name: 'FILLING',
            actionSt: 'Sfc_Step := 2;\nFill_Valve := TRUE;\n// Fill_Level rises until >= 95%'),
          SfcStep(id: 's3', name: 'CAPPING',
            actionSt: 'Sfc_Step := 3;\nFill_Valve := FALSE;\nCap_Solenoid := TRUE;\n// Hold for cap press time'),
          SfcStep(id: 's4', name: 'EJECTING',
            actionSt: 'Sfc_Step := 4;\nCap_Solenoid := FALSE;\nEject_Cyl := TRUE;'),
          SfcStep(id: 's5', name: 'COUNT',
            actionSt: 'Sfc_Step := 5;\nFilled_Count := Filled_Count + 1;\nEject_Cyl := FALSE;'),
        ],
        sfcTransitions: [
          SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Start_Cmd'),
          SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'Bottle_Present'),
          SfcTransition(id: 't2', fromStepId: 's2', toStepId: 's3', conditionSt: 'Fill_Level >= 95.0'),
          SfcTransition(id: 't3', fromStepId: 's3', toStepId: 's4', conditionSt: 'STEP_T >= 3000  (* cap press dwell *)'),
          SfcTransition(id: 't4', fromStepId: 's4', toStepId: 's5', conditionSt: 'STEP_T >= 2000  (* eject stroke *)'),
          SfcTransition(id: 't5', fromStepId: 's5', toStepId: 's1', conditionSt: 'TRUE'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'FillerSequenceTask', type: 'Periodic', periodMs: 200, programNames: ['BottleFill_SFC']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_sfc_filling',
        title: 'Bottle Filling Sequence HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'sf1', title: 'START Sequence', type: 'PushbuttonSwitch', tagBinding: 'Start_Cmd', gridSpanWidth: 2, accentColor: 'green'),
          HmiComponent(id: 'sf2', title: 'Bottle Present', type: 'ToggleSwitch', tagBinding: 'Bottle_Present', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'sf3', title: 'Fill Level (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Fill_Level', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'sf4', title: 'Fill Valve', type: 'LedIndicatorLight', tagBinding: 'Fill_Valve', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'sf5', title: 'Cap Solenoid', type: 'LedIndicatorLight', tagBinding: 'Cap_Solenoid', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'sf6', title: 'Eject Cylinder', type: 'LedIndicatorLight', tagBinding: 'Eject_Cyl', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'sf7', title: 'Sequence Running', type: 'LedIndicatorLight', tagBinding: 'Sequence_Running', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'sf8', title: 'Filled Count', type: 'StatusPillDisplay', tagBinding: 'Filled_Count', gridSpanWidth: 4, accentColor: 'teal'),
        ],
      ),
    ],
  );

  // ── 6b. SFC — Batch Mix & Dispatch (parallel fork/join + alternative) ────

  static PlcProject _sfcBatchMixProject() => PlcProject(
    id: 'proj_sfc_batchmix',
    name: 'SFC — Batch Mix & Dispatch',
    controllerName: 'PLC_BATCHMIX',
    scanPeriodMs: 200,
    tags: [
      PlcTag(name: 'Start_Cmd', path: 'Inputs/Start_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Operator start command'),
      PlcTag(name: 'Quality_OK', path: 'Inputs/Quality_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Batch quality accept (true = dispatch, false = reject)'),
      PlcTag(name: 'Temp_PV', path: 'Inputs/Temp_PV', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Mix tank temperature'),
      PlcTag(name: 'Fill_Level', path: 'Inputs/Fill_Level', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Mix tank fill level'),
      PlcTag(name: 'Temp_SP', path: 'Internal/Temp_SP', dataType: 'FLOAT64', value: 70.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Target temperature'),
      PlcTag(name: 'Fill_Target', path: 'Internal/Fill_Target', dataType: 'FLOAT64', value: 90.0, ioType: 'Internal', engineeringUnits: '%', description: 'Target fill level'),
      PlcTag(name: 'Batch_Count', path: 'Internal/Batch_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Dispatched batches'),
      PlcTag(name: 'Reject_Count', path: 'Internal/Reject_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Rejected batches'),
      PlcTag(name: 'Heater', path: 'Outputs/Heater', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Tank heater'),
      PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Fill valve'),
      PlcTag(name: 'Agitator', path: 'Outputs/Agitator', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Mixer agitator'),
      PlcTag(name: 'Dispatch_Pump', path: 'Outputs/Dispatch_Pump', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Dispatch transfer pump'),
      PlcTag(name: 'Drain_Valve', path: 'Outputs/Drain_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Reject drain valve'),
    ],
    structDefs: [],
    simRules: [
      SimRule(id: 'sim0', name: 'Heating raises temp', targetPath: 'Temp_PV',
          behavior: 'integrate', ratePerSec: 12.0, minValue: 20, maxValue: 95,
          condition: [SimClause(leftPath: 'Heater', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim1', name: 'Filling raises level', targetPath: 'Fill_Level',
          behavior: 'integrate', ratePerSec: 30.0, minValue: 0, maxValue: 100,
          condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
    ],
    programs: [
      PlcProgram(
        name: 'BatchMix_SFC',
        language: 'SequentialFunctionChart',
        description: 'Batch mix sequence: parallel heat/fill fork-join, then quality-gated dispatch/reject',
        sfcSteps: [
          SfcStep(id: 's0', name: 'IDLE', isInitial: true,
            actionSt: 'Heater := FALSE;\nFill_Valve := FALSE;\nAgitator := FALSE;\nDispatch_Pump := FALSE;\nDrain_Valve := FALSE;\nTemp_PV := 20.0;\nFill_Level := 0.0;'),
          SfcStep(id: 's1', name: 'HEATING', actionSt: 'Heater := TRUE;'),
          SfcStep(id: 's2', name: 'HEAT_DONE', actionSt: 'Heater := FALSE;'),
          SfcStep(id: 's3', name: 'FILLING', actionSt: 'Fill_Valve := TRUE;'),
          SfcStep(id: 's4', name: 'FILL_DONE', actionSt: 'Fill_Valve := FALSE;'),
          SfcStep(id: 's5', name: 'MIXING', actionSt: 'Agitator := TRUE;'),
          SfcStep(id: 's6', name: 'DISPATCH', actionSt: 'Agitator := FALSE;\nDispatch_Pump := TRUE;\nBatch_Count := Batch_Count + 1;'),
          SfcStep(id: 's7', name: 'REJECT', actionSt: 'Agitator := FALSE;\nDrain_Valve := TRUE;\nReject_Count := Reject_Count + 1;'),
        ],
        sfcTransitions: [
          SfcTransition(id: 't0', fromStepId: 's0', toStepId: '', conditionSt: 'Start_Cmd',
              kind: 'parallelFork', toStepIds: ['s1', 's3']),
          SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'Temp_PV >= Temp_SP'),
          SfcTransition(id: 't2', fromStepId: 's3', toStepId: 's4', conditionSt: 'Fill_Level >= Fill_Target'),
          SfcTransition(id: 'tj', fromStepId: '', toStepId: 's5', conditionSt: 'TRUE',
              kind: 'parallelJoin', fromStepIds: ['s2', 's4']),
          SfcTransition(id: 't3', fromStepId: 's5', toStepId: 's6', conditionSt: 'STEP_T >= 3000 AND Quality_OK'),
          SfcTransition(id: 't4', fromStepId: 's5', toStepId: 's7', conditionSt: 'STEP_T >= 3000 AND NOT Quality_OK'),
          SfcTransition(id: 't5', fromStepId: 's6', toStepId: 's0', conditionSt: 'STEP_T >= 2000'),
          SfcTransition(id: 't6', fromStepId: 's7', toStepId: 's0', conditionSt: 'STEP_T >= 2000'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'BatchSequenceTask', type: 'Periodic', periodMs: 200, programNames: ['BatchMix_SFC']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_sfc_batchmix',
        title: 'Batch Mix & Dispatch HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'bm1', title: 'START Batch', type: 'PushbuttonSwitch', tagBinding: 'Start_Cmd', gridSpanWidth: 2, accentColor: 'green'),
          HmiComponent(id: 'bm2', title: 'Quality OK', type: 'ToggleSwitch', tagBinding: 'Quality_OK', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'bm3', title: 'Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_PV', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'bm4', title: 'Fill (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Fill_Level', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'bm5', title: 'Heater', type: 'LedIndicatorLight', tagBinding: 'Heater', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'bm6', title: 'Fill Valve', type: 'LedIndicatorLight', tagBinding: 'Fill_Valve', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'bm7', title: 'Agitator', type: 'LedIndicatorLight', tagBinding: 'Agitator', gridSpanWidth: 1, accentColor: 'teal'),
          HmiComponent(id: 'bm8', title: 'Dispatch', type: 'LedIndicatorLight', tagBinding: 'Dispatch_Pump', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'bm9', title: 'Drain', type: 'LedIndicatorLight', tagBinding: 'Drain_Valve', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'bm10', title: 'Dispatched', type: 'StatusPillDisplay', tagBinding: 'Batch_Count', gridSpanWidth: 2, accentColor: 'green'),
          HmiComponent(id: 'bm11', title: 'Rejected', type: 'StatusPillDisplay', tagBinding: 'Reject_Count', gridSpanWidth: 2, accentColor: 'red'),
        ],
      ),
    ],
  );

  // ── 7. All Languages — Water Treatment Plant ─────────────────────────────

  static PlcProject _allWaterProject() {
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
          value: defaultValueFor(_emptyProject, 'TIMER', 0)..['PRE'] = 30000,
          ioType: 'Internal',
          description: 'On-delay timer: 30s backwash cycle on sustained high turbidity',
        ),
        // Showcase array tag
        PlcTag(
          name: 'Recipe_Steps',
          path: 'Recipe/Steps',
          dataType: 'INT16',
          arrayLength: 8,
          value: defaultValueFor(_emptyProject, 'INT16', 8),
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
              _xic('Start_PB', 'Start NO'),
              _xio('Stop_PB', 'Stop NC'),
              _xic('EStop', 'E-Stop NC healthy'),
              _xio('Alarm_Active', 'Alarm NC interlock'),
              _ote('Pump_Motor', 'Main pump contactor'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [_xic('Pump_Latch', 'Seal-in')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Pump Running Seal-In Latch',
            main: [_xic('Pump_Motor', 'Motor aux'), _otl('Pump_Latch', 'Latch set')],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: Chemical Dosing Interlock — Dose When Quality Fails',
            main: [
              _xic('Pump_Motor', 'Pump running'),
              _xio('Quality_OK', 'Quality not OK NC'),
              _ote('Treat_Dosing', 'Dosing pump output'),
            ],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: Backwash TON — High Turbidity Triggers Backwash Timer',
            main: [
              _xio('Quality_OK', 'Quality not OK NC'),
              _xic('Pump_Motor', 'Pump running'),
              _ton('BackwashTimer', 30000, '30s backwash timer'),
            ],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Backwash Active Output',
            main: [_xic('BackwashTimer.DN', 'Timer done'), _ote('Backwash_Active', 'Backwash active')],
          ),
        ],
      ),
      // FBD: Water quality gate logic
      PlcProgram(
        name: 'WaterQuality_FBD',
        language: 'FunctionBlockDiagram',
        description: 'Water quality gate logic using LT/GT/AND signal flow gates',
        fbdBlocks: [
          FbdBlock(id: 'wf_i1', type: 'TAG_INPUT', title: 'Turbidity PV', tagBinding: 'Turbidity_PV', x: 50, y: 80),
          FbdBlock(id: 'wf_i2', type: 'TAG_INPUT', title: 'Turbidity SP', tagBinding: 'Turbidity_SP', x: 50, y: 190),
          FbdBlock(id: 'wf_lt', type: 'LT', title: 'Turbidity < SP', tagBinding: '', x: 260, y: 130),
          FbdBlock(id: 'wf_i3', type: 'TAG_INPUT', title: 'Level PV', tagBinding: 'Level_PV', x: 50, y: 320),
          FbdBlock(id: 'wf_c1', type: 'CONST', title: 'Min Level', tagBinding: '10.0', x: 50, y: 430),
          FbdBlock(id: 'wf_gt', type: 'GT', title: 'Level > 10', tagBinding: '', x: 260, y: 360),
          FbdBlock(id: 'wf_a1', type: 'AND', title: 'Quality OK', tagBinding: '', x: 460, y: 240),
          FbdBlock(id: 'wf_o1', type: 'TAG_OUTPUT', title: 'Quality OK', tagBinding: 'Quality_OK', x: 660, y: 240),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'wf_i1', fromPin: 'OUT', toBlockId: 'wf_lt', toPin: 'IN1'), // Turbidity_PV
          FbdWire(fromBlockId: 'wf_i2', fromPin: 'OUT', toBlockId: 'wf_lt', toPin: 'IN2'), // Turbidity_SP
          FbdWire(fromBlockId: 'wf_i3', fromPin: 'OUT', toBlockId: 'wf_gt', toPin: 'IN1'), // Level_PV
          FbdWire(fromBlockId: 'wf_c1', fromPin: 'OUT', toBlockId: 'wf_gt', toPin: 'IN2'), // 10.0
          FbdWire(fromBlockId: 'wf_lt', fromPin: 'OUT', toBlockId: 'wf_a1', toPin: 'IN1'),
          FbdWire(fromBlockId: 'wf_gt', fromPin: 'OUT', toBlockId: 'wf_a1', toPin: 'IN2'),
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

  // ── 7. FBD — Tank Level PID Control ─────────────────────────────────────
  //
  // Closed-loop showcase for the PID function block: a PID compares
  // Level_SP against Level_PV and drives Valve_CV (0-100%), which controls
  // an analog-scaled inflow into the tank (sim rule keyed off Valve_CV via
  // sourcePath/refValue). A constant outflow disturbance means the valve
  // must hold open at a non-zero, non-saturated position for Level_PV to
  // sit at Level_SP — proof the loop is actually regulating, not just
  // full-opening once and coasting.
  //
  // Gains (Kp=1.0, Ki=0.2, Kd=0.05) were tuned by running the closed-loop
  // scan pipeline (see test/pid_loop_integration_test.dart): starting at
  // Level_PV=10 against Level_SP=60, the loop overshoots modestly to ~77%
  // around scan 40 then damps, settling within +/-4% of setpoint well before
  // scan 300 (of the test's 600) and holding there, with Valve_CV modulating
  // near ~16.7% (the inflow/outflow balance point) rather than sticking at a
  // rail. Zeroing the gains would pin Valve_CV at 0 and leave Level_PV at its
  // initial value forever — this is what makes the loop test falsifiable.
  static PlcProject _fbdPidTankLevelProject() => PlcProject(
    id: 'proj_tank_level_pid',
    name: 'Tank Level PID Control',
    controllerName: 'PLC_PID',
    scanPeriodMs: 500,
    tags: [
      PlcTag(name: 'Level_PV', path: 'Inputs/Level_PV', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Tank level process value'),
      PlcTag(name: 'Level_SP', path: 'Internal/Level_SP', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Tank level setpoint'),
      PlcTag(name: 'Valve_CV', path: 'Outputs/Valve_CV', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', engineeringUnits: '%', description: 'Inlet valve control variable (PID output)'),
    ],
    structDefs: [],
    simRules: [
      // Inflow: analog-scaled by Valve_CV — effective rate = 6.0 %/s * (Valve_CV/100).
      // Full-open valve fills the tank at 6%/s.
      SimRule(id: 'sim0', name: 'Inflow scaled by valve position', targetPath: 'Level_PV',
          behavior: 'integrate', ratePerSec: 6.0, sourcePath: 'Valve_CV', refValue: 100.0,
          minValue: 0, maxValue: 100),
      // Constant outflow disturbance the loop must hold against.
      SimRule(id: 'sim1', name: 'Constant outflow disturbance', targetPath: 'Level_PV',
          behavior: 'integrate', ratePerSec: -1.0, minValue: 0, maxValue: 100),
    ],
    programs: [
      PlcProgram(
        name: 'LevelPID_FBD',
        language: 'FunctionBlockDiagram',
        description: 'PID control block holds Level_PV at Level_SP by driving Valve_CV',
        fbdBlocks: [
          FbdBlock(id: 'p_sp', type: 'TAG_INPUT', title: 'Level SP', tagBinding: 'Level_SP', x: 50, y: 80),
          FbdBlock(id: 'p_pv', type: 'TAG_INPUT', title: 'Level PV', tagBinding: 'Level_PV', x: 50, y: 200),
          FbdBlock(id: 'p_kp', type: 'CONST', title: 'Kp', tagBinding: '1.0', x: 50, y: 320),
          FbdBlock(id: 'p_ki', type: 'CONST', title: 'Ki', tagBinding: '0.2', x: 50, y: 400),
          FbdBlock(id: 'p_kd', type: 'CONST', title: 'Kd', tagBinding: '0.05', x: 50, y: 480),
          FbdBlock(id: 'p_pid', type: 'PID', title: 'Level PID', tagBinding: '', x: 320, y: 250),
          FbdBlock(id: 'p_cv', type: 'TAG_OUTPUT', title: 'Valve CV', tagBinding: 'Valve_CV', x: 560, y: 250),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'p_sp', fromPin: 'OUT', toBlockId: 'p_pid', toPin: 'SP'),
          FbdWire(fromBlockId: 'p_pv', fromPin: 'OUT', toBlockId: 'p_pid', toPin: 'PV'),
          FbdWire(fromBlockId: 'p_kp', fromPin: 'OUT', toBlockId: 'p_pid', toPin: 'KP'),
          FbdWire(fromBlockId: 'p_ki', fromPin: 'OUT', toBlockId: 'p_pid', toPin: 'KI'),
          FbdWire(fromBlockId: 'p_kd', fromPin: 'OUT', toBlockId: 'p_pid', toPin: 'KD'),
          FbdWire(fromBlockId: 'p_pid', fromPin: 'CV', toBlockId: 'p_cv', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'LevelPidTask', type: 'Continuous', periodMs: 500, programNames: ['LevelPID_FBD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_tank_level_pid',
        title: 'Tank Level PID Dashboard',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'tp1', title: 'Tank Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Level_PV', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'tp2', title: 'Level Setpoint', type: 'NumericSliderInput', tagBinding: 'Level_SP', gridSpanWidth: 4, accentColor: 'teal'),
          HmiComponent(id: 'tp3', title: 'Valve CV (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Valve_CV', gridSpanWidth: 4, accentColor: 'amber'),
        ],
      ),
    ],
  );

  // ── 9. FBD — Batch Counter (CTU) ─────────────────────────────────────────
  //
  // Showcase for the CTU (count-up) function block: Part_Sensor pulses
  // (simulated part arrivals passing a photo eye) drive CTU.CU. Each rising
  // edge increments CV by exactly one — holding the sensor true does not
  // over-count, because CTU is edge-triggered, not level-triggered. CV feeds
  // Count (SimulatedOutput) and Q feeds Batch_Done once CV reaches
  // Batch_Size.
  //
  // Self-reset is wired through tag feedback, not a same-scan topological
  // cycle: a SECOND TAG_INPUT block reads Batch_Done and drives CTU.R. When
  // Q fires, Batch_Done goes true THIS scan; the second TAG_INPUT block reads
  // that new value only on the NEXT scan (the executor resolves each block
  // once per scan from the previous scan's committed tag values for
  // TAG_INPUT sources), so R resets CV to 0 one scan later — a clean,
  // cycle-free, one-scan-delayed feedback reset. See
  // test/counter_loop_integration_test.dart for the exact scan-by-scan
  // behavior this produces.
  static PlcProject _fbdBatchCounterProject() => PlcProject(
    id: 'proj_batch_counter',
    name: 'Batch Counter',
    controllerName: 'PLC_CTU',
    scanPeriodMs: 100,
    tags: [
      PlcTag(name: 'Part_Sensor', path: 'Inputs/Part_Sensor', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Photo-eye part detection sensor'),
      PlcTag(name: 'Batch_Size', path: 'Internal/Batch_Size', dataType: 'INT32', value: 5, ioType: 'Internal', description: 'Number of parts per batch (CTU preset)'),
      PlcTag(name: 'Batch_Done', path: 'Outputs/Batch_Done', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Batch complete (CTU.Q); also feeds the one-scan-delayed self-reset'),
      PlcTag(name: 'Count', path: 'Outputs/Count', dataType: 'INT32', value: 0, ioType: 'SimulatedOutput', description: 'Parts counted this batch (CTU.CV)'),
    ],
    structDefs: [],
    simRules: [
      // Part arrivals: on 250ms (~2-3 scans at 100ms/scan), off 350ms
      // (~3-4 scans) — clear, well-separated rising edges rather than
      // chattering every scan.
      SimRule(id: 'sim0', name: 'Part arrivals at the photo eye', targetPath: 'Part_Sensor',
          behavior: 'pulse', onMs: 250, offMs: 350),
    ],
    programs: [
      PlcProgram(
        name: 'BatchCount_FBD',
        language: 'FunctionBlockDiagram',
        description: 'CTU counts parts to Batch_Size, then self-resets via one-scan-delayed tag feedback',
        fbdBlocks: [
          FbdBlock(id: 'c_cu', type: 'TAG_INPUT', title: 'Part Sensor', tagBinding: 'Part_Sensor', x: 50, y: 80),
          FbdBlock(id: 'c_pv', type: 'TAG_INPUT', title: 'Batch Size', tagBinding: 'Batch_Size', x: 50, y: 200),
          FbdBlock(id: 'c_r', type: 'TAG_INPUT', title: 'Batch Done (feedback)', tagBinding: 'Batch_Done', x: 50, y: 320),
          FbdBlock(id: 'c_ctu', type: 'CTU', title: 'Batch CTU', tagBinding: '', x: 320, y: 200),
          FbdBlock(id: 'c_q', type: 'TAG_OUTPUT', title: 'Batch Done', tagBinding: 'Batch_Done', x: 560, y: 150),
          FbdBlock(id: 'c_cv', type: 'TAG_OUTPUT', title: 'Count', tagBinding: 'Count', x: 560, y: 260),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'c_cu', fromPin: 'OUT', toBlockId: 'c_ctu', toPin: 'CU'),
          FbdWire(fromBlockId: 'c_r', fromPin: 'OUT', toBlockId: 'c_ctu', toPin: 'R'),
          FbdWire(fromBlockId: 'c_pv', fromPin: 'OUT', toBlockId: 'c_ctu', toPin: 'PV'),
          FbdWire(fromBlockId: 'c_ctu', fromPin: 'Q', toBlockId: 'c_q', toPin: 'IN'),
          FbdWire(fromBlockId: 'c_ctu', fromPin: 'CV', toBlockId: 'c_cv', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'BatchCountTask', type: 'Continuous', periodMs: 100, programNames: ['BatchCount_FBD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_batch_counter',
        title: 'Batch Counter Dashboard',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'bc1', title: 'Parts Counted', type: 'DigitalGaugeDisplay', tagBinding: 'Count', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'bc2', title: 'Batch Size', type: 'NumericSliderInput', tagBinding: 'Batch_Size', gridSpanWidth: 4, accentColor: 'teal'),
          HmiComponent(id: 'bc3', title: 'Batch Done', type: 'LedIndicatorLight', tagBinding: 'Batch_Done', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'bc4', title: 'Part Sensor', type: 'LedIndicatorLight', tagBinding: 'Part_Sensor', gridSpanWidth: 1, accentColor: 'amber'),
        ],
      ),
    ],
  );

  // ── 10. FBD — Pulse Output (R_TRIG + TP) ────────────────────────────────
  //
  // Showcase for the R_TRIG edge detector gating a TP (pulse timer): each
  // rising edge of Start_Btn (button press) fires exactly one Q pulse on
  // R_TRIG, which starts TP. TP then holds Pulse_Out true for Pulse_Time ms
  // REGARDLESS of how long Start_Btn stays held — TP is non-retriggerable,
  // so further edges while a pulse is running are ignored, and without
  // R_TRIG a level-driven TP.IN would still one-shot on the first rising
  // edge (TP itself edge-detects IN internally) but a retriggerable timer
  // would extend the pulse for as long as the button is held; without TP
  // the output would simply follow the button. The sim rule drives
  // Start_Btn with an on-phase (5000ms) deliberately LONGER than Pulse_Time
  // (3000ms) so the demo visibly proves the output pulse width is set by
  // TP, not by the button hold. See test/pulse_loop_integration_test.dart
  // for the exact scan-by-scan behavior this produces.
  static PlcProject _fbdPulseOutputProject() => PlcProject(
    id: 'proj_pulse_output',
    name: 'Pulse Output',
    controllerName: 'PLC_PULSE',
    scanPeriodMs: 100,
    tags: [
      PlcTag(name: 'Start_Btn', path: 'Inputs/Start_Btn', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Momentary start button (simulated press)'),
      PlcTag(name: 'Pulse_Time', path: 'Internal/Pulse_Time', dataType: 'INT32', value: 3000, ioType: 'Internal', description: 'Fixed pulse width in ms (TP.PT preset)'),
      PlcTag(name: 'Pulse_Out', path: 'Outputs/Pulse_Out', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Fixed-width one-shot pulse (TP.Q), gated by the Start_Btn rising edge (R_TRIG.Q)'),
      PlcTag(name: 'Pulse_ET', path: 'Outputs/Pulse_ET', dataType: 'INT32', value: 0, ioType: 'SimulatedOutput', description: 'Elapsed time of the current/last pulse in ms (TP.ET)'),
    ],
    structDefs: [],
    simRules: [
      // Button presses: on 5000ms (well past Pulse_Time=3000ms), off 2000ms —
      // the on-phase deliberately outlasts the pulse width so the demo proves
      // Pulse_Out is timed by TP, not by how long Start_Btn is held.
      SimRule(id: 'sim0', name: 'Start button presses (held longer than Pulse_Time)', targetPath: 'Start_Btn',
          behavior: 'pulse', onMs: 5000, offMs: 2000),
    ],
    programs: [
      PlcProgram(
        name: 'PulseOut_FBD',
        language: 'FunctionBlockDiagram',
        description: 'R_TRIG detects the Start_Btn rising edge to start a non-retriggerable TP pulse of Pulse_Time ms',
        fbdBlocks: [
          FbdBlock(id: 'u_btn', type: 'TAG_INPUT', title: 'Start Btn', tagBinding: 'Start_Btn', x: 50, y: 80),
          FbdBlock(id: 'u_pt', type: 'TAG_INPUT', title: 'Pulse Time', tagBinding: 'Pulse_Time', x: 50, y: 260),
          FbdBlock(id: 'u_rtrig', type: 'R_TRIG', title: 'Btn Rising Edge', tagBinding: '', x: 300, y: 80),
          FbdBlock(id: 'u_tp', type: 'TP', title: 'Output Pulse', tagBinding: '', x: 560, y: 150),
          FbdBlock(id: 'u_out', type: 'TAG_OUTPUT', title: 'Pulse Out', tagBinding: 'Pulse_Out', x: 820, y: 100),
          FbdBlock(id: 'u_et', type: 'TAG_OUTPUT', title: 'Pulse ET', tagBinding: 'Pulse_ET', x: 820, y: 220),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'u_btn', fromPin: 'OUT', toBlockId: 'u_rtrig', toPin: 'CLK'),
          FbdWire(fromBlockId: 'u_rtrig', fromPin: 'Q', toBlockId: 'u_tp', toPin: 'IN'),
          FbdWire(fromBlockId: 'u_pt', fromPin: 'OUT', toBlockId: 'u_tp', toPin: 'PT'),
          FbdWire(fromBlockId: 'u_tp', fromPin: 'Q', toBlockId: 'u_out', toPin: 'IN'),
          FbdWire(fromBlockId: 'u_tp', fromPin: 'ET', toBlockId: 'u_et', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'PulseOutTask', type: 'Continuous', periodMs: 100, programNames: ['PulseOut_FBD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_pulse_output',
        title: 'Pulse Output Dashboard',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'po1', title: 'Start Btn', type: 'LedIndicatorLight', tagBinding: 'Start_Btn', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'po2', title: 'Pulse Out', type: 'LedIndicatorLight', tagBinding: 'Pulse_Out', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'po3', title: 'Pulse Elapsed (ms)', type: 'DigitalGaugeDisplay', tagBinding: 'Pulse_ET', gridSpanWidth: 4, accentColor: 'cyan'),
        ],
      ),
    ],
  );

  // ── 11. Cascade Tanks with Transport Delay (deadTime showcase) ──────────
  //
  // Showcase for the `deadTime` sim behaviour (transport dead-time / pure
  // delay line): Tank_A_Level fills from the (fixed) Feed_Valve opening via
  // an analog-scaled `integrate` inflow, minus a constant outflow. The level
  // reaching Tank_B is NOT read directly from Tank_A_Level — it passes
  // through Transfer_Line, a `deadTime` rule that reproduces Tank_A_Level
  // delayed by tauSec=3.0s (the transport delay of the pipe between the two
  // tanks). Tank_B_Level then integrates its own inflow from Transfer_Line
  // (again analog-scaled) minus a constant outflow.
  //
  // Net effect: Tank_A_Level starts rising the instant the scan loop starts
  // (Feed_Valve is a fixed nonzero opening from t=0), but Tank_B_Level does
  // not begin rising until the delay line has filled with samples showing
  // Tank_A_Level's rise — a visible, provable transport lag between the two
  // tanks. See test/deadtime_cascade_integration_test.dart for the exact
  // scan-by-scan behavior this produces (Tank_A_Level clearly risen while
  // Tank_B_Level is still ~its initial value, then Tank_B_Level rising only
  // after roughly tauSec has elapsed). Falsifiable: with tauSec=0 (or the
  // deadTime rule removed), Transfer_Line would track Tank_A_Level with zero
  // delay and Tank_B_Level would rise in lock-step with Tank_A_Level.
  static PlcProject _cascadeTanksProject() => PlcProject(
    id: 'proj_cascade_tanks',
    name: 'Cascade Tanks with Transport Delay',
    controllerName: 'PLC_CASCADE',
    scanPeriodMs: 500,
    tags: [
      PlcTag(name: 'Feed_Valve', path: 'Internal/Feed_Valve', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Manipulated feed valve opening driving inflow into Tank A'),
      PlcTag(name: 'Tank_A_Level', path: 'Inputs/Tank_A_Level', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Upstream tank level'),
      PlcTag(name: 'Transfer_Line', path: 'Internal/Transfer_Line', dataType: 'FLOAT64', value: 10.0, ioType: 'Internal', engineeringUnits: '%', description: 'Transport-delayed signal in the pipe carrying Tank A level to Tank B (deadTime of Tank_A_Level)'),
      PlcTag(name: 'Tank_B_Level', path: 'Inputs/Tank_B_Level', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Downstream tank level, lags Tank A by the transport delay'),
    ],
    structDefs: [],
    simRules: [
      // Tank A: inflow scaled by the (fixed) Feed_Valve opening — effective
      // rate = 4.0 %/s * (Feed_Valve/100) = 2.4 %/s at Feed_Valve=60.
      SimRule(id: 'sim0', name: 'Tank A inflow scaled by Feed_Valve', targetPath: 'Tank_A_Level',
          behavior: 'integrate', ratePerSec: 4.0, sourcePath: 'Feed_Valve', refValue: 100.0,
          minValue: 0, maxValue: 100),
      // Tank A: constant outflow disturbance.
      SimRule(id: 'sim1', name: 'Tank A constant outflow', targetPath: 'Tank_A_Level',
          behavior: 'integrate', ratePerSec: -0.5, minValue: 0, maxValue: 100),
      // Transfer line: the transport dead-time between the two tanks —
      // Transfer_Line reproduces Tank_A_Level delayed by 3.0 seconds.
      SimRule(id: 'sim2', name: 'Transfer line transport delay', targetPath: 'Transfer_Line',
          behavior: 'deadTime', sourcePath: 'Tank_A_Level', tauSec: 3.0,
          minValue: 0, maxValue: 100),
      // Tank B: inflow scaled by the delayed Transfer_Line signal — effective
      // rate = 4.0 %/s * (Transfer_Line/100).
      SimRule(id: 'sim3', name: 'Tank B inflow scaled by Transfer Line', targetPath: 'Tank_B_Level',
          behavior: 'integrate', ratePerSec: 4.0, sourcePath: 'Transfer_Line', refValue: 100.0,
          minValue: 0, maxValue: 100),
      // Tank B: constant outflow disturbance.
      SimRule(id: 'sim4', name: 'Tank B constant outflow', targetPath: 'Tank_B_Level',
          behavior: 'integrate', ratePerSec: -0.5, minValue: 0, maxValue: 100),
    ],
    programs: [
      // The process is entirely sim-driven (the deadTime/integrate rules
      // above do all the work); this program is a trivial, self-consistent
      // no-op monitor so the project has a real Continuous task to run,
      // mirroring how other sim-only demos wire a task.
      PlcProgram(
        name: 'CascadeMonitor_FBD',
        language: 'FunctionBlockDiagram',
        description: 'Trivial pass-through monitor of Feed_Valve; the cascade itself is entirely sim-driven',
        fbdBlocks: [
          FbdBlock(id: 'k_in', type: 'TAG_INPUT', title: 'Feed Valve', tagBinding: 'Feed_Valve', x: 50, y: 80),
          FbdBlock(id: 'k_out', type: 'TAG_OUTPUT', title: 'Feed Valve Monitor', tagBinding: 'Feed_Valve', x: 320, y: 80),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'k_in', fromPin: 'OUT', toBlockId: 'k_out', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'CascadeMonitorTask', type: 'Continuous', periodMs: 500, programNames: ['CascadeMonitor_FBD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_cascade_tanks',
        title: 'Cascade Tanks Dashboard',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'ct1', title: 'Feed Valve (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Feed_Valve', gridSpanWidth: 4, accentColor: 'amber'),
          HmiComponent(id: 'ct2', title: 'Tank A Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Tank_A_Level', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'ct3', title: 'Tank B Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Tank_B_Level', gridSpanWidth: 4, accentColor: 'teal'),
        ],
      ),
    ],
  );

  // ── 12. Noisy Level Measurement (WS14 measurement-noise showcase) ──────
  //
  // Demonstrates the `noise` Simulated I/O behaviour: a clean process value
  // (Tank_Level) is driven by an analog-scaled integrate from Fill_Valve plus
  // a constant outflow, clamped 0-100 - a smooth true level. Level_Meas is a
  // SEPARATE tag computed fresh every scan as `noise(Tank_Level)`
  // (sourcePath:'Tank_Level', amplitude in targetValue) - a source->target
  // rule, so the jitter never accumulates into Tank_Level itself (no random
  // walk / drift). Level_Filtered then runs the existing firstOrderLag block
  // on Level_Meas, showing the lag attenuating the raw sensor noise.
  //
  // Falsifiable: if the noise amplitude were 0, Level_Meas would exactly
  // track Tank_Level (no jitter) and there would be nothing for
  // Level_Filtered to smooth out - see
  // test/noise_measurement_integration_test.dart for the exact scan-by-scan
  // band/variance/filter assertions this produces.
  static PlcProject _noisyLevelProject() => PlcProject(
    id: 'proj_noisy_level',
    name: 'Noisy Level Measurement',
    controllerName: 'PLC_NOISY_LEVEL',
    scanPeriodMs: 500,
    tags: [
      PlcTag(name: 'Fill_Valve', path: 'Internal/Fill_Valve', dataType: 'FLOAT64', value: 55.0, ioType: 'Internal', engineeringUnits: '%', description: 'Manipulated fill valve opening driving inflow into the tank'),
      PlcTag(name: 'Tank_Level', path: 'Inputs/Tank_Level', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Clean (true) tank level, driven by Fill_Valve minus a constant outflow'),
      PlcTag(name: 'Level_Meas', path: 'Inputs/Level_Meas', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Raw noisy sensor reading of Tank_Level (measurement noise behaviour)'),
      PlcTag(name: 'Level_Filtered', path: 'Inputs/Level_Filtered', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'First-order-lag-filtered reading of Level_Meas'),
    ],
    structDefs: [],
    simRules: [
      // Tank_Level: inflow scaled by the (fixed) Fill_Valve opening -
      // effective rate = 3.0 %/s * (Fill_Valve/100) = 1.65 %/s at Fill_Valve=55.
      SimRule(id: 'sim0', name: 'Tank inflow scaled by Fill_Valve', targetPath: 'Tank_Level',
          behavior: 'integrate', ratePerSec: 3.0, sourcePath: 'Fill_Valve', refValue: 100.0,
          minValue: 0, maxValue: 100),
      // Tank_Level: constant outflow disturbance.
      SimRule(id: 'sim1', name: 'Tank constant outflow', targetPath: 'Tank_Level',
          behavior: 'integrate', ratePerSec: -0.4, minValue: 0, maxValue: 100),
      // Level_Meas: the noisy sensor reading - clean source Tank_Level plus
      // bounded uniform noise of amplitude 2.5%, clamped 0-100. Recomputed
      // fresh from Tank_Level every scan (source->target), so it never drifts.
      SimRule(id: 'sim2', name: 'Level measurement noise', targetPath: 'Level_Meas',
          behavior: 'noise', sourcePath: 'Tank_Level', targetValue: 2.5,
          minValue: 0, maxValue: 100),
      // Level_Filtered: first-order lag of Level_Meas, tau=1.5s - smooths the
      // raw measurement jitter while still tracking the underlying trend.
      SimRule(id: 'sim3', name: 'Level measurement filter', targetPath: 'Level_Filtered',
          behavior: 'firstOrderLag', sourcePath: 'Level_Meas', tauSec: 1.5,
          minValue: 0, maxValue: 100),
    ],
    programs: [
      // The process is entirely sim-driven (the integrate/noise/firstOrderLag
      // rules above do all the work); this program is a trivial, self-consistent
      // no-op monitor so the project has a real Continuous task to run,
      // mirroring how other sim-only demos (e.g. Cascade Tanks) wire a task.
      PlcProgram(
        name: 'NoisyLevelMonitor_FBD',
        language: 'FunctionBlockDiagram',
        description: 'Trivial pass-through monitor of Fill_Valve; the noisy level demo is entirely sim-driven',
        fbdBlocks: [
          FbdBlock(id: 'k_in', type: 'TAG_INPUT', title: 'Fill Valve', tagBinding: 'Fill_Valve', x: 50, y: 80),
          FbdBlock(id: 'k_out', type: 'TAG_OUTPUT', title: 'Fill Valve Monitor', tagBinding: 'Fill_Valve', x: 320, y: 80),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'k_in', fromPin: 'OUT', toBlockId: 'k_out', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'NoisyLevelMonitorTask', type: 'Continuous', periodMs: 500, programNames: ['NoisyLevelMonitor_FBD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_noisy_level',
        title: 'Noisy Level Measurement Dashboard',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'nl1', title: 'Tank Level (%) - Clean', type: 'TankGraphicDisplay', tagBinding: 'Tank_Level', gridSpanWidth: 4, accentColor: 'cyan'),
          HmiComponent(id: 'nl2', title: 'Level Measured (%) - Noisy', type: 'DigitalGaugeDisplay', tagBinding: 'Level_Meas', gridSpanWidth: 4, accentColor: 'amber'),
          HmiComponent(id: 'nl3', title: 'Level Filtered (%) - Smoothed', type: 'DigitalGaugeDisplay', tagBinding: 'Level_Filtered', gridSpanWidth: 4, accentColor: 'teal'),
        ],
      ),
    ],
  );
}
