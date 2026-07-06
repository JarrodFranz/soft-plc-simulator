//! The OPC UA server: builds an address space from an [`OpcuaMap`] mirroring
//! the tag [`TagMirror`], serves it over `opc.tcp://`, and forwards writes
//! to `ReadWrite` nodes onto an outbound channel toward the app.
//!
//! Anonymous/None security only (v1 — see the design doc's "out of scope").
//! The gateway executes no logic here either: reads return whatever is in
//! the mirror: writes are pushed out, never applied locally as truth.

use std::str::FromStr;
use std::sync::{Arc, Mutex};

use opcua::server::address_space::{AttrFnGetter, AttrFnSetter};
use opcua::server::prelude::*;
use tokio::sync::mpsc::UnboundedSender;

use crate::mirror::{Access, TagMirror};
use crate::opcua_map::{build_variable_specs, OpcuaMap};

/// An outbound write, produced when an OPC UA client writes a `ReadWrite`
/// node. Forwarded to the app as a `write` sync message by the caller.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingWrite {
    pub path: String,
    pub value: serde_json::Value,
}

/// Builds a [`Server`] whose address space is populated from `map` +
/// `mirror`: one `Variable` node per mapped tag present in the mirror,
/// under the Objects folder, namespace `1`. Read callbacks return the
/// mirror's current value; writes on `ReadWrite` nodes push a
/// [`PendingWrite`] onto `write_tx` (and optimistically reflect into the
/// mirror so a fast subsequent read isn't stale) instead of ever being
/// treated as authoritative here.
///
/// Returns the constructed `Server` (not yet run — call `.run()` on its own
/// thread) plus the namespace index actually registered.
pub fn build_server(
    map: &OpcuaMap,
    mirror: Arc<Mutex<TagMirror>>,
    write_tx: UnboundedSender<PendingWrite>,
    host: &str,
    port: u16,
) -> Server {
    let application_name = "Mobile Soft PLC Companion Gateway";
    let config = ServerBuilder::new_anonymous(application_name)
        .application_uri(if map.namespace_uri.is_empty() {
            "urn:softplc:gateway".to_string()
        } else {
            map.namespace_uri.clone()
        })
        .host_and_port(host, port)
        .discovery_urls(vec!["/".into()])
        .config();

    let server = Server::new(config);

    {
        let address_space = server.address_space();
        let mut address_space = address_space.write();
        let ns = address_space
            .register_namespace(&map.namespace_uri)
            .unwrap_or(1u16);

        let specs = build_variable_specs(map, &mirror.lock().expect("mirror mutex poisoned"));
        for spec in specs {
            let Ok(node_id) = NodeId::from_str(&spec.node_id) else {
                log::warn!("skipping OPC UA node with unparseable node_id: {}", spec.node_id);
                continue;
            };
            let tag_path = spec.tag_path.clone();
            let mirror_for_get = mirror.clone();
            let getter = AttrFnGetter::new_boxed(move |_, _, _, _, _, _| {
                let variant = {
                    let mirror = mirror_for_get.lock().expect("mirror mutex poisoned");
                    mirror
                        .get(&tag_path)
                        .map(|t| tag_value_to_variant(&t.value))
                        .unwrap_or(Variant::Empty)
                };
                Ok(Some(DataValue::new_now(variant)))
            });

            let mut builder = VariableBuilder::new(&node_id, spec.tag_path.as_str(), spec.tag_path.as_str())
                .organized_by(ObjectId::ObjectsFolder)
                .data_type(DataTypeId::BaseDataType)
                .value_getter(getter);

            builder = if spec.access == Access::ReadWrite {
                let tag_path_for_set = spec.tag_path.clone();
                let write_tx = write_tx.clone();
                let mirror_for_set = mirror.clone();
                let setter = AttrFnSetter::new_boxed(move |_, _, _, data_value: DataValue| {
                    if let Some(variant) = data_value.value {
                        let json = variant_to_json(&variant);
                        {
                            let mut mirror = mirror_for_set.lock().expect("mirror mutex poisoned");
                            if let Some(existing) = mirror.get(&tag_path_for_set) {
                                let coerced = crate::sync::json_to_tag_value(
                                    &json,
                                    wire_type_of(&existing.data_type),
                                );
                                mirror.set_local(&tag_path_for_set, coerced);
                            }
                        }
                        let _ = write_tx.send(PendingWrite {
                            path: tag_path_for_set.clone(),
                            value: json,
                        });
                    }
                    Ok(())
                });
                builder
                    .writable()
                    .value_setter(setter)
            } else {
                builder
            };

            builder.insert(&mut address_space);
        }
        let _ = ns; // namespace index recorded via register_namespace; reserved for future multi-namespace support.
    }

    server
}

fn wire_type_of(dt: &soft_plc_runtime::tag::DataType) -> &'static str {
    use soft_plc_runtime::tag::DataType;
    match dt {
        DataType::Bool => "BOOL",
        DataType::Int16 | DataType::UInt16 => "INT16",
        DataType::Int32 | DataType::UInt32 => "INT32",
        DataType::Int64 | DataType::UInt64 => "INT64",
        DataType::Float32 => "FLOAT32",
        DataType::Float64 => "FLOAT64",
        DataType::String => "STRING",
    }
}

/// Converts a mirrored [`soft_plc_runtime::tag::TagValue`] directly to an OPC
/// UA [`Variant`], keyed on the tag's own declared type rather than
/// `serde_json`'s (lossy) shape-guessing.
///
/// This is the fix for a whole-number-Float misclassification: a `FLOAT64`
/// tag holding e.g. `10.0` serializes to a `serde_json::Number` for which
/// `is_i64()` returns `true` (the JSON number has no fractional part), so a
/// JSON-shape-based inference would wrongly produce `Variant::Int64(10)`
/// instead of `Variant::Double(10.0)` — a silent type flip visible to any
/// OPC UA client. Converting straight from the tag's own `TagValue` variant
/// (which already carries its true type) avoids the lossy JSON round-trip
/// entirely and keeps the Variant type in lockstep with the tag's declared
/// `DataType`.
fn tag_value_to_variant(value: &soft_plc_runtime::tag::TagValue) -> Variant {
    use soft_plc_runtime::tag::TagValue;
    match value {
        TagValue::Bool(b) => Variant::Boolean(*b),
        TagValue::Int16(v) => Variant::Int16(*v),
        TagValue::UInt16(v) => Variant::UInt16(*v),
        TagValue::Int32(v) => Variant::Int32(*v),
        TagValue::UInt32(v) => Variant::UInt32(*v),
        TagValue::Int64(v) => Variant::Int64(*v),
        TagValue::UInt64(v) => Variant::UInt64(*v),
        TagValue::Float32(v) => Variant::Float(*v),
        TagValue::Float64(v) => Variant::Double(*v),
        TagValue::String(s) => Variant::from(s.clone()),
    }
}

fn variant_to_json(variant: &Variant) -> serde_json::Value {
    match variant {
        Variant::Boolean(b) => serde_json::Value::Bool(*b),
        Variant::SByte(v) => serde_json::Value::from(*v),
        Variant::Byte(v) => serde_json::Value::from(*v),
        Variant::Int16(v) => serde_json::Value::from(*v),
        Variant::UInt16(v) => serde_json::Value::from(*v),
        Variant::Int32(v) => serde_json::Value::from(*v),
        Variant::UInt32(v) => serde_json::Value::from(*v),
        Variant::Int64(v) => serde_json::Value::from(*v),
        Variant::UInt64(v) => serde_json::Value::from(*v),
        Variant::Float(v) => serde_json::Number::from_f64(*v as f64)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::from(0.0)),
        Variant::Double(v) => serde_json::Number::from_f64(*v)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::from(0.0)),
        Variant::String(s) => serde_json::Value::String(s.to_string()),
        _ => serde_json::Value::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::ExposedTag;
    use serde_json::Value;
    use tokio::sync::mpsc;

    fn map_with_two_nodes() -> OpcuaMap {
        OpcuaMap::from_json_str(
            r#"{
              "opcua_map": {
                "namespace_uri": "urn:softplc:test",
                "nodes": [
                  { "node_id": "ns=1;s=Start_PB", "tag": "Start_PB", "access": "ReadWrite" },
                  { "node_id": "ns=1;s=Motor_Run", "tag": "Motor_Run", "access": "ReadOnly" }
                ]
              }
            }"#,
        )
    }

    fn mirror_with_two_tags() -> Arc<Mutex<TagMirror>> {
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
        ]);
        Arc::new(Mutex::new(mirror))
    }

    #[test]
    fn build_server_registers_one_variable_per_mapped_node() {
        let map = map_with_two_nodes();
        let mirror = mirror_with_two_tags();
        let (tx, _rx) = mpsc::unbounded_channel();
        let server = build_server(&map, mirror, tx, "127.0.0.1", 0);

        let address_space = server.address_space();
        let address_space = address_space.read();
        let start_pb_id = NodeId::from_str("ns=1;s=Start_PB").unwrap();
        let motor_run_id = NodeId::from_str("ns=1;s=Motor_Run").unwrap();
        assert!(address_space.find_node(&start_pb_id).is_some());
        assert!(address_space.find_node(&motor_run_id).is_some());
    }

    #[test]
    fn read_callback_returns_current_mirror_value() {
        let map = map_with_two_nodes();
        let mirror = mirror_with_two_tags();
        let (tx, _rx) = mpsc::unbounded_channel();
        let server = build_server(&map, mirror, tx, "127.0.0.1", 0);

        let address_space = server.address_space();
        let mut address_space = address_space.write();
        let motor_run_id = NodeId::from_str("ns=1;s=Motor_Run").unwrap();
        let node = address_space.find_node_mut(&motor_run_id).unwrap();
        let NodeType::Variable(variable) = node else {
            panic!("expected a Variable node");
        };
        let data_value = variable.value(
            TimestampsToReturn::Neither,
            NumericRange::None,
            &QualifiedName::null(),
            0.0,
        );
        assert_eq!(data_value.value, Some(Variant::Boolean(true)));
    }

    #[test]
    fn write_on_read_write_node_forwards_a_pending_write() {
        let map = map_with_two_nodes();
        let mirror = mirror_with_two_tags();
        let (tx, mut rx) = mpsc::unbounded_channel();
        let server = build_server(&map, mirror.clone(), tx, "127.0.0.1", 0);

        // Drive the write through `Variable::set_value`, which is exactly
        // what the OPC UA Write service calls internally on an incoming
        // client WriteValue — so this exercises the same value_setter path
        // a real OPC client write would, without needing a live TCP client
        // (documented as the integration-level remainder in the task
        // report).
        let address_space = server.address_space();
        let mut address_space = address_space.write();
        let start_pb_id = NodeId::from_str("ns=1;s=Start_PB").unwrap();
        let node = address_space.find_node_mut(&start_pb_id).unwrap();
        let NodeType::Variable(variable) = node else {
            panic!("expected a Variable node");
        };
        variable
            .set_value(NumericRange::None, Variant::Boolean(true))
            .expect("set_value through the configured setter should succeed");
        drop(address_space);

        let forwarded = rx.try_recv().expect("expected a forwarded PendingWrite");
        assert_eq!(forwarded.path, "Start_PB");
        assert_eq!(forwarded.value, Value::Bool(true));

        // The mirror was optimistically updated too.
        let mirror = mirror.lock().unwrap();
        assert_eq!(
            mirror.get("Start_PB").unwrap().value,
            soft_plc_runtime::tag::TagValue::Bool(true)
        );
    }

    /// Regression test for the whole-number-Float misclassification: a
    /// `FLOAT64` tag whose mirrored value is a WHOLE number (e.g. `10.0`)
    /// must read back through the OPC UA getter as `Variant::Double(10.0)`,
    /// never an integer Variant. Under the old JSON-shape inference
    /// (`json_to_variant`, now removed), `serde_json`'s `Number::is_i64()`
    /// returns `true` for a whole-number float, so this case would have
    /// wrongly produced `Variant::Int64(10)` — a silent type flip visible to
    /// any OPC UA client. The fix (`tag_value_to_variant`) keys off the
    /// tag's own `TagValue::Float64` variant directly, so it cannot be
    /// fooled by the JSON number's shape.
    #[test]
    fn float64_whole_number_reads_back_as_double_not_int() {
        let map = OpcuaMap::from_json_str(
            r#"{
              "opcua_map": {
                "namespace_uri": "urn:softplc:test",
                "nodes": [
                  { "node_id": "ns=1;s=Level_SP", "tag": "Level_SP", "access": "ReadOnly" }
                ]
              }
            }"#,
        );
        let mut mirror = TagMirror::new();
        mirror.apply_snapshot(&[ExposedTag {
            path: "Level_SP".to_string(),
            data_type: "FLOAT64".to_string(),
            value: serde_json::json!(10.0),
            access: "ReadOnly".to_string(),
        }]);
        let mirror = Arc::new(Mutex::new(mirror));
        let (tx, _rx) = mpsc::unbounded_channel();
        let server = build_server(&map, mirror, tx, "127.0.0.1", 0);

        let address_space = server.address_space();
        let mut address_space = address_space.write();
        let node_id = NodeId::from_str("ns=1;s=Level_SP").unwrap();
        let node = address_space.find_node_mut(&node_id).unwrap();
        let NodeType::Variable(variable) = node else {
            panic!("expected a Variable node");
        };
        let data_value = variable.value(
            TimestampsToReturn::Neither,
            NumericRange::None,
            &QualifiedName::null(),
            0.0,
        );
        assert_eq!(data_value.value, Some(Variant::Double(10.0)));
    }

    /// Companion case: a normal (non-whole-number) Float64 value must also
    /// read back as `Variant::Double`, unaffected by the fix.
    #[test]
    fn float64_fractional_value_reads_back_as_double() {
        let map = OpcuaMap::from_json_str(
            r#"{
              "opcua_map": {
                "namespace_uri": "urn:softplc:test",
                "nodes": [
                  { "node_id": "ns=1;s=Level_SP", "tag": "Level_SP", "access": "ReadOnly" }
                ]
              }
            }"#,
        );
        let mut mirror = TagMirror::new();
        mirror.apply_snapshot(&[ExposedTag {
            path: "Level_SP".to_string(),
            data_type: "FLOAT64".to_string(),
            value: serde_json::json!(12.5),
            access: "ReadOnly".to_string(),
        }]);
        let mirror = Arc::new(Mutex::new(mirror));
        let (tx, _rx) = mpsc::unbounded_channel();
        let server = build_server(&map, mirror, tx, "127.0.0.1", 0);

        let address_space = server.address_space();
        let mut address_space = address_space.write();
        let node_id = NodeId::from_str("ns=1;s=Level_SP").unwrap();
        let node = address_space.find_node_mut(&node_id).unwrap();
        let NodeType::Variable(variable) = node else {
            panic!("expected a Variable node");
        };
        let data_value = variable.value(
            TimestampsToReturn::Neither,
            NumericRange::None,
            &QualifiedName::null(),
            0.0,
        );
        assert_eq!(data_value.value, Some(Variant::Double(12.5)));
    }

    #[test]
    fn write_on_read_only_node_has_no_setter_wired() {
        let map = map_with_two_nodes();
        let mirror = mirror_with_two_tags();
        let (tx, _rx) = mpsc::unbounded_channel();
        let server = build_server(&map, mirror, tx, "127.0.0.1", 0);

        let address_space = server.address_space();
        let address_space = address_space.read();
        let motor_run_id = NodeId::from_str("ns=1;s=Motor_Run").unwrap();
        let node = address_space.find_node(&motor_run_id).unwrap();
        let NodeType::Variable(variable) = node else {
            panic!("expected a Variable node");
        };
        assert!(!variable
            .user_access_level()
            .contains(UserAccessLevel::CURRENT_WRITE));
    }
}
