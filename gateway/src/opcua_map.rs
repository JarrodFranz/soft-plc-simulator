//! OPC UA node<->tag map model + address-space builder input.
//!
//! Mirrors the on-disk shape of `examples/protocol-maps/opcua_map_example.json`
//! and the Dart model `mobile/lib/models/opcua_map.dart`:
//! `{ "opcua_map": { "namespace_uri": "...", "nodes": [ { "node_id", "tag",
//! "access" }, ... ] } }`.
//!
//! This module is pure: it has no dependency on the `opcua` crate or any
//! live server. `build_variable_specs` turns a parsed map + a tag mirror
//! into the flat list of variable specs the OPC UA server layer registers;
//! that registration itself lives in `opcua_server.rs` (Phase B).

use serde::{Deserialize, Serialize};

use crate::mirror::{Access, TagMirror};

/// One OPC UA `Variable` node, bound to a project tag by name.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpcuaNode {
    pub node_id: String,
    pub tag: String,
    #[serde(default = "default_access")]
    pub access: String,
}

fn default_access() -> String {
    "ReadWrite".to_string()
}

/// The wrapper wire shape: `{ "opcua_map": { ... } }`.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct OpcuaMapWire {
    opcua_map: OpcuaMapInner,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct OpcuaMapInner {
    namespace_uri: String,
    nodes: Vec<OpcuaNode>,
}

/// The editable OPC UA address-space map: a namespace URI plus the list of
/// exposed nodes.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct OpcuaMap {
    pub namespace_uri: String,
    pub nodes: Vec<OpcuaNode>,
}

impl OpcuaMap {
    /// Parses the on-disk/wire JSON shape (`{"opcua_map": {...}}`). Returns
    /// an empty map (not an error) on malformed input, mirroring the Dart
    /// side's permissive `fromJson`.
    pub fn from_json_str(s: &str) -> Self {
        match serde_json::from_str::<OpcuaMapWire>(s) {
            Ok(wire) => OpcuaMap {
                namespace_uri: wire.opcua_map.namespace_uri,
                nodes: wire.opcua_map.nodes,
            },
            Err(_) => OpcuaMap::default(),
        }
    }

    pub fn to_json_string(&self) -> String {
        let wire = OpcuaMapWire {
            opcua_map: OpcuaMapInner {
                namespace_uri: self.namespace_uri.clone(),
                nodes: self.nodes.clone(),
            },
        };
        serde_json::to_string(&wire).expect("OpcuaMap serialization is infallible")
    }
}

/// One resolved variable to register in the OPC UA address space: the
/// node's string identifier (used as `ns=1;s=<node_id-suffix>` — the
/// `node_id` field already carries the full `ns=1;s=...` form per the map
/// format), the tag path it mirrors, and its access mode.
#[derive(Debug, Clone, PartialEq)]
pub struct VariableSpec {
    pub node_id: String,
    pub tag_path: String,
    pub access: Access,
}

/// Builds the list of [`VariableSpec`]s to register in the OPC UA address
/// space from a parsed [`OpcuaMap`] and the current [`TagMirror`].
///
/// Nodes whose `tag` isn't present in the mirror are skipped (nothing to
/// back the variable's initial value with yet — the app hasn't sent a
/// snapshot including it, or the map references a tag the project doesn't
/// have). This is a pure function: no server, no I/O.
pub fn build_variable_specs(map: &OpcuaMap, mirror: &TagMirror) -> Vec<VariableSpec> {
    map.nodes
        .iter()
        .filter(|n| mirror.contains(&n.tag))
        .map(|n| VariableSpec {
            node_id: n.node_id.clone(),
            tag_path: n.tag.clone(),
            access: Access::from_wire(&n.access),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::ExposedTag;
    use serde_json::Value;

    const EXAMPLE_MAP_JSON: &str = r#"{
      "opcua_map": {
        "namespace_uri": "urn:softplc:motor-example",
        "nodes": [
          { "node_id": "ns=1;s=Inputs.Start_PB", "tag": "Start_PB", "access": "ReadWrite" },
          { "node_id": "ns=1;s=Inputs.Stop_PB", "tag": "Stop_PB", "access": "ReadWrite" },
          { "node_id": "ns=1;s=Outputs.Motor_Run", "tag": "Motor_Run", "access": "ReadOnly" }
        ]
      }
    }"#;

    #[test]
    fn parses_the_example_map_file_shape() {
        let map = OpcuaMap::from_json_str(EXAMPLE_MAP_JSON);
        assert_eq!(map.namespace_uri, "urn:softplc:motor-example");
        assert_eq!(map.nodes.len(), 3);
        assert_eq!(map.nodes[0].node_id, "ns=1;s=Inputs.Start_PB");
        assert_eq!(map.nodes[0].tag, "Start_PB");
        assert_eq!(map.nodes[0].access, "ReadWrite");
        assert_eq!(map.nodes[2].access, "ReadOnly");
    }

    #[test]
    fn round_trips_to_json_and_back() {
        let map = OpcuaMap::from_json_str(EXAMPLE_MAP_JSON);
        let encoded = map.to_json_string();
        let decoded = OpcuaMap::from_json_str(&encoded);
        assert_eq!(decoded, map);
    }

    #[test]
    fn malformed_json_yields_empty_map() {
        let map = OpcuaMap::from_json_str("{not json");
        assert_eq!(map, OpcuaMap::default());
    }

    #[test]
    fn builder_produces_one_spec_per_mapped_node_present_in_mirror() {
        let map = OpcuaMap::from_json_str(EXAMPLE_MAP_JSON);
        let mut mirror = TagMirror::new();
        mirror.apply_snapshot(&[
            ExposedTag {
                path: "Start_PB".to_string(),
                data_type: "BOOL".to_string(),
                value: Value::Bool(false),
                access: "ReadWrite".to_string(),
            },
            ExposedTag {
                path: "Motor_Run".to_string(),
                data_type: "BOOL".to_string(),
                value: Value::Bool(true),
                access: "ReadOnly".to_string(),
            },
            // Stop_PB intentionally NOT in the mirror to exercise skip-on-missing.
        ]);

        let specs = build_variable_specs(&map, &mirror);
        assert_eq!(specs.len(), 2);
        assert_eq!(specs[0].node_id, "ns=1;s=Inputs.Start_PB");
        assert_eq!(specs[0].tag_path, "Start_PB");
        assert_eq!(specs[0].access, Access::ReadWrite);
        assert_eq!(specs[1].node_id, "ns=1;s=Outputs.Motor_Run");
        assert_eq!(specs[1].access, Access::ReadOnly);
    }

    #[test]
    fn builder_is_empty_when_mirror_is_empty() {
        let map = OpcuaMap::from_json_str(EXAMPLE_MAP_JSON);
        let mirror = TagMirror::new();
        let specs = build_variable_specs(&map, &mirror);
        assert!(specs.is_empty());
    }
}
