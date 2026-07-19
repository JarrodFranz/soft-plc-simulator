#!/usr/bin/env python3
"""Real third-party S7comm client probe (Python lane).

Drives the `python-snap7` library -- a Python wrapper around the snap7 C
library, a third-party S7comm implementation written entirely independently of
this project -- against this project's in-app S7comm host, as exercised by the
Dart fixture host `mobile/tool/s7_host_probe.dart`. This is the ONLY test in
the S7comm workstream that is not our codec talking to itself, so it -- not our
unit tests -- is the authority on wire details.

WHY THIS RUNS AT TASK 3 RATHER THAN LAST: the connect handshake is the part
built purely from specification text and never seen by a real client, so it is
proved BEFORE any read/write logic is written on top of it. At this stage the
probe deliberately covers only:

  1. connect()      -- TPKT/COTP Connection Request -> Connection Confirm, then
                       S7 Setup Communication -> its Ack_Data reply. snap7 does
                       BOTH inside connect(), so a single failure here means one
                       of them is wrong on the wire.
  2. get_connected() -- the client itself agrees the session is up.
  3. get_pdu_length() -- the PDU size snap7 parsed out of OUR Setup
                       Communication reply, asserted to be a sane negotiated
                       value. This is what catches a mislaid reply parameter
                       layout: connect() can succeed while the negotiated size
                       is garbage.
  4. disconnect()   -- clean teardown.

Read Var / Write Var / read-back coverage is added here in Task 5, once the tag
map and byte-image services exist.

Usage: python s7_probe.py <host> <port>
"""

from __future__ import annotations

import sys
import traceback

import snap7
from snap7.client import Client

# Rack/slot to connect with. This host is a simulator and accepts ANY rack and
# slot permissively -- rejecting a mismatch would give a confusing failure with
# no diagnostic value -- but the client must still send some pair, and these
# are the values that appear in the destination TSAP our host echoes back.
RACK = 0
SLOT = 2

# The negotiated PDU length must land EXACTLY on this device's documented
# maximum (`kS7MaxPduLength` in mobile/lib/protocols/s7/s7_pdu.dart). This
# client's own default proposal (see `client.pdu_length` before connect(),
# printed at step 3 below) is already 480, i.e. AT this device's maximum, so
# an exact match here is necessary to prove the reply parameter is read at
# the correct offset/byte-order, but it is NOT sufficient on its own to prove
# the server-side clamp itself fired (that would need a proposal ABOVE 480,
# which this snap7 version never sends by default -- see the note printed at
# step 3).
EXPECTED_PDU_LENGTH = 480

# How long any single snap7 socket operation may block, in milliseconds. Every
# request this probe issues is a single round trip against a loopback fixture
# host, so a stall means a hang, not slowness -- bounding it here is what keeps
# the probe from wedging the E2E script.
SOCKET_TIMEOUT_MS = 5000


class ProbeFailure(Exception):
    """Raised with a message naming the step that failed."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


def bound_timeouts(client: Client) -> None:
    """Bounds snap7's send/recv/ping waits so a wedged host cannot hang us.

    The parameter enum has moved between python-snap7 major versions, so each
    parameter is set independently and a missing one is reported rather than
    fatal -- the E2E script also wraps this process in an outer `timeout`, so a
    hang is contained either way.
    """
    for name in ("PingTimeout", "SendTimeout", "RecvTimeout"):
        param = getattr(snap7.type.Parameter, name, None)
        if param is None:
            print(f"[probe] note: snap7 has no Parameter.{name}; skipping")
            continue
        try:
            client.set_param(param, SOCKET_TIMEOUT_MS)
        except Exception as err:  # noqa: BLE001 - non-fatal, reported verbatim
            print(f"[probe] note: could not set {name}: {err!r}")


def run(host: str, port: int) -> None:
    client = Client()
    bound_timeouts(client)

    # snap7's own proposed PDU length, read BEFORE connect() overwrites
    # `client.pdu_length` with the NEGOTIATED value from our reply. This is
    # what the client actually sent in its Setup Communication request, for
    # the record -- printed so a future snap7 version proposing something
    # other than this device's maximum is visible rather than silently
    # making the exact-480 assertion below vacuous.
    proposed_pdu_length = getattr(client, "pdu_length", None)
    print(f"[probe] snap7's own proposed PDU length (pre-connect): {proposed_pdu_length!r}")

    # --- Step 1: connect (COTP CR/CC + S7 Setup Communication) ------------
    try:
        client.connect(host, RACK, SLOT, tcp_port=port)
    except Exception as err:  # noqa: BLE001 - reported verbatim below
        raise ProbeFailure(
            f"STEP 1 (connect): snap7 could not complete the COTP connect / S7 "
            f"Setup Communication handshake against {host}:{port}: {err!r}"
        ) from err
    print(f"[probe] step 1 OK: connected to {host}:{port} (rack={RACK}, slot={SLOT})")

    try:
        # --- Step 2: the client agrees the session is up ------------------
        check(
            client.get_connected(),
            "STEP 2 (get_connected): connect() returned but the client does not "
            "consider the session established",
        )
        print("[probe] step 2 OK: client reports the session is connected")

        # --- Step 3: the negotiated PDU length snap7 read off our reply ---
        pdu_length = client.get_pdu_length()
        check(
            isinstance(pdu_length, int),
            f"STEP 3 (negotiated PDU length): get_pdu_length() returned "
            f"{pdu_length!r}, which is not an integer",
        )
        check(
            pdu_length == EXPECTED_PDU_LENGTH,
            f"STEP 3 (negotiated PDU length): the client parsed {pdu_length} out "
            f"of our Setup Communication reply, not this device's documented "
            f"maximum ({EXPECTED_PDU_LENGTH}) -- either the reply parameter's "
            f"layout/byte order does not match what the client reads, or the "
            f"server-side clamp to kS7MaxPduLength did not fire as expected "
            f"(snap7 proposed {proposed_pdu_length!r})",
        )
        print(
            f"[probe] step 3 OK: negotiated PDU length is {pdu_length} "
            f"(snap7 proposed {proposed_pdu_length!r})"
        )
    finally:
        # --- Step 4: clean teardown ---------------------------------------
        try:
            client.disconnect()
        except Exception:  # noqa: BLE001 - teardown must not mask a real failure
            pass

    print("S7 PROBE PASS")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <host> <port>", file=sys.stderr)
        return 64
    host = argv[1]
    try:
        port = int(argv[2])
    except ValueError:
        print(f"invalid port: {argv[2]!r}", file=sys.stderr)
        return 64

    try:
        run(host, port)
    except ProbeFailure as err:
        print(f"S7 PROBE FAIL: {err}", file=sys.stderr)
        return 1
    except Exception as err:  # noqa: BLE001 - any unexpected error is a failure
        print(f"S7 PROBE FAIL: unexpected error: {err!r}", file=sys.stderr)
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
