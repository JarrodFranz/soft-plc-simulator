# Field I/O Simulation

Field I/O is simulated in-app so a project runs with no hardware attached:

- **Simulated inputs** — tags carrying `ioType` `SimulatedInput`/`SimulatedOutput`
  are driven from the HMI (pushbuttons, toggles, numeric entries), edited
  directly in the Memory Manager / Tag Inspector, or written by an external
  SCADA client over any of the hosted protocols.
- **Tag forcing** — a tag can be *forced* to a value, overriding whatever logic
  or simulation would otherwise write. Forcing wins over both the scan and the
  simulated-I/O engine, and an external protocol write to a forced tag is
  refused (OPC UA reports `Bad_UserAccessDenied`) rather than silently ignored,
  so a stuck sensor or held limit switch can be modelled honestly.
- **Simulated I/O rules** — per-tag `SimRule`s give inputs real dynamics
  (integrate / first-order lag / dead time / ramp / pulse / noise) instead of
  static values. See [`PROCESS_SIMULATION.md`](PROCESS_SIMULATION.md).
- **Bulk simulated test tags** — signal generators (ramp, sine, square,
  triangle for analogs; toggle for BOOLs) can be generated in bulk into a
  folder as read-only tags and are auto-mapped to every hosted protocol, for
  exercising a SCADA client against many moving values at once. See
  [`../simulated-test-tags.md`](../simulated-test-tags.md).

All of it is deterministic: the engines take no wall clock and no randomness
(noise and test-tag generators are seeded), so the same project replays the
same values.
