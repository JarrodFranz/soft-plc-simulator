#!/usr/bin/env bash
# WS26 DNP3 outstation Task 6 E2E machine-proof: starts the in-app DNP3
# outstation TCP server (the Dart fixture host, mobile/tool/dnp3_host_probe.dart)
# on a non-default port, waits for it to report READY, then runs a REAL
# third-party DNP3 master (Step Function I/O's `dnp3` crate,
# gateway/examples/dnp3_probe.rs) against it -- Class 0 integrity poll,
# DIRECT_OPERATE CROB + analog-output-block, re-poll, forced-tag rejection,
# solicited Class 1/2/3 EVENT poll, and outstation-initiated UNSOLICITED
# events -- covering BOTH input (g2/g32) AND output (g11/g42) change events.
# Kills the Dart host unconditionally on exit and propagates the
# probe's exit code. Mirrors `tool/modbus_e2e.sh` (server-role Dart fixture
# started first; the Rust binary is the client dialing in).
#
# HONEST FALLBACK: if the Rust master can't run in this environment (no
# `cargo` on PATH, or the `dnp3` crate can't be fetched/built offline), the
# script does NOT fake a pass. It instead (a) tries `cargo build --example
# dnp3_probe` to compile-check the probe, (b) runs the Dart unit suite as the
# in-process proof of the same outstation/event codec, and (c) reports the
# live-master leg as SKIPPED with the reason. Its exit code then reflects the
# unit suite, never a probe that didn't run.
#
# Usage: tool/dnp3_e2e.sh   (run from the repo root; bash/Git-Bash)
#
# PID NOTE (Windows/Git-Bash): see `tool/modbus_e2e.sh`'s identical note --
# `dart run` is a wrapper (`dart.bat`) that spawns a real `dart.exe` child;
# under MSYS/Git-Bash, `$!` is a synthetic MSYS job id, NOT the real Windows
# PID of that child, so this script finds the REAL Windows PID listening on
# the target port via `netstat -ano` and kills that (with `//T` to take any
# of its own children too), falling back to the bash job PID otherwise.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=48800
DART_LOG="$(mktemp -t dnp3-e2e-dart-host.XXXXXX 2>/dev/null || echo /tmp/dnp3-e2e-dart-host.log)"
DART_JOB_PID=""

log() { echo "[e2e] $*"; }

find_listening_pid() {
  if command -v netstat >/dev/null 2>&1; then
    netstat -ano 2>/dev/null | grep "LISTENING" | grep ":${PORT} " | awk '{print $NF}' | head -n1
  fi
}

cleanup() {
  log "cleaning up..."
  local real_pid
  real_pid="$(find_listening_pid)"
  if [ -n "${real_pid}" ] && command -v taskkill >/dev/null 2>&1; then
    log "killing dart host by real Windows PID ${real_pid} (owns port ${PORT})..."
    taskkill //F //T //PID "${real_pid}" >/dev/null 2>&1
  fi
  if [ -n "${DART_JOB_PID}" ]; then
    kill "${DART_JOB_PID}" 2>/dev/null
    wait "${DART_JOB_PID}" 2>/dev/null
  fi
  rm -f "${DART_LOG}" 2>/dev/null
}
trap cleanup EXIT

log "repo root: ${REPO_ROOT}"

# --- Honest fallback gate: can we run the live Rust master at all? ----------
# Compile-check the probe first. If cargo is missing or the build fails
# (offline crate fetch, no toolchain), skip the live leg and fall back to the
# Dart unit suite instead of pretending the master ran.
run_unit_fallback() {
  local reason="$1"
  log "LIVE MASTER LEG SKIPPED: ${reason}"
  log "falling back to the Dart unit suite (in-process proof of the same"
  log "outstation + event codec)..."
  ( cd "${REPO_ROOT}/mobile" && flutter test )
  local rc=$?
  if [ "${rc}" -eq 0 ]; then
    log "DNP3 E2E: live master SKIPPED (${reason}); Dart unit suite PASSED."
  else
    log "DNP3 E2E: live master SKIPPED (${reason}); Dart unit suite FAILED (rc=${rc})."
  fi
  exit "${rc}"
}

if ! command -v cargo >/dev/null 2>&1; then
  run_unit_fallback "cargo not on PATH"
fi

log "compile-checking the Rust probe (cargo build --example dnp3_probe)..."
if ! cargo build --manifest-path "${REPO_ROOT}/gateway/Cargo.toml" --example dnp3_probe; then
  run_unit_fallback "cargo build --example dnp3_probe failed (offline crate fetch or toolchain issue)"
fi

log "starting Dart DNP3 outstation fixture host on port ${PORT} (log: ${DART_LOG})..."

(
  cd "${REPO_ROOT}/mobile" && exec dart run tool/dnp3_host_probe.dart "${PORT}"
) >"${DART_LOG}" 2>&1 &
DART_JOB_PID=$!

log "waiting for READY (bounded ~90s)..."
READY=0
for _ in $(seq 1 180); do
  if grep -q "READY DNP3_E2E_FIXTURE" "${DART_LOG}" 2>/dev/null; then
    READY=1
    break
  fi
  sleep 0.5
done

if [ "${READY}" -ne 1 ]; then
  log "TIMED OUT waiting for READY -- log follows:"
  cat "${DART_LOG}"
  exit 1
fi

log "Dart host is READY:"
cat "${DART_LOG}"

log "running the Rust dnp3 master client probe against 127.0.0.1:${PORT}..."
# Connect/association setup + Class 0 poll + 2 DIRECT_OPERATEs + SELECT/OPERATE
# + re-polls, THEN the two events legs: a solicited Class 1/2/3 event poll loop
# and an unsolicited leg (each bounded to 30s inside the probe, see
# dnp3_probe.rs). 150s is a comfortable ceiling for slow CI/build machines.
timeout 150 cargo run --manifest-path "${REPO_ROOT}/gateway/Cargo.toml" --example dnp3_probe -- 127.0.0.1 "${PORT}"
PROBE_EXIT=$?

log "probe exit code: ${PROBE_EXIT}"
exit "${PROBE_EXIT}"
