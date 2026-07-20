#!/usr/bin/env bash
# SLMP-over-TCP E2E machine-proof: starts the in-app SLMP host (the Dart fixture
# host, mobile/tool/slmp_host_probe.dart) on a non-default TCP port, waits for it
# to report READY, then runs a REAL third-party MC-protocol client -- the
# pure-Python `pymcprotocol` library, driven by tool/py/slmp_probe.py -- against
# it.
#
# WHAT THIS PROVES that the Dart unit suite cannot: every other SLMP test in this
# repo exercises our codec against frames our codec built, which proves
# self-consistency, not conformance. This script is the only place a client
# written independently of us reads our wire bytes. It runs EARLY (Task 3),
# before any tag-map logic exists, precisely so the framing is settled against a
# real client at the earliest point: it drives a batch read of a known D word and
# asserts the value, exercising the big-endian subheader vs little-endian body,
# the 3-byte little-endian device number, the D/W device codes, the 0x0000 end
# code, and -- the wire question this task settles -- the 3E length convention
# (`total = 9 + requestDataLength`, the length field EXCLUDING the fixed header).
#
# WHY THE FIXTURE HOST PROVES THE SHIPPED HOST: every response byte is produced by
# ONE shared pure function (`dispatchSlmpFrame`,
# mobile/lib/protocols/slmp/slmp_dispatch.dart) that both the fixture host and
# `mobile/lib/services/slmp_host.dart` call. The bytes this client validates are,
# by construction rather than by diff, the bytes the app emits.
#
# This follows the shared Python-lane pattern established by `tool/s7_e2e.sh` and
# `tool/fins_e2e.sh`: a pure-Dart fixture host that never imports the app's
# ChangeNotifier-based host service and prints `READY ...` once bound; a
# third-party client probe exiting 0 with a `... PROBE PASS` line or non-zero
# naming the failing step; the client library pinned EXACTLY in
# tool/py/requirements.txt; venv create/reuse, quiet install, READY handshake,
# unconditional teardown via `trap`, and the probe's exit code propagated
# verbatim. The venv, its packages, and any `__pycache__` are git-ignored --
# nothing downloaded here is ever committed.
#
# Usage: tool/slmp_e2e.sh   (run from anywhere; bash/Git-Bash)
#
# PID NOTE (Windows/Git-Bash): `dart run` is a wrapper (`dart.bat`) that spawns a
# real `dart.exe` child; under MSYS/Git-Bash, `$!` is a synthetic MSYS job id,
# NOT the real Windows PID of that child, so `taskkill //PID $!` silently fails to
# find it and the real dart.exe keeps running (and keeps the port bound). This
# script instead finds the REAL Windows PID LISTENING on the target TCP port via
# `netstat -ano` and kills that (with `//T` to take any of its own children too),
# falling back to the bash job PID on non-Windows. Mirrors `tool/s7_e2e.sh`
# (TCP), not the FINS UDP variant.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Non-default: the config default the SLMP host ships with is 5007 (see
# kSlmpDefaultPort), which a running instance would collide with. 15007 keeps it
# clear.
PORT=15007
PY_DIR="${REPO_ROOT}/tool/py"
VENV_DIR="${PY_DIR}/.venv"
DART_LOG="$(mktemp -t slmp-e2e-dart-host.XXXXXX 2>/dev/null || echo /tmp/slmp-e2e-dart-host.log)"
DART_JOB_PID=""

log() { echo "[e2e] $*"; }

find_tcp_pid() {
  # The Windows PID LISTENING on the target TCP port.
  if command -v netstat >/dev/null 2>&1; then
    netstat -ano 2>/dev/null | grep -i "LISTENING" | grep ":${PORT} " | awk '{print $NF}' | head -n1
  fi
}

cleanup() {
  log "cleaning up..."
  local real_pid
  real_pid="$(find_tcp_pid)"
  if [ -n "${real_pid}" ] && command -v taskkill >/dev/null 2>&1; then
    log "killing dart host by real Windows PID ${real_pid} (owns TCP port ${PORT})..."
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
  log "FAILED: no Python interpreter on PATH (need Python 3.8+ for pymcprotocol)."
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
if ! "${VENV_PY}" -c "import pymcprotocol; print('[e2e] pymcprotocol import OK')"; then
  log "FAILED: pymcprotocol failed to import from the venv (see traceback above)."
  exit 1
fi

# --- Dart fixture host ----------------------------------------------------
log "starting Dart SLMP fixture host on TCP port ${PORT} (log: ${DART_LOG})..."
(
  cd "${REPO_ROOT}/mobile" && exec dart run tool/slmp_host_probe.dart "${PORT}"
) >"${DART_LOG}" 2>&1 &
DART_JOB_PID=$!

log "waiting for READY (bounded ~90s)..."
READY=0
for _ in $(seq 1 180); do
  if grep -q "READY slmp-tcp://" "${DART_LOG}" 2>/dev/null; then
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
log "running the pymcprotocol client probe against 127.0.0.1:${PORT}..."
# Every request is a loopback round trip and the probe bounds each socket
# operation at 5s itself; 120s is a generous outer bound that still cannot wedge
# CI if the probe somehow blocks outside a socket call.
timeout 120 "${VENV_PY}" "${PY_DIR}/slmp_probe.py" 127.0.0.1 "${PORT}"
PROBE_EXIT=$?

log "probe exit code: ${PROBE_EXIT}"
exit "${PROBE_EXIT}"
