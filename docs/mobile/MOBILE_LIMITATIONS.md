# Mobile OS Constraints & Mitigation Strategy

## Constraints

1. **Background Socket Server Termination**: iOS and Android suspend background apps after short periods, severing active TCP connections (OPC UA, Modbus TCP).
2. **Privileged Port Binding**: Binding ports <1024 (e.g., Modbus 502) is forbidden on non-rooted mobile devices.
3. **Battery Saving Throttling**: OS timer throttling can delay scan loop execution when running on battery.

## Mitigation Strategy

- Implement **Mode B: Companion Gateway Mode** where high-performance protocol servers run on a desktop/server while synchronizing state with mobile devices via WebSockets.
