/// **Process Control Lab** (`proj_process_lab`).
///
/// (a) Story: a control-theory bench with four independent rigs in one project
/// — a single-loop PID level rig, a 2x2 cross-coupled thermal MIMO rig with a
/// static decoupler, a cascade-tank rig with a transport dead time, and a noisy
/// measurement rig with a first-order filter.
///
/// (b) Showcase for: `PID` and autotune-resolvable loops, multivariable
/// interaction analysis (`Heater_A/B` -> `Temp_A/B` with strong off-diagonal
/// gains), the `deadTime` sim behaviour, the `noise` sim behaviour with a
/// `firstOrderLag` filter, and a **multi-screen project** (four dashboards).
/// Each rig's plant and control are reproduced VERBATIM from the demo it
/// consolidates, so the re-pointed engine tests keep their exact meaning.
///
/// (c) Falsifiable: zeroing the PID gains pins `Valve_CV` and `Level_PV` never
/// moves; setting `tauSec: 0` on the transfer line makes `Tank_B_Level` rise in
/// lock-step with `Tank_A_Level`; a zero noise amplitude leaves `Level_Meas`
/// exactly equal to `Tank_Level` with nothing for the filter to smooth.
///
/// (d) Proof test: `test/defaults/process_lab_test.dart` (plus the re-pointed
/// `pid_loop_integration_test`, `pid_autotune_test`, `pid_autotune_screen_test`,
/// `deadtime_cascade_integration_test`, `noise_measurement_integration_test`,
/// `mimo_project_test` and `interaction_analysis_screen_test`).
///
/// ORDER IS LOAD-BEARING — see the two constraints in the plan's Task 7:
/// `LevelPID_FBD` must be `programs[0]`, and `Heater_A`/`Heater_B`/`Temp_A`/
/// `Temp_B` must be the first four analog tags declared.
library;

import '../../models/project_model.dart';

PlcProject processControlLabProject() => PlcProject(
      id: 'proj_process_lab',
      name: 'Process Control Lab',
      controllerName: 'PLC_LAB',
      scanPeriodMs: 500,
      tags: [
        // ── MIMO rig FIRST (interaction-analysis prefill order) ─────────
        PlcTag(name: 'Heater_A', path: 'Outputs/Heater_A', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', engineeringUnits: '%', description: 'Zone A heater power command (decoupler output)'),
        PlcTag(name: 'Heater_B', path: 'Outputs/Heater_B', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', engineeringUnits: '%', description: 'Zone B heater power command (decoupler output)'),
        PlcTag(name: 'Temp_A', path: 'Inputs/Temp_A', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Zone A temperature process value'),
        PlcTag(name: 'Temp_B', path: 'Inputs/Temp_B', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '°C', description: 'Zone B temperature process value'),
        PlcTag(name: 'SP_A', path: 'Internal/SP_A', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Zone A temperature setpoint'),
        PlcTag(name: 'SP_B', path: 'Internal/SP_B', dataType: 'FLOAT64', value: 40.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Zone B temperature setpoint'),
        PlcTag(name: 'Amb', path: 'Internal/Amb', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal', engineeringUnits: '°C', description: 'Ambient temperature both zones lose heat toward'),
        PlcTag(name: 'u_A', path: 'Internal/u_A', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal', engineeringUnits: '%', description: 'Zone A PID output before the static decoupler'),
        PlcTag(name: 'u_B', path: 'Internal/u_B', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal', engineeringUnits: '%', description: 'Zone B PID output before the static decoupler'),
        // ── PID level rig ───────────────────────────────────────────────
        PlcTag(name: 'Level_PV', path: 'Inputs/Level_PV', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Tank level process value'),
        PlcTag(name: 'Level_SP', path: 'Internal/Level_SP', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Tank level setpoint'),
        PlcTag(name: 'Valve_CV', path: 'Outputs/Valve_CV', dataType: 'FLOAT64', value: 0.0, ioType: 'SimulatedOutput', engineeringUnits: '%', description: 'Inlet valve control variable (PID output)'),
        // ── Cascade rig ─────────────────────────────────────────────────
        PlcTag(name: 'Feed_Valve', path: 'Internal/Feed_Valve', dataType: 'FLOAT64', value: 60.0, ioType: 'Internal', engineeringUnits: '%', description: 'Manipulated feed valve opening driving inflow into Tank A'),
        PlcTag(name: 'Tank_A_Level', path: 'Inputs/Tank_A_Level', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Upstream tank level'),
        PlcTag(name: 'Transfer_Line', path: 'Internal/Transfer_Line', dataType: 'FLOAT64', value: 10.0, ioType: 'Internal', engineeringUnits: '%', description: 'Transport-delayed signal in the pipe carrying Tank A level to Tank B (deadTime of Tank_A_Level)'),
        PlcTag(name: 'Tank_B_Level', path: 'Inputs/Tank_B_Level', dataType: 'FLOAT64', value: 10.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Downstream tank level, lags Tank A by the transport delay'),
        // ── Noise rig ───────────────────────────────────────────────────
        PlcTag(name: 'Fill_Valve', path: 'Internal/Fill_Valve', dataType: 'FLOAT64', value: 55.0, ioType: 'Internal', engineeringUnits: '%', description: 'Manipulated fill valve opening driving inflow into the tank'),
        PlcTag(name: 'Tank_Level', path: 'Inputs/Tank_Level', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Clean (true) tank level, driven by Fill_Valve minus a constant outflow'),
        PlcTag(name: 'Level_Meas', path: 'Inputs/Level_Meas', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Raw noisy sensor reading of Tank_Level (measurement noise behaviour)'),
        PlcTag(name: 'Level_Filtered', path: 'Inputs/Level_Filtered', dataType: 'FLOAT64', value: 20.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'First-order-lag-filtered reading of Level_Meas'),
      ],
      structDefs: [],
      simRules: [
        // PID level rig (re-id'd; behavioural fields verbatim).
        SimRule(id: 'pid_sim0', name: 'Inflow scaled by valve position', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: 6.0, sourcePath: 'Valve_CV', refValue: 100.0,
            minValue: 0, maxValue: 100),
        SimRule(id: 'pid_sim1', name: 'Constant outflow disturbance', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: -1.0, minValue: 0, maxValue: 100),
        // MIMO rig (ids verbatim — already unique).
        SimRule(id: 'sa0', name: 'Zone A heater', targetPath: 'Temp_A', behavior: 'integrate',
            ratePerSec: 3.0, sourcePath: 'Heater_A', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sa1', name: 'A<->B conduction', targetPath: 'Temp_A', behavior: 'firstOrderLag',
            sourcePath: 'Temp_B', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sa2', name: 'Zone A heat loss', targetPath: 'Temp_A', behavior: 'firstOrderLag',
            sourcePath: 'Amb', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sb0', name: 'Zone B heater', targetPath: 'Temp_B', behavior: 'integrate',
            ratePerSec: 3.0, sourcePath: 'Heater_B', refValue: 100.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sb1', name: 'B<->A conduction', targetPath: 'Temp_B', behavior: 'firstOrderLag',
            sourcePath: 'Temp_A', tauSec: 8.0, minValue: 0, maxValue: 200, condition: const []),
        SimRule(id: 'sb2', name: 'Zone B heat loss', targetPath: 'Temp_B', behavior: 'firstOrderLag',
            sourcePath: 'Amb', tauSec: 40.0, minValue: 0, maxValue: 200, condition: const []),
        // Cascade rig (re-id'd; behavioural fields verbatim).
        SimRule(id: 'casc_sim0', name: 'Tank A inflow scaled by Feed_Valve', targetPath: 'Tank_A_Level',
            behavior: 'integrate', ratePerSec: 4.0, sourcePath: 'Feed_Valve', refValue: 100.0,
            minValue: 0, maxValue: 100),
        SimRule(id: 'casc_sim1', name: 'Tank A constant outflow', targetPath: 'Tank_A_Level',
            behavior: 'integrate', ratePerSec: -0.5, minValue: 0, maxValue: 100),
        SimRule(id: 'casc_sim2', name: 'Transfer line transport delay', targetPath: 'Transfer_Line',
            behavior: 'deadTime', sourcePath: 'Tank_A_Level', tauSec: 3.0, minValue: 0, maxValue: 100),
        SimRule(id: 'casc_sim3', name: 'Tank B inflow scaled by Transfer Line', targetPath: 'Tank_B_Level',
            behavior: 'integrate', ratePerSec: 4.0, sourcePath: 'Transfer_Line', refValue: 100.0,
            minValue: 0, maxValue: 100),
        SimRule(id: 'casc_sim4', name: 'Tank B constant outflow', targetPath: 'Tank_B_Level',
            behavior: 'integrate', ratePerSec: -0.5, minValue: 0, maxValue: 100),
        // Noise rig — ids kept VERBATIM: the noise PRNG is seeded from the id.
        SimRule(id: 'sim0', name: 'Tank inflow scaled by Fill_Valve', targetPath: 'Tank_Level',
            behavior: 'integrate', ratePerSec: 3.0, sourcePath: 'Fill_Valve', refValue: 100.0,
            minValue: 0, maxValue: 100),
        SimRule(id: 'sim1', name: 'Tank constant outflow', targetPath: 'Tank_Level',
            behavior: 'integrate', ratePerSec: -0.4, minValue: 0, maxValue: 100),
        SimRule(id: 'sim2', name: 'Level measurement noise', targetPath: 'Level_Meas',
            behavior: 'noise', sourcePath: 'Tank_Level', targetValue: 2.5,
            minValue: 0, maxValue: 100),
        SimRule(id: 'sim3', name: 'Level measurement filter', targetPath: 'Level_Filtered',
            behavior: 'firstOrderLag', sourcePath: 'Level_Meas', tauSec: 1.5,
            minValue: 0, maxValue: 100),
      ],
      programs: [
        // ── 1. LevelPID_FBD — MUST stay first (autotune prefill) ────────
        //     Copied verbatim from legacyFbdPidTankLevelProject().
        PlcProgram(
          name: 'LevelPID_FBD',
          language: 'FunctionBlockDiagram',
          description:
              'PID control block holds Level_PV at Level_SP by driving Valve_CV',
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
        // ── 2. TwoZone_FBD — copied verbatim from legacyMimoTwoZoneProject().
        PlcProgram(
          name: 'TwoZone_FBD',
          language: 'FunctionBlockDiagram',
          description:
              'Two PID loops (SP/Temp -> u) feeding a static decoupler (Heater = LIMIT(u - d*u_other, 0..100))',
          fbdBlocks: [
            // Loop A: SP_A/Temp_A -> pidA -> u_A
            FbdBlock(id: 'a_sp', type: 'TAG_INPUT', title: 'SP A', tagBinding: 'SP_A', x: 40, y: 60),
            FbdBlock(id: 'a_pv', type: 'TAG_INPUT', title: 'Temp A', tagBinding: 'Temp_A', x: 40, y: 150),
            FbdBlock(id: 'a_kp', type: 'CONST', title: 'Kp A', tagBinding: '4', x: 40, y: 240),
            FbdBlock(id: 'a_ki', type: 'CONST', title: 'Ki A', tagBinding: '0.3', x: 40, y: 310),
            FbdBlock(id: 'a_kd', type: 'CONST', title: 'Kd A', tagBinding: '0', x: 40, y: 380),
            FbdBlock(id: 'a_pid', type: 'PID', title: 'PID A', tagBinding: '', x: 280, y: 180),
            FbdBlock(id: 'a_uo', type: 'TAG_OUTPUT', title: 'u A', tagBinding: 'u_A', x: 500, y: 180),
            // Loop B: SP_B/Temp_B -> pidB -> u_B
            FbdBlock(id: 'b_sp', type: 'TAG_INPUT', title: 'SP B', tagBinding: 'SP_B', x: 40, y: 560),
            FbdBlock(id: 'b_pv', type: 'TAG_INPUT', title: 'Temp B', tagBinding: 'Temp_B', x: 40, y: 650),
            FbdBlock(id: 'b_kp', type: 'CONST', title: 'Kp B', tagBinding: '4', x: 40, y: 740),
            FbdBlock(id: 'b_ki', type: 'CONST', title: 'Ki B', tagBinding: '0.3', x: 40, y: 810),
            FbdBlock(id: 'b_kd', type: 'CONST', title: 'Kd B', tagBinding: '0', x: 40, y: 880),
            FbdBlock(id: 'b_pid', type: 'PID', title: 'PID B', tagBinding: '', x: 280, y: 680),
            FbdBlock(id: 'b_uo', type: 'TAG_OUTPUT', title: 'u B', tagBinding: 'u_B', x: 500, y: 680),
            // Decoupler shared feedback reads + LIMIT bounds
            FbdBlock(id: 'd_ua', type: 'TAG_INPUT', title: 'u A (fb)', tagBinding: 'u_A', x: 700, y: 120),
            FbdBlock(id: 'd_ub', type: 'TAG_INPUT', title: 'u B (fb)', tagBinding: 'u_B', x: 700, y: 740),
            FbdBlock(id: 'd_c0', type: 'CONST', title: 'Lo (0%)', tagBinding: '0', x: 700, y: 400),
            FbdBlock(id: 'd_c100', type: 'CONST', title: 'Hi (100%)', tagBinding: '100', x: 700, y: 470),
            // Decoupler A: Heater_A = LIMIT(u_A - d12*u_B, 0..100)
            FbdBlock(id: 'a_d12', type: 'CONST', title: 'd12', tagBinding: '0', x: 700, y: 260),
            FbdBlock(id: 'a_mul', type: 'MUL', title: 'd12 * u_B', tagBinding: '', x: 900, y: 260),
            FbdBlock(id: 'a_sub', type: 'SUB', title: 'u_A - m', tagBinding: '', x: 1080, y: 180),
            FbdBlock(id: 'a_lim', type: 'LIMIT', title: 'Clamp 0..100', tagBinding: '', x: 1260, y: 180),
            FbdBlock(id: 'a_ho', type: 'TAG_OUTPUT', title: 'Heater A', tagBinding: 'Heater_A', x: 1470, y: 180),
            // Decoupler B: Heater_B = LIMIT(u_B - d21*u_A, 0..100)
            FbdBlock(id: 'b_d21', type: 'CONST', title: 'd21', tagBinding: '0', x: 700, y: 580),
            FbdBlock(id: 'b_mul', type: 'MUL', title: 'd21 * u_A', tagBinding: '', x: 900, y: 580),
            FbdBlock(id: 'b_sub', type: 'SUB', title: 'u_B - m', tagBinding: '', x: 1080, y: 680),
            FbdBlock(id: 'b_lim', type: 'LIMIT', title: 'Clamp 0..100', tagBinding: '', x: 1260, y: 680),
            FbdBlock(id: 'b_ho', type: 'TAG_OUTPUT', title: 'Heater B', tagBinding: 'Heater_B', x: 1470, y: 680),
          ],
          fbdWires: [
            // Loop A
            FbdWire(fromBlockId: 'a_sp', fromPin: 'OUT', toBlockId: 'a_pid', toPin: 'SP'),
            FbdWire(fromBlockId: 'a_pv', fromPin: 'OUT', toBlockId: 'a_pid', toPin: 'PV'),
            FbdWire(fromBlockId: 'a_kp', fromPin: 'OUT', toBlockId: 'a_pid', toPin: 'KP'),
            FbdWire(fromBlockId: 'a_ki', fromPin: 'OUT', toBlockId: 'a_pid', toPin: 'KI'),
            FbdWire(fromBlockId: 'a_kd', fromPin: 'OUT', toBlockId: 'a_pid', toPin: 'KD'),
            FbdWire(fromBlockId: 'a_pid', fromPin: 'CV', toBlockId: 'a_uo', toPin: 'IN'),
            // Loop B
            FbdWire(fromBlockId: 'b_sp', fromPin: 'OUT', toBlockId: 'b_pid', toPin: 'SP'),
            FbdWire(fromBlockId: 'b_pv', fromPin: 'OUT', toBlockId: 'b_pid', toPin: 'PV'),
            FbdWire(fromBlockId: 'b_kp', fromPin: 'OUT', toBlockId: 'b_pid', toPin: 'KP'),
            FbdWire(fromBlockId: 'b_ki', fromPin: 'OUT', toBlockId: 'b_pid', toPin: 'KI'),
            FbdWire(fromBlockId: 'b_kd', fromPin: 'OUT', toBlockId: 'b_pid', toPin: 'KD'),
            FbdWire(fromBlockId: 'b_pid', fromPin: 'CV', toBlockId: 'b_uo', toPin: 'IN'),
            // Decoupler A: MUL(d12, u_B) -> SUB(u_A, m) -> LIMIT(0, s, 100) -> Heater_A
            FbdWire(fromBlockId: 'a_d12', fromPin: 'OUT', toBlockId: 'a_mul', toPin: 'IN1'),
            FbdWire(fromBlockId: 'd_ub', fromPin: 'OUT', toBlockId: 'a_mul', toPin: 'IN2'),
            FbdWire(fromBlockId: 'd_ua', fromPin: 'OUT', toBlockId: 'a_sub', toPin: 'IN1'),
            FbdWire(fromBlockId: 'a_mul', fromPin: 'OUT', toBlockId: 'a_sub', toPin: 'IN2'),
            FbdWire(fromBlockId: 'd_c0', fromPin: 'OUT', toBlockId: 'a_lim', toPin: 'MN'),
            FbdWire(fromBlockId: 'a_sub', fromPin: 'OUT', toBlockId: 'a_lim', toPin: 'IN'),
            FbdWire(fromBlockId: 'd_c100', fromPin: 'OUT', toBlockId: 'a_lim', toPin: 'MX'),
            FbdWire(fromBlockId: 'a_lim', fromPin: 'OUT', toBlockId: 'a_ho', toPin: 'IN'),
            // Decoupler B: MUL(d21, u_A) -> SUB(u_B, m) -> LIMIT(0, s, 100) -> Heater_B
            FbdWire(fromBlockId: 'b_d21', fromPin: 'OUT', toBlockId: 'b_mul', toPin: 'IN1'),
            FbdWire(fromBlockId: 'd_ua', fromPin: 'OUT', toBlockId: 'b_mul', toPin: 'IN2'),
            FbdWire(fromBlockId: 'd_ub', fromPin: 'OUT', toBlockId: 'b_sub', toPin: 'IN1'),
            FbdWire(fromBlockId: 'b_mul', fromPin: 'OUT', toBlockId: 'b_sub', toPin: 'IN2'),
            FbdWire(fromBlockId: 'd_c0', fromPin: 'OUT', toBlockId: 'b_lim', toPin: 'MN'),
            FbdWire(fromBlockId: 'b_sub', fromPin: 'OUT', toBlockId: 'b_lim', toPin: 'IN'),
            FbdWire(fromBlockId: 'd_c100', fromPin: 'OUT', toBlockId: 'b_lim', toPin: 'MX'),
            FbdWire(fromBlockId: 'b_lim', fromPin: 'OUT', toBlockId: 'b_ho', toPin: 'IN'),
          ],
        ),
        // ── 3. CascadeMonitor_FBD — copied from legacyCascadeTanksProject(),
        //     renaming block ids k_in/k_out -> c_in/c_out.
        PlcProgram(
          name: 'CascadeMonitor_FBD',
          language: 'FunctionBlockDiagram',
          description:
              'Trivial pass-through monitor of Feed_Valve; the cascade itself is entirely sim-driven',
          fbdBlocks: [
            FbdBlock(id: 'c_in', type: 'TAG_INPUT', title: 'Feed Valve', tagBinding: 'Feed_Valve', x: 50, y: 80),
            FbdBlock(id: 'c_out', type: 'TAG_OUTPUT', title: 'Feed Valve Monitor', tagBinding: 'Feed_Valve', x: 320, y: 80),
          ],
          fbdWires: [
            FbdWire(fromBlockId: 'c_in', fromPin: 'OUT', toBlockId: 'c_out', toPin: 'IN'),
          ],
        ),
        // ── 4. NoisyLevelMonitor_FBD — network 0 ONLY from
        //     legacyNoisyLevelProject(); the Hysteresis network moved to
        //     proj_st_reactor_control.
        PlcProgram(
          name: 'NoisyLevelMonitor_FBD',
          language: 'FunctionBlockDiagram',
          description:
              'Pass-through monitor of Fill_Valve; the noisy-measurement rig itself is entirely sim-driven',
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
        PlcTask(name: 'LabTask', type: 'Continuous', periodMs: 500, programNames: [
          'LevelPID_FBD',
          'TwoZone_FBD',
          'CascadeMonitor_FBD',
          'NoisyLevelMonitor_FBD',
        ]),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_lab_pid',
          title: 'Lab — Tank Level PID',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'lp1', title: 'Tank Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Level_PV', gridSpanWidth: 4, accentColor: 'cyan'),
            HmiComponent(id: 'lp2', title: 'Level Setpoint', type: 'NumericSliderInput', tagBinding: 'Level_SP', gridSpanWidth: 4, accentColor: 'teal'),
            HmiComponent(id: 'lp3', title: 'Valve CV (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Valve_CV', gridSpanWidth: 4, accentColor: 'amber'),
          ],
        ),
        HmiScreenDef(
          id: 'hmi_lab_mimo',
          title: 'Lab — Two Thermal Zones (MIMO)',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'lm1', title: 'Zone A Setpoint', type: 'NumericSliderInput', tagBinding: 'SP_A', gridSpanWidth: 2, accentColor: 'teal'),
            HmiComponent(id: 'lm2', title: 'Zone B Setpoint', type: 'NumericSliderInput', tagBinding: 'SP_B', gridSpanWidth: 2, accentColor: 'teal'),
            HmiComponent(id: 'lm3', title: 'Zone A Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_A', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 'lm4', title: 'Zone B Temp (°C)', type: 'DigitalGaugeDisplay', tagBinding: 'Temp_B', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 'lm5', title: 'Heater A (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Heater_A', gridSpanWidth: 2, accentColor: 'amber'),
            HmiComponent(id: 'lm6', title: 'Heater B (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Heater_B', gridSpanWidth: 2, accentColor: 'amber'),
            HmiComponent(id: 'lm7', title: 'PID A Out u_A (%)', type: 'DigitalGaugeDisplay', tagBinding: 'u_A', gridSpanWidth: 2, accentColor: 'teal'),
            HmiComponent(id: 'lm8', title: 'PID B Out u_B (%)', type: 'DigitalGaugeDisplay', tagBinding: 'u_B', gridSpanWidth: 2, accentColor: 'teal'),
          ],
        ),
        HmiScreenDef(
          id: 'hmi_lab_cascade',
          title: 'Lab — Cascade Tanks (Transport Delay)',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'lc1', title: 'Feed Valve (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Feed_Valve', gridSpanWidth: 4, accentColor: 'amber'),
            HmiComponent(id: 'lc2', title: 'Tank A Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Tank_A_Level', gridSpanWidth: 4, accentColor: 'cyan'),
            HmiComponent(id: 'lc3', title: 'Transfer Line (%)', type: 'DigitalGaugeDisplay', tagBinding: 'Transfer_Line', gridSpanWidth: 4, accentColor: 'teal'),
            HmiComponent(id: 'lc4', title: 'Tank B Level (%)', type: 'TankGraphicDisplay', tagBinding: 'Tank_B_Level', gridSpanWidth: 4, accentColor: 'teal'),
          ],
        ),
        HmiScreenDef(
          id: 'hmi_lab_noise',
          title: 'Lab — Noisy Measurement + Filter',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'ln1', title: 'Tank Level (%) — Clean', type: 'TankGraphicDisplay', tagBinding: 'Tank_Level', gridSpanWidth: 4, accentColor: 'cyan'),
            HmiComponent(id: 'ln2', title: 'Level Measured (%) — Noisy', type: 'DigitalGaugeDisplay', tagBinding: 'Level_Meas', gridSpanWidth: 4, accentColor: 'amber'),
            HmiComponent(id: 'ln3', title: 'Level Filtered (%) — Smoothed', type: 'DigitalGaugeDisplay', tagBinding: 'Level_Filtered', gridSpanWidth: 4, accentColor: 'teal'),
            HmiComponent(id: 'ln4', title: 'Fill Valve (%)', type: 'NumericSliderInput', tagBinding: 'Fill_Valve', gridSpanWidth: 4, accentColor: 'green'),
          ],
        ),
      ],
    );
