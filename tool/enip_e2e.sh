#!/usr/bin/env bash
# EtherNet/IP + CIP E2E machine-proof: starts the in-app EtherNet/IP host
# (the Dart fixture host, mobile/tool/enip_host_probe.dart) on a non-default
# port, waits for it to report READY, then runs a REAL third-party
# EtherNet/IP + CIP client -- the Python `pycomm3` library, driven by
# tool/py/enip_probe.py -- against it.
#
# WHAT THIS PROVES that the Dart unit suite cannot: every other EtherNet/IP
# test in this repo exercises our codec against frames our codec built, which
# proves self-consistency, not conformance. This script is the only place a
# client written independently of us reads our wire bytes. It drives:
#   RegisterSession -> Large Forward Open attempt (rejected 0x08) -> regular
#   Forward Open -> Read Tag -> Write Tag -> INDEPENDENT read-back asserting
#   the exact written value -> unconnected (UCMM) read -> ReadOnly/forced
#   write refusals -> Forward Close -> UnRegisterSession.
# The probe prints `ENIP PROBE PASS` and exits 0 only if every step asserted.
#
# THIS IS THE SHARED PYTHON-LANE PATTERN FOR LATER PROTOCOLS. The protocol
# expansion program's remaining hosts (S7comm, FINS, SLMP, BACnet) have
# mature Python client libraries and no vendored Rust crate, so they reuse
# this exact shape rather than inventing a new one:
#   1. A pure-Dart fixture host under `mobile/tool/<proto>_host_probe.dart`
#      that never imports the app's `ChangeNotifier`-based host service, and
#      prints `READY ...` on stdout once bound.
#   2. A third-party client probe under `tool/py/<proto>_probe.py` that
#      exits 0 with a `... PROBE PASS` line, or non-zero with a message
#      naming the failing step.
#   3. `tool/py/requirements.txt` with the client library pinned EXACTLY.
#   4. A copy of this script with the port, paths and probe name changed:
#      venv create/reuse under `tool/py/.venv`, quiet `pip install -r`,
#      READY handshake, unconditional teardown via `trap`, and the probe's
#      exit code propagated verbatim.
# The venv, its packages, and any `__pycache__` are git-ignored -- see
# `.gitignore`. Nothing downloaded here is ever committed.
#
# Usage: tool/enip_e2e.sh   (run from anywhere; bash/Git-Bash)
#
# PID NOTE (Windows/Git-Bash): `dart run` is a wrapper (`dart.bat`) that
# spawns a real `dart.exe` child; under MSYS/Git-Bash, `$!` is a synthetic
# MSYS job id, NOT the real Windows PID of that child, so `taskkill //PID
# $!` silently fails to find it and the real dart.exe keeps running (and
# keeps the port bound). This script instead finds the REAL Windows PID
# that is listening on the target port via `netstat -ano` and kills that
# (with `//T` to take any of its own children too), falling back to the
# bash job PID on non-Windows. Mirrors `tool/opcua_e2e.sh`.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=44900
PY_DIR="${REPO_ROOT}/tool/py"
VENV_DIR="${PY_DIR}/.venv"
DART_LOG="$(mktemp -t enip-e2e-dart-host.XXXXXX 2>/dev/null || echo /tmp/enip-e2e-dart-host.log)"
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

# --- Python lane: create or reuse the venv, install the pinned client ------
PY_BIN=""
for candidate in python python3 py; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    PY_BIN="${candidate}"
    break
  fi
done
if [ -z "${PY_BIN}" ]; then
  log "FAILED: no Python interpreter on PATH (need Python 3.8+ for pycomm3)."
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

log "installing pinned client library (tool/py/requirements.txt)..."
if ! "${VENV_PY}" -m pip install --quiet --disable-pip-version-check -r "${PY_DIR}/requirements.txt"; then
  log "FAILED: pip install of the pinned client library failed (no network,"
  log "proxy, or an unavailable version). This script does NOT fall back to a"
  log "hand-rolled client -- a real third-party client is the entire point."
  exit 1
fi
"${VENV_PY}" -c "import pycomm3; print('[e2e] pycomm3 version: ' + pycomm3.__version__)"

# --- Dart fixture host ----------------------------------------------------
log "starting Dart EtherNet/IP fixture host on port ${PORT} (log: ${DART_LOG})..."
(
  cd "${REPO_ROOT}/mobile" && exec dart run tool/enip_host_probe.dart "${PORT}"
) >"${DART_LOG}" 2>&1 &
DART_JOB_PID=$!

log "waiting for READY (bounded ~90s)..."
READY=0
for _ in $(seq 1 180); do
  if grep -q "READY enip-tcp://" "${DART_LOG}" 2>/dev/null; then
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
log "running the pycomm3 client probe against 127.0.0.1:${PORT}..."
# Every request is a loopback round trip and the probe bounds each socket
# operation at 5s itself; 120s is a generous outer bound that still cannot
# wedge CI if the probe somehow blocks outside a socket call.
timeout 120 "${VENV_PY}" "${PY_DIR}/enip_probe.py" 127.0.0.1 "${PORT}"
PROBE_EXIT=$?

log "probe exit code: ${PROBE_EXIT}"
exit "${PROBE_EXIT}"
