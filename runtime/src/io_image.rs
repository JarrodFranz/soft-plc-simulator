// I/O Image
//
// The I/O image is a snapshot of all simulated inputs and outputs.
// Following the traditional PLC scan cycle:
// 1. Read inputs into the I/O image
// 2. Execute logic against the I/O image
// 3. Write outputs from the I/O image
//
// In this simulator, the I/O image is managed through the tag database
// with tags marked as SimulatedInput or SimulatedOutput.

use crate::tag::{TagDatabase, IoType};

/// Snapshot the current state of all I/O points.
/// In a real PLC this would read physical I/O cards.
/// In the simulator, simulated inputs are already in the tag database.
pub fn read_inputs(_db: &mut TagDatabase) {
    // In the simulator, inputs are set manually or by simulation models.
    // This function is a hook for future process simulation integration.
    // No-op for now - inputs are already in the tag database.
}

/// Write outputs from the tag database.
/// In a real PLC this would write to physical I/O cards.
/// In the simulator, outputs are already in the tag database.
pub fn write_outputs(_db: &mut TagDatabase) {
    // In the simulator, outputs are read directly from the tag database.
    // This function is a hook for future process simulation integration.
    // No-op for now - outputs are already in the tag database.
}

/// Get a summary of all I/O points in the tag database.
pub fn io_summary(db: &TagDatabase) -> IoSummary {
    let mut inputs = Vec::new();
    let mut outputs = Vec::new();
    let mut internals = Vec::new();

    for tag in db.all_tags() {
        let point = IoPoint {
            name: tag.name.clone(),
            value_str: format!("{:?}", tag.effective_value()),
            forced: tag.is_forced(),
        };
        match tag.io_type {
            IoType::SimulatedInput => inputs.push(point),
            IoType::SimulatedOutput => outputs.push(point),
            IoType::Internal => internals.push(point),
        }
    }

    IoSummary {
        inputs,
        outputs,
        internals,
    }
}

/// Summary of I/O points for display/diagnostics.
#[derive(Debug, Clone)]
pub struct IoPoint {
    pub name: String,
    pub value_str: String,
    pub forced: bool,
}

/// Collection of all I/O point summaries.
#[derive(Debug, Clone)]
pub struct IoSummary {
    pub inputs: Vec<IoPoint>,
    pub outputs: Vec<IoPoint>,
    pub internals: Vec<IoPoint>,
}
