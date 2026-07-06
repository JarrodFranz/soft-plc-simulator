//! Tag-sync wire protocol: message types + JSON codec.
//!
//! This is the Rust side of the sole contract for the app <-> gateway
//! WebSocket connection (see
//! `docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md`,
//! "The tag-sync layer"). It must mirror the Dart codec in
//! `mobile/lib/models/gateway_sync.dart` field-for-field and
//! discriminator-for-discriminator.
//!
//! The codec is total on decode: malformed or unrecognized input decodes to
//! `SyncMessage::Unknown` carrying the raw string, never an `Err`/panic.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One exposed tag in a `snapshot` message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExposedTag {
    pub path: String,
    #[serde(rename = "dataType")]
    pub data_type: String,
    pub value: Value,
    pub access: String,
}

/// One changed tag in a `delta` message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TagChange {
    pub path: String,
    pub value: Value,
}

/// A tagged (discriminated) sync message. Mirrors the Dart `SyncMessage`
/// hierarchy exactly: the `"type"` field is the wire discriminator, and
/// fields beyond it are this variant's own fields, flattened.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SyncMessage {
    #[serde(rename = "hello")]
    Hello {
        project: String,
        controller: String,
        #[serde(rename = "scanMs")]
        scan_ms: i64,
    },
    #[serde(rename = "snapshot")]
    Snapshot { tags: Vec<ExposedTag> },
    #[serde(rename = "delta")]
    Delta { changes: Vec<TagChange> },
    #[serde(rename = "write")]
    Write { path: String, value: Value },
    #[serde(rename = "ready")]
    Ready {},
    #[serde(rename = "ping")]
    Ping {},
    #[serde(rename = "pong")]
    Pong {},
    /// Never produced by `serde`'s own untagged fallback (there isn't one for
    /// internally-tagged enums) — reserved for `decode_message`'s explicit
    /// fallback path. See its doc comment.
    #[serde(skip)]
    Unknown(String),
}

/// Encodes a [`SyncMessage`] as a JSON object string with a `"type"`
/// discriminator plus that message's own fields.
///
/// `Unknown` has no wire representation (it only ever exists as a decode
/// result); encoding it re-emits the original raw string as a bare JSON
/// string value's contents are not valid to send back over the wire, so
/// callers should never attempt to encode an `Unknown`. This function
/// still returns *something* sane (the raw text passed through) rather than
/// panicking.
pub fn encode_message(m: &SyncMessage) -> String {
    match m {
        SyncMessage::Unknown(raw) => raw.clone(),
        other => serde_json::to_string(other).expect("SyncMessage serialization is infallible"),
    }
}

/// Decodes a wire string into a [`SyncMessage`]. Never panics: any parse
/// failure or unrecognized `"type"` yields `SyncMessage::Unknown` wrapping
/// the original string, mirroring the Dart `decodeMessage`'s `UnknownMsg`
/// fallback.
pub fn decode_message(s: &str) -> SyncMessage {
    match serde_json::from_str::<Value>(s) {
        Ok(Value::Object(_)) => {
            serde_json::from_str::<SyncMessage>(s).unwrap_or_else(|_| SyncMessage::Unknown(s.to_string()))
        }
        _ => SyncMessage::Unknown(s.to_string()),
    }
}

/// Converts a decoded JSON scalar to a tag runtime value per IEC `data_type`
/// string (`BOOL`/`INT16`/`INT32`/`INT64`/`FLOAT32`/`FLOAT64`/`STRING`).
/// Total: never panics, falls back to a sensible default on mismatch —
/// mirrors the Dart `jsonToTagValue`.
pub fn json_to_tag_value(json: &Value, data_type: &str) -> soft_plc_runtime::tag::TagValue {
    use soft_plc_runtime::tag::TagValue;
    match data_type {
        "BOOL" => TagValue::Bool(json.as_bool().unwrap_or(matches!(json, Value::Bool(true)))),
        "INT16" => TagValue::Int16(json.as_i64().unwrap_or(0) as i16),
        "INT32" => TagValue::Int32(json.as_i64().unwrap_or(0) as i32),
        "INT64" => TagValue::Int64(json.as_i64().unwrap_or(0)),
        "FLOAT32" => TagValue::Float32(json.as_f64().unwrap_or(0.0) as f32),
        "FLOAT64" => TagValue::Float64(json.as_f64().unwrap_or(0.0)),
        "STRING" => TagValue::String(match json {
            Value::String(s) => s.clone(),
            Value::Null => String::new(),
            other => other.to_string(),
        }),
        _ => TagValue::String(json.to_string()),
    }
}

/// Converts a tag runtime value to a JSON-safe scalar per its IEC data type.
/// Mirrors the Dart `tagValueToJson`; always produces the JSON type the wire
/// contract expects (bool/int/float/string).
pub fn tag_value_to_json(value: &soft_plc_runtime::tag::TagValue) -> Value {
    use soft_plc_runtime::tag::TagValue;
    match value {
        TagValue::Bool(b) => Value::Bool(*b),
        TagValue::Int16(v) => Value::from(*v),
        TagValue::Int32(v) => Value::from(*v),
        TagValue::Int64(v) => Value::from(*v),
        TagValue::UInt16(v) => Value::from(*v),
        TagValue::UInt32(v) => Value::from(*v),
        TagValue::UInt64(v) => Value::from(*v),
        TagValue::Float32(v) => serde_json::Number::from_f64(*v as f64)
            .map(Value::Number)
            .unwrap_or(Value::from(0.0)),
        TagValue::Float64(v) => serde_json::Number::from_f64(*v)
            .map(Value::Number)
            .unwrap_or(Value::from(0.0)),
        TagValue::String(s) => Value::String(s.clone()),
    }
}

/// Maps a wire `dataType` string (`BOOL`, `INT16`, ...) to the runtime
/// `DataType` enum. Falls back to `Bool` for unrecognized strings (matching
/// the Dart side's `?? 'BOOL'` default-on-missing behavior for the reverse
/// direction).
pub fn data_type_from_wire(s: &str) -> soft_plc_runtime::tag::DataType {
    use soft_plc_runtime::tag::DataType;
    match s {
        "BOOL" => DataType::Bool,
        "INT16" => DataType::Int16,
        "INT32" => DataType::Int32,
        "INT64" => DataType::Int64,
        "FLOAT32" => DataType::Float32,
        "FLOAT64" => DataType::Float64,
        "STRING" => DataType::String,
        _ => DataType::Bool,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Codec parity fixtures -------------------------------------------
    // These JSON strings are copied verbatim from what the Dart codec
    // (`mobile/lib/models/gateway_sync.dart`, exercised by
    // `mobile/test/gateway_sync_test.dart`) produces for the equivalent
    // messages, so decoding them here is a direct parity check.

    #[test]
    fn decodes_dart_hello_fixture() {
        let json = r#"{"type":"hello","project":"MotorProj","controller":"PLC_01","scanMs":100}"#;
        let msg = decode_message(json);
        assert_eq!(
            msg,
            SyncMessage::Hello {
                project: "MotorProj".to_string(),
                controller: "PLC_01".to_string(),
                scan_ms: 100,
            }
        );
        // Round-trip: re-encode and decode again yields the same message.
        let re_encoded = encode_message(&msg);
        assert_eq!(decode_message(&re_encoded), msg);
    }

    #[test]
    fn decodes_dart_snapshot_fixture() {
        let json = r#"{"type":"snapshot","tags":[{"path":"Inputs/Start_PB","dataType":"BOOL","value":false,"access":"ReadWrite"},{"path":"Outputs/Motor_Run","dataType":"BOOL","value":true,"access":"ReadOnly"}]}"#;
        let msg = decode_message(json);
        let SyncMessage::Snapshot { tags } = &msg else {
            panic!("expected Snapshot, got {msg:?}");
        };
        assert_eq!(tags.len(), 2);
        assert_eq!(tags[0].path, "Inputs/Start_PB");
        assert_eq!(tags[0].data_type, "BOOL");
        assert_eq!(tags[0].value, Value::Bool(false));
        assert_eq!(tags[0].access, "ReadWrite");
        assert_eq!(tags[1].path, "Outputs/Motor_Run");
        assert_eq!(tags[1].value, Value::Bool(true));
        assert_eq!(tags[1].access, "ReadOnly");

        let re_encoded = encode_message(&msg);
        assert_eq!(decode_message(&re_encoded), msg);
    }

    #[test]
    fn decodes_dart_delta_fixture() {
        let json = r#"{"type":"delta","changes":[{"path":"Inputs/Start_PB","value":true},{"path":"Internal/Level_SP","value":42.5}]}"#;
        let msg = decode_message(json);
        let SyncMessage::Delta { changes } = &msg else {
            panic!("expected Delta, got {msg:?}");
        };
        assert_eq!(changes.len(), 2);
        assert_eq!(changes[0].path, "Inputs/Start_PB");
        assert_eq!(changes[0].value, Value::Bool(true));
        assert_eq!(changes[1].path, "Internal/Level_SP");
        assert_eq!(changes[1].value, serde_json::json!(42.5));

        let re_encoded = encode_message(&msg);
        assert_eq!(decode_message(&re_encoded), msg);
    }

    #[test]
    fn decodes_dart_write_fixture() {
        let json = r#"{"type":"write","path":"Outputs/Motor_Run","value":true}"#;
        let msg = decode_message(json);
        assert_eq!(
            msg,
            SyncMessage::Write {
                path: "Outputs/Motor_Run".to_string(),
                value: Value::Bool(true),
            }
        );
        let re_encoded = encode_message(&msg);
        assert_eq!(decode_message(&re_encoded), msg);
    }

    #[test]
    fn decodes_dart_ready_ping_pong_fixtures() {
        assert_eq!(decode_message(r#"{"type":"ready"}"#), SyncMessage::Ready {});
        assert_eq!(decode_message(r#"{"type":"ping"}"#), SyncMessage::Ping {});
        assert_eq!(decode_message(r#"{"type":"pong"}"#), SyncMessage::Pong {});
    }

    #[test]
    fn round_trip_every_variant() {
        let msgs = vec![
            SyncMessage::Hello {
                project: "P".to_string(),
                controller: "C".to_string(),
                scan_ms: 50,
            },
            SyncMessage::Snapshot {
                tags: vec![ExposedTag {
                    path: "A".to_string(),
                    data_type: "INT32".to_string(),
                    value: Value::from(7),
                    access: "ReadOnly".to_string(),
                }],
            },
            SyncMessage::Delta {
                changes: vec![TagChange {
                    path: "A".to_string(),
                    value: Value::from(8),
                }],
            },
            SyncMessage::Write {
                path: "A".to_string(),
                value: Value::from(9),
            },
            SyncMessage::Ready {},
            SyncMessage::Ping {},
            SyncMessage::Pong {},
        ];
        for m in msgs {
            let encoded = encode_message(&m);
            let decoded = decode_message(&encoded);
            assert_eq!(decoded, m, "round-trip mismatch for {encoded}");
        }
    }

    // --- malformed / unknown input never panics ---------------------------

    #[test]
    fn not_json_yields_unknown() {
        let decoded = decode_message("{not json");
        assert_eq!(decoded, SyncMessage::Unknown("{not json".to_string()));
    }

    #[test]
    fn unknown_type_yields_unknown() {
        let decoded = decode_message(r#"{"type":"bogus"}"#);
        assert_eq!(decoded, SyncMessage::Unknown(r#"{"type":"bogus"}"#.to_string()));
    }

    #[test]
    fn empty_string_yields_unknown() {
        let decoded = decode_message("");
        assert_eq!(decoded, SyncMessage::Unknown(String::new()));
    }

    #[test]
    fn json_array_yields_unknown() {
        let decoded = decode_message("[1,2,3]");
        assert_eq!(decoded, SyncMessage::Unknown("[1,2,3]".to_string()));
    }

    // --- tag value <-> JSON coercion ---------------------------------------

    #[test]
    fn json_to_tag_value_bool() {
        use soft_plc_runtime::tag::TagValue;
        assert_eq!(json_to_tag_value(&Value::Bool(true), "BOOL"), TagValue::Bool(true));
    }

    #[test]
    fn json_to_tag_value_int32() {
        use soft_plc_runtime::tag::TagValue;
        assert_eq!(json_to_tag_value(&Value::from(42), "INT32"), TagValue::Int32(42));
    }

    #[test]
    fn json_to_tag_value_float64_stays_float_for_whole_numbers() {
        // The whole-number-float regression this project already guards on
        // the Dart side (fixed in commit 04d82ec): a JSON number like `5.0`
        // that round-trips as an integer-looking value must still coerce to
        // TagValue::Float64, not an integer type.
        use soft_plc_runtime::tag::TagValue;
        let json: Value = serde_json::from_str("5.0").unwrap();
        assert_eq!(json_to_tag_value(&json, "FLOAT64"), TagValue::Float64(5.0));
        let json_int_shaped: Value = serde_json::from_str("5").unwrap();
        assert_eq!(json_to_tag_value(&json_int_shaped, "FLOAT64"), TagValue::Float64(5.0));
    }

    #[test]
    fn json_to_tag_value_string() {
        use soft_plc_runtime::tag::TagValue;
        assert_eq!(
            json_to_tag_value(&Value::String("hello".to_string()), "STRING"),
            TagValue::String("hello".to_string())
        );
    }

    #[test]
    fn json_to_tag_value_is_total_on_mismatch() {
        use soft_plc_runtime::tag::TagValue;
        assert_eq!(json_to_tag_value(&Value::String("not a number".to_string()), "INT32"), TagValue::Int32(0));
        assert_eq!(json_to_tag_value(&Value::Null, "BOOL"), TagValue::Bool(false));
        assert_eq!(json_to_tag_value(&Value::from(123), "STRING"), TagValue::String("123".to_string()));
    }

    #[test]
    fn tag_value_to_json_round_trip() {
        use soft_plc_runtime::tag::TagValue;
        assert_eq!(tag_value_to_json(&TagValue::Bool(true)), Value::Bool(true));
        assert_eq!(tag_value_to_json(&TagValue::Int32(42)), Value::from(42));
        assert_eq!(tag_value_to_json(&TagValue::Float64(12.5)), serde_json::json!(12.5));
        assert_eq!(
            tag_value_to_json(&TagValue::String("hi".to_string())),
            Value::String("hi".to_string())
        );
    }
}
