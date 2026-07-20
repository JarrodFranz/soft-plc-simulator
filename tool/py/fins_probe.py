#!/usr/bin/env python3
"""Real third-party Omron FINS client probe (Python lane).

Drives the pure-Python `fins` library -- a third-party FINS implementation
written entirely independently of this project -- against this project's in-app
FINS host, as exercised by the Dart fixture host
`mobile/tool/fins_host_probe.dart`. This is the ONLY test in the FINS
workstream that is not our codec talking to itself, so it -- not our unit tests
-- is the authority on wire details. It is also the suite's FIRST client over
UDP: every prior probe (pycomm3, python-snap7) spoke TCP.

The fixture host and the shipped host (`mobile/lib/services/fins_host.dart`) do
not merely mirror each other on the read path: they SHARE it, calling the same
pure `dispatchFinsDatagram` (`mobile/lib/protocols/fins/fins_dispatch.dart`) to
build every response byte. So what this probe validates here is what the app
puts on the wire.

WHAT THIS PROVES, in order:

  1. connect()             -- bind the client UDP socket and point it at the
                             host (FINS/UDP has no session handshake; this only
                             sets up the socket).
  2. memory_area_read()    -- a Memory Area Read of one DM word, asserting the
                             raw response frame: the FINS response HEADER (the
                             DNA/DA1/DA2 <-> SNA/SA1/SA2 node swap, the ICF
                             response bit, the SID echo -- via the library's
                             own `FinsHeader.from_bytes`), the echoed command
                             code, a NORMAL end code, and the word data
                             BIG-ENDIAN (a value whose two bytes DIFFER so a
                             byte-order fault cannot pass).
  3. read()                -- the same word via the library's high-level
                             INT decode, cross-checking the interpreted value.
  4. a two-word read       -- proves word ordering across adjacent DM words.
  5. read() a 32-bit DINT  -- reads a value the FIXTURE seeded independently of
                             this client and asserts it EXACTLY. This is what
                             SETTLES the two-word order: a write->read-back is
                             byte-transparent through our symmetric encode/decode
                             and cannot detect a word swap, but a seeded value
                             read through the client's own multi-word decode can.
                             Also asserts the raw on-wire word order (low word
                             at the lower address).
  6. read() a REAL         -- a seeded FLOAT64-narrowed-to-REAL, riding the same
                             two-word order.
  7. write()+read() DINT   -- writes a NEW 32-bit value and reads it back in a
                             SEPARATE request, asserting the exact value: the
                             core read -> write -> independent read-back.
  8. BOOL bit round trip   -- reads the BOOL's word (bit clear), writes the word
                             with the bit set, reads it back (bit set).
  9. CIO second area       -- read / write / independent read-back in a
                             DIFFERENT memory area (CIO, not DM).
  10. ReadOnly refusal      -- a write to a ReadOnly-mapped tag is REFUSED (a
                             not-writable end code) and the value is unchanged.

Step 2 is one point of the file: a real client parsing OUR response frame is
the first independent confirmation that the 10-byte header, the DNA/DA1/DA2 <->
SNA/SA1/SA2 node swap, the ICF response bit, the echoed SID, the command-code
echo, the end code, and the big-endian word data are all on the wire where the
client expects them. The header assertions specifically use six DISTINCT,
non-zero node-address values set on the connection before the request (see
`run()`) -- the library's own defaults are all zero, which would make a
completely broken swap indistinguishable from a correct one, since a UDP
client's reply is delivered by the socket's 4-tuple regardless of what the
FINS node bytes inside the header say.

Step 5 is the OTHER point: the 32-bit two-word order. The `fins` library
serializes a multi-word value LOW-WORD-FIRST (it word-reverses the big-endian
byte string -- see `fins.fins_common.reverse_word_order`), so this probe is the
authority that overturned our provisional high-word-first choice. Because the
fixture seeds the DINT into a tag independently of this client, reading it back
through the client's own decode is a true conformance check, not a round trip.

Usage: python fins_probe.py <host> <port>
"""

from __future__ import annotations

import socket
import struct
import sys
import traceback

from fins.udp import FinsHeader, FinsPLCMemoryAreas, UDPFinsConnection

# --- The fixture's layout ---------------------------------------------------
#
# Every constant below is pinned in `mobile/tool/fins_host_probe.dart`
# (`_fixtureProject`). Keep the two files in step.

DM100_ADDRESS = 100  # DM word 100 -> W0
DM100_VALUE = 0x1234  # its value; two bytes DIFFER so byte order is testable
DM101_ADDRESS = 101  # adjacent DM word -> W1
DM101_VALUE = 0x5678

# Reg32 -- INT32 across DM words 110..111. All four bytes distinct AND the high
# word differs from the low, so a word-order fault cannot survive the seeded
# read in step 5. Low word (bits 0..15) and high word (bits 16..31) are named
# separately for the on-wire word-order assertion.
REG32_ADDRESS = 110
REG32_VALUE = 0x1A2B3C4D
REG32_LOW_WORD = REG32_VALUE & 0xFFFF  # 0x3C4D
REG32_HIGH_WORD = (REG32_VALUE >> 16) & 0xFFFF  # 0x1A2B
REG32_WRITTEN = 0x5B6C7D0E  # step 7 writes this; distinct bytes again

# Real1 -- FLOAT64 narrowed to a 4-byte FINS REAL, DM words 112..113. 12.5 is
# exactly representable in float32, so the narrowing does not blur the assert.
REAL1_ADDRESS = 112
REAL1_VALUE = 12.5

# Flag -- a BOOL at DM word 114, bit 0. Starts False.
FLAG_ADDRESS = 114
FLAG_BIT = 0

# CioReg -- INT16 in the CIO area (word 5), a DIFFERENT memory area from DM.
CIO_REG_ADDRESS = 5
CIO_REG_VALUE = 0x0A0B
CIO_REG_WRITTEN = 0x0C0D

# Locked -- INT16 at DM word 116, mapped ReadOnly.
LOCKED_ADDRESS = 116
LOCKED_VALUE = 250

# The FINS not-writable end code (`kFinsEndNotWritable` in
# mobile/lib/protocols/fins/fins_frame.dart), returned for a refused write.
FINS_END_NOT_WRITABLE = b"\x21\x01"

# --- Distinct node addresses for the response-header swap assertion --------
#
# `fins.udp.FinsConnection` defaults every one of these six fields to 0, which
# would make a broken DNA/DA1/DA2 <-> SNA/SA1/SA2 swap invisible (0 swapped
# with 0 is still 0). Setting six DISTINCT, non-zero values means the swap
# assertion in step 2 actually distinguishes "swapped correctly" from "not
# swapped", "swapped into the wrong slot", or "left alone". The host
# (`buildFinsResponse` in `mobile/lib/protocols/fins/fins_frame.dart`) accepts
# node addressing PERMISSIVELY -- it never validates these bytes against any
# notion of its own address, so any values are legal here.
REQUEST_DEST_NET = 1
REQUEST_DEST_NODE = 2
REQUEST_DEST_UNIT = 3
REQUEST_SRCE_NET = 4
REQUEST_SRCE_NODE = 5
REQUEST_SRCE_UNIT = 6

# How long any single UDP socket operation may block, in seconds. Every request
# this probe issues is a single round trip against a loopback fixture host, so a
# stall means a hang, not slowness -- bounding it here is what keeps the probe
# from wedging the E2E script (the script also wraps it in an outer `timeout`).
SOCKET_TIMEOUT_S = 5.0


class ProbeFailure(Exception):
    """Raised with a message naming the step that failed."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


def hexs(data: bytes) -> str:
    return data.hex(" ") if data else "<empty>"


def _beginning_address(word_address: int, bit: int = 0) -> bytes:
    """The FINS 3-byte 'beginning address': word address (2 bytes big-endian)
    then bit address (1 byte). This is exactly the layout our
    `parseMemAreaReadItem` expects for bytes 1..3 of the item spec."""
    return word_address.to_bytes(2, "big") + bit.to_bytes(1, "big")


def run(host: str, port: int) -> None:
    connection = UDPFinsConnection()
    memory_areas = FinsPLCMemoryAreas()

    # --- Step 1: connect (bind the client socket, aim it at the host) ------
    try:
        # bind_port=0 lets the OS pick a free local UDP port, so this probe
        # never collides with anything already holding FINS's default 9600 on
        # the loopback interface.
        connection.connect(host, port=port, bind_port=0)
        connection.fins_socket.settimeout(SOCKET_TIMEOUT_S)
    except Exception as err:  # noqa: BLE001 - reported verbatim below
        raise ProbeFailure(
            f"STEP 1 (connect): the fins client could not open a UDP socket to "
            f"{host}:{port}: {err!r}"
        ) from err
    print(f"[probe] step 1 OK: fins client aimed at {host}:{port} (UDP)")

    # Six distinct, non-zero node-address fields (see the module constants
    # above) so step 2's response-header swap assertion is actually
    # meaningful -- the library's defaults are all zero, which a broken swap
    # could not be told apart from.
    connection.dest_net_add = REQUEST_DEST_NET
    connection.dest_node_add = REQUEST_DEST_NODE
    connection.dest_unit_add = REQUEST_DEST_UNIT
    connection.srce_net_add = REQUEST_SRCE_NET
    connection.srce_node_add = REQUEST_SRCE_NODE
    connection.srce_unit_add = REQUEST_SRCE_UNIT

    try:
        _step2_raw_memory_area_read(connection, memory_areas)
        _step3_high_level_read(connection)
        _step4_two_word_read(connection, memory_areas)
        _step5_read_32bit_settles_word_order(connection, memory_areas)
        _step6_read_real(connection)
        _step7_write_32bit_and_read_back(connection)
        _step8_bool_bit_round_trip(connection)
        _step9_cio_second_area(connection)
        _step10_readonly_refused(connection)
    finally:
        # --- teardown: close the client socket --------------------------------
        try:
            connection.fins_socket.close()
        except Exception:  # noqa: BLE001 - teardown must not mask a real failure
            pass

    print("FINS PROBE PASS")


# --- Step 2 -----------------------------------------------------------------


def _step2_raw_memory_area_read(
    connection: UDPFinsConnection, memory_areas: FinsPLCMemoryAreas
) -> None:
    """Reads one DM word via `memory_area_read` and asserts the RAW response
    frame our host built: the response HEADER (node-field swap, ICF response
    bit, SID echo), command-code echo, NORMAL end code, and the word data
    big-endian. DM100 = 0x1234, whose bytes differ, so a little-endian encoder
    would return `34 12` and fail here.

    The header assertions below are the only place in this probe that proves
    the DNA/DA1/DA2 <-> SNA/SA1/SA2 swap and the ICF response bit against a
    REAL client's own parsed view of the header -- not merely by the reply
    reaching this UDP socket. A UDP client receives its reply by the socket's
    4-tuple, not by the FINS node bytes inside the frame, so a completely
    broken swap (or a response ICF that never got its response bit set) would
    still be delivered here and pass every other assertion in this file. That
    is why `run()` sets six DISTINCT, non-zero node-address fields on the
    connection before this request: the library's own defaults are all zero,
    which a broken swap could not be told apart from.
    """
    try:
        response = connection.memory_area_read(
            memory_areas.DATA_MEMORY_WORD, _beginning_address(DM100_ADDRESS), 1
        )
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 2 (memory_area_read): no response datagram from {connection.ip_address}:"
            f"{connection.fins_port} within {SOCKET_TIMEOUT_S}s. The host either did not "
            f"reply, or replied to the wrong address/port -- check the DNA/DA1/DA2 <-> "
            f"SNA/SA1/SA2 node swap and that the reply is sent to the datagram's source."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 2 (memory_area_read): request failed: {err!r}") from err

    # The FINS response frame: 10-byte header, 2-byte command code, 2-byte end
    # code, then the word data. This is `FinsResponseFrame.from_bytes`'s layout.
    check(
        len(response) >= 14,
        f"STEP 2 (memory_area_read): response is only {len(response)} bytes "
        f"({hexs(response)}), too short to hold a FINS response header + command "
        f"code + end code (14 bytes).",
    )
    command_code = response[10:12]
    end_code = response[12:14]
    text = response[14:]

    check(
        command_code == b"\x01\x01",
        f"STEP 2 (command-code echo): response command code is {hexs(command_code)}, "
        f"expected 01 01 (Memory Area Read). The host must echo the command code it "
        f"was sent.",
    )
    check(
        end_code == b"\x00\x00",
        f"STEP 2 (end code): response end code is {hexs(end_code)}, expected 00 00 "
        f"(normal completion). A non-zero end code means the host rejected a read it "
        f"should have served.",
    )
    expected = struct.pack(">H", DM100_VALUE)
    check(
        text == expected,
        f"STEP 2 (word data, big-endian): DM{DM100_ADDRESS} read as {hexs(text)}, "
        f"expected {hexs(expected)} (0x{DM100_VALUE:04X} BIG-ENDIAN). A byte-swapped "
        f"result here means the response word data was encoded little-endian.",
    )

    # --- The response HEADER, via the library's own parser -------------------
    #
    # `FinsHeader.from_bytes` is the `fins` library's own view of the header
    # that came back on the wire (not bytes this probe hand-parses itself).
    header = FinsHeader()
    header.from_bytes(response[:10])

    # Node-field swap: whatever this client sent as its DESTINATION
    # (dest_net_add/dest_node_add/dest_unit_add) must come back in the
    # response's SOURCE fields (SNA/SA1/SA2), and whatever it sent as its own
    # SOURCE must come back in the response's DESTINATION fields (DNA/DA1/DA2)
    # -- that is the actual swap `buildFinsResponse` performs, per
    # `mobile/lib/protocols/fins/fins_frame.dart`.
    response_dna_da1_da2 = header.dna + header.da1 + header.da2
    response_sna_sa1_sa2 = header.sna + header.sa1 + header.sa2
    expected_dna_da1_da2 = bytes(
        (connection.srce_net_add, connection.srce_node_add, connection.srce_unit_add)
    )
    expected_sna_sa1_sa2 = bytes(
        (connection.dest_net_add, connection.dest_node_add, connection.dest_unit_add)
    )
    check(
        response_dna_da1_da2 == expected_dna_da1_da2,
        f"STEP 2 (header node swap, DNA/DA1/DA2): response DNA/DA1/DA2 is "
        f"{hexs(response_dna_da1_da2)}, expected {hexs(expected_dna_da1_da2)} -- "
        f"the request's own SNA/SA1/SA2 (source), which must come back as the "
        f"response's destination. A mismatch means the response header did not "
        f"correctly swap destination<->source.",
    )
    check(
        response_sna_sa1_sa2 == expected_sna_sa1_sa2,
        f"STEP 2 (header node swap, SNA/SA1/SA2): response SNA/SA1/SA2 is "
        f"{hexs(response_sna_sa1_sa2)}, expected {hexs(expected_sna_sa1_sa2)} -- "
        f"the request's own DNA/DA1/DA2 (destination), which must come back as "
        f"the response's source. A mismatch means the response header did not "
        f"correctly swap destination<->source.",
    )

    # ICF response bit: the client always sends icf=0x80 (see
    # `fins.fins_common.FinsConnection.fins_command_frame`'s default), and our
    # host's response ICF must be that value with bit 6 (0x40, "this is a
    # response") set and nothing else touched -- i.e. exactly 0xC0.
    icf = header.icf[0]
    check(
        icf == 0xC0,
        f"STEP 2 (ICF response bit): response ICF is 0x{icf:02X}, expected "
        f"0xC0 (request ICF 0x80 with the response bit, mask 0x40, set and no "
        f"other bit changed). This means the client's OWN parsed header does "
        f"not have the response bit set on our reply.",
    )

    # SID echo: the client's fixed request SID must come back unchanged --
    # this is how the client (not node addressing) correlates a reply to its
    # request.
    sid = header.sid[0]
    check(
        sid == 0x60,
        f"STEP 2 (SID echo): response SID is 0x{sid:02X}, expected 0x60 (the "
        f"fins client's fixed request SID). An unechoed SID would break "
        f"request/response correlation.",
    )

    print(
        f"[probe] step 2 OK: raw memory_area_read of DM{DM100_ADDRESS} returned "
        f"cmd={hexs(command_code)} end={hexs(end_code)} data={hexs(text)} "
        f"(big-endian 0x{DM100_VALUE:04X}); response header node swap "
        f"DNA/DA1/DA2={hexs(response_dna_da1_da2)} "
        f"SNA/SA1/SA2={hexs(response_sna_sa1_sa2)}, ICF=0x{icf:02X}, SID=0x{sid:02X}"
    )


# --- Step 3 -----------------------------------------------------------------


def _step3_high_level_read(connection: UDPFinsConnection) -> None:
    """Reads the same DM word through the library's high-level `read` (which
    parses the response frame itself and decodes an INT), cross-checking the
    interpreted value. This exercises the client's OWN frame parser end to end,
    not just our byte comparison."""
    try:
        value = connection.read("d", DM100_ADDRESS, data_type="i")
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 3 (high-level read): no response within {SOCKET_TIMEOUT_S}s."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 3 (high-level read): request failed: {err!r}") from err

    check(
        value == DM100_VALUE,
        f"STEP 3 (high-level read): the fins client decoded DM{DM100_ADDRESS} as "
        f"{value!r}, expected {DM100_VALUE} (0x{DM100_VALUE:04X}). The client parsed "
        f"our whole response frame itself, so a mismatch here means a header/end-code/"
        f"data-offset disagreement its own parser tripped on.",
    )
    print(f"[probe] step 3 OK: high-level read decoded DM{DM100_ADDRESS} = {value} (0x{value:04X})")


# --- Step 4 -----------------------------------------------------------------


def _step4_two_word_read(
    connection: UDPFinsConnection, memory_areas: FinsPLCMemoryAreas
) -> None:
    """Reads TWO adjacent DM words in one request and asserts both, proving word
    ORDER across a multi-word read: DM100 must come before DM101 in the response
    data, each still big-endian."""
    try:
        response = connection.memory_area_read(
            memory_areas.DATA_MEMORY_WORD, _beginning_address(DM100_ADDRESS), 2
        )
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 4 (two-word read): no response within {SOCKET_TIMEOUT_S}s."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 4 (two-word read): request failed: {err!r}") from err

    text = response[14:]
    expected = struct.pack(">HH", DM100_VALUE, DM101_VALUE)
    check(
        text == expected,
        f"STEP 4 (two-word read): DM{DM100_ADDRESS}..{DM101_ADDRESS} read as "
        f"{hexs(text)}, expected {hexs(expected)} (DM{DM100_ADDRESS} 0x{DM100_VALUE:04X} "
        f"THEN DM{DM101_ADDRESS} 0x{DM101_VALUE:04X}, each big-endian). A swapped pair "
        f"means the words came back in the wrong order.",
    )
    print(f"[probe] step 4 OK: two-word read returned {hexs(text)} (DM{DM100_ADDRESS} then DM{DM101_ADDRESS})")


# --- Step 5: THE 32-BIT WORD-ORDER SETTLER ----------------------------------


def _step5_read_32bit_settles_word_order(
    connection: UDPFinsConnection, memory_areas: FinsPLCMemoryAreas
) -> None:
    """Reads Reg32 (a DINT the FIXTURE seeded to 0x1A2B3C4D) two ways and asserts
    both, SETTLING the two-word order.

    (a) The library's high-level `di` (two-word signed) decode. Because the
        value was seeded into a tag independently of this client, a correct
        read-back can only happen if OUR encode word order matches what the
        client's decode expects -- this is NOT a byte-transparent round trip.
    (b) The RAW two words, to document the on-wire order explicitly: the LOW
        word (0x3C4D) must sit at the LOWER address and the HIGH word (0x1A2B)
        at the higher, i.e. LOW-WORD-FIRST. If a future `fins` version changed
        its convention, this raw assertion localizes the disagreement.
    """
    try:
        value = connection.read("d", REG32_ADDRESS, data_type="di")
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 5 (read 32-bit DINT): no response within {SOCKET_TIMEOUT_S}s."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 5 (read 32-bit DINT): request failed: {err!r}") from err

    check(
        value == REG32_VALUE,
        f"STEP 5 (32-bit WORD ORDER): the fins client decoded the SEEDED DINT at "
        f"DM{REG32_ADDRESS} as 0x{value & 0xFFFFFFFF:08X} ({value!r}), expected "
        f"0x{REG32_VALUE:08X}. This value was seeded into the tag independently of "
        f"this client, so a mismatch means OUR two-word order disagrees with the "
        f"client's -- the `fins` library is LOW-WORD-FIRST (it word-reverses a "
        f"multi-word value); flip the word order in fins_area_image.dart.",
    )

    raw = connection.memory_area_read(
        memory_areas.DATA_MEMORY_WORD, _beginning_address(REG32_ADDRESS), 2
    )[14:]
    expected_raw = struct.pack(">HH", REG32_LOW_WORD, REG32_HIGH_WORD)
    check(
        raw == expected_raw,
        f"STEP 5 (on-wire word order): the two raw words of DM{REG32_ADDRESS} are "
        f"{hexs(raw)}, expected {hexs(expected_raw)} (LOW word 0x{REG32_LOW_WORD:04X} "
        f"at the lower address, HIGH word 0x{REG32_HIGH_WORD:04X} at the higher -- "
        f"LOW-WORD-FIRST, each big-endian).",
    )
    print(
        f"[probe] step 5 OK: seeded DINT DM{REG32_ADDRESS} = 0x{value & 0xFFFFFFFF:08X} "
        f"settled LOW-WORD-FIRST (raw words {hexs(raw)})"
    )


# --- Step 6 -----------------------------------------------------------------


def _step6_read_real(connection: UDPFinsConnection) -> None:
    """Reads Real1, a seeded FLOAT64 narrowed to a 4-byte FINS REAL, via the
    library's `r` (two-word float) decode -- it rides the same two-word order as
    the DINT."""
    try:
        value = connection.read("d", REAL1_ADDRESS, data_type="r")
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 6 (read REAL): no response within {SOCKET_TIMEOUT_S}s."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 6 (read REAL): request failed: {err!r}") from err

    check(
        abs(value - REAL1_VALUE) < 1e-6,
        f"STEP 6 (read REAL): the fins client decoded the seeded REAL at "
        f"DM{REAL1_ADDRESS} as {value!r}, expected {REAL1_VALUE!r}. A wildly "
        f"different value means the REAL was not encoded as a big-endian IEEE-754 "
        f"single across the two words in the settled order.",
    )
    print(f"[probe] step 6 OK: seeded REAL DM{REAL1_ADDRESS} = {value}")


# --- Step 7 -----------------------------------------------------------------


def _step7_write_32bit_and_read_back(connection: UDPFinsConnection) -> None:
    """Writes a NEW 32-bit value to Reg32 and reads it back in a SEPARATE request,
    asserting the exact value -- the core read -> write -> independent read-back
    for a multi-word value. With step 5 having proven the read (encode) order, a
    correct read-back here proves the write (decode) order too."""
    try:
        connection.write(REG32_WRITTEN, "d", REG32_ADDRESS, data_type="di")
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 7 (write 32-bit DINT): writing DM{REG32_ADDRESS} = "
            f"0x{REG32_WRITTEN:08X} was rejected: {err!r}"
        ) from err

    value = connection.read("d", REG32_ADDRESS, data_type="di")
    check(
        value == REG32_WRITTEN,
        f"STEP 7 (write 32-bit read-back): wrote 0x{REG32_WRITTEN:08X} to "
        f"DM{REG32_ADDRESS} and an INDEPENDENT read returned 0x{value & 0xFFFFFFFF:08X} "
        f"({value!r}). A word-swapped result means the write path decoded the two "
        f"words in the wrong order.",
    )
    print(
        f"[probe] step 7 OK: wrote 0x{REG32_WRITTEN:08X} to DM{REG32_ADDRESS} and read "
        f"back exactly 0x{value & 0xFFFFFFFF:08X}"
    )


# --- Step 8 -----------------------------------------------------------------


def _step8_bool_bit_round_trip(connection: UDPFinsConnection) -> None:
    """Exercises a BOOL bit. The `fins` library's high-level read/write have no
    BOOL codec and our host serves only WORD areas, so a BOOL is addressed
    through its containing word: read the word (bit clear), write the word with
    the bit set, read the word back (bit set)."""
    word = connection.read("d", FLAG_ADDRESS, data_type="ui")
    check(
        (word >> FLAG_BIT) & 1 == 0,
        f"STEP 8 (BOOL initial): DM{FLAG_ADDRESS} bit {FLAG_BIT} (Flag) read as set "
        f"(word 0x{word:04X}); the fixture seeds it False (clear).",
    )

    try:
        connection.write(1 << FLAG_BIT, "d", FLAG_ADDRESS, data_type="ui")
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 8 (BOOL write): writing DM{FLAG_ADDRESS} bit {FLAG_BIT} = True was "
            f"rejected: {err!r}"
        ) from err

    word = connection.read("d", FLAG_ADDRESS, data_type="ui")
    check(
        (word >> FLAG_BIT) & 1 == 1,
        f"STEP 8 (BOOL read-back): after setting DM{FLAG_ADDRESS} bit {FLAG_BIT} = "
        f"True, an INDEPENDENT read returned word 0x{word:04X}, whose bit {FLAG_BIT} "
        f"is not set. The bit write did not land.",
    )
    print(f"[probe] step 8 OK: BOOL bit at DM{FLAG_ADDRESS}.{FLAG_BIT} written and read back set")


# --- Step 9 -----------------------------------------------------------------


def _step9_cio_second_area(connection: UDPFinsConnection) -> None:
    """Exercises a SECOND memory area -- CIO, not DM -- with a read, a write, and
    an independent read-back. If the area code were ignored (everything served
    from DM), CioReg would read as DM word 5 instead."""
    value = connection.read("c", CIO_REG_ADDRESS, data_type="i")
    check(
        value == CIO_REG_VALUE,
        f"STEP 9 (CIO read): CIO word {CIO_REG_ADDRESS} read as {value!r}, expected "
        f"0x{CIO_REG_VALUE:04X}. If this does not match, the CIO area code is not "
        f"discriminating between memory areas.",
    )

    try:
        connection.write(CIO_REG_WRITTEN, "c", CIO_REG_ADDRESS, data_type="i")
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 9 (CIO write): writing CIO word {CIO_REG_ADDRESS} was rejected: {err!r}") from err

    read_back = connection.read("c", CIO_REG_ADDRESS, data_type="i")
    check(
        read_back == CIO_REG_WRITTEN,
        f"STEP 9 (CIO read-back): wrote 0x{CIO_REG_WRITTEN:04X} to CIO word "
        f"{CIO_REG_ADDRESS} and an INDEPENDENT read returned {read_back!r}.",
    )
    print(
        f"[probe] step 9 OK: CIO area read/write/read-back "
        f"(CIO word {CIO_REG_ADDRESS} = 0x{read_back & 0xFFFF:04X})"
    )


# --- Step 10 ----------------------------------------------------------------


def _step10_readonly_refused(connection: UDPFinsConnection) -> None:
    """Locked is mapped ReadOnly. The write must be REFUSED with a not-writable
    end code and the value must be UNCHANGED afterwards -- a refusal that still
    mutated the tag would be worse than no refusal at all."""
    response = connection.write(999, "d", LOCKED_ADDRESS, data_type="i")
    end_code = response.end_code
    check(
        end_code == FINS_END_NOT_WRITABLE,
        f"STEP 10 (ReadOnly refusal): writing DM{LOCKED_ADDRESS} (a ReadOnly map "
        f"entry) returned end code {hexs(end_code)}, expected "
        f"{hexs(FINS_END_NOT_WRITABLE)} (not writable). A normal end code means the "
        f"refusal did not fire.",
    )

    value = connection.read("d", LOCKED_ADDRESS, data_type="i")
    check(
        value == LOCKED_VALUE,
        f"STEP 10 (ReadOnly refusal): after the refused write, DM{LOCKED_ADDRESS} "
        f"reads {value!r}, expected the UNCHANGED {LOCKED_VALUE}.",
    )
    print(f"[probe] step 10 OK: ReadOnly write refused ({hexs(end_code)}) and the value is unchanged ({value})")


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
        print(f"FINS PROBE FAIL: {err}", file=sys.stderr)
        return 1
    except Exception as err:  # noqa: BLE001 - any unexpected error is a failure
        print(f"FINS PROBE FAIL: unexpected error: {err!r}", file=sys.stderr)
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
