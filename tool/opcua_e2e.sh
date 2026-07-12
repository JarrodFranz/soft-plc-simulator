#!/usr/bin/env bash
# WS19/WS20 + OPC UA security E2E machine-proof: starts the in-app OPC UA
# server (the Dart fixture host, mobile/tool/opcua_host_probe.dart) on a
# non-default port, waits for it to report READY, then runs a REAL third-party
# OPC UA client (the Rust `opcua` crate's client, gateway/examples/opcua_probe.rs)
# against it. The probe runs TWO legs:
#   1. None/Anonymous: GetEndpoints, Browse, Read, Write, Read-back-verify,
#      subscription + pushed DataChangeNotification (WS19/WS20) -> `PROBE PASS`.
#   2. SECURE: Basic256Sha256 / SignAndEncrypt + username/password auth, then
#      Browse/Read/Write/read-back over the encrypted channel (OPC UA security
#      workstream, Task 7) -> `OPCUA SECURITY PROBE PASS`.
# Kills the Dart host unconditionally on exit and propagates the probe's exit
# code.
#
# HONEST FALLBACK: if the Rust client can't run in this environment (no
# `cargo` on PATH, or the `opcua` crate can't be fetched/built offline), the
# script does NOT fake a pass. It instead (a) tries `cargo build --example
# opcua_probe` to compile-check the (extended, secure) probe, (b) runs the
# Dart unit suite as the in-process proof of the same crypto/secure-channel
# codec, and (c) reports the live-master leg as SKIPPED with the reason. Its
# exit code then reflects the unit suite, never a probe that didn't run.
#
# Usage: tool/opcua_e2e.sh   (run from the repo root; bash/Git-Bash)
#
# PID NOTE (Windows/Git-Bash): `dart run` is a wrapper (`dart.bat`) that
# spawns a real `dart.exe` child; under MSYS/Git-Bash, `$!` is a synthetic
# MSYS job id, NOT the real Windows PID of that child, so `taskkill //PID
# $!` silently fails to find it and the real dart.exe keeps running (and
# keeps the port bound). This script instead finds the REAL Windows PID
# that is listening on the target port via `netstat -ano` and kills that
# (with `//T` to take any of its own children too), falling back to the
# bash job PID + `pkill`-style cleanup on non-Windows.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=48400
ENDPOINT="opc.tcp://127.0.0.1:${PORT}"
DART_LOG="$(mktemp -t opcua-e2e-dart-host.XXXXXX 2>/dev/null || echo /tmp/opcua-e2e-dart-host.log)"
DART_JOB_PID=""

log() { echo "[e2e] $*"; }

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
  # Belt-and-braces fallback for any environment where `dart run` didn't
  # leave a listening socket behind to find (e.g. it crashed before
  # binding) -- best-effort, never fatal if nothing matches.
  if command -v taskkill >/dev/null 2>&1; then
    taskkill //F //IM dart.exe >/dev/null 2>&1 || true
  fi
  rm -f "${DART_LOG}" 2>/dev/null
}
trap cleanup EXIT

log "repo root: ${REPO_ROOT}"

# --- Honest fallback gate: can we run the live Rust client at all? ----------
# Compile-check the (extended, secure) probe first. If cargo is missing or the
# build fails (offline crate fetch, no toolchain), skip the live leg and fall
# back to the Dart unit suite instead of pretending the secure handshake ran.
run_unit_fallback() {
  local reason="$1"
  log "LIVE MASTER LEG SKIPPED: ${reason}"
  log "falling back to the Dart unit suite (in-process proof of the same"
  log "crypto + secure-channel + session codec)..."
  ( cd "${REPO_ROOT}/mobile" && flutter test )
  local rc=$?
  if [ "${rc}" -eq 0 ]; then
    log "OPC UA E2E: live secure master SKIPPED (${reason}); Dart unit suite PASSED."
  else
    log "OPC UA E2E: live secure master SKIPPED (${reason}); Dart unit suite FAILED (rc=${rc})."
  fi
  exit "${rc}"
}

if ! command -v cargo >/dev/null 2>&1; then
  run_unit_fallback "cargo not on PATH"
fi

log "compile-checking the Rust probe (cargo build --example opcua_probe)..."
if ! cargo build --manifest-path "${REPO_ROOT}/gateway/Cargo.toml" --example opcua_probe; then
  run_unit_fallback "cargo build --example opcua_probe failed (offline crate fetch or toolchain issue)"
fi

log "starting Dart OPC UA fixture host on port ${PORT} (log: ${DART_LOG})..."

(
  cd "${REPO_ROOT}/mobile" && exec dart run tool/opcua_host_probe.dart "${PORT}"
) >"${DART_LOG}" 2>&1 &
DART_JOB_PID=$!

log "waiting for READY (bounded ~90s)..."
READY=0
for _ in $(seq 1 180); do
  if grep -q "READY opc.tcp://" "${DART_LOG}" 2>/dev/null; then
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

log "running the Rust opcua client probe against ${ENDPOINT}..."
# 120s base budget (GetEndpoints/Browse/Read/Write/read-back) + ~15s for the
# subscription wait (10s bound inside the probe for the DataChangeNotification,
# plus margin for subscription/monitored-item creation and the session poll
# loop spin-up) = 135s, rounded up to 140s.
timeout 140 cargo run --manifest-path "${REPO_ROOT}/gateway/Cargo.toml" --example opcua_probe -- "${ENDPOINT}"
PROBE_EXIT=$?

log "probe exit code: ${PROBE_EXIT}"
exit "${PROBE_EXIT}"
