// Program
//
// A program is a named collection of rungs that implements control logic.
// Programs are assigned to tasks and executed during the scan cycle.

use serde::{Deserialize, Serialize};
use crate::instructions::Rung;

/// The language used to define a program.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ProgramLanguage {
    LadderLogic,
    StructuredText,
    FunctionBlockDiagram,
    SequentialFunctionChart,
    InternalInstructions,
}

/// A PLC program containing logic to execute.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Program {
    pub name: String,
    pub language: ProgramLanguage,
    pub description: String,
    pub rungs: Vec<Rung>,
    pub enabled: bool,
}

impl Program {
    /// Create a new program with the given name and language.
    pub fn new(name: &str, language: ProgramLanguage, description: &str) -> Self {
        Self {
            name: name.to_string(),
            language,
            description: description.to_string(),
            rungs: Vec::new(),
            enabled: true,
        }
    }

    /// Add a rung to the program.
    pub fn add_rung(&mut self, rung: Rung) {
        self.rungs.push(rung);
    }
}

/// A task defines the scheduling of one or more programs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub name: String,
    pub task_type: TaskType,
    pub period_ms: u64,
    pub programs: Vec<String>,
    pub enabled: bool,
}

/// Type of task scheduling.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TaskType {
    /// Runs continuously every scan.
    Continuous,
    /// Runs at a fixed period.
    Periodic,
    /// Runs on an event trigger.
    Event,
}

impl Task {
    pub fn new_continuous(name: &str, period_ms: u64) -> Self {
        Self {
            name: name.to_string(),
            task_type: TaskType::Continuous,
            period_ms,
            programs: Vec::new(),
            enabled: true,
        }
    }

    pub fn add_program(&mut self, program_name: &str) {
        self.programs.push(program_name.to_string());
    }
}
