/// Retired default-project builders, preserved verbatim as test fixtures.
///
/// These are NOT shipped (see `mobile/lib/data/default_projects/` for the seven
/// curated defaults). They exist so engine tests whose assertions are tied to a
/// specific plant/timing keep their original harness: re-pointing them at a new
/// project would silently change what they prove.
library;

import 'package:soft_plc_mobile/models/project_model.dart';

// ── Batch Counter (CTU) ──────────────────────────────────────────────────
//
// Showcase for the CTU (count-up) function block: Part_Sensor pulses
// (simulated part arrivals passing a photo eye) drive CTU.CU. Each rising
// edge increments CV by exactly one — holding the sensor true does not
// over-count, because CTU is edge-triggered, not level-triggered. CV feeds
// Count (SimulatedOutput) and Q feeds Batch_Done once CV reaches Batch_Size.
//
// Self-reset is wired through tag feedback, not a same-scan topological
// cycle: a SECOND TAG_INPUT block reads Batch_Done and drives CTU.R. When
// Q fires, Batch_Done goes true THIS scan; the second TAG_INPUT block reads
// that new value only on the NEXT scan, so R resets CV to 0 one scan later —
// a clean, cycle-free, one-scan-delayed feedback reset. See
// test/counter_loop_integration_test.dart for the exact scan-by-scan
// behavior this produces.
PlcProject legacyBatchCounterProject() => PlcProject(
      id: 'proj_batch_counter',
      name: 'Batch Counter',
      controllerName: 'PLC_CTU',
      scanPeriodMs: 100,
      tags: [
        PlcTag(
            name: 'Part_Sensor',
            path: 'Inputs/Part_Sensor',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedInput',
            description: 'Photo-eye part detection sensor'),
        PlcTag(
            name: 'Batch_Size',
            path: 'Internal/Batch_Size',
            dataType: 'INT32',
            value: 5,
            ioType: 'Internal',
            description: 'Number of parts per batch (CTU preset)'),
        PlcTag(
            name: 'Batch_Done',
            path: 'Outputs/Batch_Done',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedOutput',
            description:
                'Batch complete (CTU.Q); also feeds the one-scan-delayed self-reset'),
        PlcTag(
            name: 'Count',
            path: 'Outputs/Count',
            dataType: 'INT32',
            value: 0,
            ioType: 'SimulatedOutput',
            description: 'Parts counted this batch (CTU.CV)'),
      ],
      structDefs: [],
      simRules: [
        // Part arrivals: on 250ms (~2-3 scans at 100ms/scan), off 350ms
        // (~3-4 scans) — clear, well-separated rising edges rather than
        // chattering every scan.
        SimRule(
            id: 'sim0',
            name: 'Part arrivals at the photo eye',
            targetPath: 'Part_Sensor',
            behavior: 'pulse',
            onMs: 250,
            offMs: 350),
      ],
      programs: [
        PlcProgram(
          name: 'BatchCount_FBD',
          language: 'FunctionBlockDiagram',
          description:
              'CTU counts parts to Batch_Size, then self-resets via one-scan-delayed tag feedback',
          fbdBlocks: [
            FbdBlock(
                id: 'c_cu',
                type: 'TAG_INPUT',
                title: 'Part Sensor',
                tagBinding: 'Part_Sensor',
                x: 50,
                y: 80),
            FbdBlock(
                id: 'c_pv',
                type: 'TAG_INPUT',
                title: 'Batch Size',
                tagBinding: 'Batch_Size',
                x: 50,
                y: 200),
            FbdBlock(
                id: 'c_r',
                type: 'TAG_INPUT',
                title: 'Batch Done (feedback)',
                tagBinding: 'Batch_Done',
                x: 50,
                y: 320),
            FbdBlock(
                id: 'c_ctu',
                type: 'CTU',
                title: 'Batch CTU',
                tagBinding: '',
                x: 320,
                y: 200),
            FbdBlock(
                id: 'c_q',
                type: 'TAG_OUTPUT',
                title: 'Batch Done',
                tagBinding: 'Batch_Done',
                x: 560,
                y: 150),
            FbdBlock(
                id: 'c_cv',
                type: 'TAG_OUTPUT',
                title: 'Count',
                tagBinding: 'Count',
                x: 560,
                y: 260),
          ],
          fbdWires: [
            FbdWire(
                fromBlockId: 'c_cu',
                fromPin: 'OUT',
                toBlockId: 'c_ctu',
                toPin: 'CU'),
            FbdWire(
                fromBlockId: 'c_r',
                fromPin: 'OUT',
                toBlockId: 'c_ctu',
                toPin: 'R'),
            FbdWire(
                fromBlockId: 'c_pv',
                fromPin: 'OUT',
                toBlockId: 'c_ctu',
                toPin: 'PV'),
            FbdWire(
                fromBlockId: 'c_ctu',
                fromPin: 'Q',
                toBlockId: 'c_q',
                toPin: 'IN'),
            FbdWire(
                fromBlockId: 'c_ctu',
                fromPin: 'CV',
                toBlockId: 'c_cv',
                toPin: 'IN'),
          ],
        ),
      ],
      tasks: [
        PlcTask(
            name: 'BatchCountTask',
            type: 'Continuous',
            periodMs: 100,
            programNames: ['BatchCount_FBD']),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_batch_counter',
          title: 'Batch Counter Dashboard',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(
                id: 'bc1',
                title: 'Parts Counted',
                type: 'DigitalGaugeDisplay',
                tagBinding: 'Count',
                gridSpanWidth: 4,
                accentColor: 'cyan'),
            HmiComponent(
                id: 'bc2',
                title: 'Batch Size',
                type: 'NumericSliderInput',
                tagBinding: 'Batch_Size',
                gridSpanWidth: 4,
                accentColor: 'teal'),
            HmiComponent(
                id: 'bc3',
                title: 'Batch Done',
                type: 'LedIndicatorLight',
                tagBinding: 'Batch_Done',
                gridSpanWidth: 1,
                accentColor: 'green'),
            HmiComponent(
                id: 'bc4',
                title: 'Part Sensor',
                type: 'LedIndicatorLight',
                tagBinding: 'Part_Sensor',
                gridSpanWidth: 1,
                accentColor: 'amber'),
          ],
        ),
      ],
    );

// ── Pulse Output (R_TRIG + TP) ───────────────────────────────────────────
//
// Showcase for the R_TRIG edge detector gating a TP (pulse timer): each
// rising edge of Start_Btn fires exactly one Q pulse on R_TRIG, which starts
// TP. TP then holds Pulse_Out true for Pulse_Time ms REGARDLESS of how long
// Start_Btn stays held — TP is non-retriggerable. The sim rule drives
// Start_Btn with an on-phase (5000ms) deliberately LONGER than Pulse_Time
// (3000ms) so the demo visibly proves the output pulse width is set by TP,
// not by the button hold. See test/pulse_loop_integration_test.dart.
PlcProject legacyPulseOutputProject() => PlcProject(
      id: 'proj_pulse_output',
      name: 'Pulse Output',
      controllerName: 'PLC_PULSE',
      scanPeriodMs: 100,
      tags: [
        PlcTag(
            name: 'Start_Btn',
            path: 'Inputs/Start_Btn',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedInput',
            description: 'Momentary start button (simulated press)'),
        PlcTag(
            name: 'Pulse_Time',
            path: 'Internal/Pulse_Time',
            dataType: 'INT32',
            value: 3000,
            ioType: 'Internal',
            description: 'Fixed pulse width in ms (TP.PT preset)'),
        PlcTag(
            name: 'Pulse_Out',
            path: 'Outputs/Pulse_Out',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedOutput',
            description:
                'Fixed-width one-shot pulse (TP.Q), gated by the Start_Btn rising edge (R_TRIG.Q)'),
        PlcTag(
            name: 'Pulse_ET',
            path: 'Outputs/Pulse_ET',
            dataType: 'INT32',
            value: 0,
            ioType: 'SimulatedOutput',
            description:
                'Elapsed time of the current/last pulse in ms (TP.ET)'),
      ],
      structDefs: [],
      simRules: [
        // Button presses: on 5000ms (well past Pulse_Time=3000ms), off 2000ms —
        // the on-phase deliberately outlasts the pulse width so the demo proves
        // Pulse_Out is timed by TP, not by how long Start_Btn is held.
        SimRule(
            id: 'sim0',
            name: 'Start button presses (held longer than Pulse_Time)',
            targetPath: 'Start_Btn',
            behavior: 'pulse',
            onMs: 5000,
            offMs: 2000),
      ],
      programs: [
        PlcProgram(
          name: 'PulseOut_FBD',
          language: 'FunctionBlockDiagram',
          description:
              'R_TRIG detects the Start_Btn rising edge to start a non-retriggerable TP pulse of Pulse_Time ms',
          fbdBlocks: [
            FbdBlock(
                id: 'u_btn',
                type: 'TAG_INPUT',
                title: 'Start Btn',
                tagBinding: 'Start_Btn',
                x: 50,
                y: 80),
            FbdBlock(
                id: 'u_pt',
                type: 'TAG_INPUT',
                title: 'Pulse Time',
                tagBinding: 'Pulse_Time',
                x: 50,
                y: 260),
            FbdBlock(
                id: 'u_rtrig',
                type: 'R_TRIG',
                title: 'Btn Rising Edge',
                tagBinding: '',
                x: 300,
                y: 80),
            FbdBlock(
                id: 'u_tp',
                type: 'TP',
                title: 'Output Pulse',
                tagBinding: '',
                x: 560,
                y: 150),
            FbdBlock(
                id: 'u_out',
                type: 'TAG_OUTPUT',
                title: 'Pulse Out',
                tagBinding: 'Pulse_Out',
                x: 820,
                y: 100),
            FbdBlock(
                id: 'u_et',
                type: 'TAG_OUTPUT',
                title: 'Pulse ET',
                tagBinding: 'Pulse_ET',
                x: 820,
                y: 220),
          ],
          fbdWires: [
            FbdWire(
                fromBlockId: 'u_btn',
                fromPin: 'OUT',
                toBlockId: 'u_rtrig',
                toPin: 'CLK'),
            FbdWire(
                fromBlockId: 'u_rtrig',
                fromPin: 'Q',
                toBlockId: 'u_tp',
                toPin: 'IN'),
            FbdWire(
                fromBlockId: 'u_pt',
                fromPin: 'OUT',
                toBlockId: 'u_tp',
                toPin: 'PT'),
            FbdWire(
                fromBlockId: 'u_tp',
                fromPin: 'Q',
                toBlockId: 'u_out',
                toPin: 'IN'),
            FbdWire(
                fromBlockId: 'u_tp',
                fromPin: 'ET',
                toBlockId: 'u_et',
                toPin: 'IN'),
          ],
        ),
      ],
      tasks: [
        PlcTask(
            name: 'PulseOutTask',
            type: 'Continuous',
            periodMs: 100,
            programNames: ['PulseOut_FBD']),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_pulse_output',
          title: 'Pulse Output Dashboard',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(
                id: 'po1',
                title: 'Start Btn',
                type: 'LedIndicatorLight',
                tagBinding: 'Start_Btn',
                gridSpanWidth: 1,
                accentColor: 'amber'),
            HmiComponent(
                id: 'po2',
                title: 'Pulse Out',
                type: 'LedIndicatorLight',
                tagBinding: 'Pulse_Out',
                gridSpanWidth: 1,
                accentColor: 'green'),
            HmiComponent(
                id: 'po3',
                title: 'Pulse Elapsed (ms)',
                type: 'DigitalGaugeDisplay',
                tagBinding: 'Pulse_ET',
                gridSpanWidth: 4,
                accentColor: 'cyan'),
          ],
        ),
      ],
    );
