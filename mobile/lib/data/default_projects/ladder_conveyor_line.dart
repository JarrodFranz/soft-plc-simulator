/// **Ladder — Conveyor Line** (`proj_ld_conveyor_line`).
///
/// (a) Story: a two-zone conveyor line. The operator starts the line with a
/// beginner seal-in rung (absorbed from the retired "Basic Motor Start Stop"
/// demo), zone 1 runs under E-Stop/overload/jam interlocks, parts are counted
/// off the photo eye, a batch is tracked against a target, and zone 2 is
/// driven by a LADDER-BODIED custom function block.
///
/// (b) Showcase for the full LD element set: contacts `normal`/`negated`/
/// `rising`/`falling`; coils `normal`/`negated`/`set`/`reset`/`rising` and
/// `falling` (the two one-scan pulse coils); OR branches (`BranchSpec`);
/// `TON`, `TOF`, `CTU`; comparisons
/// `GT`/`LT`/`EQ`; arithmetic `ADD`/`SUB`/`MOVE`; a `TIMER` composite tag; a DUT
/// tag; and — the never-before-shipped headline — a **ladder-bodied
/// `FbDefinition`** (`MotorStarter`) whose seal-in state lives inside the
/// instance struct `Zone2Starter`, not in a global tag.
///
/// (c) Falsifiable: zeroing the seal-in branch makes Start a jog; removing the
/// rising contact on rung 3 lets a HELD Start clear the E-Stop fault latch;
/// removing the falling contact on rung 5 counts once per scan instead of once
/// per part; deleting the `MotorStarter` body leaves `Zone2_Motor` dead even
/// though the request pulses.
///
/// (d) Proof test: `test/defaults/ld_conveyor_line_test.dart` (plus the
/// re-pointed `test/ld_exec_integration_test.dart`).
library;

import '../../models/ld_graph.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import 'builders.dart';

PlcProject ladderConveyorLineProject() {
  final structDefs = [
    PlcStructDef(name: 'Line_DUT', fields: [
      StructFieldDef(name: 'Running', dataType: 'BOOL', defaultValue: false),
      StructFieldDef(name: 'Faulted', dataType: 'BOOL', defaultValue: false),
      StructFieldDef(name: 'Speed', dataType: 'INT32', defaultValue: 0),
    ]),
  ];

  // Ladder-bodied custom FB. `stSource` stays EMPTY: a non-empty `ladderRungs`
  // is what selects the ladder dispatch in `fb_exec.dart`. `Seal` is an
  // INTERNAL var, so each instance keeps its own latch inside its struct tag.
  final motorStarterFb = FbDefinition(
    name: 'MotorStarter',
    vars: [
      FbVar(name: 'Run', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Permit', dataType: 'BOOL', direction: FbVarDir.input),
      FbVar(name: 'Seal', dataType: 'BOOL', direction: FbVarDir.internal),
      FbVar(name: 'Out', dataType: 'BOOL', direction: FbVarDir.output),
    ],
    ladderRungs: [
      buildRung(
        index: 0,
        comment: 'FB rung 0: seal in the run request while the permit holds',
        main: [ldXic('Run', 'Run request'), ldXic('Permit', 'Permit'), ldOte('Seal', 'Instance seal')],
        branches: [
          BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Seal', 'Seal-in aux')]),
        ],
      ),
      buildRung(
        index: 1,
        comment: 'FB rung 1: drive the output from the sealed state',
        main: [ldXic('Seal', 'Sealed'), ldXic('Permit', 'Permit'), ldOte('Out', 'Starter output')],
      ),
    ],
  );

  final fbScratch = scratchProjectFor(fbDefinitions: [motorStarterFb]);
  final dutScratch = scratchProjectFor(structDefs: structDefs);

  return PlcProject(
    id: 'proj_ld_conveyor_line',
    name: 'Ladder — Conveyor Line',
    controllerName: 'PLC_LINE',
    scanPeriodMs: 100,
    fbDefinitions: [motorStarterFb],
    tags: [
      // Start_PB MUST stay first: persistence_integration_test asserts the
      // boot-active project's first tag is Start_PB.
      PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Line start pushbutton NO'),
      PlcTag(name: 'Stop_PB', path: 'Inputs/Stop_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Line stop pushbutton NC'),
      PlcTag(name: 'EStop_OK', path: 'Inputs/EStop_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Emergency stop healthy (TRUE = healthy)'),
      PlcTag(name: 'Overload_OK', path: 'Inputs/Overload_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Thermal overload healthy'),
      PlcTag(name: 'Photo_Eye', path: 'Inputs/Photo_Eye', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Part detection photo eye'),
      PlcTag(name: 'Manual_Jog', path: 'Inputs/Manual_Jog', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Manual jog pushbutton (runs zone 1 without latching)'),
      PlcTag(name: 'Line_Latch', path: 'Internal/Line_Latch', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Line seal-in latch'),
      PlcTag(name: 'Part_Present', path: 'Internal/Part_Present', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Part present flag (follows the photo eye)'),
      PlcTag(name: 'Part_Edge', path: 'Internal/Part_Edge', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'One-scan pulse per part leaving the photo eye (rising pulse coil)'),
      PlcTag(name: 'Line_Stop_Edge', path: 'Internal/Line_Stop_Edge', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'One-scan pulse when the line stops (falling pulse coil) — abandons the partial batch'),
      PlcTag(name: 'Zone2_Request', path: 'Internal/Zone2_Request', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'One-scan zone-2 start request at batch completion'),
      PlcTag(name: 'Zone2_Permit', path: 'Internal/Zone2_Permit', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Zone-2 permit — TOF run-on 3s after the line stops'),
      PlcTag(name: 'Batch_Running', path: 'Internal/Batch_Running', dataType: 'BOOL', value: true, ioType: 'Internal', description: 'Batch in progress (negated coil: cleared when no parts remain)'),
      PlcTag(name: 'Zone1_Motor', path: 'Outputs/Zone1_Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Zone 1 belt drive contactor'),
      PlcTag(name: 'Zone2_Motor', path: 'Outputs/Zone2_Motor', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Zone 2 belt drive contactor (driven by the MotorStarter FB)'),
      PlcTag(name: 'Belt_Jammed', path: 'Outputs/Belt_Jammed', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Belt jam alarm (latched)'),
      PlcTag(name: 'Line_Fault', path: 'Outputs/Line_Fault', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'E-Stop fault latch — requires a fresh Start press to clear'),
      PlcTag(name: 'JamTimer', path: 'Timers/JamTimer', dataType: 'TIMER', value: defaultValueFor(emptyScratchProject, 'TIMER', 0), ioType: 'Internal', description: 'On-delay timer: zone 1 running with no part for 5s trips the jam alarm'),
      PlcTag(name: 'StopDelay', path: 'Timers/StopDelay', dataType: 'TIMER', value: defaultValueFor(emptyScratchProject, 'TIMER', 0), ioType: 'Internal', description: 'Off-delay timer: holds the zone-2 permit 3s after the line stops'),
      PlcTag(name: 'PartCtu', path: 'Counters/PartCtu', dataType: 'COUNTER', value: defaultValueFor(emptyScratchProject, 'COUNTER', 0), ioType: 'Internal', description: 'Count-up counter (preset 10): cumulative parts since power-up — rung 12 zeroes Part_Count, not this counter, so PartCtu.CV never resets'),
      PlcTag(name: 'Part_Count', path: 'Internal/Part_Count', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Parts counted in the current batch'),
      PlcTag(name: 'Batch_Target', path: 'Internal/Batch_Target', dataType: 'INT32', value: 10, ioType: 'Internal', description: 'Batch size used by the SUB/EQ batch logic; note the CTU preset is a fixed literal 10 — changing this affects only the compare logic'),
      PlcTag(name: 'Parts_Remaining', path: 'Internal/Parts_Remaining', dataType: 'INT32', value: 10, ioType: 'Internal', description: 'Batch_Target - Part_Count (SUB block)'),
      PlcTag(name: 'Shift_Total', path: 'Internal/Shift_Total', dataType: 'INT32', value: 0, ioType: 'Internal', description: 'Parts counted this shift (never reset by the batch)'),
      PlcTag(name: 'Zone2Starter', path: 'Internal/Zone2Starter', dataType: 'MotorStarter', value: defaultValueFor(fbScratch, 'MotorStarter', 0), ioType: 'Internal', description: 'Ladder-bodied MotorStarter FB instance driving zone 2'),
      PlcTag(name: 'Line_DUT', path: 'Status/Line_DUT', dataType: 'Line_DUT', value: defaultValueFor(dutScratch, 'Line_DUT', 0), ioType: 'Internal', description: 'Line status/telemetry struct instance'),
    ],
    structDefs: structDefs,
    simRules: [
      // Parts every ~4.5s while zone 1 runs, so the 5s no-part jam threshold
      // only trips once parts genuinely stop arriving.
      SimRule(id: 'sim0', name: 'Photo eye blips while zone 1 runs', targetPath: 'Photo_Eye',
          behavior: 'pulse', onMs: 2000, offMs: 2500,
          condition: [SimClause(leftPath: 'Zone1_Motor', comparator: '==', operand: 'true')]),
    ],
    programs: [
      PlcProgram(
        name: 'ConveyorLine_LD',
        language: 'LadderLogic',
        description: 'Two-zone conveyor: seal-in, interlocks, part counting, batching, '
            'jam detection and a ladder-bodied MotorStarter FB for zone 2',
        rungs: [
          buildRung(
            index: 0,
            comment: 'Rung 0: Line Start/Stop Seal-In',
            main: [
              ldXic('Start_PB', 'Start NO'),
              ldXio('Stop_PB', 'Stop NC'),
              ldXic('EStop_OK', 'E-Stop healthy'),
              ldXic('Overload_OK', 'Overload healthy'),
              ldOte('Line_Latch', 'Seal-in latch'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Line_Latch', 'Seal-in aux')]),
            ],
          ),
          buildRung(
            index: 1,
            comment: 'Rung 1: Zone 1 Motor Permissives (jam interlock)',
            main: [
              ldXic('Line_Latch', 'Latched'),
              ldXic('EStop_OK', 'E-Stop healthy'),
              ldXio('Belt_Jammed', 'Jam interlock NC'),
              ldOte('Zone1_Motor', 'Zone 1 contactor'),
            ],
            branches: [
              BranchSpec(startIndex: 0, endIndex: 0, nodes: [ldXic('Manual_Jog', 'Manual jog')]),
            ],
          ),
          buildRung(
            index: 2,
            comment: 'Rung 2: E-Stop Latches the Line Fault (SET coil)',
            main: [ldXio('EStop_OK', 'E-Stop opened'), ldOtl('Line_Fault', 'Latch fault')],
          ),
          buildRung(
            index: 3,
            comment: 'Rung 3: A FRESH Start Press Unlatches the Fault (rising contact + RESET coil)',
            main: [ldXicRising('Start_PB', 'Start rising edge'), ldOtu('Line_Fault', 'Unlatch fault')],
          ),
          buildRung(
            index: 4,
            comment: 'Rung 4: Part Present Flag',
            main: [ldXic('Photo_Eye', 'Eye blocked'), ldOte('Part_Present', 'Part present')],
          ),
          buildRung(
            index: 5,
            comment: 'Rung 5: Part Leaves the Eye — falling contact drives a one-scan pulse coil',
            main: [ldXicFalling('Photo_Eye', 'Eye clears'), ldOsr('Part_Edge', 'One-scan pulse')],
          ),
          buildRung(
            index: 6,
            comment: 'Rung 6: Count the Part into the Batch (ADD)',
            main: [ldXic('Part_Edge', 'One part'), ldMath('ADD', 'Part_Count', 'Part_Count', '1', 'Part_Count + 1')],
          ),
          buildRung(
            index: 7,
            comment: 'Rung 7: Count the Part into the Shift Total (ADD)',
            main: [ldXic('Part_Edge', 'One part'), ldMath('ADD', 'Shift_Total', 'Shift_Total', '1', 'Shift_Total + 1')],
          ),
          buildRung(
            index: 8,
            comment: 'Rung 8: Parts Remaining in the Batch (SUB)',
            main: [ldXic('Line_Latch', 'Line running'), ldMath('SUB', 'Parts_Remaining', 'Batch_Target', 'Part_Count', 'Target - Count')],
          ),
          buildRung(
            index: 9,
            comment: 'Rung 9: Batch Part Counter (GT gate + CTU)',
            main: [
              ldCmp('GT', 'Part_Count', '0', 'Batch started'),
              ldXic('Part_Edge', 'One part'),
              ldCtu('PartCtu', 10, 'Parts per batch'),
            ],
          ),
          buildRung(
            index: 10,
            comment: 'Rung 10: Batch Complete Requests Zone 2 (EQ)',
            main: [ldCmp('EQ', 'Part_Count', 'Batch_Target', 'Count = Target'), ldOte('Zone2_Request', 'Zone 2 request')],
          ),
          buildRung(
            index: 11,
            comment: 'Rung 11: Batch Complete Zeroes the Count (LT + MOVE)',
            main: [ldCmp('LT', 'Parts_Remaining', '1', 'Nothing left'), ldMove('Part_Count', '0', '0 -> Part_Count')],
          ),
          buildRung(
            index: 12,
            comment: 'Rung 12: Batch Running Flag (NEGATED coil)',
            main: [ldCmp('LT', 'Parts_Remaining', '1', 'Nothing left'), ldOteNeg('Batch_Running', 'Inverted: batch idle')],
          ),
          buildRung(
            index: 13,
            comment: 'Rung 13: Jam Detection — zone 1 running with no part for 5s (TON)',
            main: [
              ldXic('Zone1_Motor', 'Zone 1 running'),
              ldXio('Part_Present', 'No part NC'),
              ldTon('JamTimer', 5000, '5s jam timer'),
            ],
          ),
          buildRung(
            index: 14,
            comment: 'Rung 14: Latch the Jam Alarm',
            main: [ldXic('JamTimer.DN', 'Timer done'), ldOtl('Belt_Jammed', 'Latch jam')],
          ),
          buildRung(
            index: 15,
            comment: 'Rung 15: A Part Clears the Jam Alarm',
            main: [ldXic('Photo_Eye', 'Part seen'), ldOtu('Belt_Jammed', 'Unlatch jam')],
          ),
          buildRung(
            index: 16,
            comment: 'Rung 16: Zone 2 Permit — 3s off-delay run-on after the line stops (TOF)',
            main: [
              ldXic('Line_Latch', 'Line running'),
              ldTof('StopDelay', 3000, '3s run-on'),
              ldOte('Zone2_Permit', 'Zone 2 permit'),
            ],
          ),
          buildRung(
            index: 17,
            comment: 'Rung 17: Zone 2 Starter — LADDER-BODIED custom FB call. '
                'Unconditional (wired straight off the left rail) so the FB keeps '
                'evaluating its own Permit and can drop its seal when the permit goes away.',
            main: [
              ldFbCall('MotorStarter', 'Zone2Starter', {
                'Run': 'Zone2_Request',
                'Permit': 'Zone2_Permit',
                'Out': 'Zone2_Motor',
              }, 'Zone 2 starter instance'),
            ],
          ),
          buildRung(
            index: 18,
            comment: 'Rung 18: DUT — Running member',
            main: [ldXic('Zone1_Motor', 'Zone 1 running'), ldOte('Line_DUT.Running', 'DUT.Running')],
          ),
          buildRung(
            index: 19,
            comment: 'Rung 19: DUT — Faulted member',
            main: [ldXic('Line_Fault', 'Line faulted'), ldOte('Line_DUT.Faulted', 'DUT.Faulted')],
          ),
          buildRung(
            index: 20,
            comment: 'Rung 20: DUT — Speed member (MOVE)',
            main: [ldXic('Zone1_Motor', 'Zone 1 running'), ldMove('Line_DUT.Speed', '1450', 'Nameplate rpm')],
          ),
          buildRung(
            index: 21,
            comment: 'Rung 21: Line Stopped — one-scan pulse on the FALLING power edge',
            main: [ldXic('Line_Latch', 'Line running'), ldOsf('Line_Stop_Edge', 'One-scan stop pulse')],
          ),
          buildRung(
            index: 22,
            comment: 'Rung 22: Stopping the Line Abandons the Partial Batch (MOVE)',
            main: [ldXic('Line_Stop_Edge', 'Line just stopped'), ldMove('Part_Count', '0', '0 -> Part_Count')],
          ),
        ],
      ),
    ],
    tasks: [
      PlcTask(name: 'LineTask', type: 'Continuous', periodMs: 100, programNames: ['ConveyorLine_LD']),
    ],
    hmis: [
      HmiScreenDef(
        id: 'hmi_ld_conveyor_line',
        title: 'Conveyor Line HMI',
        layoutType: 'GridDashboard',
        components: [
          HmiComponent(id: 'cl1', title: 'START Line (NO)', type: 'PushbuttonSwitch', tagBinding: 'Start_PB', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'cl2', title: 'STOP Line (NC)', type: 'PushbuttonSwitch', tagBinding: 'Stop_PB', gridSpanWidth: 1, accentColor: 'red'),
          HmiComponent(id: 'cl3', title: 'Manual JOG', type: 'PushbuttonSwitch', tagBinding: 'Manual_Jog', gridSpanWidth: 1, accentColor: 'amber'),
          HmiComponent(id: 'cl4', title: 'E-Stop Healthy', type: 'ToggleSwitch', tagBinding: 'EStop_OK', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'cl5', title: 'Overload Healthy', type: 'ToggleSwitch', tagBinding: 'Overload_OK', gridSpanWidth: 1, accentColor: 'teal'),
          HmiComponent(id: 'cl6', title: 'Zone 1 Running', type: 'LedIndicatorLight', tagBinding: 'Zone1_Motor', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'cl7', title: 'Zone 2 Running', type: 'LedIndicatorLight', tagBinding: 'Zone2_Motor', gridSpanWidth: 1, accentColor: 'green'),
          HmiComponent(id: 'cl8', title: 'Part Detected', type: 'LedIndicatorLight', tagBinding: 'Photo_Eye', gridSpanWidth: 1, accentColor: 'cyan'),
          HmiComponent(id: 'cl9', title: 'Parts Counted', type: 'DigitalGaugeDisplay', tagBinding: 'Part_Count', gridSpanWidth: 2, accentColor: 'cyan'),
          HmiComponent(id: 'cl10', title: 'Parts Remaining', type: 'DigitalGaugeDisplay', tagBinding: 'Parts_Remaining', gridSpanWidth: 2, accentColor: 'teal'),
          HmiComponent(id: 'cl11', title: 'Batch Target', type: 'NumericSliderInput', tagBinding: 'Batch_Target', gridSpanWidth: 4, accentColor: 'teal'),
          HmiComponent(id: 'cl12', title: 'JAM ALARM', type: 'StatusPillDisplay', tagBinding: 'Belt_Jammed', gridSpanWidth: 2, accentColor: 'red'),
          HmiComponent(id: 'cl13', title: 'LINE FAULT', type: 'StatusPillDisplay', tagBinding: 'Line_Fault', gridSpanWidth: 2, accentColor: 'red'),
        ],
      ),
    ],
  );
}
