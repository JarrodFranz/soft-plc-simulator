#!/usr/bin/env python3
"""Real third-party EtherNet/IP + CIP client probe (Python lane).

Drives the `pycomm3` library -- a third-party EtherNet/IP + CIP client written
from the public CIP specification entirely independently of this project --
against this project's in-app EtherNet/IP host, as exercised by the Dart
fixture host `mobile/tool/enip_host_probe.dart`. This is the ONLY test in the
EtherNet/IP workstream that is not our codec talking to itself, so it -- not
our unit tests -- is the authority on wire details.

Sequence proved end to end (every step asserted; any failure exits non-zero
with a message naming the step):

  1. RegisterSession                     (encapsulation command 0x65)
  2. Forward Open                        (Connection Manager service 0x54)
     pycomm3 attempts the Large Forward Open (0x5B) first; this host does not
     implement it, replies "Service Not Supported" (0x08), and pycomm3 falls
     back to the regular Forward Open -- so the fallback path is proved too.
  3. Read Tag  (0x4C) over CONNECTED messaging   (SendUnitData, 0x70)
  4. Write Tag (0x4D) over CONNECTED messaging
  5. INDEPENDENT read-back asserting the EXACT written value
  6. Read Tag over UNCONNECTED messaging          (SendRRData/UCMM, 0x6F)
  7. Refusal semantics: ReadOnly-mapped write and forced-tag write are both
     refused with CIP general status 0x0F (Privilege Violation) and leave the
     value unchanged; an unmapped tag name returns 0x05.
  8. Symbol Object browse: Get Instance Attribute List (0x55) walked over the
     Symbol Object (class 0x6B), asserting every fixture tag's name + CIP type
     code. This is the generic-messaging tag-directory upload -- the same path
     LogixDriver walks -- proved WITHOUT LogixDriver.open() (a later task).
  9. Forward Close (0x4E), then UnRegisterSession (0x66)

USING pycomm3's LOWER-LEVEL GENERIC CIP MESSAGING (NOT `LogixDriver`)
---------------------------------------------------------------------
`LogixDriver` uploads a controller tag list at connect time via the Symbol
and Template objects, which this host defers to v2 -- it would fail before
reaching any read or write. This probe therefore uses `CIPDriver`, its
session/Forward-Open machinery, and its request/response packet classes
directly.

ONE HONEST LIMITATION, REPORTED RATHER THAN WORKED AROUND: `CIPDriver.
generic_message()` builds its request path from `class_code`/`instance`
through `pycomm3.packets.util.request_path()`, which emits only LOGICAL
segments (Class/Instance/Attribute). It has no parameter that emits an ANSI
Extended Symbol segment (0x91), which is what SYMBOLIC tag addressing -- the
addressing mode this host implements in v1 -- requires. So `generic_message`
cannot express a symbolic Read/Write Tag at all, for any target.

Rather than hand-build bytes, this probe uses pycomm3's OWN symbolic
tag-path builder, `pycomm3.packets.util.tag_request_path()` (the exact
function `LogixDriver` itself calls to address a tag by name), and pycomm3's
own request/response packet classes, submitted through `CIPDriver.send()`.
Everything on the wire -- the encapsulation header, session handling, CPF
item framing, connection sequence counts, response parsing and CIP status
decoding -- is still produced and consumed by pycomm3, not by us. The single
`_setup_message` override below swaps `request_path(...)` (logical) for
`tag_request_path(...)` (symbolic); both are pycomm3 functions.

Usage: python enip_probe.py <host> <port>
"""

from __future__ import annotations

import sys
import traceback

from pycomm3 import BOOL, DINT, INT, LINT, REAL, UINT, CIPDriver, Services
from pycomm3.cip_driver import with_forward_open
from pycomm3.packets import (
    GenericConnectedRequestPacket,
    GenericUnconnectedRequestPacket,
    SendRRDataRequestPacket,
    SendUnitDataRequestPacket,
)
from pycomm3.packets.util import tag_request_path

# --- Fixture expectations -------------------------------------------------
#
# These mirror the constants at the top of `mobile/tool/enip_host_probe.dart`.
# Changing one there without changing it here breaks the E2E, deliberately.

SPEED_INITIAL = 100
SPEED_WRITTEN = 123456  # outside 16-bit range: catches a truncating DINT path
RUNNING_INITIAL = True
COUNT16_INITIAL = -1234
TOTAL64_INITIAL = 8589934592  # 2^33: needs the full 64 bits
LEVEL_INITIAL = 12.5  # exactly representable as IEEE-754 single precision
TEMP_INITIAL = 21.75
FORCED_SPEED_FORCED = 777

# CIP general status codes asserted by this probe.
CIP_SUCCESS = 0x00
CIP_PARTIAL_TRANSFER = 0x06  # more Symbol instances remain; re-request from last_id + 1
CIP_PATH_DESTINATION_UNKNOWN = 0x05
CIP_PRIVILEGE_VIOLATION = 0x0F

# The Symbol Object (class 0x6B) directory the fixture host exposes: every
# mapped tag as a flat atomic symbol, {name: CIP type code}. Mirrors the
# CipMap in `mobile/tool/enip_host_probe.dart`; the `.code` values come from
# pycomm3's OWN elementary-type classes, so this cross-checks our type codes
# against a third party's, not against ourselves.
EXPECTED_SYMBOLS = {
    "Running": BOOL.code,   # 0xC1
    "Count16": INT.code,    # 0xC3
    "Speed": DINT.code,     # 0xC4
    "Total64": LINT.code,   # 0xC5
    "Level": REAL.code,     # 0xCA
    "Temp": REAL.code,      # 0xCA (ReadOnly-mapped, but still browsable)
    "Forced_Speed": DINT.code,  # 0xC4
}

# CIP service code for Get Instance Attribute List, the Symbol Object browse.
CIP_SERVICE_GET_INSTANCE_ATTRIBUTE_LIST = 0x55
# The Symbol Object class id, and its two attributes the browse requests:
# attr 1 (symbol name) and attr 2 (symbol type).
CIP_SYMBOL_OBJECT_CLASS = 0x6B
CIP_SYMBOL_ATTR_NAME = 1
CIP_SYMBOL_ATTR_TYPE = 2

# How long any single socket operation may block, in seconds. Every request
# this probe issues is a single round trip against a loopback fixture host,
# so a stall means a hang, not slowness -- bounding it here is what keeps the
# probe from wedging the E2E script.
SOCKET_TIMEOUT = 5.0


class ProbeFailure(Exception):
    """Raised with a message naming the step that failed."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


class SymbolicConnectedRequest(GenericConnectedRequestPacket):
    """A connected (SendUnitData) CIP request addressed by SYMBOLIC tag name.

    Identical to pycomm3's `GenericConnectedRequestPacket` except that the
    request path comes from pycomm3's `tag_request_path()` (an ANSI Extended
    Symbol segment) instead of `request_path()` (logical segments). See this
    module's docstring for why the override is necessary.
    """

    def __init__(self, sequence, service, tag: str, request_data: bytes = b""):
        super().__init__(
            sequence=sequence,
            service=service,
            class_code=b"\x02",  # unused: the path is replaced below
            instance=b"\x01",
            request_data=request_data,
        )
        self._tag_path = tag_request_path(tag, {}, False)

    def _setup_message(self):
        SendUnitDataRequestPacket._setup_message(self)
        self._msg += [self.service, self._tag_path, self.request_data]


class SymbolicUnconnectedRequest(GenericUnconnectedRequestPacket):
    """The UCMM (SendRRData) counterpart of `SymbolicConnectedRequest`."""

    def __init__(self, service, tag: str, request_data: bytes = b""):
        super().__init__(
            service=service,
            class_code=b"\x02",  # unused: the path is replaced below
            instance=b"\x01",
            request_data=request_data,
        )
        self._tag_path = tag_request_path(tag, {}, False)

    def _setup_message(self):
        SendRRDataRequestPacket._setup_message(self)
        self._msg += [self.service, self._tag_path, self.request_data]


def read_tag(driver: CIPDriver, tag: str, connected: bool = True):
    """Issues a CIP Read Tag (0x4C) for `tag`.

    Returns `(service_status, type_code, value_bytes)`. `type_code` and
    `value_bytes` are `None` when the request did not succeed.
    """
    request_data = UINT.encode(1)  # element count
    if connected:
        request = SymbolicConnectedRequest(
            driver._sequence, Services.read_tag, tag, request_data
        )
    else:
        request = SymbolicUnconnectedRequest(Services.read_tag, tag, request_data)
    response = driver.send(request)
    status = response.service_status
    if status != CIP_SUCCESS:
        return status, None, None
    data = response.data
    check(
        data is not None and len(data) >= 2,
        f"Read Tag {tag!r} succeeded but returned {len(data or b'')} reply bytes "
        f"(expected at least the 2-byte type code)",
    )
    return status, UINT.decode(data[:2]), data[2:]


def write_tag(driver: CIPDriver, tag: str, type_code: int, value_bytes: bytes,
              connected: bool = True) -> int:
    """Issues a CIP Write Tag (0x4D). Returns the CIP general status."""
    request_data = UINT.encode(type_code) + UINT.encode(1) + value_bytes
    if connected:
        request = SymbolicConnectedRequest(
            driver._sequence, Services.write_tag, tag, request_data
        )
    else:
        request = SymbolicUnconnectedRequest(Services.write_tag, tag, request_data)
    return driver.send(request).service_status


def expect_read(driver: CIPDriver, tag: str, decoder, expected, label: str,
                connected: bool = True):
    status, type_code, value_bytes = read_tag(driver, tag, connected=connected)
    check(
        status == CIP_SUCCESS,
        f"{label}: Read Tag {tag!r} returned CIP general status "
        f"0x{status:02X}, expected 0x00 (success)",
    )
    check(
        type_code == decoder.code,
        f"{label}: Read Tag {tag!r} returned CIP type code 0x{type_code:02X}, "
        f"expected 0x{decoder.code:02X} ({decoder.__name__})",
    )
    value = decoder.decode(value_bytes)
    check(
        value == expected,
        f"{label}: Read Tag {tag!r} returned {value!r}, expected {expected!r}",
    )
    return value


def symbol_browse(driver: CIPDriver) -> dict[str, int]:
    """Browses the Symbol Object (class 0x6B) via Get Instance Attribute List
    (service 0x55) over CONNECTED messaging, returning ``{name: type_code}``.

    Unlike the Read/Write Tag steps, the Symbol browse addresses a LOGICAL
    object path (class 0x6B + instance) rather than a symbolic tag name, so it
    needs no `tag_request_path` override -- pycomm3's stock
    `GenericConnectedRequestPacket` encodes exactly that logical path. We build
    and `driver.send()` the packet directly (rather than `generic_message`,
    which returns a `Tag` with no `service_status`) so we can read both the CIP
    general status and the raw reply bytes off pycomm3's own response packet.

    `data_type=None` makes pycomm3 hand back the raw CIP reply data verbatim in
    `response.value`; this probe -- not our codec -- parses it as the repeated
    `instance(u32) + name_len(u16) + name(ascii) + type(u16)` layout, so a
    wrong string layout in `cip_symbol.dart` surfaces here as garbage names.
    Status 0x06 (Partial Transfer) means more instances remain: re-request from
    `last_id + 1` until 0x00, accumulating instances across pages.
    """
    request_data = (
        UINT.encode(2)  # attribute count
        + UINT.encode(CIP_SYMBOL_ATTR_NAME)
        + UINT.encode(CIP_SYMBOL_ATTR_TYPE)
    )
    tags: dict[str, int] = {}
    start = 0
    for _ in range(64):  # bounded: fixture has < 64 tags; guards against a loop
        request = GenericConnectedRequestPacket(
            sequence=driver._sequence,
            service=CIP_SERVICE_GET_INSTANCE_ATTRIBUTE_LIST,
            class_code=CIP_SYMBOL_OBJECT_CLASS,
            instance=start,
            request_data=request_data,
            data_type=None,
        )
        response = driver.send(request)
        status = response.service_status
        check(
            status in (CIP_SUCCESS, CIP_PARTIAL_TRANSFER),
            f"STEP 8 (Symbol browse): Get Instance Attribute List from instance "
            f"{start} returned CIP general status 0x{status:02X}, expected 0x00 "
            f"(success) or 0x06 (partial transfer)",
        )
        raw = response.value or b""
        off = 0
        last = start
        while off + 4 <= len(raw):
            inst = int.from_bytes(raw[off:off + 4], "little")
            off += 4
            check(
                off + 2 <= len(raw),
                "STEP 8 (Symbol browse): reply truncated in the name-length field",
            )
            nlen = int.from_bytes(raw[off:off + 2], "little")
            off += 2
            check(
                off + nlen + 2 <= len(raw),
                f"STEP 8 (Symbol browse): reply truncated in the {nlen}-byte name "
                f"or the type code that follows it",
            )
            name = raw[off:off + nlen].decode("ascii")
            off += nlen
            tcode = int.from_bytes(raw[off:off + 2], "little")
            off += 2
            tags[name] = tcode
            last = inst
        if status != CIP_PARTIAL_TRANSFER:
            break
        start = last + 1
    return tags


def run(host: str, port: int) -> None:
    driver = CIPDriver(f"{host}")
    driver._cfg["port"] = port
    driver.socket_timeout = SOCKET_TIMEOUT
    driver._cfg["timeout"] = int(SOCKET_TIMEOUT)

    # --- Step 1: RegisterSession -----------------------------------------
    check(driver.open(), "STEP 1 (RegisterSession): CIPDriver.open() returned False")
    check(
        driver._session not in (0, None),
        "STEP 1 (RegisterSession): the host did not return a session handle",
    )
    print(f"[probe] step 1 OK: session registered, handle={driver._session}")

    try:
        # --- Step 2: Forward Open ----------------------------------------
        # `with_forward_open` performs the Large Forward Open (0x5B) attempt
        # and the fall back to the regular Forward Open (0x54) that this host
        # implements. It raises `ResponseError` if neither succeeds.
        try:
            with_forward_open(lambda _driver: None)(driver)
        except Exception as err:  # noqa: BLE001 - reported verbatim below
            raise ProbeFailure(f"STEP 2 (Forward Open): {err!r}") from err
        check(
            driver._target_is_connected,
            "STEP 2 (Forward Open): driver reports the target is not connected",
        )
        check(
            driver._target_cid is not None and len(driver._target_cid) == 4,
            "STEP 2 (Forward Open): no 4-byte target connection id was returned",
        )
        check(
            driver._target_cid != b"\x00\x00\x00\x00",
            "STEP 2 (Forward Open): the reply's connection id is all zeros -- the "
            "target must ALLOCATE the connection id the originator addresses "
            "connected messages to, not echo the originator's placeholder",
        )
        print(
            f"[probe] step 2 OK: forward open, target CID="
            f"0x{int.from_bytes(driver._target_cid, 'little'):08X}"
        )

        # --- Step 3: Read a tag (connected) -------------------------------
        expect_read(driver, "Speed", DINT, SPEED_INITIAL, "STEP 3 (Read Tag)")
        print(f"[probe] step 3 OK: Speed reads {SPEED_INITIAL} (DINT)")

        # Every other supported CIP wire type, same round trip. FLOAT64 is
        # narrowed to CIP REAL (IEEE-754 SINGLE precision) on the wire; the
        # fixture's values are exactly representable as float32, so an exact
        # comparison is valid here and the narrowing is documented, not hidden.
        expect_read(driver, "Running", BOOL, RUNNING_INITIAL, "STEP 3 (BOOL)")
        expect_read(driver, "Count16", INT, COUNT16_INITIAL, "STEP 3 (INT)")
        expect_read(driver, "Total64", LINT, TOTAL64_INITIAL, "STEP 3 (LINT)")
        expect_read(driver, "Level", REAL, LEVEL_INITIAL, "STEP 3 (REAL)")
        print("[probe] step 3 OK: BOOL / INT / DINT / LINT / REAL all read correctly")

        # --- Step 4: Write the tag ----------------------------------------
        status = write_tag(driver, "Speed", DINT.code, DINT.encode(SPEED_WRITTEN))
        check(
            status == CIP_SUCCESS,
            f"STEP 4 (Write Tag): writing Speed={SPEED_WRITTEN} returned CIP "
            f"general status 0x{status:02X}, expected 0x00 (success)",
        )
        print(f"[probe] step 4 OK: wrote Speed={SPEED_WRITTEN}")

        # --- Step 5: Independent read-back --------------------------------
        # A SEPARATE Read Tag request, not the write's own reply -- the write
        # reply carries no value, so this is the only thing that can prove
        # the write actually landed in the tag.
        expect_read(driver, "Speed", DINT, SPEED_WRITTEN, "STEP 5 (read-back)")
        print(f"[probe] step 5 OK: independent read-back returns {SPEED_WRITTEN}")

        # --- Step 6: Unconnected (UCMM / SendRRData) read ------------------
        expect_read(
            driver, "Speed", DINT, SPEED_WRITTEN, "STEP 6 (UCMM read)", connected=False
        )
        print("[probe] step 6 OK: same value over unconnected (SendRRData) messaging")

        # --- Step 7: Refusal semantics ------------------------------------
        status = write_tag(driver, "Temp", REAL.code, REAL.encode(99.5))
        check(
            status == CIP_PRIVILEGE_VIOLATION,
            f"STEP 7 (ReadOnly write): writing the ReadOnly-mapped tag Temp "
            f"returned 0x{status:02X}, expected 0x0F (Privilege Violation)",
        )
        expect_read(driver, "Temp", REAL, TEMP_INITIAL, "STEP 7 (ReadOnly unchanged)")

        # A forced tag reads its FORCED value, and refuses an external write
        # VISIBLY (0x0F) rather than silently discarding it.
        expect_read(
            driver, "Forced_Speed", DINT, FORCED_SPEED_FORCED, "STEP 7 (forced read)"
        )
        status = write_tag(driver, "Forced_Speed", DINT.code, DINT.encode(5))
        check(
            status == CIP_PRIVILEGE_VIOLATION,
            f"STEP 7 (forced write): writing the FORCED tag Forced_Speed returned "
            f"0x{status:02X}, expected 0x0F (Privilege Violation)",
        )
        expect_read(
            driver, "Forced_Speed", DINT, FORCED_SPEED_FORCED, "STEP 7 (forced unchanged)"
        )

        status, _, _ = read_tag(driver, "Unexposed")
        check(
            status == CIP_PATH_DESTINATION_UNKNOWN,
            f"STEP 7 (unmapped tag): reading a tag absent from the CipMap returned "
            f"0x{status:02X}, expected 0x05 (Path Destination Unknown)",
        )
        print(
            "[probe] step 7 OK: ReadOnly write refused 0x0F, forced read-through + "
            "write refused 0x0F, unmapped tag 0x05"
        )

        # --- Step 8: Symbol Object browse ---------------------------------
        # Uploads the controller tag directory the way a Logix client does --
        # Get Instance Attribute List (0x55) walked over the Symbol Object
        # (class 0x6B) -- and asserts every fixture tag comes back with the
        # right CIP type code. This is the FIRST time a third-party client
        # reads our Symbol codec's bytes; it is where the attr-1 name string
        # layout is confirmed against pycomm3's own byte reading, WITHOUT
        # needing LogixDriver.open() (that is a later task).
        symbols = symbol_browse(driver)
        for name, code in EXPECTED_SYMBOLS.items():
            check(
                name in symbols,
                f"STEP 8 (Symbol browse): expected tag {name!r} was absent from the "
                f"browsed symbol list {sorted(symbols)}",
            )
            check(
                symbols[name] == code,
                f"STEP 8 (Symbol browse): tag {name!r} browsed as CIP type code "
                f"0x{symbols[name]:02X}, expected 0x{code:02X}",
            )
        check(
            len(symbols) == len(EXPECTED_SYMBOLS),
            f"STEP 8 (Symbol browse): browsed {len(symbols)} tags "
            f"({sorted(symbols)}), expected exactly {len(EXPECTED_SYMBOLS)} "
            f"({sorted(EXPECTED_SYMBOLS)})",
        )
        print(f"[probe] step 8 OK: Symbol Object browse returned {len(symbols)} tags")

        # --- Step 9: Forward Close ----------------------------------------
        check(
            driver._forward_close(),
            "STEP 9 (Forward Close): the host did not accept the Forward Close",
        )
        print("[probe] step 9 OK: forward close accepted")
    finally:
        try:
            driver.close()
        except Exception:  # noqa: BLE001 - teardown must not mask a real failure
            pass

    print("ENIP PROBE PASS")


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
        print(f"ENIP PROBE FAIL: {err}", file=sys.stderr)
        return 1
    except Exception as err:  # noqa: BLE001 - any unexpected error is a failure
        print(f"ENIP PROBE FAIL: unexpected error: {err!r}", file=sys.stderr)
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
