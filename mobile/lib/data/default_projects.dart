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
    _allWaterProject(),
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
          FbdWire(fromBlockId: 't_sp', toBlockId: 't_sub'),  // Level_SP (left)
          FbdWire(fromBlockId: 't_db', toBlockId: 't_sub'),  // 5.0 (right) -> SP-5
          FbdWire(fromBlockId: 't_pv', toBlockId: 't_lt'),   // Level_PV (left)
          FbdWire(fromBlockId: 't_sub', toBlockId: 't_lt'),  // SP-5 (right) -> PV < SP-5
          FbdWire(fromBlockId: 't_auto', toBlockId: 't_af'),
          FbdWire(fromBlockId: 't_lt', toBlockId: 't_af'),
          FbdWire(fromBlockId: 't_af', toBlockId: 't_of'),
          FbdWire(fromBlockId: 't_sp', toBlockId: 't_add'),  // Level_SP (left)
          FbdWire(fromBlockId: 't_db', toBlockId: 't_add'),  // 5.0 (right) -> SP+5
          FbdWire(fromBlockId: 't_pv', toBlockId: 't_gt'),   // Level_PV (left)
          FbdWire(fromBlockId: 't_add', toBlockId: 't_gt'),  // SP+5 (right) -> PV > SP+5
          FbdWire(fromBlockId: 't_auto', toBlockId: 't_ad'),
          FbdWire(fromBlockId: 't_gt', toBlockId: 't_ad'),
          FbdWire(fromBlockId: 't_ad', toBlockId: 't_od'),
          FbdWire(fromBlockId: 't_pv', toBlockId: 't_ga'),   // Level_PV (left)
          FbdWire(fromBlockId: 't_hi', toBlockId: 't_ga'),   // 85.0 (right) -> PV > 85
          FbdWire(fromBlockId: 't_ga', toBlockId: 't_oa'),
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
      PlcTag(name: 'Auto_Mode', path: 'Inputs/Auto_Mode', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Auto / Manual selector switch'),
      PlcTag(name: 'Heat_Cmd', path: 'Outputs/Heat_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Heater element contactor'),
      PlcTag(name: 'Cool_Cmd', path: 'Outputs/Cool_Cmd', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Cooling water valve'),
      PlcTag(name: 'Alarm_High', path: 'Outputs/Alarm_High', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'High temperature alarm (>95°C)'),
      PlcTag(name: 'Alarm_Low', path: 'Outputs/Alarm_Low', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Low temperature alarm (<5°C)'),
      PlcTag(name: 'Reactor_Ready', path: 'Outputs/Reactor_Ready', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Reactor at setpoint ±2°C'),
    ],
    structDefs: [],
    simRules: [
      SimRule(id: 'sim0', name: 'Heating raises temp', targetPath: 'Temp_PV',
          behavior: 'integrate', ratePerSec: 0.6, minValue: 0, maxValue: 105,
          condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim1', name: 'Cooling lowers temp', targetPath: 'Temp_PV',
          behavior: 'integrate', ratePerSec: -0.4, minValue: 0, maxValue: 105,
          condition: [SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'true')]),
      SimRule(id: 'sim2', name: 'Ambient heat loss', targetPath: 'Temp_PV',
          behavior: 'integrate', ratePerSec: -0.04, minValue: 20, maxValue: 105,
          condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'false'), SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'false')]),
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
          FbdWire(fromBlockId: 'f_i2', toBlockId: 'f_n1'),
          FbdWire(fromBlockId: 'f_i1', toBlockId: 'f_a1'),
          FbdWire(fromBlockId: 'f_n1', toBlockId: 'f_a1'),
          FbdWire(fromBlockId: 'f_a1', toBlockId: 'f_o1'),
          FbdWire(fromBlockId: 'f_a1', toBlockId: 'f_o2'),
          // Heat: Room_Temp < (Setpoint - 1.0)
          FbdWire(fromBlockId: 'f_i4', toBlockId: 'f_s1'), // Setpoint (left)
          FbdWire(fromBlockId: 'f_c1', toBlockId: 'f_s1'), // 1.0 (right)
          FbdWire(fromBlockId: 'f_i3', toBlockId: 'f_lt'), // Room_Temp (left)
          FbdWire(fromBlockId: 'f_s1', toBlockId: 'f_lt'), // SP-1 (right)
          FbdWire(fromBlockId: 'f_a1', toBlockId: 'f_a2'),
          FbdWire(fromBlockId: 'f_lt', toBlockId: 'f_a2'),
          FbdWire(fromBlockId: 'f_a2', toBlockId: 'f_o3'),
          // Cool: Room_Temp > (Setpoint + 1.0)
          FbdWire(fromBlockId: 'f_i4', toBlockId: 'f_a3'), // Setpoint (left)
          FbdWire(fromBlockId: 'f_c1', toBlockId: 'f_a3'), // 1.0 (right)
          FbdWire(fromBlockId: 'f_i3', toBlockId: 'f_gt'), // Room_Temp (left)
          FbdWire(fromBlockId: 'f_a3', toBlockId: 'f_gt'), // SP+1 (right)
          FbdWire(fromBlockId: 'f_a1', toBlockId: 'f_a4'),
          FbdWire(fromBlockId: 'f_gt', toBlockId: 'f_a4'),
          FbdWire(fromBlockId: 'f_a4', toBlockId: 'f_o4'),
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
          FbdWire(fromBlockId: 'wf_i1', toBlockId: 'wf_lt'), // Turbidity_PV (left)
          FbdWire(fromBlockId: 'wf_i2', toBlockId: 'wf_lt'), // Turbidity_SP (right)
          FbdWire(fromBlockId: 'wf_i3', toBlockId: 'wf_gt'), // Level_PV (left)
          FbdWire(fromBlockId: 'wf_c1', toBlockId: 'wf_gt'), // 10.0 (right)
          FbdWire(fromBlockId: 'wf_lt', toBlockId: 'wf_a1'),
          FbdWire(fromBlockId: 'wf_gt', toBlockId: 'wf_a1'),
          FbdWire(fromBlockId: 'wf_a1', toBlockId: 'wf_o1'),
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
}
