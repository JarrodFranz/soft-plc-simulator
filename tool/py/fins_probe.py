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
                             raw response frame: the FINS response header, the
                             echoed command code, a NORMAL end code, and the
                             word data BIG-ENDIAN (a value whose two bytes DIFFER
                             so a byte-order fault cannot pass).
  3. read()                -- the same word via the library's high-level
                             INT decode, cross-checking the interpreted value.
  4. a two-word read       -- proves word ordering across adjacent DM words.

Step 2 is the point of the file: a real client parsing OUR response frame is
the first independent confirmation that the 10-byte header, the DNA/DA1/DA2 <->
SNA/SA1/SA2 node swap, the echoed SID, the command-code echo, the end code, and
the big-endian word data are all on the wire where the client expects them.

Usage: python fins_probe.py <host> <port>
"""

from __future__ import annotations

import socket
import struct
import sys
import traceback

from fins.udp import UDPFinsConnection, FinsPLCMemoryAreas

# --- The fixture's layout ---------------------------------------------------
#
# Every constant below is pinned in `mobile/tool/fins_host_probe.dart`
# (`_fixtureImage`). Keep the two files in step.

DM100_ADDRESS = 100  # DM word 100
DM100_VALUE = 0x1234  # its value; two bytes DIFFER so byte order is testable
DM101_ADDRESS = 101  # adjacent DM word
DM101_VALUE = 0x5678

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

    try:
        _step2_raw_memory_area_read(connection, memory_areas)
        _step3_high_level_read(connection)
        _step4_two_word_read(connection, memory_areas)
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
    frame our host built: command-code echo, NORMAL end code, and the word data
    big-endian. DM100 = 0x1234, whose bytes differ, so a little-endian encoder
    would return `34 12` and fail here."""
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
    print(
        f"[probe] step 2 OK: raw memory_area_read of DM{DM100_ADDRESS} returned "
        f"cmd={hexs(command_code)} end={hexs(end_code)} data={hexs(text)} "
        f"(big-endian 0x{DM100_VALUE:04X})"
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
