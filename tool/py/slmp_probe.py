#!/usr/bin/env python3
"""Real third-party Mitsubishi SLMP / MC-protocol client probe (Python lane).

Drives the pure-Python `pymcprotocol` library -- a third-party MELSEC
Communication (MC protocol, 3E binary) implementation written entirely
independently of this project -- against this project's in-app SLMP host, as
exercised by the Dart fixture host `mobile/tool/slmp_host_probe.dart`. This is
the ONLY test in the SLMP workstream that is not our codec talking to itself,
so it -- not our unit tests -- is the authority on wire details. It runs EARLY,
at Task 3, before any tag-map logic exists.

The fixture host and the shipped host (`mobile/lib/services/slmp_host.dart`) do
not merely mirror each other on the dispatch path: they SHARE it, calling the
same pure `dispatchSlmpFrame` (`mobile/lib/protocols/slmp/slmp_dispatch.dart`)
to build every response byte. So what this probe validates here is what the app
puts on the wire.

WHAT THIS PROVES, in order:

  1. connect()               -- open a TCP socket to the host. `pymcprotocol`'s
                               `Type3E.connect(ip, port)` takes the port
                               explicitly; MC protocol has no universal default
                               port, so this settles that a bound port works.
  2. read D100 (1 word)      -- `batchread_wordunits("D100", 1)` asserts the one
                               known value. This one call exercises the ENTIRE
                               framing the client cares about: the big-endian
                               subheader, the little-endian routing + length +
                               command/subcommand, the 3-byte little-endian
                               device number, the D device code (0xA8), the
                               little-endian point count, our reassembly using
                               the 3E length convention, the 0x0000 end code the
                               client's `_check_cmdanswer` validates, and the
                               little-endian word data. D100 = 0x1234, whose two
                               bytes differ, so a byte-order fault cannot pass.
  3. read D100..D103 (4)     -- proves multi-word order across adjacent D words
                               AND that a longer request reassembles (its length
                               field differs from step 2's).
  4. read W0 (device code)   -- reads the W (link register) device, a DIFFERENT
                               device code (0xB4, not D's 0xA8). If the host
                               ignored the device code, W0 would read as D0 (0)
                               instead of its seeded 0x0A0B -- so this proves the
                               device code is not discarded.

Write, bit units, and the 32-bit two-word order are DEFERRED to Task 5's
extended probe (they need the tag-backed device image and map, which Task 4
builds). This Task-3 probe deliberately proves connect + read only.

Usage: python slmp_probe.py <host> <port>
"""

from __future__ import annotations

import socket
import sys
import traceback

import pymcprotocol

# --- The fixture's layout ---------------------------------------------------
#
# Every constant below is pinned in `mobile/tool/slmp_host_probe.dart`
# (`_fixtureImage`). Keep the two files in step.

D100_DEVICE = "D100"  # D word 100
D100_VALUE = 0x1234  # its value; two bytes DIFFER so byte order is testable
# D100..D103, adjacent words, for the multi-word order + longer-frame read.
D_BLOCK_VALUES = [0x1234, 0x5678, 0x9ABC, 0xDEF0]

W0_DEVICE = "W0"  # W (link register) word 0 -- device code 0xB4, NOT D's 0xA8
W0_VALUE = 0x0A0B

# How long any single socket operation may block, in seconds. Every request
# this probe issues is a single round trip against a loopback fixture host, so a
# stall means a hang, not slowness -- bounding it here keeps the probe from
# wedging the E2E script (the script also wraps it in an outer `timeout`).
SOCKET_TIMEOUT_S = 5.0


class ProbeFailure(Exception):
    """Raised with a message naming the step that failed."""


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


def _u16(value: int) -> int:
    """`batchread_wordunits` decodes each word as a SIGNED 16-bit int; mask back
    to unsigned so the fixture's 0x9ABC/0xDEF0 (high bit set) compare cleanly."""
    return value & 0xFFFF


def run(host: str, port: int) -> None:
    # `Type3E` defaults to binary + Q-series -- exactly the 3E binary frame our
    # host serves. No `setaccessopt` call: the library's defaults (network 0,
    # pc 0xFF, dest_moduleio 0x03FF, dest_modulesta 0) are what a stock client
    # sends, and our host echoes them back permissively.
    mc = pymcprotocol.Type3E()

    # --- Step 1: connect (open the TCP socket) -----------------------------
    try:
        mc.connect(host, port)
        mc._sock.settimeout(SOCKET_TIMEOUT_S)
    except Exception as err:  # noqa: BLE001 - reported verbatim below
        raise ProbeFailure(
            f"STEP 1 (connect): the pymcprotocol client could not open a TCP "
            f"socket to {host}:{port}: {err!r}"
        ) from err
    print(f"[probe] step 1 OK: pymcprotocol Type3E connected to {host}:{port} (TCP)")

    try:
        _step2_read_d100(mc)
        _step3_read_d_block(mc)
        _step4_read_w0_device_code(mc)
    finally:
        # --- teardown: close the client socket ---------------------------------
        try:
            mc.close()
        except Exception:  # noqa: BLE001 - teardown must not mask a real failure
            pass

    print("SLMP PROBE PASS")


# --- Step 2 -----------------------------------------------------------------


def _step2_read_d100(mc: "pymcprotocol.Type3E") -> None:
    """Reads one D word via `batchread_wordunits` and asserts the value. A
    successful decode here means the client parsed our whole response frame --
    big-endian subheader, little-endian body, 0x0000 end code, little-endian
    word data -- and our host reassembled the client's request using the 3E
    length convention (`total = 9 + requestDataLength`) and decoded the D
    device code (0xA8) and 3-byte little-endian device number. D100 = 0x1234,
    whose bytes differ, so a little-endian/big-endian word-data fault fails."""
    try:
        values = mc.batchread_wordunits(headdevice=D100_DEVICE, readsize=1)
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 2 (batchread_wordunits {D100_DEVICE}): no response within "
            f"{SOCKET_TIMEOUT_S}s. The host either did not reply, or the length "
            f"reassembly desynced (check total = 9 + requestDataLength)."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 2 (batchread_wordunits {D100_DEVICE}): request failed: {err!r}. "
            f"A pymcprotocol error here is likely a non-zero end code (the client "
            f"validated our response and rejected it) or a malformed response frame."
        ) from err

    check(
        len(values) == 1,
        f"STEP 2 ({D100_DEVICE}): expected exactly 1 word, got {len(values)}: {values!r}.",
    )
    check(
        _u16(values[0]) == D100_VALUE,
        f"STEP 2 ({D100_DEVICE}): the pymcprotocol client decoded {D100_DEVICE} as "
        f"0x{_u16(values[0]):04X} ({values[0]!r}), expected 0x{D100_VALUE:04X}. A "
        f"byte-swapped result means the response word data was encoded big-endian "
        f"(the SLMP body must be little-endian); a totally wrong value means a "
        f"device-code, device-number, or length-reassembly fault.",
    )
    print(
        f"[probe] step 2 OK: batchread_wordunits({D100_DEVICE}, 1) = "
        f"0x{_u16(values[0]):04X} (little-endian word data, 0x0000 end code)"
    )


# --- Step 3 -----------------------------------------------------------------


def _step3_read_d_block(mc: "pymcprotocol.Type3E") -> None:
    """Reads FOUR adjacent D words in one request and asserts all four, proving
    word ORDER across a multi-word read and that a longer request (whose length
    field differs from step 2's single-word read) reassembles correctly."""
    try:
        values = mc.batchread_wordunits(headdevice=D100_DEVICE, readsize=len(D_BLOCK_VALUES))
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 3 (batchread_wordunits {D100_DEVICE} x{len(D_BLOCK_VALUES)}): no "
            f"response within {SOCKET_TIMEOUT_S}s."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 3 (batchread_wordunits {D100_DEVICE} x{len(D_BLOCK_VALUES)}): "
            f"request failed: {err!r}"
        ) from err

    got = [_u16(v) for v in values]
    check(
        got == D_BLOCK_VALUES,
        f"STEP 3 (multi-word read): {D100_DEVICE}..D103 read as "
        f"{[f'0x{v:04X}' for v in got]}, expected "
        f"{[f'0x{v:04X}' for v in D_BLOCK_VALUES]}. A reordered or wrong-length "
        f"result means the word order or the longer-frame reassembly is off.",
    )
    print(
        f"[probe] step 3 OK: batchread_wordunits({D100_DEVICE}, {len(D_BLOCK_VALUES)}) = "
        f"{[f'0x{v:04X}' for v in got]}"
    )


# --- Step 4 -----------------------------------------------------------------


def _step4_read_w0_device_code(mc: "pymcprotocol.Type3E") -> None:
    """Reads the W (link register) device -- a DIFFERENT device code (0xB4) from
    D (0xA8). If the host ignored the device code and served everything from D,
    W0 would read as D0 (0x0000) instead of its seeded 0x0A0B, so this proves
    the device code is discriminated, not discarded."""
    try:
        values = mc.batchread_wordunits(headdevice=W0_DEVICE, readsize=1)
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 4 (batchread_wordunits {W0_DEVICE}): no response within "
            f"{SOCKET_TIMEOUT_S}s."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 4 (batchread_wordunits {W0_DEVICE}): request failed: {err!r}"
        ) from err

    check(
        _u16(values[0]) == W0_VALUE,
        f"STEP 4 (device-code discrimination): {W0_DEVICE} (device code 0xB4) read "
        f"as 0x{_u16(values[0]):04X}, expected 0x{W0_VALUE:04X}. Reading 0x0000 "
        f"here means the host ignored the device code and served the D bank.",
    )
    print(
        f"[probe] step 4 OK: batchread_wordunits({W0_DEVICE}, 1) = "
        f"0x{_u16(values[0]):04X} (W device code 0xB4 discriminated from D 0xA8)"
    )


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
        print(f"SLMP PROBE FAIL: {err}", file=sys.stderr)
        return 1
    except Exception as err:  # noqa: BLE001 - any unexpected error is a failure
        print(f"SLMP PROBE FAIL: unexpected error: {err!r}", file=sys.stderr)
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
