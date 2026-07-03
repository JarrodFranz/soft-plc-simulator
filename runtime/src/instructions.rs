// Logic Instructions
//
// Basic PLC logic instructions for Boolean logic execution.
// These form the internal instruction model that all IEC 61131-3
// languages compile down to.
//
// Supported instructions:
// - ExamineOpen (XIC / Normally Open Contact): true if tag is true
// - ExamineClosed (XIO / Normally Closed Contact): true if tag is false
// - OutputCoil (OTE): writes result to tag
// - SetCoil (OTL / Latch): sets tag to true when result is true
// - ResetCoil (OTU / Unlatch): resets tag to false when result is true
// - TimerOnDelay (TON): timer that turns on after preset delay

use serde::{Deserialize, Serialize};
use crate::tag::TagDatabase;

/// A single logic instruction in the internal instruction model.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Instruction {
    /// Normally Open Contact - true when tag is true.
    /// If this is the first instruction in a rung, it sets the rung state.
    /// Otherwise, it ANDs with the current rung state.
    ExamineOpen { tag: String },

    /// Normally Closed Contact - true when tag is false.
    /// If this is the first instruction in a rung, it sets the rung state.
    /// Otherwise, it ANDs with the current rung state.
    ExamineClosed { tag: String },

    /// Output Coil - writes the current rung state to the tag.
    OutputCoil { tag: String },

    /// Set (Latch) Coil - sets tag to true when rung state is true.
    /// Does NOT reset when rung state goes false.
    SetCoil { tag: String },

    /// Reset (Unlatch) Coil - resets tag to false when rung state is true.
    ResetCoil { tag: String },

    /// Branch Start - begins a parallel branch (OR logic).
    /// Saves the current rung state on a stack.
    BranchStart,

    /// Branch Next - ORs the current branch result with the saved state.
    /// Starts a new parallel path.
    BranchNext,

    /// Branch End - ends the parallel branch group.
    /// ORs the final branch result.
    BranchEnd,

    /// Timer On Delay - activates output after preset time.
    /// Uses a named timer instance.
    TimerOnDelay {
        timer_name: String,
        enable_tag: String,
        done_tag: String,
        preset_ms: u64,
    },
}

/// A rung is a sequence of instructions that form one line of logic.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Rung {
    pub comment: String,
    pub instructions: Vec<Instruction>,
}

struct BranchFrame {
    incoming_state: bool,
    accumulated_or: bool,
}

/// The state maintained during rung execution.
struct RungExecutionState {
    /// Current rung continuity (power rail state).
    rung_state: bool,
    /// Stack of branch frames for nested parallel branches.
    branch_stack: Vec<BranchFrame>,
}

impl RungExecutionState {
    fn new() -> Self {
        Self {
            rung_state: true,
            branch_stack: Vec::new(),
        }
    }
}

/// Execute a single rung of instructions against the tag database.
///
/// Returns the final rung state (true = continuity, false = no continuity).
pub fn execute_rung(
    rung: &Rung,
    db: &mut TagDatabase,
    timers: &mut std::collections::HashMap<String, crate::timer::TonTimer>,
    scan_time_ms: u64,
) -> bool {
    let mut state = RungExecutionState::new();

    for instruction in &rung.instructions {
        match instruction {
            Instruction::ExamineOpen { tag } => {
                let tag_value = db.read_bool(tag);
                state.rung_state = state.rung_state && tag_value;
            }
            Instruction::ExamineClosed { tag } => {
                let tag_value = db.read_bool(tag);
                state.rung_state = state.rung_state && !tag_value;
            }
            Instruction::OutputCoil { tag } => {
                db.write_bool(tag, state.rung_state);
            }
            Instruction::SetCoil { tag } => {
                if state.rung_state {
                    db.write_bool(tag, true);
                }
            }
            Instruction::ResetCoil { tag } => {
                if state.rung_state {
                    db.write_bool(tag, false);
                }
            }
            Instruction::BranchStart => {
                // Save incoming power state and start accumulated OR as false
                state.branch_stack.push(BranchFrame {
                    incoming_state: state.rung_state,
                    accumulated_or: false,
                });
            }
            Instruction::BranchNext => {
                // Accumulate current branch path result into branch OR
                if let Some(frame) = state.branch_stack.last_mut() {
                    frame.accumulated_or |= state.rung_state;
                    // Reset rung state back to incoming state for the next parallel path
                    state.rung_state = frame.incoming_state;
                }
            }
            Instruction::BranchEnd => {
                // Complete branch group: OR last path result with accumulated OR result
                if let Some(frame) = state.branch_stack.pop() {
                    state.rung_state = frame.accumulated_or || state.rung_state;
                }
            }
            Instruction::TimerOnDelay {
                timer_name,
                enable_tag,
                done_tag,
                preset_ms,
            } => {
                let enable = db.read_bool(enable_tag);
                let timer = timers
                    .entry(timer_name.clone())
                    .or_insert_with(|| crate::timer::TonTimer::new(*preset_ms));

                timer.update(enable, scan_time_ms);
                db.write_bool(done_tag, timer.done);
            }
        }
    }

    state.rung_state
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tag::{Tag, IoType};

    fn make_test_db() -> TagDatabase {
        let mut db = TagDatabase::new();
        db.add_tag(Tag::new_bool("A", "Test/A", IoType::SimulatedInput, "Input A"));
        db.add_tag(Tag::new_bool("B", "Test/B", IoType::SimulatedInput, "Input B"));
        db.add_tag(Tag::new_bool("C", "Test/C", IoType::SimulatedInput, "Input C"));
        db.add_tag(Tag::new_bool("Out", "Test/Out", IoType::SimulatedOutput, "Output"));
        db.add_tag(Tag::new_bool("Latch", "Test/Latch", IoType::Internal, "Latch"));
        db
    }

    #[test]
    fn test_examine_open_true() {
        let mut db = make_test_db();
        db.write_bool("A", true);
        let mut timers = std::collections::HashMap::new();
        let rung = Rung {
            comment: "A -> Out".to_string(),
            instructions: vec![
                Instruction::ExamineOpen { tag: "A".to_string() },
                Instruction::OutputCoil { tag: "Out".to_string() },
            ],
        };
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Out"), true);
    }

    #[test]
    fn test_examine_open_false() {
        let mut db = make_test_db();
        let mut timers = std::collections::HashMap::new();
        let rung = Rung {
            comment: "A -> Out".to_string(),
            instructions: vec![
                Instruction::ExamineOpen { tag: "A".to_string() },
                Instruction::OutputCoil { tag: "Out".to_string() },
            ],
        };
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Out"), false);
    }

    #[test]
    fn test_examine_closed() {
        let mut db = make_test_db();
        // A is false, so NC contact is true
        let mut timers = std::collections::HashMap::new();
        let rung = Rung {
            comment: "/A -> Out".to_string(),
            instructions: vec![
                Instruction::ExamineClosed { tag: "A".to_string() },
                Instruction::OutputCoil { tag: "Out".to_string() },
            ],
        };
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Out"), true);
    }

    #[test]
    fn test_series_and_logic() {
        let mut db = make_test_db();
        db.write_bool("A", true);
        db.write_bool("B", true);
        let mut timers = std::collections::HashMap::new();
        let rung = Rung {
            comment: "A AND B -> Out".to_string(),
            instructions: vec![
                Instruction::ExamineOpen { tag: "A".to_string() },
                Instruction::ExamineOpen { tag: "B".to_string() },
                Instruction::OutputCoil { tag: "Out".to_string() },
            ],
        };
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Out"), true);
    }

    #[test]
    fn test_series_and_fails() {
        let mut db = make_test_db();
        db.write_bool("A", true);
        db.write_bool("B", false);
        let mut timers = std::collections::HashMap::new();
        let rung = Rung {
            comment: "A AND B -> Out".to_string(),
            instructions: vec![
                Instruction::ExamineOpen { tag: "A".to_string() },
                Instruction::ExamineOpen { tag: "B".to_string() },
                Instruction::OutputCoil { tag: "Out".to_string() },
            ],
        };
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Out"), false);
    }

    #[test]
    fn test_set_coil() {
        let mut db = make_test_db();
        db.write_bool("A", true);
        let mut timers = std::collections::HashMap::new();
        let rung = Rung {
            comment: "A --(L)-- Latch".to_string(),
            instructions: vec![
                Instruction::ExamineOpen { tag: "A".to_string() },
                Instruction::SetCoil { tag: "Latch".to_string() },
            ],
        };
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Latch"), true);

        // Latch stays on even when A goes false
        db.write_bool("A", false);
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Latch"), true);
    }

    #[test]
    fn test_reset_coil() {
        let mut db = make_test_db();
        db.write_bool("Latch", true);
        db.write_bool("B", true);
        let mut timers = std::collections::HashMap::new();
        let rung = Rung {
            comment: "B --(U)-- Latch".to_string(),
            instructions: vec![
                Instruction::ExamineOpen { tag: "B".to_string() },
                Instruction::ResetCoil { tag: "Latch".to_string() },
            ],
        };
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Latch"), false);
    }

    #[test]
    fn test_branch_or_logic() {
        let mut db = make_test_db();
        db.write_bool("A", false);
        db.write_bool("B", true);
        let mut timers = std::collections::HashMap::new();

        // A OR B -> Out
        let rung = Rung {
            comment: "A OR B -> Out".to_string(),
            instructions: vec![
                Instruction::BranchStart,
                Instruction::ExamineOpen { tag: "A".to_string() },
                Instruction::BranchNext,
                Instruction::ExamineOpen { tag: "B".to_string() },
                Instruction::BranchEnd,
                Instruction::OutputCoil { tag: "Out".to_string() },
            ],
        };
        execute_rung(&rung, &mut db, &mut timers, 100);
        assert_eq!(db.read_bool("Out"), true);
    }
}
