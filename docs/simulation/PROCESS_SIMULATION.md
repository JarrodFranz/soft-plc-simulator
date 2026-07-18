# Process Simulation

Process dynamics are **not** hardcoded physics models. They are built from
composable per-tag **Simulated I/O rules** (`SimRule`), edited in the
**Simulated I/O** section and executed by the pure, deterministic engine in
`mobile/lib/models/sim_engine.dart` — one pass per scan tick, no clock and no
randomness, so a given project always produces the same sequence.

Each rule drives a target tag with one behaviour, optionally gated by a
condition and scaled by a driving (actuator) tag:

| Behaviour | Dynamics |
|---|---|
| `setWhileCondition` / `delayedSet` / `pulse` | Discrete: set while true, on-delay, and on/off pulse trains. |
| `ramp` | Moves the target toward a value at a fixed rate. |
| `integrate` | Accumulates at a rate, optionally scaled by an actuator fraction (`source/refValue`) — an integrating process such as tank level. |
| `firstOrderLag` | Relaxes the target toward a source with time constant τ — a self-regulating lag, and (when the source is another PV) the conduction/coupling term between two zones. |
| `deadTime` | Replays a source delayed by τ through a FIFO — transport delay. |
| `noise` | Adds measurement noise to a clean source: uniform, Gaussian, or pink (1/f), plus optional bounded sensor drift. |

Because multiple rules may target the same tag and are applied in order, richer
plants compose from simple parts — a coupled 2×2 process, for example, is each
zone's own `integrate` heat input plus a `firstOrderLag` toward the other zone
plus a slower `firstOrderLag` loss toward ambient.

Actuator response can additionally be shaped by a **valve characteristic**
(`linear` / `equal-percentage` / `quick-opening`) before it scales an
`integrate`/`ramp` rate.

Shipped demo projects exercise these: tank level, cascade tanks with transport
delay, a thermal reactor, PID tank level, noisy level measurement, and the
two-zone MIMO plant.

See also:

- [`../valve-curves.md`](../valve-curves.md) — valve characteristics.
- [`../measurement-noise.md`](../measurement-noise.md) — uniform / Gaussian / pink noise and sensor drift.
- [`../pid-autotune.md`](../pid-autotune.md) — relay-feedback auto-tuning against a simulated loop.
- [`../mimo-coupled-plant.md`](../mimo-coupled-plant.md) — the coupled two-zone plant, gain matrix / RGA, and the static decoupler.
- [`IO_SIMULATION.md`](IO_SIMULATION.md) — field I/O simulation and forcing.
