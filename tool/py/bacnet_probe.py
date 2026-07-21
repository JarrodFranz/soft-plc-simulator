#!/usr/bin/env python3
"""Real third-party BACnet/IP client probe (Python lane) — EARLY gate.

Drives `bacpypes3` -- a real, third-party BACnet/IP implementation written
entirely independently of this project -- against this project's in-app
BACnet/IP host, as exercised by the Dart fixture host
`mobile/tool/bacnet_host_probe.dart`. This is the FIRST place in the BACnet/IP
workstream that a client written independently of us reads our wire bytes, and
it runs BEFORE the tag-backed object model exists (Task 3 of 5) -- the whole
point is to settle every open ASN.1-tag-encoding question (see
`mobile/lib/protocols/bacnet/bacnet_tags.dart`'s "TAG-STRUCTURE TRAP" note)
against an independent implementation while the blast radius of being wrong is
still small.

*** CLIENT LIBRARY SUBSTITUTION (report prominently) ***
The plan/brief specified `BAC0==22.9.21` + `bacpypes==0.18.6` (BAC0's sync
API, itself a wrapper around `bacpypes`). That pin FAILS TO INITIALIZE on this
venv's Python (3.12): `bacpypes/core.py` does `import asyncore`, a module the
standard library REMOVED in Python 3.12 (it was deprecated since 3.6). This
is not a transient install failure -- `pip install` succeeds, but every
`import bacpypes` raises `ModuleNotFoundError: No module named 'asyncore'`.

Per the task brief's explicit fallback instruction, this lane instead uses
`bacpypes3` (`pip install bacpypes3`, pinned in `tool/py/requirements.txt`) --
an independent, actively-maintained, asyncio-native reimplementation of the
BACnet/IP stack (not a shim over the old `bacpypes`; its APDU/tag codec is its
own). It is still a REAL third-party client, written without reference to this
project's Dart implementation, so the conformance proof this probe exists for
is unaffected by the substitution -- only the API shape (async, not BAC0's
sync wrapper) changed. This substitution was verified necessary and the
alternative verified working (Who-Is/I-Am + both reads passing end to end)
before this file was written.

WHAT THIS PROVES, in order:

  1. connect()        -- build a `bacpypes3.app.Application` bound to its OWN
                         local UDP port (127.0.0.1:47809, distinct from the
                         host's port so both can run on loopback
                         simultaneously). This only builds the client-side
                         BACnet/IP stack; no datagram is sent yet.
  2. who_is()          -- a directed (unicast) Who-Is at the fixture host,
                         asserting the fixture's device instance (3056) comes
                         back in an I-Am -- proving the BVLL/NPDU framing,
                         Who-Is encoding, and I-Am decoding all round-trip
                         through the CLIENT'S OWN parser, not just ours.
  3. read_property() objectName -- reads the fixture Device object's
                         Object_Name and asserts it EXACTLY against the value
                         the fixture host seeded independently of this client
                         (`BACNET-E2E-FIXTURE`) -- a CharacterString decode
                         through the client's own tag reader.
  4. read_property() presentValue -- reads the fixture's one Analog Value's
                         Present_Value and asserts it EXACTLY against 12.5,
                         the value the fixture SEEDED independently of this
                         client -- a Real (IEEE-754 float32) decode through
                         the client's own tag reader. This is what SETTLES the
                         Real/CharacterString/ObjectIdentifier tag encodings:
                         a client-built ReadProperty round-tripped through our
                         OWN encoder/decoder would prove nothing (see the
                         TAG-STRUCTURE TRAP note); reading a value seeded
                         independently of the client is a true conformance
                         check.

Usage: python bacnet_probe.py <host> <port>
"""

from __future__ import annotations

import asyncio
import sys
import traceback

# --- The fixture's layout ----------------------------------------------------
#
# Every constant below is pinned in `mobile/tool/bacnet_host_probe.dart`.
# Keep the two files in step.

FIXTURE_DEVICE_INSTANCE = 3056
FIXTURE_DEVICE_NAME = "BACNET-E2E-FIXTURE"
FIXTURE_AV_INSTANCE = 0
FIXTURE_AV_PRESENT_VALUE = 12.5

# This client's OWN local UDP port -- distinct from the fixture host's port so
# both can bind on loopback at the same time (per the task brief).
CLIENT_LOCAL_PORT = 47809

# An arbitrary device instance for the CLIENT's own (never-served) local
# device object -- distinct from the fixture's 3056 so a mix-up would be
# visible immediately.
CLIENT_DEVICE_INSTANCE = 599999

# How long any single confirmed-service round trip may take, in seconds.
# Every request here is a loopback round trip against a fixture host, so a
# stall means a hang, not slowness.
REQUEST_TIMEOUT_S = 10.0


class ProbeFailure(Exception):
    """Raised with a message naming the step that failed."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


async def run(host: str, port: int) -> None:
    # Imported inside `run` (not at module scope) so a missing/broken
    # `bacpypes3` install fails with a clear ProbeFailure at step 1 rather
    # than an opaque ImportError before `main` even runs its try/except.
    try:
        from bacpypes3.app import Application
        from bacpypes3.argparse import SimpleArgumentParser
        from bacpypes3.pdu import Address
    except Exception as err:  # noqa: BLE001 - reported verbatim below
        raise ProbeFailure(
            f"STEP 1 (import bacpypes3): could not import bacpypes3: {err!r}"
        ) from err

    # --- Step 1: connect (build the client's own BACnet/IP stack) ----------
    try:
        parser = SimpleArgumentParser()
        args = parser.parse_args(
            [
                "--address",
                f"127.0.0.1:{CLIENT_LOCAL_PORT}",
                "--instance",
                str(CLIENT_DEVICE_INSTANCE),
                "--name",
                "bacnet-e2e-probe",
            ]
        )
        app = Application.from_args(args)
    except Exception as err:  # noqa: BLE001 - reported verbatim below
        raise ProbeFailure(
            f"STEP 1 (connect): bacpypes3 could not build a local Application "
            f"bound to 127.0.0.1:{CLIENT_LOCAL_PORT}: {err!r}"
        ) from err
    print(f"[probe] step 1 OK: bacpypes3 Application bound to 127.0.0.1:{CLIENT_LOCAL_PORT}")

    try:
        target = Address(f"{host}:{port}")

        # --- Step 2: Who-Is -> I-Am --------------------------------------
        try:
            i_ams = await asyncio.wait_for(app.who_is(address=target), timeout=REQUEST_TIMEOUT_S)
        except asyncio.TimeoutError as err:
            raise ProbeFailure(
                f"STEP 2 (who_is): no I-Am from {target} within {REQUEST_TIMEOUT_S}s."
            ) from err
        except Exception as err:  # noqa: BLE001 - reported verbatim
            raise ProbeFailure(f"STEP 2 (who_is): request failed: {err!r}") from err

        instances = [i_am.iAmDeviceIdentifier[1] for i_am in i_ams]
        check(
            FIXTURE_DEVICE_INSTANCE in instances,
            f"STEP 2 (who_is): I-Am(s) received from {target} named device "
            f"instance(s) {instances!r}, expected to find "
            f"{FIXTURE_DEVICE_INSTANCE} (the fixture's Device_Object_Instance) "
            f"among them. A missing/wrong instance means the Who-Is/I-Am "
            f"ObjectIdentifier encoding disagrees with this independent client.",
        )
        print(f"[probe] step 2 OK: who_is at {target} -> I-Am device instance(s) {instances!r}")

        # --- Step 3: read the fixture Device object's Object_Name ---------
        try:
            name = await asyncio.wait_for(
                app.read_property(target, f"device,{FIXTURE_DEVICE_INSTANCE}", "objectName"),
                timeout=REQUEST_TIMEOUT_S,
            )
        except asyncio.TimeoutError as err:
            raise ProbeFailure(
                f"STEP 3 (read objectName): no response within {REQUEST_TIMEOUT_S}s."
            ) from err
        except Exception as err:  # noqa: BLE001 - reported verbatim
            raise ProbeFailure(f"STEP 3 (read objectName): request failed: {err!r}") from err

        check(
            str(name) == FIXTURE_DEVICE_NAME,
            f"STEP 3 (read objectName): device {FIXTURE_DEVICE_INSTANCE}'s "
            f"Object_Name read as {name!r}, expected {FIXTURE_DEVICE_NAME!r} "
            f"(the value the fixture host seeded independently of this "
            f"client). A mismatch means the CharacterString tag encoding "
            f"disagrees with this independent client.",
        )
        print(f"[probe] step 3 OK: device {FIXTURE_DEVICE_INSTANCE} objectName = {name!r}")

        # --- Step 4: read the seeded Analog Value's Present_Value ---------
        try:
            pv = await asyncio.wait_for(
                app.read_property(
                    target, f"analogValue,{FIXTURE_AV_INSTANCE}", "presentValue"
                ),
                timeout=REQUEST_TIMEOUT_S,
            )
        except asyncio.TimeoutError as err:
            raise ProbeFailure(
                f"STEP 4 (read presentValue): no response within {REQUEST_TIMEOUT_S}s."
            ) from err
        except Exception as err:  # noqa: BLE001 - reported verbatim
            raise ProbeFailure(f"STEP 4 (read presentValue): request failed: {err!r}") from err

        check(
            abs(float(pv) - FIXTURE_AV_PRESENT_VALUE) < 1e-6,
            f"STEP 4 (read presentValue): analogValue,{FIXTURE_AV_INSTANCE}'s "
            f"Present_Value read as {pv!r}, expected {FIXTURE_AV_PRESENT_VALUE!r} "
            f"(the value the fixture host SEEDED independently of this "
            f"client). This is the tag-encoding settler: a mismatch here "
            f"means the Real (IEEE-754 float32) encoding disagrees with this "
            f"independent client -- fix the Dart, not this probe.",
        )
        print(
            f"[probe] step 4 OK: analogValue,{FIXTURE_AV_INSTANCE} presentValue = "
            f"{float(pv)} (seeded {FIXTURE_AV_PRESENT_VALUE})"
        )
    finally:
        # --- teardown: close the client's local BACnet/IP stack -----------
        try:
            app.close()
        except Exception:  # noqa: BLE001 - teardown must not mask a real failure
            pass

    print("BACNET PROBE PASS")


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
        asyncio.run(run(host, port))
    except ProbeFailure as err:
        print(f"BACNET PROBE FAIL: {err}", file=sys.stderr)
        return 1
    except Exception as err:  # noqa: BLE001 - any unexpected error is a failure
        print(f"BACNET PROBE FAIL: unexpected error: {err!r}", file=sys.stderr)
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
