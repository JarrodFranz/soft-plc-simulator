# IEC 61131-3 Language Support Specifications

The Soft PLC Simulator provides support for IEC 61131-3 programmable controller languages:

1. **Structured Text (ST)**: Pascal-like textual programming language ([STRUCTURED_TEXT.md](STRUCTURED_TEXT.md)).
2. **Ladder Diagram (LD)**: Relay-logic graphic representation ([LADDER_LOGIC.md](LADDER_LOGIC.md)).
3. **Function Block Diagram (FBD)**: Graphic signal-flow diagrams ([FUNCTION_BLOCK_DIAGRAM.md](FUNCTION_BLOCK_DIAGRAM.md)).
4. **Sequential Function Chart (SFC)**: State-machine sequential flow ([SEQUENTIAL_FUNCTION_CHART.md](SEQUENTIAL_FUNCTION_CHART.md)).

All high-level language programs compile into a unified internal instruction model executed by the `ScanEngine`.
