#!/usr/bin/env bash
# RTU-over-TCP E2E machine-proof: starts the in-app Modbus server (the Dart
# fixture host, mobile/tool/modbus_host_probe.dart) on a non-default port
# with RTU framing selected (no MBAP header; unitId + PDU + CRC-16, per
# mobile/lib/protocols/modbus/modbus_rtu.dart +
# mobile/lib/services/modbus_host.dart's `_onDataRtu`), waits for it to
# report READY, then runs a REAL third-party Modbus RTU client (the Rust
# `tokio-modbus` crate's own RTU client stack, attached to a plain TCP
# transport via `tokio_modbus::client::rtu::attach_slave` --
# gateway/examples/modbus_rtu_probe.rs) against it: read-holding-registers,
# write-single-register + independent read-back, write-single-coil +
# read-back. Proves the server's RTU framing path is interoperable with a
# real third-party RTU client, not just the classic MBAP Modbus TCP path
# already proven by tool/modbus_e2e.sh. Kills the Dart host unconditionally
# on exit and propagates the probe's exit code.
#
# Usage: tool/modbus_rtu_e2e.sh   (run from the repo root; bash/Git-Bash)
#
# PID NOTE (Windows/Git-Bash): see tool/modbus_e2e.sh's identical note --
# `dart run` spawns a real `dart.exe` child whose PID `$!` does not capture
# under MSYS/Git-Bash, so this script finds the REAL Windows PID listening on
# the target port via `netstat -ano` and kills that (with `//T` for any of
# its own children), falling back to the bash job PID otherwise.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=48601 # distinct from tool/modbus_e2e.sh's 48600 so both can run concurrently
DART_LOG="$(mktemp -t modbus-rtu-e2e-dart-host.XXXXXX 2>/dev/null || echo /tmp/modbus-rtu-e2e-dart-host.log)"
DART_JOB_PID=""

log() { echo "[rtu-e2e] $*"; }

# Finds the real Windows PID of whatever process is LISTENING on $PORT, via
# `netstat -ano` (present on every Windows install; this script is meant to
# run under Git Bash on Windows per this repo's environment). Prints
# nothing (empty string) if not found -- never fails the script.
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
log "starting Dart Modbus RTU-over-TCP fixture host on port ${PORT} (log: ${DART_LOG})..."

(
  cd "${REPO_ROOT}/mobile" && exec dart run tool/modbus_host_probe.dart "${PORT}" rtuOverTcp
) >"${DART_LOG}" 2>&1 &
DART_JOB_PID=$!

log "waiting for READY (bounded ~90s)..."
READY=0
for _ in $(seq 1 180); do
  if grep -q "READY MODBUS_E2E_FIXTURE" "${DART_LOG}" 2>/dev/null; then
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

log "running the Rust tokio-modbus RTU client probe against 127.0.0.1:${PORT}..."
# 10s connect budget + a handful of bounded (5s each) request/response round
# trips for the read/write/read-back steps, plus margin = comfortably under
# 60s; rounded up to 90s for slow CI/build machines.
timeout 90 cargo run --manifest-path "${REPO_ROOT}/gateway/Cargo.toml" --example modbus_rtu_probe -- 127.0.0.1 "${PORT}"
PROBE_EXIT=$?

log "probe exit code: ${PROBE_EXIT}"
exit "${PROBE_EXIT}"
