/// **ST — Reactor Temperature Controller** (`proj_st_reactor_control`).
///
/// (a) Story: a jacketed reactor held at temperature by a ±2 °C on/off deadband
/// controller written in Structured Text, with high/low trip alarms, an
/// eight-step recipe table and a status struct. A small companion FBD program
/// hosts a custom `Hysteresis` function block that latches a hot-vessel alarm
/// with a 40–60 °C deadband (ST has no FB-call syntax in the supported subset,
/// so the call has to live in FBD).
///
/// (b) Showcase for: ST `IF/ELSIF/ELSE/END_IF`, assignment, comparators and
/// `AND`/`OR`/`NOT`; **ST array-index read** (`Recipe_Setpoints[0]`); **ST
/// struct-member write** (`Reactor_Status.Heating := …`); an `INT16` array tag;
/// a DUT tag; and the ST-bodied `Hysteresis` FB whose internal `Q` persists
/// across scans inside the instance struct `TempAlarmHyst`.
///
/// (c) Falsifiable: zeroing the deadband block leaves `Heat_Cmd`/`Cool_Cmd`
/// false and the reactor drifts to ambient forever; removing the `Heat_Prev`
/// edge guard makes `Reactor_Status.Cycles` climb every scan; deleting the FB's
/// internal `Q` makes the hot-vessel alarm chatter inside the deadband.
///
/// (d) Proof test: `test/defaults/st_reactor_control_test.dart` (plus the
/// re-pointed `test/st_exec_integration_test.dart`,
/// `test/hysteresis_fb_demo_test.dart` and `test/simulated_io_screen_test.dart`).
library;

import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'builders.dart';

PlcProject stReactorControlProject() {
  // Moved VERBATIM from the retired "Noisy Level Measurement" demo: same name,
  // same five vars, same initial values, same stSource. Only its host project
  // and its instance name changed.
  final hysteresisFb = FbDefinition(
    name: 'Hysteresis',
    stSource: 'IF PV > High THEN\n'
        '    Q := TRUE;\n'
        'ELSIF PV < Low THEN\n'
        '    Q := FALSE;\n'
        'END_IF;\n'
        'Out := Q;',
    vars: [
      FbVar(name: 'PV', dataType: 'FLOAT64', direction: FbVarDir.input),
      FbVar(name: 'High', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 60.0),
      FbVar(name: 'Low', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 40.0),
      FbVar(name: 'Q', dataType: 'BOOL', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ],
  );

  final structDefs = [
    PlcStructDef(name: 'Reactor_DUT', fields: [
      StructFieldDef(name: 'Heating', dataType: 'BOOL', defaultValue: false),
      StructFieldDef(name: 'Cooling', dataType: 'BOOL', defaultValue: false),
      StructFieldDef(name: 'Cycles', dataType: 'INT32', defaultValue: 0),
    ]),
  ];
  final fbScratch = scratchProjectFor(fbDefinitions: [hysteresisFb]);
  final dutScratch = scratchProjectFor(structDefs: structDefs);

  return PlcProject(
    id: 'proj_st_reactor_control',
    name: 'ST — Reactor Temperature Controller',
    controllerName: 'PLC_ST',
    scanPeriodMs: 100,
    fbDefinitions: [hysteresisFb],
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
      PlcTag(name: 'Recipe_Select', path: 'Inputs/Recipe_Select', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Load the setpoint from the recipe table'),
      PlcTag(name: 'Heat_Prev', path: 'Internal/Heat_Prev', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Previous-scan Heat_Cmd — the ST edge guard for the cycle counter'),
      PlcTag(name: 'Alarm_Latched', path: 'Outputs/Alarm_Latched', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Hot-vessel latch: sets above 60 °C, clears below 40 °C (Hysteresis FB deadband)'),
      PlcTag(
        name: 'Recipe_Setpoints',
        path: 'Recipe/Setpoints',
        dataType: 'INT16',
        arrayLength: 8,
        value: defaultValueFor(emptyScratchProject, 'INT16', 8),
        ioType: 'Internal',
        description: '8-step recipe setpoint table (°C); index 0 feeds Temp_SP on recipe select',
      ),
      PlcTag(
        name: 'Reactor_Status',
        path: 'Status/Reactor',
        dataType: 'Reactor_DUT',
        value: defaultValueFor(dutScratch, 'Reactor_DUT', 0),
        ioType: 'Internal',
        description: 'Reactor status struct written by ST member assignments',
      ),
      PlcTag(
        name: 'TempAlarmHyst',
        path: 'Internal/TempAlarmHyst',
        dataType: 'Hysteresis',
        value: defaultValueFor(fbScratch, 'Hysteresis', 0),
        ioType: 'Internal',
        description: 'Custom function block instance: hot-vessel hysteresis (60 °C set / 40 °C reset)',
      ),
    ],
    structDefs: structDefs,
    simRules: [
      // First-order thermal process: ambient pull always acts (the loss term),
      // heating/cooling add/remove energy while their contactors are closed.
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
        description: 'Reactor temperature on/off deadband control with alarms, a recipe '
            'table lookup and a status struct',
        stSource: r'''// IEC 61131-3 Structured Text — Reactor Temperature Controller
// ±2°C deadband on/off control with high/low trip alarms

IF Recipe_Select THEN
    Temp_SP := Recipe_Setpoints[0];
END_IF;

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
             AND (Temp_PV <= Temp_SP + 2.0);

// Status struct: member assignments into the Reactor_DUT instance.
Reactor_Status.Heating := Heat_Cmd;
Reactor_Status.Cooling := Cool_Cmd;
IF Heat_Cmd AND NOT Heat_Prev THEN
    Reactor_Status.Cycles := Reactor_Status.Cycles + 1;
END_IF;
Heat_Prev := Heat_Cmd;''',
      ),
      PlcProgram(
        name: 'ReactorAlarm_FBD',
        language: 'FunctionBlockDiagram',
        description: 'Hot-vessel latch driven by the custom Hysteresis function block '
            '(60 °C set / 40 °C reset) — ST has no FB-call syntax, so the call lives here',
        fbdBlocks: [
          FbdBlock(id: 'ra_pv', type: 'TAG_INPUT', title: 'Reactor Temp', tagBinding: 'Temp_PV', x: 50, y: 200),
          FbdBlock(id: 'ra_high', type: 'CONST', title: 'High Threshold', tagBinding: '60.0', x: 50, y: 280),
          FbdBlock(id: 'ra_low', type: 'CONST', title: 'Low Threshold', tagBinding: '40.0', x: 50, y: 360),
          FbdBlock(id: 'ra_hyst', type: 'Hysteresis', title: 'Hot Vessel Hysteresis', tagBinding: 'TempAlarmHyst', x: 320, y: 280),
          FbdBlock(id: 'ra_out', type: 'TAG_OUTPUT', title: 'Alarm Latched', tagBinding: 'Alarm_Latched', x: 560, y: 280),
        ],
        fbdWires: [
          FbdWire(fromBlockId: 'ra_pv', fromPin: 'OUT', toBlockId: 'ra_hyst', toPin: 'PV'),
          FbdWire(fromBlockId: 'ra_high', fromPin: 'OUT', toBlockId: 'ra_hyst', toPin: 'High'),
          FbdWire(fromBlockId: 'ra_low', fromPin: 'OUT', toBlockId: 'ra_hyst', toPin: 'Low'),
          FbdWire(fromBlockId: 'ra_hyst', fromPin: 'Out', toBlockId: 'ra_out', toPin: 'IN'),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'TempControlTask', type: 'Continuous', periodMs: 100, programNames: ['ReactorTemp_ST', 'ReactorAlarm_FBD']),
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
          HmiComponent(id: 'sr7', title: 'Recipe Select', type: 'ToggleSwitch', tagBinding: 'Recipe_Select', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'sr8', title: 'Recipe Step 0 (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Recipe_Setpoints[0]', gridSpanWidth: 3, accentColor: 'teal'),
          HmiComponent(id: 'sr9', title: 'Heat Cycles', type: 'DigitalGaugeDisplay', tagBinding: 'Reactor_Status.Cycles', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'sr10', title: 'HIGH TEMP ALARM', type: 'StatusPillDisplay', tagBinding: 'Alarm_High', gridSpanWidth: 2, accentColor: 'red'),
          HmiComponent(id: 'sr11', title: 'LOW TEMP ALARM', type: 'StatusPillDisplay', tagBinding: 'Alarm_Low', gridSpanWidth: 2, accentColor: 'amber'),
          HmiComponent(id: 'sr12', title: 'HOT VESSEL LATCH (Hysteresis FB)', type: 'StatusPillDisplay', tagBinding: 'Alarm_Latched', gridSpanWidth: 2, accentColor: 'red'),
        ],
      ),
    ],
  );
}
