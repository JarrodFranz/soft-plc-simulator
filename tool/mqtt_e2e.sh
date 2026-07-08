#!/usr/bin/env bash
# WS-mqtt Task 6 E2E machine-proof: runs `gateway/examples/mqtt_probe.rs`,
# which (unlike `tool/modbus_e2e.sh`/`tool/opcua_e2e.sh`) does ALL of its own
# orchestration internally -- it embeds a real `rumqttd` broker, connects a
# real `rumqttc` subscriber, spawns the Dart fixture host
# (`mobile/tool/mqtt_host_probe.dart`) as a child process TWICE (once per
# payload format: JSON, then Sparkplug B), and asserts birth/telemetry/
# NBIRTH-NDATA/remote-write round-trips against each. This wrapper only adds
# a bounded timeout and consistent logging, matching the other protocols'
# `tool/*_e2e.sh` scripts.
#
# ROLE REVERSAL vs. modbus/opcua: those Dart fixture hosts are SERVERS this
# script starts first, waiting for their own "READY" line before running the
# Rust probe as a client. Here the Dart fixture is an outbound MQTT CLIENT --
# it can't start until a broker already exists to dial into -- so the Rust
# example itself owns starting the broker and spawning/killing each Dart
# fixture run; there is nothing for this script to start or wait on directly.
#
# Usage: tool/mqtt_e2e.sh   (run from the repo root; bash/Git-Bash)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[e2e] $*"; }

log "repo root: ${REPO_ROOT}"
log "running the Rust mqtt_probe example (embeds rumqttd + rumqttc, drives the Dart MQTT/Sparkplug B fixture host twice: JSON then Sparkplug)..."

# Budget: broker bind (~<1s) + two fixture-process starts (~a few s of `dart
# run` VM startup each) + up to 15s per individual wait_for() inside the
# probe (several waits per phase, but each resolves in well under a second
# once the expected message actually arrives -- the 15s bound is a ceiling,
# not the expected latency) + the fixture's own fixed T+3s server-side
# mutation, twice (once per phase) = comfortably under 150s; rounded up for
# slow CI/build machines.
timeout 180 cargo run --manifest-path "${REPO_ROOT}/gateway/Cargo.toml" --example mqtt_probe
PROBE_EXIT=$?

log "probe exit code: ${PROBE_EXIT}"
exit "${PROBE_EXIT}"
