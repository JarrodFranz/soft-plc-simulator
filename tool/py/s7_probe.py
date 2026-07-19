#!/usr/bin/env python3
"""Real third-party S7comm client probe (Python lane).

Drives the `python-snap7` library -- a third-party S7comm implementation
written entirely independently of this project -- against this project's in-app
S7comm host, as exercised by the Dart fixture host
`mobile/tool/s7_host_probe.dart`. This is the ONLY test in the S7comm
workstream that is not our codec talking to itself, so it -- not our unit tests
-- is the authority on wire details.

The fixture host and the shipped host (`mobile/lib/services/s7_host.dart`) do
not merely mirror each other on the read/write path: they SHARE it, calling the
same pure `dispatchS7VarJob` (`mobile/lib/protocols/s7/s7_services.dart`) to
build every response byte. So what this probe validates here is what the app
puts on the wire.

WHAT THIS PROVES, in order:

  1.  connect()          -- TPKT/COTP Connection Request -> Connection Confirm,
                            then S7 Setup Communication -> its Ack_Data reply.
                            snap7 does BOTH inside connect().
  2.  get_connected()    -- the client itself agrees the session is up.
  3.  get_pdu_length()   -- the PDU size snap7 parsed out of OUR Setup
                            Communication reply.
  4.  Read Var, DB area, multi-byte numeric -- byte order proved against a
                            value whose bytes all differ.
  5.  Read Var, ODD length -- see "OPEN WIRE QUESTION 2" below.
  6.  Read Var, BIT transport -- see "OPEN WIRE QUESTION 1" below.
  7.  Write Var, BIT transport, then an INDEPENDENT read-back proving both the
                            written bit AND that its byte-neighbour survived.
  8.  Write Var, multi-byte, then an INDEPENDENT read-back of the exact value.
  9.  S7 REAL decoding (FLOAT64 narrowed to single precision).
  10. A SECOND memory area (merker/M, which has no data-block number): read,
                            write, independent read-back, plus a bit.
  11. Gap semantics -- unmapped bytes read as zero.
  12. Write refusal on a ReadOnly map entry, value unchanged.
  13. Write refusal on a FORCED tag, value unchanged.
  14. disconnect()       -- clean teardown.

Steps 7, 8 and 10 are the point of the whole file: a read that agrees with a
write we just issued proves nothing on its own if both go through the same
buggy path, so every write is followed by a SEPARATE request that reads the
value back and asserts the exact bytes.

=== OPEN WIRE QUESTION 1: the BIT-transport declared length ===
Our `buildDataItem` declares a BIT (transport 0x03) data item's length as a BIT
COUNT (1 for a single bit), not `len(data) * 8` (8). A Dart round-trip cannot
settle which is right, because our own write parser recovers the byte count as
`(declared + 7) // 8`, which is 1 byte for BOTH 1 and 8. Step 6 makes a real
client adjudicate: snap7 slices a data item's payload as `data_length // 8` for
every transport size except 0x00/0x09, so a declared length of 1 yields ZERO
bytes and a declared length of 8 yields one byte. Whatever this step reports is
the answer; see `docs/protocols/s7comm.md`.

=== OPEN WIRE QUESTION 2: the trailing pad byte ===
Our `buildDataItem` pads EVERY data item to an even byte count, including the
LAST one in a response. Real S7 pads BETWEEN items, not after the final one.
Step 5 issues an ODD-length read (3 bytes -> a 1-byte trailing pad) so a real
client either accepts the extra byte or rejects the frame.

Usage: python s7_probe.py <host> <port>
"""

from __future__ import annotations

import struct
import sys
import traceback

import snap7
from snap7.client import Client
from snap7.type import Area, WordLen

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

# --- The fixture's layout ---------------------------------------------------
#
# Every constant below is pinned in `mobile/tool/s7_host_probe.dart`
# (`_fixtureProject`). Keep the two files in step.

DB = 1

RUNNING_BYTE, RUNNING_BIT = 0, 0  # BOOL, initially False
ALARM_BYTE, ALARM_BIT = 0, 3  # BOOL, initially True
COUNT16_BYTE = 2  # INT16  0x1234
SPEED_BYTE = 4  # INT32  0x01020304
LEVEL_BYTE = 8  # FLOAT64 12.5, on the wire a 4-byte S7 REAL
GAP_BYTE = 12  # unmapped -- must read as zero
TOTAL64_BYTE = 16  # INT64  0x0102030405060708
TEMP_BYTE = 24  # INT16  250, mapped ReadOnly
FORCED_SPEED_BYTE = 28  # INT32, forced to 777

COUNT16_INITIAL = 0x1234
SPEED_INITIAL = 0x01020304
LEVEL_INITIAL = 12.5
TOTAL64_INITIAL = 0x0102030405060708
TEMP_INITIAL = 250
FORCED_SPEED_FORCED = 777

# Merker area (no data-block number).
MFLAG_BYTE, MFLAG_BIT = 0, 1  # BOOL, initially False
MCOUNT_BYTE = 2  # INT16 0x0A0B
MCOUNT_INITIAL = 0x0A0B

# Values this probe writes. Each is chosen so all of its bytes differ, so a
# byte-order fault cannot survive the read-back.
COUNT16_WRITTEN = 0x7B2C
MCOUNT_WRITTEN = 0x5566


class ProbeFailure(Exception):
    """Raised with a message naming the step that failed."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


def hexs(data: bytes) -> str:
    return data.hex(" ") if data else "<empty>"


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

        _step4_read_multibyte(client)
        _step5_read_odd_length(client)
        _step6_read_bit(client)
        _step7_write_bit_and_read_back(client)
        _step8_write_multibyte_and_read_back(client)
        _step9_read_real(client)
        _step10_merker_area(client)
        _step11_gap_reads_zero(client)
        _step12_readonly_refused(client)
        _step13_forced_refused(client)
    finally:
        # --- Step 14: clean teardown --------------------------------------
        try:
            client.disconnect()
        except Exception:  # noqa: BLE001 - teardown must not mask a real failure
            pass

    print("S7 PROBE PASS")


# --- Step 4 -----------------------------------------------------------------


def _step4_read_multibyte(client: Client) -> None:
    """Reads Count16 (DB1 bytes 2..3). 0x1234's two bytes DIFFER, so a
    little-endian encoder cannot pass this: it would return `34 12`."""
    data = bytes(client.db_read(DB, COUNT16_BYTE, 2))
    expected = struct.pack(">h", COUNT16_INITIAL)
    check(
        data == expected,
        f"STEP 4 (Read Var, INT16): read DB{DB}.DBW{COUNT16_BYTE} as "
        f"{hexs(data)}, expected {hexs(expected)} "
        f"(0x{COUNT16_INITIAL:04X} BIG-ENDIAN). A byte-swapped result here means "
        f"the area image encoded little-endian.",
    )
    print(f"[probe] step 4 OK: DB{DB}.DBW{COUNT16_BYTE} = {hexs(data)} (big-endian 0x{COUNT16_INITIAL:04X})")


# --- Step 5: OPEN WIRE QUESTION 2 -------------------------------------------


def _step5_read_odd_length(client: Client) -> None:
    """Reads an ODD number of bytes (3), which makes our response's single data
    item carry a TRAILING PAD byte -- the padding real S7 applies only BETWEEN
    items. Whether a real client tolerates that is what this step settles.

    Byte 0 holds two BOOLs: Running (bit 0, False) and Alarm (bit 3, True), so
    it must be 0x08. Byte 1 is an unmapped gap -> 0x00. Byte 2 is the high byte
    of Count16 (0x12), which also proves the odd read is not off by one.
    """
    data = bytes(client.db_read(DB, 0, 3))
    expected = bytes([0x08, 0x00, 0x12])
    check(
        len(data) == 3,
        f"STEP 5 (Read Var, ODD length): asked for 3 bytes and got "
        f"{len(data)} ({hexs(data)}). If this is 0 or short, the client "
        f"REJECTED our trailing pad byte on the last data item -- see OPEN WIRE "
        f"QUESTION 2 in this file's docstring.",
    )
    check(
        data == expected,
        f"STEP 5 (Read Var, ODD length): read DB{DB}.DBB0..2 as {hexs(data)}, "
        f"expected {hexs(expected)} (bit-packed BOOLs, then a gap byte, then "
        f"Count16's high byte)",
    )
    print(
        f"[probe] step 5 OK: odd-length (3-byte) read returned {hexs(data)} -- "
        f"the client ACCEPTED the trailing pad byte on the final data item"
    )


# --- Step 6: OPEN WIRE QUESTION 1 -------------------------------------------


def _step6_read_bit(client: Client) -> None:
    """Reads ONE bit with the BIT transport size (0x01 in the item spec, 0x03
    in the data item), addressing Alarm at DB1.DBX0.3 -- initially True.

    snap7 encodes a BIT read's `start` as the BIT address (`byte * 8 + bit`),
    so 3 here means byte 0, bit 3, NOT byte 3. That the right tag comes back
    is itself a check on our 24-bit address split.

    This is the step that adjudicates the BIT declared length: snap7 slices a
    data item's payload as `declared_length // 8`, so it recovers ONE byte from
    a declared length of 8 and ZERO bytes from a declared length of 1.
    """
    bit_address = ALARM_BYTE * 8 + ALARM_BIT
    data = bytes(client.read_area(Area.DB, DB, bit_address, 1, WordLen.Bit))
    check(
        len(data) >= 1,
        f"STEP 6 (Read Var, BIT transport): a single-bit read of DB{DB}.DBX"
        f"{ALARM_BYTE}.{ALARM_BIT} returned {hexs(data)} -- NO payload byte. "
        f"This is OPEN WIRE QUESTION 1 resolving AGAINST our code: snap7 slices "
        f"a data item as `declared_length // 8`, so our BIT item's declared "
        f"length of 1 bit yields zero bytes for this client. It wants 8 "
        f"(`len(data) * 8`). Fix `buildDataItem`'s BIT branch in "
        f"mobile/lib/protocols/s7/s7_pdu.dart.",
    )
    check(
        data[0] == 0x01,
        f"STEP 6 (Read Var, BIT transport): DB{DB}.DBX{ALARM_BYTE}.{ALARM_BIT} "
        f"(Alarm, initially True) read back as {hexs(data)}, expected 01. A 00 "
        f"here means the bit offset was mis-split out of the 24-bit address.",
    )
    print(
        f"[probe] step 6 OK: BIT-transport read of DB{DB}.DBX{ALARM_BYTE}."
        f"{ALARM_BIT} returned {hexs(data)}"
    )


# --- Step 7 -----------------------------------------------------------------


def _step7_write_bit_and_read_back(client: Client) -> None:
    """Writes ONE bit with the BIT transport size, then reads the whole byte
    back in a SEPARATE request.

    The read-back asserts two things at once: Running (bit 0) became True, and
    Alarm (bit 3) -- a DIFFERENT tag sharing the same byte -- is still True. A
    bit write that clobbered its neighbours would pass a naive
    read-just-that-bit check and fail here.
    """
    bit_address = RUNNING_BYTE * 8 + RUNNING_BIT
    try:
        client.write_area(Area.DB, DB, bit_address, bytearray([0x01]), WordLen.Bit)
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 7 (Write Var, BIT transport): writing DB{DB}.DBX"
            f"{RUNNING_BYTE}.{RUNNING_BIT} = True was rejected: {err!r}"
        ) from err

    data = bytes(client.db_read(DB, RUNNING_BYTE, 1))
    check(
        data == bytes([0x09]),
        f"STEP 7 (Write Var, BIT read-back): after setting DB{DB}.DBX"
        f"{RUNNING_BYTE}.{RUNNING_BIT} = True, an INDEPENDENT read of byte "
        f"{RUNNING_BYTE} returned {hexs(data)}, expected 09 (bit 0 newly set "
        f"AND bit 3 -- the neighbouring Alarm tag -- still set). A value of 01 "
        f"means the bit write wiped its byte-neighbours; 08 means the write "
        f"never landed.",
    )
    print(
        f"[probe] step 7 OK: BIT write landed and the neighbouring BOOL in the "
        f"same byte survived (byte {RUNNING_BYTE} = {hexs(data)})"
    )


# --- Step 8 -----------------------------------------------------------------


def _step8_write_multibyte_and_read_back(client: Client) -> None:
    """Writes Count16 and reads it back in a SEPARATE request, asserting the
    exact value -- the core read -> write -> independent read-back proof."""
    payload = struct.pack(">h", COUNT16_WRITTEN)
    try:
        client.db_write(DB, COUNT16_BYTE, bytearray(payload))
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 8 (Write Var, INT16): writing DB{DB}.DBW{COUNT16_BYTE} = "
            f"0x{COUNT16_WRITTEN:04X} was rejected: {err!r}"
        ) from err

    data = bytes(client.db_read(DB, COUNT16_BYTE, 2))
    check(
        data == payload,
        f"STEP 8 (Write Var read-back): wrote {hexs(payload)} to DB{DB}.DBW"
        f"{COUNT16_BYTE} and an INDEPENDENT read returned {hexs(data)}. A "
        f"byte-swapped result means the write path decoded little-endian.",
    )
    print(
        f"[probe] step 8 OK: wrote {hexs(payload)} to DB{DB}.DBW{COUNT16_BYTE} "
        f"and read back exactly {hexs(data)}"
    )


# --- Step 9 -----------------------------------------------------------------


def _step9_read_real(client: Client) -> None:
    """Reads Level, a FLOAT64 tag narrowed to a 4-byte big-endian S7 REAL."""
    data = bytes(client.db_read(DB, LEVEL_BYTE, 4))
    check(len(data) == 4, f"STEP 9 (Read Var, REAL): expected 4 bytes, got {hexs(data)}")
    value = struct.unpack(">f", data)[0]
    check(
        value == LEVEL_INITIAL,
        f"STEP 9 (Read Var, REAL): DB{DB}.DBD{LEVEL_BYTE} decoded as {value!r} "
        f"({hexs(data)}), expected {LEVEL_INITIAL!r}. A wildly different value "
        f"means the REAL was not encoded big-endian IEEE-754 single precision.",
    )
    print(f"[probe] step 9 OK: DB{DB}.DBD{LEVEL_BYTE} = {value} ({hexs(data)}) as a big-endian S7 REAL")


# --- Step 10 ----------------------------------------------------------------


def _step10_merker_area(client: Client) -> None:
    """Exercises a SECOND memory area -- merker/M, which carries no data-block
    number -- with a multi-byte read, a write, an independent read-back, and a
    single-bit round trip. If the area code were being ignored (everything
    served from the data block), MCount would read as DB bytes 2..3 instead."""
    data = bytes(client.mb_read(MCOUNT_BYTE, 2))
    expected = struct.pack(">h", MCOUNT_INITIAL)
    check(
        data == expected,
        f"STEP 10 (M area read): MW{MCOUNT_BYTE} read as {hexs(data)}, expected "
        f"{hexs(expected)}. If this matches the DB's contents instead, the area "
        f"code is not discriminating between memory areas.",
    )

    payload = struct.pack(">h", MCOUNT_WRITTEN)
    try:
        client.mb_write(MCOUNT_BYTE, 2, bytearray(payload))
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 10 (M area write): writing MW{MCOUNT_BYTE} was rejected: {err!r}") from err

    read_back = bytes(client.mb_read(MCOUNT_BYTE, 2))
    check(
        read_back == payload,
        f"STEP 10 (M area read-back): wrote {hexs(payload)} to MW{MCOUNT_BYTE} "
        f"and an INDEPENDENT read returned {hexs(read_back)}",
    )

    # And a single bit in the merker area, written with the BIT transport.
    bit_address = MFLAG_BYTE * 8 + MFLAG_BIT
    try:
        client.write_area(Area.MK, 0, bit_address, bytearray([0x01]), WordLen.Bit)
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 10 (M area bit write): writing M{MFLAG_BYTE}.{MFLAG_BIT} was rejected: {err!r}") from err

    bit_byte = bytes(client.mb_read(MFLAG_BYTE, 1))
    check(
        bit_byte == bytes([1 << MFLAG_BIT]),
        f"STEP 10 (M area bit read-back): after setting M{MFLAG_BYTE}."
        f"{MFLAG_BIT} = True, an INDEPENDENT read of MB{MFLAG_BYTE} returned "
        f"{hexs(bit_byte)}, expected {1 << MFLAG_BIT:02x}",
    )
    print(
        f"[probe] step 10 OK: merker area read/write/read-back "
        f"(MW{MCOUNT_BYTE} = {hexs(read_back)}, MB{MFLAG_BYTE} = {hexs(bit_byte)})"
    )


# --- Step 11 ----------------------------------------------------------------


def _step11_gap_reads_zero(client: Client) -> None:
    """Bytes 12..15 are mapped to no tag at all. A real controller's data block
    is a fixed-size buffer whose unused bytes hold zero, and this device
    matches that so a driver can block-read a whole block."""
    data = bytes(client.db_read(DB, GAP_BYTE, 4))
    check(
        data == bytes(4),
        f"STEP 11 (gap semantics): unmapped DB{DB}.DBD{GAP_BYTE} read as "
        f"{hexs(data)}, expected four zero bytes",
    )
    print(f"[probe] step 11 OK: unmapped bytes read as zero ({hexs(data)})")


# --- Step 12 ----------------------------------------------------------------


def _step12_readonly_refused(client: Client) -> None:
    """Temp is mapped ReadOnly. The write must be REFUSED and the value must be
    unchanged afterwards -- a refusal that still mutated the tag would be worse
    than no refusal at all."""
    refused = False
    try:
        client.db_write(DB, TEMP_BYTE, bytearray(struct.pack(">h", 999)))
    except Exception as err:  # noqa: BLE001 - the expected outcome
        refused = True
        print(f"[probe] step 12: write to the ReadOnly entry was refused as expected: {err}")
    check(
        refused,
        f"STEP 12 (ReadOnly refusal): writing DB{DB}.DBW{TEMP_BYTE} (a ReadOnly "
        f"map entry) SUCCEEDED. It must be refused with a per-item error code.",
    )
    data = bytes(client.db_read(DB, TEMP_BYTE, 2))
    expected = struct.pack(">h", TEMP_INITIAL)
    check(
        data == expected,
        f"STEP 12 (ReadOnly refusal): after the refused write, DB{DB}.DBW"
        f"{TEMP_BYTE} reads {hexs(data)}, expected the UNCHANGED "
        f"{hexs(expected)}",
    )
    print(f"[probe] step 12 OK: ReadOnly write refused and the value is unchanged ({hexs(data)})")


# --- Step 13 ----------------------------------------------------------------


def _step13_forced_refused(client: Client) -> None:
    """Forced_Speed is mapped ReadWrite, but the TAG itself is forced. The
    refusal must therefore come from the force check, not from the map's access
    mode, and reads must see the FORCED value."""
    refused = False
    try:
        client.db_write(DB, FORCED_SPEED_BYTE, bytearray(struct.pack(">i", 12345)))
    except Exception as err:  # noqa: BLE001 - the expected outcome
        refused = True
        print(f"[probe] step 13: write to the FORCED tag was refused as expected: {err}")
    check(
        refused,
        f"STEP 13 (force refusal): writing DB{DB}.DBD{FORCED_SPEED_BYTE} (a "
        f"ReadWrite entry whose tag is FORCED) SUCCEEDED. Forcing is "
        f"authoritative: the write must be refused.",
    )
    data = bytes(client.db_read(DB, FORCED_SPEED_BYTE, 4))
    expected = struct.pack(">i", FORCED_SPEED_FORCED)
    check(
        data == expected,
        f"STEP 13 (force refusal): after the refused write, DB{DB}.DBD"
        f"{FORCED_SPEED_BYTE} reads {hexs(data)}, expected the FORCED value "
        f"{hexs(expected)} ({FORCED_SPEED_FORCED})",
    )
    print(f"[probe] step 13 OK: write to the forced tag refused and the forced value stands ({hexs(data)})")


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
