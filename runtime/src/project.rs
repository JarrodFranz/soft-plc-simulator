// Project
//
// PLC project file loading and management.
// A project defines the controller, tags, programs, tasks,
// and protocol mappings.

use serde::{Deserialize, Serialize};
use crate::tag::{Tag, TagValue, TagQuality, DataType, AccessMode, IoType, TagDatabase};
use crate::program::{Program, ProgramLanguage, Task, TaskType};
use crate::instructions::{Instruction, Rung};

/// A PLC project definition, loadable from JSON.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub name: String,
    pub version: String,
    pub description: String,
    pub controller: ControllerConfig,
    pub tags: Vec<TagDefinition>,
    pub programs: Vec<ProgramDefinition>,
    pub tasks: Vec<TaskDefinition>,
}

/// Controller configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ControllerConfig {
    pub name: String,
    pub scan_period_ms: u64,
}

/// Tag definition in a project file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TagDefinition {
    pub name: String,
    pub path: String,
    pub data_type: String,
    pub initial_value: Option<serde_json::Value>,
    pub access: String,
    pub retentive: bool,
    pub description: String,
    pub engineering_units: String,
    pub io_type: String,
}

/// Program definition in a project file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProgramDefinition {
    pub name: String,
    pub language: String,
    pub description: String,
    pub rungs: Option<Vec<RungDefinition>>,
    pub st_source: Option<String>,
}

/// Rung definition in a project file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RungDefinition {
    pub comment: String,
    pub instructions: Vec<InstructionDefinition>,
}

/// Instruction definition in a project file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstructionDefinition {
    #[serde(rename = "type")]
    pub instruction_type: String,
    pub tag: Option<String>,
    pub timer_name: Option<String>,
    pub enable_tag: Option<String>,
    pub done_tag: Option<String>,
    pub preset_ms: Option<u64>,
}

/// Task definition in a project file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskDefinition {
    pub name: String,
    #[serde(rename = "type")]
    pub task_type: String,
    pub period_ms: u64,
    pub programs: Vec<String>,
}

impl Project {
    /// Load a project from a JSON string.
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        // The JSON wraps the project in a "project" key
        let wrapper: serde_json::Value = serde_json::from_str(json)?;
        if let Some(project_value) = wrapper.get("project") {
            serde_json::from_value(project_value.clone())
        } else {
            serde_json::from_str(json)
        }
    }

    /// Build a tag database from the project definition.
    pub fn build_tag_database(&self) -> TagDatabase {
        let mut db = TagDatabase::new();

        for tag_def in &self.tags {
            let data_type = match tag_def.data_type.as_str() {
                "BOOL" => DataType::Bool,
                "INT16" | "INT" => DataType::Int16,
                "INT32" | "DINT" => DataType::Int32,
                "INT64" | "LINT" => DataType::Int64,
                "UINT16" | "UINT" => DataType::UInt16,
                "UINT32" | "UDINT" => DataType::UInt32,
                "UINT64" | "ULINT" => DataType::UInt64,
                "FLOAT32" | "REAL" => DataType::Float32,
                "FLOAT64" | "LREAL" => DataType::Float64,
                "STRING" => DataType::String,
                _ => DataType::Bool,
            };

            let io_type = match tag_def.io_type.as_str() {
                "SimulatedInput" => IoType::SimulatedInput,
                "SimulatedOutput" => IoType::SimulatedOutput,
                "Internal" => IoType::Internal,
                _ => IoType::Internal,
            };

            let access = match tag_def.access.as_str() {
                "ReadOnly" => AccessMode::ReadOnly,
                "ReadWrite" => AccessMode::ReadWrite,
                "WriteOnly" => AccessMode::WriteOnly,
                _ => AccessMode::ReadWrite,
            };

            let initial_value = tag_def.initial_value.as_ref().map(|v| {
                match &data_type {
                    DataType::Bool => TagValue::Bool(v.as_bool().unwrap_or(false)),
                    DataType::Float64 => TagValue::Float64(v.as_f64().unwrap_or(0.0)),
                    DataType::Float32 => TagValue::Float32(v.as_f64().unwrap_or(0.0) as f32),
                    DataType::Int32 => TagValue::Int32(v.as_i64().unwrap_or(0) as i32),
                    _ => TagValue::default_for(&data_type),
                }
            }).unwrap_or_else(|| TagValue::default_for(&data_type));

            let mut tag = Tag::new_bool(&tag_def.name, &tag_def.path, io_type, &tag_def.description);
            tag.data_type = data_type;
            tag.value = initial_value;
            tag.access = access;
            tag.retentive = tag_def.retentive;
            tag.engineering_units = tag_def.engineering_units.clone();

            db.add_tag(tag);
        }

        db
    }

    /// Build programs from the project definition.
    pub fn build_programs(&self) -> Vec<Program> {
        self.programs.iter().map(|prog_def| {
            let language = match prog_def.language.as_str() {
                "LadderLogic" => ProgramLanguage::LadderLogic,
                "StructuredText" => ProgramLanguage::StructuredText,
                "FunctionBlockDiagram" => ProgramLanguage::FunctionBlockDiagram,
                "SequentialFunctionChart" => ProgramLanguage::SequentialFunctionChart,
                _ => ProgramLanguage::InternalInstructions,
            };

            let mut program = Program::new(&prog_def.name, language, &prog_def.description);

            if let Some(source) = &prog_def.st_source {
                if let Err(e) = program.set_st_source(source) {
                    log::error!("Failed to parse ST source for program '{}': {}", prog_def.name, e);
                }
            }

            if let Some(rungs) = &prog_def.rungs {
                for rung_def in rungs {
                    let instructions: Vec<Instruction> = rung_def.instructions.iter().map(|inst_def| {
                        match inst_def.instruction_type.as_str() {
                            "ExamineOpen" | "XIC" => Instruction::ExamineOpen {
                                tag: inst_def.tag.clone().unwrap_or_default(),
                            },
                            "ExamineClosed" | "XIO" => Instruction::ExamineClosed {
                                tag: inst_def.tag.clone().unwrap_or_default(),
                            },
                            "OutputCoil" | "OTE" => Instruction::OutputCoil {
                                tag: inst_def.tag.clone().unwrap_or_default(),
                            },
                            "SetCoil" | "OTL" => Instruction::SetCoil {
                                tag: inst_def.tag.clone().unwrap_or_default(),
                            },
                            "ResetCoil" | "OTU" => Instruction::ResetCoil {
                                tag: inst_def.tag.clone().unwrap_or_default(),
                            },
                            "BranchStart" => Instruction::BranchStart,
                            "BranchNext" => Instruction::BranchNext,
                            "BranchEnd" => Instruction::BranchEnd,
                            "TimerOnDelay" | "TON" => Instruction::TimerOnDelay {
                                timer_name: inst_def.timer_name.clone().unwrap_or_default(),
                                enable_tag: inst_def.enable_tag.clone().unwrap_or_default(),
                                done_tag: inst_def.done_tag.clone().unwrap_or_default(),
                                preset_ms: inst_def.preset_ms.unwrap_or(1000),
                            },
                            _ => Instruction::ExamineOpen {
                                tag: "UNKNOWN".to_string(),
                            },
                        }
                    }).collect();

                    program.add_rung(Rung {
                        comment: rung_def.comment.clone(),
                        instructions,
                    });
                }
            }

            program
        }).collect()
    }

    /// Build tasks from the project definition.
    pub fn build_tasks(&self) -> Vec<Task> {
        self.tasks.iter().map(|task_def| {
            let task_type = match task_def.task_type.as_str() {
                "Continuous" => TaskType::Continuous,
                "Periodic" => TaskType::Periodic,
                "Event" => TaskType::Event,
                _ => TaskType::Continuous,
            };

            Task {
                name: task_def.name.clone(),
                task_type,
                period_ms: task_def.period_ms,
                programs: task_def.programs.clone(),
                enabled: true,
            }
        }).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_project_from_json() {
        let json = r#"{
            "project": {
                "name": "Test Project",
                "version": "1.0.0",
                "description": "Unit test project",
                "controller": {
                    "name": "PLC_01",
                    "scan_period_ms": 100
                },
                "tags": [
                    {
                        "name": "Start_PB",
                        "path": "Inputs/Start_PB",
                        "data_type": "BOOL",
                        "initial_value": false,
                        "access": "ReadWrite",
                        "retentive": false,
                        "description": "Start pushbutton",
                        "engineering_units": "",
                        "io_type": "SimulatedInput"
                    }
                ],
                "programs": [],
                "tasks": []
            }
        }"#;

        let project = Project::from_json(json).expect("Failed to parse project JSON");
        assert_eq!(project.name, "Test Project");
        assert_eq!(project.controller.scan_period_ms, 100);
        assert_eq!(project.tags.len(), 1);
        assert_eq!(project.tags[0].name, "Start_PB");
    }

    #[test]
    fn test_build_tag_database() {
        let json = r#"{
            "project": {
                "name": "Test",
                "version": "1.0.0",
                "description": "Test",
                "controller": { "name": "PLC", "scan_period_ms": 100 },
                "tags": [
                    {
                        "name": "Bool_Tag",
                        "path": "Test/Bool",
                        "data_type": "BOOL",
                        "initial_value": true,
                        "access": "ReadWrite",
                        "retentive": false,
                        "description": "Boolean tag",
                        "engineering_units": "",
                        "io_type": "Internal"
                    },
                    {
                        "name": "Float_Tag",
                        "path": "Test/Float",
                        "data_type": "LREAL",
                        "initial_value": 42.5,
                        "access": "ReadOnly",
                        "retentive": false,
                        "description": "Float tag",
                        "engineering_units": "degC",
                        "io_type": "SimulatedInput"
                    }
                ],
                "programs": [],
                "tasks": []
            }
        }"#;

        let project = Project::from_json(json).unwrap();
        let db = project.build_tag_database();

        assert_eq!(db.len(), 2);
        assert_eq!(db.read_bool("Bool_Tag"), true);
        assert!((db.read_f64("Float_Tag") - 42.5).abs() < f64::EPSILON);
    }
}
