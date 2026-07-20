#!/usr/bin/env bash
# FINS-over-UDP E2E machine-proof: starts the in-app FINS host (the Dart
# fixture host, mobile/tool/fins_host_probe.dart) on a non-default UDP port,
# waits for it to report READY, then runs a REAL third-party FINS client -- the
# pure-Python `fins` library, driven by tool/py/fins_probe.py -- against it.
#
# THIS IS THE PYTHON LANE'S FIRST USE OVER UDP. Every prior probe here (pycomm3
# for EtherNet/IP, python-snap7 for S7comm) spoke TCP against a `ServerSocket`;
# FINS is the suite's first `RawDatagramSocket` host, and datagram framing is
# exactly the kind of wire detail a real client catches and a unit test does
# not -- which is why this probe runs EARLY, before any tag-map logic exists.
#
# WHAT THIS PROVES that the Dart unit suite cannot: every other FINS test in
# this repo exercises our codec against frames our codec built, which proves
# self-consistency, not conformance. This script is the only place a client
# written independently of us reads our wire bytes. It drives:
#   a Memory Area Read of a known DM word -> asserts the response frame our host
#   built (the 10-byte header, the DNA/DA1/DA2 <-> SNA/SA1/SA2 node swap, the
#   echoed SID, the command-code echo, a NORMAL end code, and the word data
#   BIG-ENDIAN), then the same word via the client's own high-level decode, then
#   a two-word read that settles word ORDER.
#
# WHY THE FIXTURE HOST PROVES THE SHIPPED HOST: every Memory Area Read response
# byte is produced by ONE shared pure function (`dispatchFinsDatagram`,
# mobile/lib/protocols/fins/fins_dispatch.dart) that both the fixture host and
# `mobile/lib/services/fins_host.dart` call. The bytes this client validates
# are, by construction rather than by diff, the bytes the app emits.
#
# This follows the shared Python-lane pattern established by `tool/s7_e2e.sh`
# (see that file's header): a pure-Dart fixture host that never imports the
# app's ChangeNotifier-based host service and prints `READY ...` once bound; a
# third-party client probe exiting 0 with a `... PROBE PASS` line or non-zero
# naming the failing step; the client library pinned EXACTLY in
# `tool/py/requirements.txt`; venv create/reuse, quiet install, READY
# handshake, unconditional teardown via `trap`, and the probe's exit code
# propagated verbatim. The venv, its packages, and any `__pycache__` are
# git-ignored -- nothing downloaded here is ever committed.
#
# Usage: tool/fins_e2e.sh   (run from anywhere; bash/Git-Bash)
#
# PID NOTE (Windows/Git-Bash): `dart run` is a wrapper (`dart.bat`) that spawns
# a real `dart.exe` child; under MSYS/Git-Bash, `$!` is a synthetic MSYS job id,
# NOT the real Windows PID of that child, so `taskkill //PID $!` silently fails
# to find it and the real dart.exe keeps running (and keeps the port bound).
# This script instead finds the REAL Windows PID that is bound to the target UDP
# port via `netstat -ano` and kills that (with `//T` to take any of its own
# children too), falling back to the bash job PID on non-Windows. Mirrors
# `tool/s7_e2e.sh`, but greps for a UDP binding (which has no LISTENING state).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Non-default: FINS's real port is 9600, which anything already hosting FINS
# would collide with.
PORT=19600
PY_DIR="${REPO_ROOT}/tool/py"
VENV_DIR="${PY_DIR}/.venv"
DART_LOG="$(mktemp -t fins-e2e-dart-host.XXXXXX 2>/dev/null || echo /tmp/fins-e2e-dart-host.log)"
DART_JOB_PID=""

log() { echo "[e2e] $*"; }

find_udp_pid() {
  # UDP bindings in netstat carry no "LISTENING" state column, unlike TCP.
  if command -v netstat >/dev/null 2>&1; then
    netstat -ano 2>/dev/null | grep -i "UDP" | grep ":${PORT} " | awk '{print $NF}' | head -n1
  fi
}

cleanup() {
  log "cleaning up..."
  local real_pid
  real_pid="$(find_udp_pid)"
  if [ -n "${real_pid}" ] && command -v taskkill >/dev/null 2>&1; then
    log "killing dart host by real Windows PID ${real_pid} (owns UDP port ${PORT})..."
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

# --- Python lane: create or reuse the venv, install the pinned client ------
PY_BIN=""
for candidate in python python3 py; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    PY_BIN="${candidate}"
    break
  fi
done
if [ -z "${PY_BIN}" ]; then
  log "FAILED: no Python interpreter on PATH (need Python 3.8+ for fins)."
  exit 1
fi

if [ ! -d "${VENV_DIR}" ]; then
  log "creating venv at ${VENV_DIR}..."
  if ! "${PY_BIN}" -m venv "${VENV_DIR}"; then
    log "FAILED: could not create the venv."
    exit 1
  fi
fi

# Windows venvs put the interpreter in Scripts/, POSIX ones in bin/.
if [ -x "${VENV_DIR}/Scripts/python.exe" ]; then
  VENV_PY="${VENV_DIR}/Scripts/python.exe"
elif [ -x "${VENV_DIR}/bin/python" ]; then
  VENV_PY="${VENV_DIR}/bin/python"
else
  log "FAILED: no interpreter found inside ${VENV_DIR}."
  exit 1
fi

log "installing pinned client libraries (tool/py/requirements.txt)..."
if ! "${VENV_PY}" -m pip install --quiet --disable-pip-version-check -r "${PY_DIR}/requirements.txt"; then
  log "FAILED: pip install of the pinned client library failed (no network,"
  log "proxy, or an unavailable version). This script does NOT fall back to a"
  log "hand-rolled client -- a real third-party client is the entire point."
  exit 1
fi
if ! "${VENV_PY}" -c "import fins; print('[e2e] fins import OK')"; then
  log "FAILED: fins failed to import from the venv (see traceback above)."
  exit 1
fi

# --- Dart fixture host ----------------------------------------------------
log "starting Dart FINS fixture host on UDP port ${PORT} (log: ${DART_LOG})..."
(
  cd "${REPO_ROOT}/mobile" && exec dart run tool/fins_host_probe.dart "${PORT}"
) >"${DART_LOG}" 2>&1 &
DART_JOB_PID=$!

log "waiting for READY (bounded ~90s)..."
READY=0
for _ in $(seq 1 180); do
  if grep -q "READY fins-udp://" "${DART_LOG}" 2>/dev/null; then
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

# --- The real third-party client ------------------------------------------
log "running the fins client probe against 127.0.0.1:${PORT}..."
# Every request is a loopback round trip and the probe bounds each UDP socket
# operation at 5s itself; 120s is a generous outer bound that still cannot wedge
# CI if the probe somehow blocks outside a socket call.
timeout 120 "${VENV_PY}" "${PY_DIR}/fins_probe.py" 127.0.0.1 "${PORT}"
PROBE_EXIT=$?

log "probe exit code: ${PROBE_EXIT}"
exit "${PROBE_EXIT}"
