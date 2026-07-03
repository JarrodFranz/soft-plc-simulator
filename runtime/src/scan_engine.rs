// Scan Engine
//
// The scan engine is the heart of the PLC runtime.
// It implements the classic PLC scan cycle:
//
// 1. Read inputs (snapshot I/O image)
// 2. Execute all programs (in task order)
// 3. Write outputs (commit I/O image)
// 4. Service communications (protocol adapters)
// 5. Housekeeping (diagnostics, timing)
//
// The scan engine runs at a configurable scan period and tracks
// performance metrics like scan time and scan count.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::instructions::{self, Rung};
use crate::io_image;
use crate::program::Program;
use crate::tag::TagDatabase;
use crate::timer::TonTimer;

/// Diagnostics from the scan engine.
#[derive(Debug, Clone)]
pub struct ScanDiagnostics {
    /// Total number of scan cycles executed.
    pub scan_count: u64,
    /// Duration of the last scan cycle.
    pub last_scan_time: Duration,
    /// Minimum scan time observed.
    pub min_scan_time: Duration,
    /// Maximum scan time observed.
    pub max_scan_time: Duration,
    /// Average scan time (running average).
    pub avg_scan_time: Duration,
    /// Configured scan period.
    pub scan_period: Duration,
    /// Whether the scan overran its configured period.
    pub overrun: bool,
}

impl ScanDiagnostics {
    fn new(scan_period: Duration) -> Self {
        Self {
            scan_count: 0,
            last_scan_time: Duration::ZERO,
            min_scan_time: Duration::MAX,
            max_scan_time: Duration::ZERO,
            avg_scan_time: Duration::ZERO,
            scan_period,
            overrun: false,
        }
    }

    fn update(&mut self, scan_time: Duration) {
        self.scan_count += 1;
        self.last_scan_time = scan_time;
        self.min_scan_time = self.min_scan_time.min(scan_time);
        self.max_scan_time = self.max_scan_time.max(scan_time);
        self.overrun = scan_time > self.scan_period;

        // Running average
        if self.scan_count == 1 {
            self.avg_scan_time = scan_time;
        } else {
            let total = self.avg_scan_time.as_nanos() as u128 * (self.scan_count - 1) as u128
                + scan_time.as_nanos() as u128;
            self.avg_scan_time = Duration::from_nanos((total / self.scan_count as u128) as u64);
        }
    }
}

/// The scan engine executes PLC programs in a repeating scan cycle.
pub struct ScanEngine {
    /// Timer instances used by logic instructions.
    pub timers: HashMap<String, TonTimer>,
    /// Scan diagnostics.
    pub diagnostics: ScanDiagnostics,
    /// Configured scan period.
    scan_period: Duration,
}

impl ScanEngine {
    /// Create a new scan engine with the given scan period.
    pub fn new(scan_period_ms: u64) -> Self {
        let scan_period = Duration::from_millis(scan_period_ms);
        Self {
            timers: HashMap::new(),
            diagnostics: ScanDiagnostics::new(scan_period),
            scan_period,
        }
    }

    /// Execute one complete scan cycle.
    ///
    /// This performs:
    /// 1. Read inputs
    /// 2. Execute all programs (all rungs in each program)
    /// 3. Write outputs
    /// 4. Update diagnostics
    pub fn execute_scan(&mut self, db: &mut TagDatabase, programs: &[Program]) {
        let scan_start = Instant::now();
        let scan_time_ms = self.scan_period.as_millis() as u64;

        // 1. Read inputs (snapshot I/O image)
        io_image::read_inputs(db);

        // 2. Execute all programs
        for program in programs {
            if !program.enabled {
                continue;
            }
            self.execute_program(db, program, scan_time_ms);
        }

        // 3. Write outputs (commit I/O image)
        io_image::write_outputs(db);

        // 4. Update diagnostics
        let scan_time = scan_start.elapsed();
        self.diagnostics.update(scan_time);
    }

    /// Execute a single program (all rungs).
    fn execute_program(&mut self, db: &mut TagDatabase, program: &Program, scan_time_ms: u64) {
        for rung in &program.rungs {
            instructions::execute_rung(rung, db, &mut self.timers, scan_time_ms);
        }
    }

    /// Get the configured scan period.
    pub fn scan_period(&self) -> Duration {
        self.scan_period
    }

    /// Set the scan period.
    pub fn set_scan_period(&mut self, period_ms: u64) {
        self.scan_period = Duration::from_millis(period_ms);
        self.diagnostics.scan_period = self.scan_period;
    }

    /// Reset the scan engine state (timers and diagnostics).
    pub fn reset(&mut self) {
        self.timers.clear();
        self.diagnostics = ScanDiagnostics::new(self.scan_period);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::instructions::{Instruction, Rung};
    use crate::program::{Program, ProgramLanguage};
    use crate::tag::{Tag, IoType};

    fn make_motor_circuit() -> (TagDatabase, Vec<Program>) {
        let mut db = TagDatabase::new();
        db.add_tag(Tag::new_bool("Start_PB", "Inputs/Start_PB", IoType::SimulatedInput, "Start pushbutton"));
        db.add_tag(Tag::new_bool("Stop_PB", "Inputs/Stop_PB", IoType::SimulatedInput, "Stop pushbutton"));
        db.add_tag(Tag::new_bool("EStop_OK", "Inputs/EStop_OK", IoType::SimulatedInput, "E-stop OK"));
        db.add_tag(Tag::new_bool("Overload_OK", "Inputs/Overload_OK", IoType::SimulatedInput, "Overload OK"));
        db.add_tag(Tag::new_bool("Motor_Latch", "Internal/Motor_Latch", IoType::Internal, "Motor latch"));
        db.add_tag(Tag::new_bool("Motor_Run", "Outputs/Motor_Run", IoType::SimulatedOutput, "Motor running"));

        // Set permissives OK by default
        db.write_bool("EStop_OK", true);
        db.write_bool("Overload_OK", true);

        let mut program = Program::new("MotorControl", ProgramLanguage::LadderLogic, "Motor start/stop");

        // Rung 1: Motor Latch
        // Start_PB OR Motor_Latch (seal-in), AND NOT Stop_PB, AND EStop_OK, AND Overload_OK -> Latch Motor_Latch
        program.add_rung(Rung {
            comment: "Motor latch - start/seal-in with permissives".to_string(),
            instructions: vec![
                // Start OR seal-in branch
                Instruction::BranchStart,
                Instruction::ExamineOpen { tag: "Start_PB".to_string() },
                Instruction::BranchNext,
                Instruction::ExamineOpen { tag: "Motor_Latch".to_string() },
                Instruction::BranchEnd,
                // AND permissives
                Instruction::ExamineClosed { tag: "Stop_PB".to_string() },
                Instruction::ExamineOpen { tag: "EStop_OK".to_string() },
                Instruction::ExamineOpen { tag: "Overload_OK".to_string() },
                // Output
                Instruction::OutputCoil { tag: "Motor_Latch".to_string() },
            ],
        });

        // Rung 2: Motor Run = Motor Latch (could add additional interlock here)
        program.add_rung(Rung {
            comment: "Motor run output".to_string(),
            instructions: vec![
                Instruction::ExamineOpen { tag: "Motor_Latch".to_string() },
                Instruction::OutputCoil { tag: "Motor_Run".to_string() },
            ],
        });

        (db, vec![program])
    }

    #[test]
    fn test_scan_engine_creates() {
        let engine = ScanEngine::new(100);
        assert_eq!(engine.scan_period().as_millis(), 100);
        assert_eq!(engine.diagnostics.scan_count, 0);
    }

    #[test]
    fn test_motor_start() {
        let (mut db, programs) = make_motor_circuit();
        let mut engine = ScanEngine::new(100);

        // Initial state - motor off
        engine.execute_scan(&mut db, &programs);
        assert!(!db.read_bool("Motor_Run"));

        // Press start
        db.write_bool("Start_PB", true);
        engine.execute_scan(&mut db, &programs);
        assert!(db.read_bool("Motor_Run"));
        assert!(db.read_bool("Motor_Latch"));

        // Release start - motor stays on (seal-in)
        db.write_bool("Start_PB", false);
        engine.execute_scan(&mut db, &programs);
        assert!(db.read_bool("Motor_Run"));
    }

    #[test]
    fn test_motor_stop() {
        let (mut db, programs) = make_motor_circuit();
        let mut engine = ScanEngine::new(100);

        // Start motor
        db.write_bool("Start_PB", true);
        engine.execute_scan(&mut db, &programs);
        db.write_bool("Start_PB", false);
        engine.execute_scan(&mut db, &programs);
        assert!(db.read_bool("Motor_Run"));

        // Press stop
        db.write_bool("Stop_PB", true);
        engine.execute_scan(&mut db, &programs);
        assert!(!db.read_bool("Motor_Run"));
        assert!(!db.read_bool("Motor_Latch"));
    }

    #[test]
    fn test_motor_estop() {
        let (mut db, programs) = make_motor_circuit();
        let mut engine = ScanEngine::new(100);

        // Start motor
        db.write_bool("Start_PB", true);
        engine.execute_scan(&mut db, &programs);
        db.write_bool("Start_PB", false);
        engine.execute_scan(&mut db, &programs);
        assert!(db.read_bool("Motor_Run"));

        // E-stop drops
        db.write_bool("EStop_OK", false);
        engine.execute_scan(&mut db, &programs);
        assert!(!db.read_bool("Motor_Run"), "Motor must stop on E-stop");
        assert!(!db.read_bool("Motor_Latch"));
    }

    #[test]
    fn test_motor_overload() {
        let (mut db, programs) = make_motor_circuit();
        let mut engine = ScanEngine::new(100);

        // Start motor
        db.write_bool("Start_PB", true);
        engine.execute_scan(&mut db, &programs);
        db.write_bool("Start_PB", false);
        engine.execute_scan(&mut db, &programs);
        assert!(db.read_bool("Motor_Run"));

        // Overload trips
        db.write_bool("Overload_OK", false);
        engine.execute_scan(&mut db, &programs);
        assert!(!db.read_bool("Motor_Run"), "Motor must stop on overload");
        assert!(!db.read_bool("Motor_Latch"));
    }

    #[test]
    fn test_motor_cannot_start_without_permissives() {
        let (mut db, programs) = make_motor_circuit();
        let mut engine = ScanEngine::new(100);

        // E-stop not OK
        db.write_bool("EStop_OK", false);
        db.write_bool("Start_PB", true);
        engine.execute_scan(&mut db, &programs);
        assert!(!db.read_bool("Motor_Run"), "Motor must not start without E-stop OK");
    }

    #[test]
    fn test_scan_diagnostics() {
        let (mut db, programs) = make_motor_circuit();
        let mut engine = ScanEngine::new(100);

        engine.execute_scan(&mut db, &programs);
        assert_eq!(engine.diagnostics.scan_count, 1);
        assert!(engine.diagnostics.last_scan_time < Duration::from_millis(10));

        engine.execute_scan(&mut db, &programs);
        assert_eq!(engine.diagnostics.scan_count, 2);
    }

    #[test]
    fn test_ton_in_scan_cycle() {
        let mut db = TagDatabase::new();
        db.add_tag(Tag::new_bool("Enable", "Test/Enable", IoType::SimulatedInput, "Timer enable"));
        db.add_tag(Tag::new_bool("Done", "Test/Done", IoType::SimulatedOutput, "Timer done"));

        let mut program = Program::new("TimerTest", ProgramLanguage::InternalInstructions, "Timer test");
        program.add_rung(Rung {
            comment: "TON timer test".to_string(),
            instructions: vec![
                Instruction::TimerOnDelay {
                    timer_name: "T1".to_string(),
                    enable_tag: "Enable".to_string(),
                    done_tag: "Done".to_string(),
                    preset_ms: 500,
                },
            ],
        });
        let programs = vec![program];

        let mut engine = ScanEngine::new(100);

        // Enable timer
        db.write_bool("Enable", true);

        // Run 4 scans (400ms) - not done yet
        for _ in 0..4 {
            engine.execute_scan(&mut db, &programs);
            assert!(!db.read_bool("Done"));
        }

        // Run 5th scan (500ms total) - should be done
        engine.execute_scan(&mut db, &programs);
        assert!(db.read_bool("Done"), "TON timer should be done after 500ms");
    }
}
