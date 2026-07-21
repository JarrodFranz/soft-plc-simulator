#!/usr/bin/env bash
# BACnet/IP E2E machine-proof (EXTENDED/full gate, Task 5 of the workstream):
# starts the in-app BACnet/IP host (the Dart fixture host,
# mobile/tool/bacnet_host_probe.dart) on a non-default UDP port, waits for it
# to report READY, then runs a REAL third-party BACnet/IP client --
# `bacpypes3`, driven by tool/py/bacnet_probe.py -- against it.
#
# AS OF THIS TASK, the fixture serves the REAL tag-backed object model
# (`BacnetTagImage`) -- a Device object plus 5 mapped Analog Value/Binary
# Value objects -- not the Task-3 minimal `BacnetSimpleImage`. This probe is
# therefore the authority on the FULL wire surface a shipped project exposes:
# Who-Is/I-Am, ReadProperty (incl. Object_List array-index reads),
# ReadPropertyMultiple (incl. a per-property embedded error inside an
# otherwise-successful batch), WriteProperty (plain and WITH a priority
# argument), the force/ReadOnly-gated write refusal, and the unknown-property
# error path -- exactly the same real-client-is-the-authority pattern
# `tool/fins_e2e.sh` and `tool/slmp_e2e.sh` established for their own
# byte-order/framing questions.
#
# CLIENT LIBRARY SUBSTITUTION: the plan specified BAC0/bacpypes (bacpypes
# 0.18.6's sync API); that pin fails to IMPORT on this venv's Python (3.12)
# because `bacpypes/core.py` does `import asyncore`, a module Python 3.12
# removed. This lane installs `bacpypes3` instead (an independent,
# asyncio-native reimplementation, NOT a shim over the old `bacpypes`) per the
# task's explicit fallback instruction -- see `tool/py/bacnet_probe.py`'s
# header and `tool/py/requirements.txt`'s comment for the full note.
#
# WHY THE FIXTURE HOST PROVES THE SHIPPED HOST: every response byte is
# produced by ONE shared pure function (`dispatchBacnetDatagram`,
# mobile/lib/protocols/bacnet/bacnet_dispatch.dart) that both the fixture host
# and `mobile/lib/services/bacnet_host.dart` call. The bytes this client
# validates are, by construction rather than by diff, the bytes the app emits.
#
# This follows the shared Python-lane pattern established by `tool/fins_e2e.sh`
# (see that file's header): a pure-Dart fixture host that never imports the
# app's ChangeNotifier-based host service and prints `READY ...` once bound; a
# third-party client probe exiting 0 with a `... PROBE PASS` line or non-zero
# naming the failing step; the client library pinned EXACTLY in
# `tool/py/requirements.txt`; venv create/reuse, quiet install, READY
# handshake, unconditional teardown via `trap`, and the probe's exit code
# propagated verbatim. The venv, its packages, and any `__pycache__` are
# git-ignored -- nothing downloaded here is ever committed.
#
# Usage: tool/bacnet_e2e.sh   (run from anywhere; bash/Git-Bash)
#
# PID NOTE (Windows/Git-Bash): `dart run` is a wrapper (`dart.bat`) that spawns
# a real `dart.exe` child; under MSYS/Git-Bash, `$!` is a synthetic MSYS job
# id, NOT the real Windows PID of that child, so `taskkill //PID $!` silently
# fails to find it and the real dart.exe keeps running (and keeps the port
# bound). This script instead finds the REAL Windows PID that is bound to the
# target UDP port via `netstat -ano` and kills that (with `//T` to take any of
# its own children too), falling back to the bash job PID on non-Windows.
# Mirrors `tool/fins_e2e.sh`, which greps for a UDP binding (no LISTENING
# state, unlike TCP).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Non-default: BACnet/IP's real port is 47808, which anything already hosting
# BACnet/IP would collide with.
PORT=47810
PY_DIR="${REPO_ROOT}/tool/py"
VENV_DIR="${PY_DIR}/.venv"
DART_LOG="$(mktemp -t bacnet-e2e-dart-host.XXXXXX 2>/dev/null || echo /tmp/bacnet-e2e-dart-host.log)"
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
  log "FAILED: no Python interpreter on PATH (need Python 3.8+ for bacpypes3)."
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
if ! "${VENV_PY}" -c "import bacpypes3; print('[e2e] bacpypes3 import OK')"; then
  log "FAILED: bacpypes3 failed to import from the venv (see traceback above)."
  exit 1
fi

# --- Dart fixture host ----------------------------------------------------
log "starting Dart BACnet/IP fixture host on UDP port ${PORT} (log: ${DART_LOG})..."
(
  cd "${REPO_ROOT}/mobile" && exec dart run tool/bacnet_host_probe.dart "${PORT}"
) >"${DART_LOG}" 2>&1 &
DART_JOB_PID=$!

log "waiting for READY (bounded ~90s)..."
READY=0
for _ in $(seq 1 180); do
  if grep -q "READY bacnet-udp://" "${DART_LOG}" 2>/dev/null; then
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
log "running the bacpypes3 client probe against 127.0.0.1:${PORT}..."
# Every request is a loopback round trip and the probe bounds each request at
# 10s itself; 120s is a generous outer bound that still cannot wedge CI if the
# probe somehow blocks outside a request call.
timeout 120 "${VENV_PY}" "${PY_DIR}/bacnet_probe.py" 127.0.0.1 "${PORT}"
PROBE_EXIT=$?

log "probe exit code: ${PROBE_EXIT}"
exit "${PROBE_EXIT}"
