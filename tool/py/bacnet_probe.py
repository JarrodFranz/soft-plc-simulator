#!/usr/bin/env python3
"""Real third-party BACnet/IP client probe (Python lane) — EXTENDED gate
(Task 5 of 5, the workstream's full E2E proof).

Drives `bacpypes3` -- a real, third-party BACnet/IP implementation written
entirely independently of this project -- against this project's in-app
BACnet/IP host, as exercised by the Dart fixture host
`mobile/tool/bacnet_host_probe.dart`. As of this task the fixture serves the
REAL tag-backed object model (`BacnetTagImage`), not the Task-3 minimal
`BacnetSimpleImage` -- so this probe is the authority on the FULL wire surface
a shipped project actually exposes: RPM's per-property embedded errors, both
write forms (plain and WITH a priority argument), the force/ReadOnly-gated
write refusal, and the unknown-property error path.

*** CLIENT LIBRARY SUBSTITUTION (unchanged since Task 3 -- see that note) ***
The plan/brief specified `BAC0==22.9.21` + `bacpypes==0.18.6`. That pin FAILS
TO INITIALIZE on this venv's Python (3.12): `bacpypes/core.py` does
`import asyncore`, a module the standard library REMOVED in Python 3.12. Per
the task brief's explicit fallback instruction, this lane instead uses
`bacpypes3` (pinned in `tool/py/requirements.txt`) -- an independent,
actively-maintained, asyncio-native reimplementation of the BACnet/IP stack
(not a shim over the old `bacpypes`). It is still a REAL third-party client,
so the conformance proof this probe exists for is unaffected -- only the API
shape (async, not BAC0's sync wrapper) changed.

*** TWO ENCODING DISPUTES THE CLIENT SETTLED AT THIS TASK (report prominently) ***
1. `read_property_multiple`'s `parameter_list` argument is NOT a list of
   `(objid, prop_list)` tuples despite its type hint reading that way -- the
   implementation destructures it as a FLAT, alternating sequence
   (`objid, prop_list, objid, prop_list, ...`) via `object_identifier,
   property_reference_list, *parameter_list = parameter_list`. Passing a list
   of 2-tuples raises `TypeError("objid")` immediately. This probe builds the
   flat form.
2. `read_property`/`write_property`'s OWN docstrings say they "return...the
   error, reject, or abort if that was received" -- true for a PER-PROPERTY
   embedded error inside an RPM ACK (an `ErrorType` value in the result
   tuple), but NOT true for a top-level Error/Reject/Abort APDU answering a
   single RP/WP request: `Application.request()` RAISES that as a Python
   exception (`bacpypes3.apdu.Error`, a subclass of the library's
   `ErrorRejectAbortNack`, which is itself (surprisingly) a `BaseException`
   subclass via its MRO) rather than returning it. This probe catches
   `ErrorRejectAbortNack` around every RP/WP call that expects a possible
   refusal, and reads `.errorClass`/`.errorCode` straight off the caught
   exception (both attributes ARE present on it).
Both were verified interactively against the running fixture before this
file was written (see the PR/commit description for the transcript).

WHAT THIS PROVES, in order (steps 1-4 are the ORIGINAL Task-3 EARLY-gate
proof, now running against the REAL `BacnetTagImage` rather than the minimal
fixture image -- unchanged assertions, new object model underneath):

  1. connect()            -- build a `bacpypes3.app.Application` bound to its
                             OWN local UDP port.
  2. who_is()              -- a directed (unicast) Who-Is at the fixture,
                             asserting device instance 3056 comes back.
  3. read objectName       -- the Device object's Object_Name, seeded
                             independently ("BACNET-E2E-FIXTURE").
  4. Object_List           -- the WHOLE array (6 objects: device + 5 mapped
                             AV/BV), index 0 (the count, 6), and index 1 (the
                             Device object itself) -- the array-index
                             indirection path through a REAL client.
  5. seeded AV/BV reads    -- Analog Value 0's Present_Value (12.5, seeded
                             independently) and Binary Value 0's Present_Value
                             (active/true, seeded independently).
  6. RPM batch             -- one ReadPropertyMultiple spanning the Device,
                             the write-target AV, and a BV property this
                             device does NOT serve (`description`) -- asserts
                             the unsupported property surfaces as an embedded
                             `ErrorType` INSIDE the ack (not a whole-request
                             failure) while the other two items still return
                             real values.
  7. write AV + read-back  -- WriteProperty a NEW value onto the AV write
                             target, then an INDEPENDENT ReadProperty proves
                             it landed (through the host, not just the model).
  8. write BV w/ priority + read-back -- WriteProperty the BV write target
                             carrying an explicit `priority` argument (accepted
                             and IGNORED per the write-gate's documented
                             semantics), then reads it back.
  9. ReadOnly-mapped AV write -- refused: `write_property` raises
                             `ErrorRejectAbortNack` (errorClass=property,
                             errorCode=write-access-denied per this device's
                             gate), and an independent read-back proves the
                             value is UNCHANGED.
  10. unknown property     -- reading a property (`description`) this device
                             does not serve on an object it DOES serve raises
                             `ErrorRejectAbortNack` (errorCode=unknown-property).

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

# AV 0 / BV 0 -- seeded-read targets (ReadOnly-mapped; never written by this
# probe, so their seeded values stay stable for the whole run).
AV0_INSTANCE = 0
AV0_SEED_VALUE = 12.5
BV0_INSTANCE = 0
BV0_SEED_ACTIVE = True

# AV 1 / BV 1 -- write + independent-read-back targets (ReadWrite-mapped).
AV1_INSTANCE = 1
AV1_INITIAL_VALUE = 5.0
AV1_WRITE_VALUE = 21.5
BV1_INSTANCE = 1
BV1_WRITE_PRIORITY = 8

# AV 2 -- the ReadOnly-MAPPED refused-write target.
AV2_INSTANCE = 2
AV2_VALUE = 42.0

# Device + 5 mapped AV/BV objects.
EXPECTED_OBJECT_LIST_LENGTH = 6

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
        from bacpypes3.apdu import ErrorRejectAbortNack
        from bacpypes3.argparse import SimpleArgumentParser
        from bacpypes3.basetypes import ErrorType
        from bacpypes3.pdu import Address
    except Exception as err:  # noqa: BLE001 - reported verbatim below
        raise ProbeFailure(
            f"STEP 1 (import bacpypes3): could not import bacpypes3: {err!r}"
        ) from err

    async def timed(awaitable, step_label: str):
        """Awaits `awaitable` under `REQUEST_TIMEOUT_S`, translating a timeout
        into a `ProbeFailure` naming `step_label` (every request below is a
        loopback round trip, so a timeout means a hang, not slowness)."""
        try:
            return await asyncio.wait_for(awaitable, timeout=REQUEST_TIMEOUT_S)
        except asyncio.TimeoutError as err:
            raise ProbeFailure(
                f"{step_label}: no response within {REQUEST_TIMEOUT_S}s."
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
            i_ams = await timed(app.who_is(address=target), "STEP 2 (who_is)")
        except ProbeFailure:
            raise
        except Exception as err:  # noqa: BLE001 - reported verbatim
            raise ProbeFailure(f"STEP 2 (who_is): request failed: {err!r}") from err

        instances = [i_am.iAmDeviceIdentifier[1] for i_am in i_ams]
        check(
            FIXTURE_DEVICE_INSTANCE in instances,
            f"STEP 2 (who_is): I-Am(s) received from {target} named device "
            f"instance(s) {instances!r}, expected to find "
            f"{FIXTURE_DEVICE_INSTANCE} (the fixture's Device_Object_Instance) "
            f"among them.",
        )
        print(f"[probe] step 2 OK: who_is at {target} -> I-Am device instance(s) {instances!r}")

        # --- Step 3: read the Device object's Object_Name -----------------
        name = await timed(
            app.read_property(target, f"device,{FIXTURE_DEVICE_INSTANCE}", "objectName"),
            "STEP 3 (read objectName)",
        )
        check(
            str(name) == FIXTURE_DEVICE_NAME,
            f"STEP 3 (read objectName): device {FIXTURE_DEVICE_INSTANCE}'s "
            f"Object_Name read as {name!r}, expected {FIXTURE_DEVICE_NAME!r}.",
        )
        print(f"[probe] step 3 OK: device {FIXTURE_DEVICE_INSTANCE} objectName = {name!r}")

        # --- Step 4: Object_List -- whole, index 0 (count), index 1 -------
        object_list = await timed(
            app.read_property(target, f"device,{FIXTURE_DEVICE_INSTANCE}", "objectList"),
            "STEP 4a (read objectList whole)",
        )
        check(
            len(object_list) == EXPECTED_OBJECT_LIST_LENGTH,
            f"STEP 4a (read objectList whole): expected "
            f"{EXPECTED_OBJECT_LIST_LENGTH} objects (device + 5 mapped AV/BV), "
            f"got {len(object_list)}: {object_list!r}.",
        )
        object_list_count = await timed(
            app.read_property(
                target, f"device,{FIXTURE_DEVICE_INSTANCE}", "objectList", array_index=0
            ),
            "STEP 4b (read objectList[0], the count)",
        )
        check(
            int(object_list_count) == EXPECTED_OBJECT_LIST_LENGTH,
            f"STEP 4b (read objectList[0]): expected the count "
            f"{EXPECTED_OBJECT_LIST_LENGTH}, got {object_list_count!r}.",
        )
        object_list_first = await timed(
            app.read_property(
                target, f"device,{FIXTURE_DEVICE_INSTANCE}", "objectList", array_index=1
            ),
            "STEP 4c (read objectList[1], one indexed entry)",
        )
        check(
            str(object_list_first[0]) == "device" and int(object_list_first[1]) == FIXTURE_DEVICE_INSTANCE,
            f"STEP 4c (read objectList[1]): expected the Device object itself "
            f"(device,{FIXTURE_DEVICE_INSTANCE}), got {object_list_first!r}.",
        )
        print(
            f"[probe] step 4 OK: objectList whole ({len(object_list)} objects), "
            f"[0]={object_list_count}, [1]={object_list_first}"
        )

        # --- Step 5: seeded AV/BV Present_Value reads ----------------------
        av0_value = await timed(
            app.read_property(target, f"analogValue,{AV0_INSTANCE}", "presentValue"),
            "STEP 5a (read seeded AV presentValue)",
        )
        check(
            abs(float(av0_value) - AV0_SEED_VALUE) < 1e-6,
            f"STEP 5a (read seeded AV presentValue): analogValue,{AV0_INSTANCE} "
            f"read as {av0_value!r}, expected {AV0_SEED_VALUE!r} (seeded "
            f"independently of this client). A mismatch means the Real "
            f"(IEEE-754 float32) encoding disagrees with this independent client.",
        )
        bv0_value = await timed(
            app.read_property(target, f"binaryValue,{BV0_INSTANCE}", "presentValue"),
            "STEP 5b (read seeded BV presentValue)",
        )
        check(
            bool(int(bv0_value)) == BV0_SEED_ACTIVE,
            f"STEP 5b (read seeded BV presentValue): binaryValue,{BV0_INSTANCE} "
            f"read as {bv0_value!r}, expected active={BV0_SEED_ACTIVE!r} (seeded "
            f"independently of this client).",
        )
        print(
            f"[probe] step 5 OK: analogValue,{AV0_INSTANCE} presentValue = "
            f"{float(av0_value)}; binaryValue,{BV0_INSTANCE} presentValue = {bv0_value}"
        )

        # --- Step 6: RPM batch -- device + AV + an unsupported BV property -
        # NOTE the flat parameter_list shape (objid, prop_list, objid,
        # prop_list, ...) -- see this file's header note #1.
        rpm_result = await timed(
            app.read_property_multiple(
                target,
                [
                    f"device,{FIXTURE_DEVICE_INSTANCE}",
                    ["objectName"],
                    f"analogValue,{AV1_INSTANCE}",
                    ["presentValue"],
                    f"binaryValue,{BV0_INSTANCE}",
                    ["description"],  # NOT served by this device -> embedded error
                ],
            ),
            "STEP 6 (read_property_multiple batch)",
        )
        check(
            len(rpm_result) == 3,
            f"STEP 6 (RPM batch): expected 3 result items, got {len(rpm_result)}: {rpm_result!r}.",
        )
        device_item, av_item, bv_item = rpm_result
        check(
            str(device_item[3]) == FIXTURE_DEVICE_NAME and not isinstance(device_item[3], ErrorType),
            f"STEP 6 (RPM batch): the Device objectName item should be a real "
            f"value ({FIXTURE_DEVICE_NAME!r}), got {device_item!r}.",
        )
        check(
            not isinstance(av_item[3], ErrorType) and abs(float(av_item[3]) - AV1_INITIAL_VALUE) < 1e-6,
            f"STEP 6 (RPM batch): the AV presentValue item should be a real "
            f"value ({AV1_INITIAL_VALUE!r}), got {av_item!r}.",
        )
        check(
            isinstance(bv_item[3], ErrorType),
            f"STEP 6 (RPM batch): the unsupported `description` property on "
            f"binaryValue,{BV0_INSTANCE} should surface as an EMBEDDED error "
            f"inside the ack (not a whole-request failure) -- got {bv_item!r}, "
            f"expected an ErrorType in position 3.",
        )
        print(
            f"[probe] step 6 OK: RPM batch of 3 -- 2 real values + 1 embedded "
            f"error ({bv_item[3]!r}), the whole batch still answered"
        )

        # --- Step 7: write AV + independent read-back ---------------------
        write_result = await timed(
            app.write_property(target, f"analogValue,{AV1_INSTANCE}", "presentValue", AV1_WRITE_VALUE),
            "STEP 7a (write AV presentValue)",
        )
        check(
            write_result is None,
            f"STEP 7a (write AV presentValue): expected a plain SimpleAck "
            f"(None), got {write_result!r}.",
        )
        av1_readback = await timed(
            app.read_property(target, f"analogValue,{AV1_INSTANCE}", "presentValue"),
            "STEP 7b (independent read-back of AV presentValue)",
        )
        check(
            abs(float(av1_readback) - AV1_WRITE_VALUE) < 1e-6,
            f"STEP 7b (independent read-back): analogValue,{AV1_INSTANCE} read "
            f"back as {av1_readback!r}, expected the just-written "
            f"{AV1_WRITE_VALUE!r}.",
        )
        print(
            f"[probe] step 7 OK: wrote analogValue,{AV1_INSTANCE} = "
            f"{AV1_WRITE_VALUE}, independent read-back confirms {float(av1_readback)}"
        )

        # --- Step 8: write BV WITH a priority argument + read-back --------
        write_bv_result = await timed(
            app.write_property(
                target,
                f"binaryValue,{BV1_INSTANCE}",
                "presentValue",
                "active",
                priority=BV1_WRITE_PRIORITY,
            ),
            "STEP 8a (write BV presentValue WITH a priority argument)",
        )
        check(
            write_bv_result is None,
            f"STEP 8a (write BV w/ priority): expected a plain SimpleAck "
            f"(None) -- priority is ACCEPTED and IGNORED by this device's "
            f"write gate, not rejected -- got {write_bv_result!r}.",
        )
        bv1_readback = await timed(
            app.read_property(target, f"binaryValue,{BV1_INSTANCE}", "presentValue"),
            "STEP 8b (independent read-back of BV presentValue)",
        )
        check(
            bool(int(bv1_readback)) is True,
            f"STEP 8b (independent read-back): binaryValue,{BV1_INSTANCE} read "
            f"back as {bv1_readback!r}, expected active/true (the just-written "
            f"value -- the priority argument must be accepted, not refused).",
        )
        print(
            f"[probe] step 8 OK: wrote binaryValue,{BV1_INSTANCE} = active "
            f"WITH priority={BV1_WRITE_PRIORITY}, independent read-back confirms {bv1_readback}"
        )

        # --- Step 9: ReadOnly-mapped AV write -- refused, value unchanged --
        try:
            await timed(
                app.write_property(target, f"analogValue,{AV2_INSTANCE}", "presentValue", 1.0),
                "STEP 9a (write ReadOnly-mapped AV)",
            )
            raise ProbeFailure(
                f"STEP 9a (write ReadOnly-mapped AV): expected the write to "
                f"analogValue,{AV2_INSTANCE} (a ReadOnly-mapped object) to be "
                f"REFUSED with a BACnet error, but it succeeded."
            )
        except ProbeFailure:
            raise
        except ErrorRejectAbortNack as err:
            error_class = getattr(err, "errorClass", None)
            error_code = getattr(err, "errorCode", None)
            check(
                str(error_class) == "property" and str(error_code) == "write-access-denied",
                f"STEP 9a (write ReadOnly-mapped AV): expected "
                f"errorClass=property/errorCode=write-access-denied, got "
                f"errorClass={error_class!r}/errorCode={error_code!r} ({err!r}).",
            )
        av2_unchanged = await timed(
            app.read_property(target, f"analogValue,{AV2_INSTANCE}", "presentValue"),
            "STEP 9b (read-back confirming AV2 is unchanged)",
        )
        check(
            abs(float(av2_unchanged) - AV2_VALUE) < 1e-6,
            f"STEP 9b (read-back after refused write): analogValue,{AV2_INSTANCE} "
            f"read as {av2_unchanged!r}, expected the ORIGINAL (unwritten) "
            f"value {AV2_VALUE!r} -- the refused write must not have landed.",
        )
        print(
            f"[probe] step 9 OK: write to ReadOnly-mapped analogValue,{AV2_INSTANCE} "
            f"was REFUSED (property/write-access-denied), value unchanged at {float(av2_unchanged)}"
        )

        # --- Step 10: unknown property -> error ----------------------------
        try:
            await timed(
                app.read_property(target, f"analogValue,{AV0_INSTANCE}", "description"),
                "STEP 10 (read unknown property)",
            )
            raise ProbeFailure(
                f"STEP 10 (read unknown property): expected reading "
                f"`description` (a property this device does not serve on "
                f"analogValue,{AV0_INSTANCE}) to fail with a BACnet error, but "
                f"it succeeded."
            )
        except ProbeFailure:
            raise
        except ErrorRejectAbortNack as err:
            error_class = getattr(err, "errorClass", None)
            error_code = getattr(err, "errorCode", None)
            check(
                str(error_class) == "property" and str(error_code) == "unknown-property",
                f"STEP 10 (read unknown property): expected "
                f"errorClass=property/errorCode=unknown-property, got "
                f"errorClass={error_class!r}/errorCode={error_code!r} ({err!r}).",
            )
        print("[probe] step 10 OK: reading an unsupported property surfaced a BACnet error")
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
