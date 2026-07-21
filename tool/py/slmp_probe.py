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

Task 5 EXTENDS this to a full read -> write -> independent read-back, adding:

  5. read D110..D111 (2)     -- the 32-bit WORD-ORDER SETTLER. The fixture seeds
                               Reg32 = 0x1A2B3C4D (an INT32 tag) INDEPENDENTLY of
                               this client; reading its two words back through
                               `pymcprotocol`'s own per-word little-endian decode
                               and asserting the LITERAL word order (low word
                               0x3C4D at the LOWER address, high word 0x1A2B at
                               the higher) settles the two-word order. A
                               write->read-back round trip alone could NOT catch
                               a word swap (it is byte-transparent through our
                               symmetric encode/decode); reading an
                               independently-seeded value is what pins it.
  6. write + read D110..D111 -- write a NEW DINT and read it back, proving the
                               WRITE (decode) path round-trips consistently with
                               the read (encode) path settled by step 5.
  7. BOOL bit at D114        -- read the containing word (bit clear), write it
                               with the bit set, read back (bit set).
  8. write D116 (ReadOnly)   -- the write MUST be refused with SLMP end code
                               0xC05B (the force/read-only write-protect code)
                               and the value MUST be unchanged afterwards.

The fixture is served through the tag-backed `SlmpTagImage` (a `SlmpMap` over
real project tags), so a write mutates a tag and a following read observes it --
exactly the shipped host's path.

Usage: python slmp_probe.py <host> <port>
"""

from __future__ import annotations

import socket
import sys
import traceback

import pymcprotocol
from pymcprotocol.mcprotocolerror import MCProtocolError

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

# --- The 32-bit word-order settler (step 5) ---------------------------------
# Reg32 is an INT32 tag the fixture SEEDS to 0x1A2B3C4D (all four bytes
# distinct, high word != low word) at D110..D111, independently of this client.
REG32_HEAD = "D110"  # low word (D110) then high word (D111)
REG32_VALUE = 0x1A2B3C4D
REG32_LOW_WORD = REG32_VALUE & 0xFFFF  # 0x3C4D -- sits at the LOWER address
REG32_HIGH_WORD = (REG32_VALUE >> 16) & 0xFFFF  # 0x1A2B -- at the higher address

# A NEW DINT written back in step 6 (also asymmetric, distinct from the seed).
REG32_WRITTEN = 0x11223344
REG32_WRITTEN_LOW = REG32_WRITTEN & 0xFFFF  # 0x3344
REG32_WRITTEN_HIGH = (REG32_WRITTEN >> 16) & 0xFFFF  # 0x1122

# --- BOOL bit (step 7) ------------------------------------------------------
FLAG_DEVICE = "D114"  # Flag (BOOL) lives in bit 0 of this word; starts False.
FLAG_BIT = 0

# --- Bit-units subcommand on an M bit device (step 7b) -----------------------
# MFlag (BOOL) is mapped at M word 0, bit 3 = device point M3; starts False.
# The bit-units subcommand (0x0001) is how Ignition's Mitsubishi driver
# addresses a Boolean on a bit device (`M3`), which the word-only v1 dropped.
MFLAG_BIT_DEVICE = "M3"  # bit-units head device (point number 3)
MFLAG_WORD_DEVICE = "M0"  # word-units view of the same memory (word 0)
MFLAG_BIT = 3  # bit position inside that word

# --- ReadOnly refusal (step 8) ----------------------------------------------
LOCKED_DEVICE = "D116"  # Locked (INT16), mapped ReadOnly.
LOCKED_VALUE = 250
# The SLMP end code the host returns for a write refused by the write gate
# (ReadOnly entry / forced root / reserved System). See
# `kSlmpEndWriteProtect` in slmp_device_image.dart.
SLMP_END_WRITE_PROTECT = "0xC05B"

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
        _step5_read_32bit_settles_word_order(mc)
        _step6_write_32bit_and_read_back(mc)
        _step7_bool_bit_round_trip(mc)
        _step7b_bit_units_m_device(mc)
        _step8_readonly_refused(mc)
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


# --- Step 5: THE 32-BIT WORD-ORDER SETTLER ----------------------------------


def _step5_read_32bit_settles_word_order(mc: "pymcprotocol.Type3E") -> None:
    """Reads the two words of Reg32 (a DINT the FIXTURE seeded to 0x1A2B3C4D)
    and asserts their LITERAL order, SETTLING the two-word order.

    `batchread_wordunits` returns each word decoded by the client's OWN per-word
    little-endian logic (`int.from_bytes(2 bytes, "little")`). Because the value
    was seeded into a tag INDEPENDENTLY of this client, the only way the low word
    (0x3C4D) lands at the LOWER address and the high word (0x1A2B) at the higher
    is if OUR multi-word encode places the low word first -- this is NOT a
    byte-transparent round trip. A word-swapped host would return
    [0x1A2B, 0x3C4D] and fail here. Reconstructing the full DINT the way
    `pymcprotocol.randomread`'s dword decode would (a 4-byte little-endian
    `int.from_bytes`) then yields exactly 0x1A2B3C4D."""
    try:
        values = mc.batchread_wordunits(headdevice=REG32_HEAD, readsize=2)
    except socket.timeout as err:
        raise ProbeFailure(
            f"STEP 5 (read 32-bit {REG32_HEAD}): no response within {SOCKET_TIMEOUT_S}s."
        ) from err
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 5 (read 32-bit {REG32_HEAD}): request failed: {err!r}") from err

    got = [_u16(v) for v in values]
    check(
        got == [REG32_LOW_WORD, REG32_HIGH_WORD],
        f"STEP 5 (32-bit WORD ORDER): the SEEDED DINT 0x{REG32_VALUE:08X} at "
        f"{REG32_HEAD}..D111 read back as words {[f'0x{v:04X}' for v in got]}, expected "
        f"[0x{REG32_LOW_WORD:04X}, 0x{REG32_HIGH_WORD:04X}] (LOW word at the lower "
        f"address, HIGH word at the higher -- LOW-WORD-FIRST). This value was seeded "
        f"into the tag independently of this client, so a swap means OUR two-word "
        f"order disagrees with a little-endian client; flip _wordSlot in "
        f"slmp_device_image.dart.",
    )
    # Reconstruct the full value the client's own dword decode would (4-byte
    # little-endian), documenting that low-word-first yields the seed exactly.
    reconstructed = got[0] | (got[1] << 16)
    check(
        reconstructed == REG32_VALUE,
        f"STEP 5 (32-bit reconstruction): the two words reconstruct to "
        f"0x{reconstructed:08X}, expected the seeded 0x{REG32_VALUE:08X}.",
    )
    print(
        f"[probe] step 5 OK: seeded DINT {REG32_HEAD} = 0x{REG32_VALUE:08X} settled "
        f"LOW-WORD-FIRST (words 0x{got[0]:04X}, 0x{got[1]:04X})"
    )


# --- Step 6: write a 32-bit value and read it back --------------------------


def _step6_write_32bit_and_read_back(mc: "pymcprotocol.Type3E") -> None:
    """Writes a NEW DINT to Reg32 (as two LOW-WORD-FIRST words) and reads it back
    in a SEPARATE request, asserting the exact words. With step 5 having settled
    the read (encode) order, a correct read-back here proves the write (decode)
    order round-trips consistently."""
    try:
        mc.batchwrite_wordunits(
            headdevice=REG32_HEAD, values=[REG32_WRITTEN_LOW, REG32_WRITTEN_HIGH]
        )
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 6 (write 32-bit {REG32_HEAD}): writing 0x{REG32_WRITTEN:08X} was "
            f"rejected: {err!r}"
        ) from err

    try:
        values = mc.batchread_wordunits(headdevice=REG32_HEAD, readsize=2)
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 6 (32-bit read-back): request failed: {err!r}") from err

    got = [_u16(v) for v in values]
    check(
        got == [REG32_WRITTEN_LOW, REG32_WRITTEN_HIGH],
        f"STEP 6 (write 32-bit read-back): wrote 0x{REG32_WRITTEN:08X} to "
        f"{REG32_HEAD}..D111 and an INDEPENDENT read returned words "
        f"{[f'0x{v:04X}' for v in got]}, expected "
        f"[0x{REG32_WRITTEN_LOW:04X}, 0x{REG32_WRITTEN_HIGH:04X}]. A word-swapped "
        f"result means the write path decoded the two words in the wrong order.",
    )
    print(
        f"[probe] step 6 OK: wrote 0x{REG32_WRITTEN:08X} to {REG32_HEAD} and read back "
        f"words 0x{got[0]:04X}, 0x{got[1]:04X}"
    )


# --- Step 7: BOOL bit round trip --------------------------------------------


def _step7_bool_bit_round_trip(mc: "pymcprotocol.Type3E") -> None:
    """Exercises a BOOL bit through its containing word: read the word (bit
    clear), write the word with the bit set, read the word back (bit set). The
    host maps Flag as BOOL at D114 bit 0 and serves/decodes only the addressed
    bit of the word."""
    try:
        word = _u16(mc.batchread_wordunits(headdevice=FLAG_DEVICE, readsize=1)[0])
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(f"STEP 7 (BOOL initial read): request failed: {err!r}") from err
    check(
        (word >> FLAG_BIT) & 1 == 0,
        f"STEP 7 (BOOL initial): {FLAG_DEVICE} bit {FLAG_BIT} (Flag) read as set "
        f"(word 0x{word:04X}); the fixture seeds it False (clear).",
    )

    try:
        mc.batchwrite_wordunits(headdevice=FLAG_DEVICE, values=[1 << FLAG_BIT])
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 7 (BOOL write): writing {FLAG_DEVICE} bit {FLAG_BIT} = True was "
            f"rejected: {err!r}"
        ) from err

    word = _u16(mc.batchread_wordunits(headdevice=FLAG_DEVICE, readsize=1)[0])
    check(
        (word >> FLAG_BIT) & 1 == 1,
        f"STEP 7 (BOOL read-back): after setting {FLAG_DEVICE} bit {FLAG_BIT} = True, "
        f"an INDEPENDENT read returned word 0x{word:04X}, whose bit {FLAG_BIT} is not "
        f"set. The bit write did not land.",
    )
    print(f"[probe] step 7 OK: BOOL bit at {FLAG_DEVICE}.{FLAG_BIT} written and read back set")


# --- Step 7b: bit-units subcommand on an M bit device -----------------------


def _step7b_bit_units_m_device(mc: "pymcprotocol.Type3E") -> None:
    """Exercises the BIT-UNITS subcommand (0x0001) on an M bit device — the
    exact shape Ignition's Mitsubishi driver uses for a Boolean (`M3`), which
    the word-only v1 dropped (5s poll timeouts, diagnosed 2026-07-21).

    `batchread_bitunits` / `batchwrite_bitunits` put the nibble-packed
    bit-unit layout on the wire (two points per byte, first point in the high
    nibble) and parse the reply themselves — a real third-party check of the
    packing in both directions. The step ends with a WORD-units read of the
    same memory (M0) to prove the bit and word views are the same image.
    """
    # (1) Initial bit-units read: M3 (MFlag, seeded False) and its neighbour.
    try:
        bits = mc.batchread_bitunits(headdevice=MFLAG_BIT_DEVICE, readsize=2)
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 7b (bit-units read): request failed: {err!r}. The host must "
            f"serve Batch Read with the BIT subcommand (0x0001), not drop it."
        ) from err
    check(
        bits == [0, 0],
        f"STEP 7b (bit-units initial): {MFLAG_BIT_DEVICE} x2 read as {bits!r}, "
        f"expected [0, 0] (MFlag seeded False, neighbour a gap).",
    )

    # (2) The Ignition Boolean write shape: bit-units write of ONE point.
    try:
        mc.batchwrite_bitunits(headdevice=MFLAG_BIT_DEVICE, values=[1])
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 7b (bit-units write): writing {MFLAG_BIT_DEVICE} = 1 was "
            f"rejected: {err!r}"
        ) from err

    # (3) Independent bit-units read-back.
    bits = mc.batchread_bitunits(headdevice=MFLAG_BIT_DEVICE, readsize=1)
    check(
        bits == [1],
        f"STEP 7b (bit-units read-back): after writing 1, {MFLAG_BIT_DEVICE} read "
        f"as {bits!r}, expected [1]. The bit-units write did not land.",
    )

    # (4) Cross-view: a WORD-units read of M0 must show bit 3 set — the bit
    # and word views must be the same memory.
    word = _u16(mc.batchread_wordunits(headdevice=MFLAG_WORD_DEVICE, readsize=1)[0])
    check(
        (word >> MFLAG_BIT) & 1 == 1,
        f"STEP 7b (bit->word consistency): after the bit-units write, a "
        f"word-units read of {MFLAG_WORD_DEVICE} returned 0x{word:04X} with bit "
        f"{MFLAG_BIT} clear -- the bit and word views are not the same memory.",
    )

    # (5) Clear it again through bit-units and confirm.
    mc.batchwrite_bitunits(headdevice=MFLAG_BIT_DEVICE, values=[0])
    bits = mc.batchread_bitunits(headdevice=MFLAG_BIT_DEVICE, readsize=1)
    check(
        bits == [0],
        f"STEP 7b (bit-units clear): after writing 0, {MFLAG_BIT_DEVICE} read as "
        f"{bits!r}, expected [0].",
    )
    print(
        f"[probe] step 7b OK: bit-units subcommand on {MFLAG_BIT_DEVICE} -- "
        f"nibble-packed read/write/clear, consistent with the word view "
        f"(the Ignition M-device Boolean shape)"
    )


# --- Step 8: ReadOnly write is refused --------------------------------------


def _step8_readonly_refused(mc: "pymcprotocol.Type3E") -> None:
    """Locked is mapped ReadOnly. The write MUST be refused with the SLMP
    write-protect end code (0xC05B), which `pymcprotocol` surfaces by raising
    `MCProtocolError`; the value MUST be unchanged afterwards -- a refusal that
    still mutated the tag would be worse than no refusal at all."""
    try:
        mc.batchwrite_wordunits(headdevice=LOCKED_DEVICE, values=[999])
    except MCProtocolError as err:
        # MCProtocolError renders errorcode as e.g. "0xC05B" (a lowercase "0x"
        # prefix + uppercase hex); compare case-insensitively on the hex digits.
        check(
            err.errorcode.lower() == SLMP_END_WRITE_PROTECT.lower(),
            f"STEP 8 (ReadOnly refusal): writing {LOCKED_DEVICE} (a ReadOnly map "
            f"entry) raised end code {err.errorcode}, expected {SLMP_END_WRITE_PROTECT} "
            f"(write protect). A different code means the refusal fired for the wrong "
            f"reason.",
        )
    except Exception as err:  # noqa: BLE001 - reported verbatim
        raise ProbeFailure(
            f"STEP 8 (ReadOnly refusal): writing {LOCKED_DEVICE} failed with an "
            f"unexpected error (not an MC-protocol end code): {err!r}"
        ) from err
    else:
        raise ProbeFailure(
            f"STEP 8 (ReadOnly refusal): writing {LOCKED_DEVICE} (a ReadOnly map entry) "
            f"was ACCEPTED (no error). The write gate did not refuse it."
        )

    value = _u16(mc.batchread_wordunits(headdevice=LOCKED_DEVICE, readsize=1)[0])
    check(
        value == LOCKED_VALUE,
        f"STEP 8 (ReadOnly refusal): after the refused write, {LOCKED_DEVICE} reads "
        f"0x{value:04X} ({value}), expected the UNCHANGED {LOCKED_VALUE}.",
    )
    print(
        f"[probe] step 8 OK: ReadOnly write refused ({SLMP_END_WRITE_PROTECT}) and the "
        f"value is unchanged ({value})"
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
