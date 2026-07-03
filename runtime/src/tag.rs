// Tag Database
//
// The tag database is the central data store for the soft PLC.
// All tags (inputs, outputs, internals) live here.
// Protocol adapters and UI access tags through this module.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Data types supported by the tag database, following IEC 61131-3.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum DataType {
    Bool,
    Int16,
    Int32,
    Int64,
    UInt16,
    UInt32,
    UInt64,
    Float32,
    Float64,
    String,
}

/// Runtime value of a tag.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TagValue {
    Bool(bool),
    Int16(i16),
    Int32(i32),
    Int64(i64),
    UInt16(u16),
    UInt32(u32),
    UInt64(u64),
    Float32(f32),
    Float64(f64),
    String(String),
}

impl TagValue {
    /// Returns the boolean value if the tag is Bool, or false otherwise.
    pub fn as_bool(&self) -> bool {
        match self {
            TagValue::Bool(v) => *v,
            _ => false,
        }
    }

    /// Returns the f64 representation of numeric values.
    pub fn as_f64(&self) -> f64 {
        match self {
            TagValue::Bool(v) => if *v { 1.0 } else { 0.0 },
            TagValue::Int16(v) => *v as f64,
            TagValue::Int32(v) => *v as f64,
            TagValue::Int64(v) => *v as f64,
            TagValue::UInt16(v) => *v as f64,
            TagValue::UInt32(v) => *v as f64,
            TagValue::UInt64(v) => *v as f64,
            TagValue::Float32(v) => *v as f64,
            TagValue::Float64(v) => *v,
            TagValue::String(_) => 0.0,
        }
    }

    /// Returns the default value for a given data type.
    pub fn default_for(data_type: &DataType) -> Self {
        match data_type {
            DataType::Bool => TagValue::Bool(false),
            DataType::Int16 => TagValue::Int16(0),
            DataType::Int32 => TagValue::Int32(0),
            DataType::Int64 => TagValue::Int64(0),
            DataType::UInt16 => TagValue::UInt16(0),
            DataType::UInt32 => TagValue::UInt32(0),
            DataType::UInt64 => TagValue::UInt64(0),
            DataType::Float32 => TagValue::Float32(0.0),
            DataType::Float64 => TagValue::Float64(0.0),
            DataType::String => TagValue::String(String::new()),
        }
    }
}

/// Quality status of a tag value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TagQuality {
    Good,
    Bad,
    Uncertain,
}

/// Read/write access mode for a tag.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum AccessMode {
    ReadOnly,
    ReadWrite,
    WriteOnly,
}

/// I/O classification of a tag.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum IoType {
    SimulatedInput,
    SimulatedOutput,
    Internal,
}

/// A single tag in the tag database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tag {
    pub name: String,
    pub path: String,
    pub data_type: DataType,
    pub value: TagValue,
    pub quality: TagQuality,
    pub timestamp: DateTime<Utc>,
    pub access: AccessMode,
    pub retentive: bool,
    pub description: String,
    pub engineering_units: String,
    pub io_type: IoType,
    /// If Some, the tag value is forced to this value regardless of logic.
    pub forced_value: Option<TagValue>,
}

impl Tag {
    /// Create a new boolean tag with default values.
    pub fn new_bool(name: &str, path: &str, io_type: IoType, description: &str) -> Self {
        Self {
            name: name.to_string(),
            path: path.to_string(),
            data_type: DataType::Bool,
            value: TagValue::Bool(false),
            quality: TagQuality::Good,
            timestamp: Utc::now(),
            access: AccessMode::ReadWrite,
            retentive: false,
            description: description.to_string(),
            engineering_units: String::new(),
            io_type,
            forced_value: None,
        }
    }

    /// Create a new float tag with default values.
    pub fn new_float(name: &str, path: &str, io_type: IoType, description: &str, units: &str) -> Self {
        Self {
            name: name.to_string(),
            path: path.to_string(),
            data_type: DataType::Float64,
            value: TagValue::Float64(0.0),
            quality: TagQuality::Good,
            timestamp: Utc::now(),
            access: AccessMode::ReadWrite,
            retentive: false,
            description: description.to_string(),
            engineering_units: units.to_string(),
            io_type,
            forced_value: None,
        }
    }

    /// Get the effective value (forced value if forced, otherwise actual value).
    pub fn effective_value(&self) -> &TagValue {
        self.forced_value.as_ref().unwrap_or(&self.value)
    }

    /// Set the tag value, updating timestamp.
    pub fn set_value(&mut self, value: TagValue) {
        self.value = value;
        self.timestamp = Utc::now();
    }

    /// Force the tag to a specific value.
    pub fn force(&mut self, value: TagValue) {
        self.forced_value = Some(value);
        self.timestamp = Utc::now();
    }

    /// Remove the force from this tag.
    pub fn unforce(&mut self) {
        self.forced_value = None;
        self.timestamp = Utc::now();
    }

    /// Check if the tag is currently forced.
    pub fn is_forced(&self) -> bool {
        self.forced_value.is_some()
    }
}

/// The tag database holds all tags in the PLC.
#[derive(Debug, Clone)]
pub struct TagDatabase {
    tags: HashMap<String, Tag>,
}

impl TagDatabase {
    /// Create an empty tag database.
    pub fn new() -> Self {
        Self {
            tags: HashMap::new(),
        }
    }

    /// Add a tag to the database.
    pub fn add_tag(&mut self, tag: Tag) {
        self.tags.insert(tag.name.clone(), tag);
    }

    /// Get a reference to a tag by name.
    pub fn get_tag(&self, name: &str) -> Option<&Tag> {
        self.tags.get(name)
    }

    /// Get a mutable reference to a tag by name.
    pub fn get_tag_mut(&mut self, name: &str) -> Option<&mut Tag> {
        self.tags.get_mut(name)
    }

    /// Read the effective boolean value of a tag.
    pub fn read_bool(&self, name: &str) -> bool {
        self.tags
            .get(name)
            .map(|t| t.effective_value().as_bool())
            .unwrap_or(false)
    }

    /// Read the effective f64 value of a tag.
    pub fn read_f64(&self, name: &str) -> f64 {
        self.tags
            .get(name)
            .map(|t| t.effective_value().as_f64())
            .unwrap_or(0.0)
    }

    /// Write a boolean value to a tag.
    pub fn write_bool(&mut self, name: &str, value: bool) {
        if let Some(tag) = self.tags.get_mut(name) {
            tag.set_value(TagValue::Bool(value));
        }
    }

    /// Write an f64 value to a tag.
    pub fn write_f64(&mut self, name: &str, value: f64) {
        if let Some(tag) = self.tags.get_mut(name) {
            tag.set_value(TagValue::Float64(value));
        }
    }

    /// Force a tag to a specific boolean value.
    pub fn force_bool(&mut self, name: &str, value: bool) {
        if let Some(tag) = self.tags.get_mut(name) {
            tag.force(TagValue::Bool(value));
        }
    }

    /// Remove force from a tag.
    pub fn unforce(&mut self, name: &str) {
        if let Some(tag) = self.tags.get_mut(name) {
            tag.unforce();
        }
    }

    /// Get all tag names.
    pub fn tag_names(&self) -> Vec<&String> {
        self.tags.keys().collect()
    }

    /// Get all tags as a slice of references.
    pub fn all_tags(&self) -> Vec<&Tag> {
        self.tags.values().collect()
    }

    /// Get the number of tags.
    pub fn len(&self) -> usize {
        self.tags.len()
    }

    /// Check if the database is empty.
    pub fn is_empty(&self) -> bool {
        self.tags.is_empty()
    }
}

impl Default for TagDatabase {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tag_creation() {
        let tag = Tag::new_bool("Start_PB", "Inputs/Start_PB", IoType::SimulatedInput, "Start pushbutton");
        assert_eq!(tag.name, "Start_PB");
        assert_eq!(tag.effective_value().as_bool(), false);
        assert_eq!(tag.quality, TagQuality::Good);
    }

    #[test]
    fn test_tag_set_value() {
        let mut tag = Tag::new_bool("Motor_Run", "Outputs/Motor_Run", IoType::SimulatedOutput, "Motor running");
        tag.set_value(TagValue::Bool(true));
        assert_eq!(tag.effective_value().as_bool(), true);
    }

    #[test]
    fn test_tag_force() {
        let mut tag = Tag::new_bool("Motor_Run", "Outputs/Motor_Run", IoType::SimulatedOutput, "Motor running");
        tag.set_value(TagValue::Bool(true));
        tag.force(TagValue::Bool(false));
        assert!(tag.is_forced());
        assert_eq!(tag.effective_value().as_bool(), false);
        assert_eq!(tag.value.as_bool(), true); // Underlying value unchanged
    }

    #[test]
    fn test_tag_unforce() {
        let mut tag = Tag::new_bool("Motor_Run", "Outputs/Motor_Run", IoType::SimulatedOutput, "Motor running");
        tag.set_value(TagValue::Bool(true));
        tag.force(TagValue::Bool(false));
        tag.unforce();
        assert!(!tag.is_forced());
        assert_eq!(tag.effective_value().as_bool(), true);
    }

    #[test]
    fn test_database_operations() {
        let mut db = TagDatabase::new();
        db.add_tag(Tag::new_bool("Start_PB", "Inputs/Start_PB", IoType::SimulatedInput, "Start"));
        db.add_tag(Tag::new_bool("Motor_Run", "Outputs/Motor_Run", IoType::SimulatedOutput, "Motor"));

        assert_eq!(db.len(), 2);
        assert!(!db.is_empty());

        db.write_bool("Start_PB", true);
        assert_eq!(db.read_bool("Start_PB"), true);
        assert_eq!(db.read_bool("Motor_Run"), false);
    }

    #[test]
    fn test_database_force() {
        let mut db = TagDatabase::new();
        db.add_tag(Tag::new_bool("Motor_Run", "Outputs/Motor_Run", IoType::SimulatedOutput, "Motor"));
        db.write_bool("Motor_Run", true);
        db.force_bool("Motor_Run", false);
        assert_eq!(db.read_bool("Motor_Run"), false);
        db.unforce("Motor_Run");
        assert_eq!(db.read_bool("Motor_Run"), true);
    }

    #[test]
    fn test_float_tag() {
        let mut db = TagDatabase::new();
        db.add_tag(Tag::new_float("Level_PV", "Inputs/Level_PV", IoType::SimulatedInput, "Tank level", "%"));
        db.write_f64("Level_PV", 75.5);
        assert!((db.read_f64("Level_PV") - 75.5).abs() < f64::EPSILON);
    }

    #[test]
    fn test_tag_value_default() {
        assert_eq!(TagValue::default_for(&DataType::Bool), TagValue::Bool(false));
        assert_eq!(TagValue::default_for(&DataType::Int32), TagValue::Int32(0));
        assert_eq!(TagValue::default_for(&DataType::Float64), TagValue::Float64(0.0));
    }
}
