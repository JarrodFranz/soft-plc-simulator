# Mobile OS Constraints & Mitigation Strategy

> **Update (ADR-010):** Android, iOS, and desktop all **can** host every
> in-app protocol server (OPC UA, Modbus TCP, MQTT, DNP3) directly — pure
> Dart `dart:io` sockets running in-process, no companion required. The
> constraints below are real OS-level behaviors the in-app hosts live with
> (documented per-protocol in `docs/protocols/`), not gaps that block mobile
> hosting entirely. The **only** platform that cannot host a protocol server
> is a **web build** — a browser tab cannot bind an inbound `ServerSocket`;
> web still runs the simulator/editors fine, just not the protocol listeners.

## Constraints

1. **Background Socket Server Termination**: iOS suspends the app in the background, so it stops accepting **new** inbound connections until foregrounded again (existing connections may also drop). Android keeps hosting while the app process is alive, but requires the client to be on the **same LAN** — no NAT traversal/port-forwarding.
2. **Privileged Port Binding**: Binding ports <1024 (e.g., Modbus 502, OPC UA's port is already >1024) is forbidden on non-rooted mobile devices — reconfigure the port field to a non-privileged value (e.g. `5020`) in the Outbound Protocols screen; this is a normal user-space socket otherwise.
3. **Battery Saving Throttling**: OS timer throttling can delay scan loop execution when running on battery.
4. **Web cannot host sockets**: a web build compiles and runs the app, but a browser sandbox has no `ServerSocket` API — none of the four protocol servers can be started from a web build. This is the one platform-level limitation with no mitigation short of not using web for protocol hosting.

## Mitigation Strategy

- Each protocol server binds directly in-process on the device (ADR-010); no companion process or WebSocket sync layer is needed. Use a non-default, non-privileged port on mobile if the default (e.g. Modbus's 502) can't be bound, and keep the app foregrounded on iOS for continuous availability.
