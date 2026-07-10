# Soft PLC Runtime Core (`/runtime`)

Rust-based library crate implementing the Soft PLC scan cycle engine, tag database, logic interpreter, and timer management. This is a **reference/legacy engine** — the live, shipped scan engine is the pure-Dart one in `mobile/lib/models` (see `ARCHITECTURE.md`); this crate is not wired into the app via FFI.

## Building and Testing
```bash
cargo check
cargo test
```
