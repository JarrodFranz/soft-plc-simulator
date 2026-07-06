//! The tag mirror: an in-memory, last-synced copy of the app's exposed tags.
//!
//! The gateway executes no PLC logic. This module only holds whatever the
//! app last told it (via `snapshot`/`delta`) and lets the OPC UA server read
//! it back. See `docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md`,
//! "The tag-sync layer".

use std::collections::HashMap;

use soft_plc_runtime::tag::{DataType, TagValue};

use crate::sync::{data_type_from_wire, json_to_tag_value, SyncMessage};

/// Read/write access of a mirrored tag, mirroring the wire `access` string
/// (`"ReadOnly"` / `"ReadWrite"`). Anything else defaults to `ReadWrite`,
/// matching the Dart side's permissive default.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    ReadOnly,
    ReadWrite,
}

impl Access {
    pub fn from_wire(s: &str) -> Self {
        match s {
            "ReadOnly" => Access::ReadOnly,
            _ => Access::ReadWrite,
        }
    }
}

/// One mirrored tag: its last-known value, IEC data type, and access mode.
#[derive(Debug, Clone, PartialEq)]
pub struct MirroredTag {
    pub value: TagValue,
    pub data_type: DataType,
    pub access: Access,
}

/// The tag mirror: `path -> MirroredTag`. Populated purely from inbound
/// `snapshot`/`delta` messages; never mutated by any local logic.
#[derive(Debug, Clone, Default)]
pub struct TagMirror {
    tags: HashMap<String, MirroredTag>,
}

impl TagMirror {
    pub fn new() -> Self {
        Self { tags: HashMap::new() }
    }

    /// Replaces the entire mirror with the tags in `tags` (a `snapshot`
    /// message's payload). Each tag's JSON value is coerced to its declared
    /// `dataType` so e.g. a FLOAT stays a float even if the JSON number
    /// looks integral.
    pub fn apply_snapshot(&mut self, tags: &[crate::sync::ExposedTag]) {
        self.tags.clear();
        for t in tags {
            let data_type = data_type_from_wire(&t.data_type);
            let value = json_to_tag_value(&t.value, &t.data_type);
            self.tags.insert(
                t.path.clone(),
                MirroredTag {
                    value,
                    data_type,
                    access: Access::from_wire(&t.access),
                },
            );
        }
    }

    /// Applies a `delta` message's changes: updates the value of each
    /// already-known path (coerced to that tag's existing data type).
    /// Paths not already present in the mirror (never seen in a snapshot)
    /// are silently ignored — the mirror only tracks tags the app has
    /// explicitly exposed.
    pub fn apply_delta(&mut self, changes: &[crate::sync::TagChange]) {
        for c in changes {
            if let Some(existing) = self.tags.get_mut(&c.path) {
                let wire_type = wire_type_name(&existing.data_type);
                existing.value = json_to_tag_value(&c.value, wire_type);
            }
            // Unknown path: ignored (matches the design's "unknown paths
            // ignored" requirement).
        }
    }

    /// Convenience: dispatches a decoded [`SyncMessage`] to the appropriate
    /// apply method. Non-tag messages (hello/write/ready/ping/pong/unknown)
    /// are no-ops here — they're handled elsewhere (connection/session
    /// layer).
    pub fn apply_message(&mut self, msg: &SyncMessage) {
        match msg {
            SyncMessage::Snapshot { tags } => self.apply_snapshot(tags),
            SyncMessage::Delta { changes } => self.apply_delta(changes),
            _ => {}
        }
    }

    pub fn get(&self, path: &str) -> Option<&MirroredTag> {
        self.tags.get(path)
    }

    pub fn contains(&self, path: &str) -> bool {
        self.tags.contains_key(path)
    }

    pub fn len(&self) -> usize {
        self.tags.len()
    }

    pub fn is_empty(&self) -> bool {
        self.tags.is_empty()
    }

    /// Sets a value directly, used by the OPC UA write path once a write
    /// has been (optimistically) forwarded to the app. The app remains
    /// authoritative; this is a local reflect-back so a fast subsequent OPC
    /// read sees the pending value rather than a stale one.
    pub fn set_local(&mut self, path: &str, value: TagValue) {
        if let Some(existing) = self.tags.get_mut(path) {
            existing.value = value;
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = (&String, &MirroredTag)> {
        self.tags.iter()
    }
}

/// Maps a runtime `DataType` back to its wire `dataType` string, so a delta
/// (which carries only a bare JSON value) can be coerced using the type the
/// tag was declared with in its snapshot.
fn wire_type_name(dt: &DataType) -> &'static str {
    match dt {
        DataType::Bool => "BOOL",
        DataType::Int16 => "INT16",
        DataType::Int32 => "INT32",
        DataType::Int64 => "INT64",
        DataType::UInt16 => "INT16",
        DataType::UInt32 => "INT32",
        DataType::UInt64 => "INT64",
        DataType::Float32 => "FLOAT32",
        DataType::Float64 => "FLOAT64",
        DataType::String => "STRING",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::{ExposedTag, TagChange};
    use serde_json::Value;

    fn tag(path: &str, data_type: &str, value: Value, access: &str) -> ExposedTag {
        ExposedTag {
            path: path.to_string(),
            data_type: data_type.to_string(),
            value,
            access: access.to_string(),
        }
    }

    #[test]
    fn snapshot_then_delta_yields_expected_values_and_types() {
        let mut mirror = TagMirror::new();
        mirror.apply_snapshot(&[
            tag("Inputs/Start_PB", "BOOL", Value::Bool(false), "ReadWrite"),
            tag("Outputs/Motor_Run", "BOOL", Value::Bool(false), "ReadOnly"),
            tag("Internal/Level_SP", "FLOAT64", serde_json::json!(10.0), "ReadWrite"),
        ]);
        assert_eq!(mirror.len(), 3);

        mirror.apply_delta(&[
            TagChange {
                path: "Inputs/Start_PB".to_string(),
                value: Value::Bool(true),
            },
            TagChange {
                path: "Internal/Level_SP".to_string(),
                value: serde_json::json!(42.5),
            },
        ]);

        assert_eq!(mirror.get("Inputs/Start_PB").unwrap().value, TagValue::Bool(true));
        assert_eq!(mirror.get("Outputs/Motor_Run").unwrap().value, TagValue::Bool(false));
        assert_eq!(mirror.get("Outputs/Motor_Run").unwrap().access, Access::ReadOnly);
        assert_eq!(
            mirror.get("Internal/Level_SP").unwrap().value,
            TagValue::Float64(42.5)
        );
    }

    #[test]
    fn delta_preserves_float_type_for_whole_number_values() {
        let mut mirror = TagMirror::new();
        mirror.apply_snapshot(&[tag("Level_SP", "FLOAT64", serde_json::json!(1.5), "ReadWrite")]);
        mirror.apply_delta(&[TagChange {
            path: "Level_SP".to_string(),
            value: serde_json::json!(5), // whole-number JSON, integer-shaped
        }]);
        assert_eq!(mirror.get("Level_SP").unwrap().value, TagValue::Float64(5.0));
    }

    #[test]
    fn delta_ignores_unknown_paths() {
        let mut mirror = TagMirror::new();
        mirror.apply_snapshot(&[tag("A", "BOOL", Value::Bool(false), "ReadWrite")]);
        mirror.apply_delta(&[TagChange {
            path: "NeverSeen".to_string(),
            value: Value::Bool(true),
        }]);
        assert_eq!(mirror.len(), 1);
        assert!(mirror.get("NeverSeen").is_none());
        assert_eq!(mirror.get("A").unwrap().value, TagValue::Bool(false));
    }

    #[test]
    fn second_snapshot_replaces_the_mirror() {
        let mut mirror = TagMirror::new();
        mirror.apply_snapshot(&[tag("A", "BOOL", Value::Bool(false), "ReadWrite")]);
        mirror.apply_snapshot(&[tag("B", "INT32", Value::from(7), "ReadOnly")]);
        assert_eq!(mirror.len(), 1);
        assert!(mirror.get("A").is_none());
        assert_eq!(mirror.get("B").unwrap().value, TagValue::Int32(7));
    }

    #[test]
    fn apply_message_dispatches_snapshot_and_delta_only() {
        let mut mirror = TagMirror::new();
        mirror.apply_message(&SyncMessage::Snapshot {
            tags: vec![tag("A", "BOOL", Value::Bool(true), "ReadWrite")],
        });
        assert_eq!(mirror.get("A").unwrap().value, TagValue::Bool(true));

        // A Hello/Write/Ready/Ping/Pong message must not alter the mirror.
        mirror.apply_message(&SyncMessage::Hello {
            project: "P".to_string(),
            controller: "C".to_string(),
            scan_ms: 100,
        });
        assert_eq!(mirror.len(), 1);
    }

    #[test]
    fn empty_snapshot_yields_empty_mirror() {
        let mut mirror = TagMirror::new();
        mirror.apply_snapshot(&[]);
        assert!(mirror.is_empty());
    }
}
