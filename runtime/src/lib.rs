// Soft PLC Runtime Core
//
// This crate implements the core PLC runtime including:
// - Tag database (in-memory tag store)
// - Scan cycle execution engine
// - Basic logic instructions (contacts, coils, timers)
// - Simulated I/O
// - Runtime lifecycle management

pub mod tag;
pub mod scan_engine;
pub mod instructions;
pub mod timer;
pub mod program;
pub mod runtime;
pub mod project;
pub mod io_image;

pub use runtime::Runtime;
pub use tag::{Tag, TagValue, TagQuality, DataType, AccessMode};
pub use scan_engine::ScanEngine;
pub use project::Project;
