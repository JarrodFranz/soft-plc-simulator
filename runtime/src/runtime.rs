// Runtime
//
// The top-level PLC runtime that owns the tag database, scan engine,
// programs, and manages the runtime lifecycle.
//
// This is the primary API surface that the UI and protocol adapters
// interact with.

use std::time::{Duration, Instant};

use crate::program::Program;
use crate::project::Project;
use crate::scan_engine::{ScanEngine, ScanDiagnostics};
use crate::tag::{Tag, TagDatabase, TagValue};
use crate::io_image;

/// Runtime state.
#[derive(Debug, Clone, PartialEq)]
pub enum RuntimeState {
    /// Runtime is stopped. No scans are executing.
    Stopped,
    /// Runtime is running. Scans are executing.
    Running,
    /// Runtime has encountered a fault.
    Faulted(String),
}

/// The PLC runtime - owns all state and provides the public API.
pub struct Runtime {
    /// Current runtime state.
    pub state: RuntimeState,
    /// Tag database.
    pub tags: TagDatabase,
    /// Programs loaded in the runtime.
    pub programs: Vec<Program>,
    /// Scan engine.
    pub scan_engine: ScanEngine,
    /// Project name.
    pub project_name: String,
    /// Controller name.
    pub controller_name: String,
}

impl Runtime {
    /// Create a new empty runtime with the given scan period.
    pub fn new(scan_period_ms: u64) -> Self {
        Self {
            state: RuntimeState::Stopped,
            tags: TagDatabase::new(),
            programs: Vec::new(),
            scan_engine: ScanEngine::new(scan_period_ms),
            project_name: String::new(),
            controller_name: String::new(),
        }
    }

    /// Load a project into the runtime.
    pub fn load_project(&mut self, project: &Project) {
        self.project_name = project.name.clone();
        self.controller_name = project.controller.name.clone();
        self.tags = project.build_tag_database();
        self.programs = project.build_programs();
        self.scan_engine = ScanEngine::new(project.controller.scan_period_ms);
        self.state = RuntimeState::Stopped;

        log::info!(
            "Loaded project '{}' with {} tags, {} programs",
            self.project_name,
            self.tags.len(),
            self.programs.len()
        );
    }

    /// Start the runtime.
    pub fn start(&mut self) {
        match &self.state {
            RuntimeState::Stopped | RuntimeState::Faulted(_) => {
                self.scan_engine.reset();
                self.state = RuntimeState::Running;
                log::info!("Runtime started");
            }
            RuntimeState::Running => {
                log::warn!("Runtime is already running");
            }
        }
    }

    /// Stop the runtime.
    pub fn stop(&mut self) {
        self.state = RuntimeState::Stopped;
        log::info!("Runtime stopped");
    }

    /// Execute a single scan cycle.
    /// Returns true if the scan executed, false if the runtime is not running.
    pub fn execute_scan(&mut self) -> bool {
        if self.state != RuntimeState::Running {
            return false;
        }

        self.scan_engine.execute_scan(&mut self.tags, &self.programs);
        true
    }

    /// Run the runtime for a specified number of scans.
    /// Useful for testing.
    pub fn run_scans(&mut self, count: u64) {
        self.start();
        for _ in 0..count {
            self.execute_scan();
        }
    }

    /// Read a boolean tag value.
    pub fn read_bool(&self, name: &str) -> Option<bool> {
        self.tags.get_tag(name).map(|t| t.effective_value().as_bool())
    }

    /// Read a float tag value.
    pub fn read_f64(&self, name: &str) -> Option<f64> {
        self.tags.get_tag(name).map(|t| t.effective_value().as_f64())
    }

    /// Write a boolean tag value.
    pub fn write_bool(&mut self, name: &str, value: bool) {
        self.tags.write_bool(name, value);
    }

    /// Write a float tag value.
    pub fn write_f64(&mut self, name: &str, value: f64) {
        self.tags.write_f64(name, value);
    }

    /// Force a tag to a boolean value.
    pub fn force_bool(&mut self, name: &str, value: bool) {
        self.tags.force_bool(name, value);
    }

    /// Remove force from a tag.
    pub fn unforce(&mut self, name: &str) {
        self.tags.unforce(name);
    }

    /// Get scan diagnostics.
    pub fn diagnostics(&self) -> &ScanDiagnostics {
        &self.scan_engine.diagnostics
    }

    /// Get the runtime state.
    pub fn is_running(&self) -> bool {
        self.state == RuntimeState::Running
    }

    /// Get an I/O summary.
    pub fn io_summary(&self) -> io_image::IoSummary {
        io_image::io_summary(&self.tags)
    }

    /// Get all tag names.
    pub fn tag_names(&self) -> Vec<&String> {
        self.tags.tag_names()
    }

    /// Get a tag reference.
    pub fn get_tag(&self, name: &str) -> Option<&Tag> {
        self.tags.get_tag(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::instructions::{Instruction, Rung};
    use crate::program::ProgramLanguage;
    use crate::tag::IoType;

    fn create_motor_runtime() -> Runtime {
        let json = r#"{
            "project": {
                "name": "Motor Test",
                "version": "1.0.0",
                "description": "Motor start/stop test",
                "controller": { "name": "PLC_01", "scan_period_ms": 100 },
                "tags": [
                    { "name": "Start_PB", "path": "Inputs/Start_PB", "data_type": "BOOL", "initial_value": false, "access": "ReadWrite", "retentive": false, "description": "Start", "engineering_units": "", "io_type": "SimulatedInput" },
                    { "name": "Stop_PB", "path": "Inputs/Stop_PB", "data_type": "BOOL", "initial_value": false, "access": "ReadWrite", "retentive": false, "description": "Stop", "engineering_units": "", "io_type": "SimulatedInput" },
                    { "name": "EStop_OK", "path": "Inputs/EStop_OK", "data_type": "BOOL", "initial_value": true, "access": "ReadWrite", "retentive": false, "description": "E-stop", "engineering_units": "", "io_type": "SimulatedInput" },
                    { "name": "Overload_OK", "path": "Inputs/Overload_OK", "data_type": "BOOL", "initial_value": true, "access": "ReadWrite", "retentive": false, "description": "Overload", "engineering_units": "", "io_type": "SimulatedInput" },
                    { "name": "Motor_Latch", "path": "Internal/Motor_Latch", "data_type": "BOOL", "initial_value": false, "access": "ReadWrite", "retentive": false, "description": "Latch", "engineering_units": "", "io_type": "Internal" },
                    { "name": "Motor_Run", "path": "Outputs/Motor_Run", "data_type": "BOOL", "initial_value": false, "access": "ReadWrite", "retentive": false, "description": "Motor", "engineering_units": "", "io_type": "SimulatedOutput" }
                ],
                "programs": [
                    {
                        "name": "MotorControl",
                        "language": "LadderLogic",
                        "description": "Motor control",
                        "rungs": [
                            {
                                "comment": "Motor latch with seal-in and permissives",
                                "instructions": [
                                    { "type": "BranchStart" },
                                    { "type": "ExamineOpen", "tag": "Start_PB" },
                                    { "type": "BranchNext" },
                                    { "type": "ExamineOpen", "tag": "Motor_Latch" },
                                    { "type": "BranchEnd" },
                                    { "type": "ExamineClosed", "tag": "Stop_PB" },
                                    { "type": "ExamineOpen", "tag": "EStop_OK" },
                                    { "type": "ExamineOpen", "tag": "Overload_OK" },
                                    { "type": "OutputCoil", "tag": "Motor_Latch" }
                                ]
                            },
                            {
                                "comment": "Motor run output",
                                "instructions": [
                                    { "type": "ExamineOpen", "tag": "Motor_Latch" },
                                    { "type": "OutputCoil", "tag": "Motor_Run" }
                                ]
                            }
                        ]
                    }
                ],
                "tasks": [
                    { "name": "MainTask", "type": "Continuous", "period_ms": 100, "programs": ["MotorControl"] }
                ]
            }
        }"#;

        let project = Project::from_json(json).expect("Failed to parse project");
        let mut runtime = Runtime::new(100);
        runtime.load_project(&project);
        runtime
    }

    #[test]
    fn test_runtime_lifecycle() {
        let mut runtime = Runtime::new(100);
        assert_eq!(runtime.state, RuntimeState::Stopped);
        assert!(!runtime.is_running());

        runtime.start();
        assert_eq!(runtime.state, RuntimeState::Running);
        assert!(runtime.is_running());

        runtime.stop();
        assert_eq!(runtime.state, RuntimeState::Stopped);
        assert!(!runtime.is_running());
    }

    #[test]
    fn test_runtime_scan_when_stopped() {
        let mut runtime = Runtime::new(100);
        assert!(!runtime.execute_scan());
    }

    #[test]
    fn test_motor_full_sequence() {
        let mut rt = create_motor_runtime();
        rt.start();

        // Initial: motor off
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(false));

        // Press start: motor on
        rt.write_bool("Start_PB", true);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(true));

        // Release start: motor stays on (seal-in)
        rt.write_bool("Start_PB", false);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(true));

        // Press stop: motor off
        rt.write_bool("Stop_PB", true);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(false));

        // Release stop
        rt.write_bool("Stop_PB", false);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(false));
    }

    #[test]
    fn test_motor_estop_drops_output() {
        let mut rt = create_motor_runtime();
        rt.start();

        // Start motor
        rt.write_bool("Start_PB", true);
        rt.execute_scan();
        rt.write_bool("Start_PB", false);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(true));

        // E-stop
        rt.write_bool("EStop_OK", false);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(false), "E-stop must drop motor");
    }

    #[test]
    fn test_motor_overload_drops_output() {
        let mut rt = create_motor_runtime();
        rt.start();

        // Start motor
        rt.write_bool("Start_PB", true);
        rt.execute_scan();
        rt.write_bool("Start_PB", false);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(true));

        // Overload trip
        rt.write_bool("Overload_OK", false);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(false), "Overload must drop motor");
    }

    #[test]
    fn test_runtime_diagnostics() {
        let mut rt = create_motor_runtime();
        rt.start();
        rt.execute_scan();
        rt.execute_scan();
        assert_eq!(rt.diagnostics().scan_count, 2);
    }

    #[test]
    fn test_runtime_force() {
        let mut rt = create_motor_runtime();
        rt.start();

        // Force Motor_Run on even though logic says off
        rt.force_bool("Motor_Run", true);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(true));

        // Unforce
        rt.unforce("Motor_Run");
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(false));
    }

    #[test]
    fn test_st_program_execution() {
        let json = r#"{
            "project": {
                "name": "ST Motor Test",
                "version": "1.0.0",
                "description": "Structured Text motor control",
                "controller": { "name": "PLC_02", "scan_period_ms": 100 },
                "tags": [
                    { "name": "Start_PB", "path": "Inputs/Start_PB", "data_type": "BOOL", "initial_value": false, "access": "ReadWrite", "retentive": false, "description": "Start", "engineering_units": "", "io_type": "SimulatedInput" },
                    { "name": "Stop_PB", "path": "Inputs/Stop_PB", "data_type": "BOOL", "initial_value": false, "access": "ReadWrite", "retentive": false, "description": "Stop", "engineering_units": "", "io_type": "SimulatedInput" },
                    { "name": "EStop_OK", "path": "Inputs/EStop_OK", "data_type": "BOOL", "initial_value": true, "access": "ReadWrite", "retentive": false, "description": "E-stop", "engineering_units": "", "io_type": "SimulatedInput" },
                    { "name": "Motor_Run", "path": "Outputs/Motor_Run", "data_type": "BOOL", "initial_value": false, "access": "ReadWrite", "retentive": false, "description": "Motor", "engineering_units": "", "io_type": "SimulatedOutput" }
                ],
                "programs": [
                    {
                        "name": "StMotorControl",
                        "language": "StructuredText",
                        "description": "ST Motor logic",
                        "st_source": "IF (Start_PB OR Motor_Run) AND NOT Stop_PB AND EStop_OK THEN Motor_Run := TRUE; ELSE Motor_Run := FALSE; END_IF;"
                    }
                ],
                "tasks": [
                    { "name": "MainTask", "type": "Continuous", "period_ms": 100, "programs": ["StMotorControl"] }
                ]
            }
        }"#;

        let project = Project::from_json(json).expect("Failed to parse ST project JSON");
        let mut rt = Runtime::new(100);
        rt.load_project(&project);
        rt.start();

        // Initial: Motor off
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(false));

        // Start pressed
        rt.write_bool("Start_PB", true);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(true));

        // Start released -> seal-in active
        rt.write_bool("Start_PB", false);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(true));

        // Stop pressed -> motor turns off
        rt.write_bool("Stop_PB", true);
        rt.execute_scan();
        assert_eq!(rt.read_bool("Motor_Run"), Some(false));
    }
}
