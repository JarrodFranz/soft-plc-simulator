// TON Timer (Timer On Delay)
//
// IEC 61131-3 standard timer that turns on its output after
// a configurable preset delay.
//
// Behavior:
// - When enable goes true, the timer starts accumulating time.
// - When accumulated time >= preset time, done output goes true.
// - When enable goes false, the timer resets (accumulated = 0, done = false).
// - Timer timing status (tt) is true while timing (enabled but not done).

use serde::{Deserialize, Serialize};

/// Timer On Delay (TON) function block.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TonTimer {
    /// Preset time in milliseconds.
    pub preset_ms: u64,
    /// Accumulated time in milliseconds.
    pub accumulated_ms: u64,
    /// Done output - true when accumulated >= preset.
    pub done: bool,
    /// Timer timing - true when enabled but not yet done.
    pub timing: bool,
    /// Previous enable state for edge detection.
    prev_enable: bool,
}

impl TonTimer {
    /// Create a new TON timer with the given preset.
    pub fn new(preset_ms: u64) -> Self {
        Self {
            preset_ms,
            accumulated_ms: 0,
            done: false,
            timing: false,
            prev_enable: false,
        }
    }

    /// Update the timer for one scan cycle.
    ///
    /// # Arguments
    /// * `enable` - The enable input (IN)
    /// * `scan_time_ms` - The elapsed time since the last scan in milliseconds
    pub fn update(&mut self, enable: bool, scan_time_ms: u64) {
        if enable {
            if !self.done {
                self.accumulated_ms = self.accumulated_ms.saturating_add(scan_time_ms);
                if self.accumulated_ms >= self.preset_ms {
                    self.accumulated_ms = self.preset_ms;
                    self.done = true;
                    self.timing = false;
                } else {
                    self.timing = true;
                }
            }
        } else {
            // Reset when enable goes false
            self.accumulated_ms = 0;
            self.done = false;
            self.timing = false;
        }
        self.prev_enable = enable;
    }

    /// Reset the timer to initial state.
    pub fn reset(&mut self) {
        self.accumulated_ms = 0;
        self.done = false;
        self.timing = false;
        self.prev_enable = false;
    }
}

/// Timer Off Delay (TOF) function block.
/// Output stays on for a preset time after enable goes false.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TofTimer {
    pub preset_ms: u64,
    pub accumulated_ms: u64,
    pub done: bool,
    pub timing: bool,
    prev_enable: bool,
}

impl TofTimer {
    pub fn new(preset_ms: u64) -> Self {
        Self {
            preset_ms,
            accumulated_ms: 0,
            done: false,
            timing: false,
            prev_enable: false,
        }
    }

    pub fn update(&mut self, enable: bool, scan_time_ms: u64) {
        if enable {
            // While enabled, output is on, timer is reset
            self.done = true;
            self.accumulated_ms = 0;
            self.timing = false;
        } else if self.prev_enable && !enable {
            // Falling edge - start timing
            self.timing = true;
        }

        if !enable && self.timing {
            self.accumulated_ms = self.accumulated_ms.saturating_add(scan_time_ms);
            if self.accumulated_ms >= self.preset_ms {
                self.accumulated_ms = self.preset_ms;
                self.done = false;
                self.timing = false;
            }
        }

        self.prev_enable = enable;
    }

    pub fn reset(&mut self) {
        self.accumulated_ms = 0;
        self.done = false;
        self.timing = false;
        self.prev_enable = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ton_basic_operation() {
        let mut timer = TonTimer::new(1000); // 1 second preset

        // Not enabled - should stay off
        timer.update(false, 100);
        assert!(!timer.done);
        assert!(!timer.timing);
        assert_eq!(timer.accumulated_ms, 0);

        // Enable - should start timing
        timer.update(true, 100);
        assert!(!timer.done);
        assert!(timer.timing);
        assert_eq!(timer.accumulated_ms, 100);

        // Continue timing
        timer.update(true, 400);
        assert!(!timer.done);
        assert!(timer.timing);
        assert_eq!(timer.accumulated_ms, 500);

        // Not done yet
        timer.update(true, 400);
        assert!(!timer.done);
        assert!(timer.timing);
        assert_eq!(timer.accumulated_ms, 900);

        // Now done (900 + 200 = 1100 >= 1000)
        timer.update(true, 200);
        assert!(timer.done);
        assert!(!timer.timing);
        assert_eq!(timer.accumulated_ms, 1000); // Capped at preset
    }

    #[test]
    fn test_ton_reset_on_disable() {
        let mut timer = TonTimer::new(1000);

        // Accumulate some time
        timer.update(true, 500);
        assert_eq!(timer.accumulated_ms, 500);

        // Disable - should reset
        timer.update(false, 100);
        assert!(!timer.done);
        assert!(!timer.timing);
        assert_eq!(timer.accumulated_ms, 0);
    }

    #[test]
    fn test_ton_stays_done() {
        let mut timer = TonTimer::new(500);

        // Run to completion
        timer.update(true, 600);
        assert!(timer.done);

        // Stays done while enabled
        timer.update(true, 100);
        assert!(timer.done);
        assert_eq!(timer.accumulated_ms, 500);
    }

    #[test]
    fn test_ton_exact_preset() {
        let mut timer = TonTimer::new(100);
        timer.update(true, 100);
        assert!(timer.done);
        assert_eq!(timer.accumulated_ms, 100);
    }

    #[test]
    fn test_ton_multiple_cycles() {
        let mut timer = TonTimer::new(500);
        let scan_time = 100;

        for i in 1..=4 {
            timer.update(true, scan_time);
            assert!(!timer.done, "Should not be done after {} scans", i);
            assert_eq!(timer.accumulated_ms, scan_time * i as u64);
        }

        timer.update(true, scan_time);
        assert!(timer.done, "Should be done after 5 scans (500ms)");
    }

    #[test]
    fn test_tof_basic_operation() {
        let mut timer = TofTimer::new(1000);

        // Enable - output on immediately
        timer.update(true, 100);
        assert!(timer.done);
        assert!(!timer.timing);

        // Disable - start off-delay
        timer.update(false, 100);
        assert!(timer.timing);

        // Output stays on during delay
        timer.update(false, 400);
        assert!(timer.timing);

        // After delay - output goes off
        timer.update(false, 600);
        assert!(!timer.done);
        assert!(!timer.timing);
    }
}
