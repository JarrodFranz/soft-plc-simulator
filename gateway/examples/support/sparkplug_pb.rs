//! Minimal, checked-in `prost::Message`-derived Rust module standing in for
//! a `prost-build`/protoc-generated one — see `gateway/proto/sparkplug_b.proto`
//! (a trimmed, wire-compatible reference copy of the official Eclipse Tahu
//! `sparkplug_b.proto`) for the schema this mirrors and why it's hand-authored
//! here instead of compiled at build time (per WS-mqtt Task 6's brief:
//! "vendor the ... proto ... OR check in a minimal generated Payload/Metric
//! module" — this repo takes the latter, to avoid a protoc build-time
//! dependency for a small fixed wire shape).
//!
//! This is used ONLY by `gateway/examples/mqtt_probe.rs` (the Task 6 E2E
//! probe) to `prost::Message::decode` NBIRTH/NDATA bytes produced by the
//! Dart app's Sparkplug B encoder (`mobile/lib/protocols/mqtt/mqtt_sparkplug.dart`)
//! and to `encode` NCMD bytes for the remote-write round-trip proof — not
//! part of the shipped Dart/Flutter app itself.
//!
//! Field numbers below match this app's encoder exactly (see
//! `mqtt_sparkplug.dart`'s file-level doc comment), which in turn match the
//! REAL Eclipse Tahu `sparkplug_b.proto` numbering: `Payload` 1=timestamp,
//! 2=metrics (repeated), 3=seq; `Metric` 1=name, 2=alias, 4=datatype
//! (fields 5-9 are the spec's `is_historical`/`is_transient`/`is_null`/
//! `metadata`/`properties` metadata fields — not populated by this app, and
//! deliberately NOT declared as struct fields here since prost simply
//! ignores unknown field numbers on decode), and exactly one value field
//! selected by `datatype`: 10=int_value (uint32, unsigned-reinterpreted
//! Int8/16/32), 11=long_value (uint64, used for `bdSeq`/UInt64),
//! 13=double_value (double), 14=boolean_value (bool), 15=string_value
//! (string).

#[derive(Clone, PartialEq, ::prost::Message)]
pub struct Payload {
    #[prost(uint64, optional, tag = "1")]
    pub timestamp: Option<u64>,
    #[prost(message, repeated, tag = "2")]
    pub metrics: Vec<Metric>,
    #[prost(uint64, optional, tag = "3")]
    pub seq: Option<u64>,
}

#[derive(Clone, PartialEq, ::prost::Message)]
pub struct Metric {
    #[prost(string, optional, tag = "1")]
    pub name: Option<String>,
    #[prost(uint64, optional, tag = "2")]
    pub alias: Option<u64>,
    #[prost(uint32, optional, tag = "4")]
    pub datatype: Option<u32>,
    #[prost(uint32, optional, tag = "10")]
    pub int_value: Option<u32>,
    #[prost(uint64, optional, tag = "11")]
    pub long_value: Option<u64>,
    #[prost(double, optional, tag = "13")]
    pub double_value: Option<f64>,
    #[prost(bool, optional, tag = "14")]
    pub boolean_value: Option<bool>,
    #[prost(string, optional, tag = "15")]
    pub string_value: Option<String>,
}

/// Mirrors `SparkplugDatatype` in `mqtt_sparkplug.dart` (the subset of the
/// full Tahu `DataType` enum this app's encoder ever emits).
#[allow(dead_code)]
pub mod datatype {
    pub const INT8: u32 = 1;
    pub const INT16: u32 = 2;
    pub const INT32: u32 = 3;
    pub const INT64: u32 = 4;
    pub const UINT64: u32 = 8;
    pub const FLOAT: u32 = 9;
    pub const DOUBLE: u32 = 10;
    pub const BOOLEAN: u32 = 11;
    pub const STRING: u32 = 12;
}
