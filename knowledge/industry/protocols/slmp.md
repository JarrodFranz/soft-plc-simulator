---
id: knowledge:industry/protocols/slmp
title: SLMP (MC Protocol)
domain: industry/protocols
version: "2026-08"
topics: [slmp, mc-protocol, mitsubishi, 3e-frame, little-endian, mixed-endian, device-code]
summary: Mitsubishi SLMP 3E binary wire format, its mixed-endian subheader/body split, device + device-number addressing, the low-word-first 32-bit order, and how an in-app pure-Dart server implements and E2E-proves it against a real pymcprotocol client.
related:
  - knowledge:industry/protocols/index
  - knowledge:industry/protocols/endianness-and-framing
  - knowledge:industry/protocols/fins
learnings: [CL-5]
---

# SLMP (MC Protocol)

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** distilled from `mobile/lib/protocols/slmp/slmp_frame.dart`,
> `slmp_commands.dart`, `slmp_device_image.dart`, `slmp_dispatch.dart`,
> `mobile/lib/services/slmp_host.dart`, and the real-client E2E script
> `tool/slmp_e2e.sh`.
> **Read this before:** implementing or debugging an SLMP/MC-protocol
> client/server, diagnosing a subheader-vs-body endianness mismatch, or a
> bit-unit (nibble-packed) device write.

---

## 1. The headline rule

**SLMP 3E binary is little-endian throughout its body, with exactly ONE documented exception: the 2-byte subheader is big-endian - a genuinely mixed-convention wire format, not a copy-paste error to "fix".**

This is the exact inverse of S7comm and FINS (both big-endian throughout) sitting right next to it in this protocol family, which makes SLMP the easiest place in the whole suite to introduce a pattern-matched endianness bug by copying a neighboring codec's convention.

---

## 2. Wire format

### 2.1 Frame layout (length-prefixed TCP)

`subheader` u16 **BIG-ENDIAN** (`0x5000` request -> bytes `0x50, 0x00`; `0xD000` response -> `0xD0, 0x00`), then routing (`network` u8, `pc` u8 - `0xFF` = host station, `destModuleIo` u16, `destModuleStation` u8), `requestDataLength` u16 **little-endian** - counts the bytes that **follow it** (monitoring timer + command + subcommand + data), does **not** include the 9-byte fixed prefix before it - `monitoringTimer` u16, `command` u16, `subcommand` u16, then command data. A response mirrors the shape with a `responseDataLength` (end code + data that follow it) and an `endCode` u16 (`0x0000` = success).

**The length-field convention is the trap this transport most easily gets wrong.** Because `requestDataLength` excludes the fixed 9-byte prefix, a stream reassembler must compute the total frame size as `9 + requestDataLength` - not `requestDataLength` alone, and not counting the subheader/routing bytes inside it. This is the opposite convention from TPKT's length (S7comm), which counts the whole packet including its own header (see [s7comm.md](./s7comm.md)).

### 2.2 Byte order: the one documented mixed convention

**The body - routing fields, `requestDataLength`, the 3-byte device number, the point count, every encoded word value - is little-endian throughout.** The **one** exception is the 2-byte subheader, which is big-endian. This mixed convention is not an implementation quirk invented locally - a real third-party client (`pymcprotocol`) emits the subheader with an explicit big-endian conversion and every other field little-endian (CL-5), and settled an earlier draft that had wrongly written the subheader little-endian too.

A build-parse round trip inside one implementation cannot catch an endianness bug of this shape - it cancels out perfectly even when fully broken. Byte-order claims for a mixed-convention format need literal expected-byte fixture tests, not only round-trips.

### 2.3 Device addressing

| Device | Wire code |
|---|---|
| Data register (D) | `0xA8` |
| Internal relay (M) | `0x90` |
| Link register (W) | `0xB4` |
| File register (R) | `0xAF` |

Both a **word-units** subcommand (`0x0000`) and a **bit-units** subcommand (`0x0001`) are commonly required in practice - **Ignition's Mitsubishi driver polls a bit device (`M0`) with subcommand `0x0001`**, a distinct code path from word-units reads, and a word-only build drops every such poll outright (5-second timeouts, not a decode error - diagnosed 2026-07-21).

In 3E binary, **bit-unit data is nibble-packed** - two points per byte, the FIRST point in the HIGH nibble, an odd final point leaving the trailing low nibble `0`. The device number counts **points**: point number `n` addresses word `n >> 4`, bit `n & 15` of the word-addressed map - consistent with word-unit access packing 16 points per word. Bit-unit reads/writes must be served off the exact same underlying word image as word-unit access, or the two addressing modes silently disagree about the same memory.

### 2.4 The 32-bit word order - low word first

A 32-bit (or wider) value spans two or more consecutive words, and - exactly as with FINS - which word holds the high half is a separate axis from byte order that a self-consistent round trip cannot verify. **Settled by a real client (CL-5's companion finding): low word at the lower word address, little-endian within each word.** `DINT 0x1A2B3C4D` occupies word N = `0x3C4D` (low), word N+1 = `0x1A2B` (high) - on the wire, bytes `4D 3C 2B 1A`. This must be proven by seeding a value independently of the client under test, not by a write-then-read-back through the same encode/decode path.

---

## 3. Transport and port

TCP, no universal default port defined by the MC-protocol standard itself (a common convention like `5007` is a deployment choice, not a spec mandate) - unprivileged on every native platform, so the port is safely user-editable with no privileged-port caveat.

---

## 4. Addressing / map model

Like FINS, SLMP addresses **device + device number** (word-addressed) rather than a symbolic name. A general binding model mirrors FINS/S7comm's area-image approach: materialize a packed word image of a device from named points, serve slices, decode written slices back onto overlapping points. Gap/partial-coverage/write-refusal semantics mirror the same S7comm/FINS pattern: unmapped words read as zero, writes to unmapped words are silently discarded, a partially-covered point's write is explicitly refused rather than corrupted.

## 5. What the in-app host implements

*(app-specific - this section describes this repository's implementation, not the SLMP standard itself.)*

The 3E binary frame only (not 4E, which adds a serial-number correlation header; not the ASCII variant). Devices served: `D`/`M`/`W`/`R`, in both word-units and bit-units subcommands. Types: `BOOL`(1 bit), `INT16`(1 word), `INT32`(2), `INT64`(4-word integer), `FLOAT64`->`REAL`(2 words, narrowed to single precision, lossy round-trip by design). `STRING`, iQ-R extended subcommands (`0x0002`/`0x0003`), and Random read/write commands are not served - **Ignition's Mitsubishi driver sends the iQ-R extended subcommands (with 4E framing) when its device Series is set to iQ-R**, which this scope doesn't cover; setting **Device Series = Q** (or L) on the driver is the documented workaround, not a defect in the 3E/standard-subcommand implementation.

## 6. Write-gate interaction

A write to a read-only map entry, or to a **FORCED** point, is refused with a write-protect end code, the point left unchanged - resolved against the point's root, the same shared write-gate backstop every adapter in this suite consults.

## 7. Real-client E2E proof

Proven against a genuine third-party **`pymcprotocol`** client (v0.3.0 - pure Python, socket-based, no native library; it was the arbiter that settled both the length-field convention and the subheader/body endianness split). The probe drives a single-word Batch Read, a four-word block read (proving multi-word order + longer-frame reassembly), a `W`-device read (proving device-code discrimination), **the 32-bit settler** (a DINT with all four bytes distinct, seeded independently of the client, asserting the literal low-word-first order), a DINT write with independent read-back, a BOOL bit round trip in both word-view and bit-units-subcommand forms cross-checked against each other - the byte-for-byte **Ignition M-device Boolean shape** - and a read-only-entry write refusal asserting the client's own decoded error carries the exact write-protect end code.

### 7.1 Connecting Ignition's Mitsubishi driver (the proven recipe, 2026-07-21)

1. **Device Series = Q** (or L). iQ-R makes the driver send 4E frames + extended subcommands, which are dropped - every poll then times out (~5s response times in the device Details page) while the device still shows connected.
2. **Addresses must be registered on the Gateway first** (device config -> its address-configuration page). This driver does NOT resolve freeform typed OPC item paths; an unregistered address is `Bad_NodeIdUnknown` before any poll is sent.
3. **32-bit values:** the driver's default word order (`@HL`) matches this host's low-word-first wire layout - `D<float>1` / `D<float@HL>1` reads a REAL at D1..D2 correctly (`@LH` scrambles it to a denormal that displays as 0).
4. **Writable Booleans:** map the tag to an **M device** in the app's SLMP map and address it as `M<n>` (natively Boolean, read/write via the bit-units subcommand). A bit index on a word device (`D0.0`) reads fine but is **read-only in the driver** (writes fail `Bad_NotSupported`), and `M<n>.<bit>` is invalid - M is already a bit device.

## 8. Gotchas

- **CL-5: SLMP 3E binary is little-endian EXCEPT the 2-byte subheader (big-endian) - a documented mixed convention, confirmed against a real client, not a bug to "fix" by making the subheader little-endian too.**
- **Do not pattern-match S7comm's or FINS's big-endian convention onto SLMP's body, and do not pattern-match SLMP's little-endian body onto its own subheader.** Both directions of copy-paste are live risks in this specific protocol because of the split convention.
- **The length field excludes the fixed prefix before it - total frame size is `9 + requestDataLength`, not `requestDataLength` alone.** This is the opposite of TPKT's length (S7comm), which includes its own header.
- **A word-only implementation silently fails Ignition's Mitsubishi driver, which polls a bit device (`M0`) with the bit-units subcommand by default.** This manifests as 5-second poll timeouts on that specific device type while the device still shows connected, not as a decode error, which makes it easy to misdiagnose as a network problem.
- **32-bit word order (low-word-first here, same as FINS) is settled the same way as FINS's - only an externally-seeded value read by a genuinely independent client implementation can prove it; a round trip cannot.** Ignition's driver default word order (`@HL`) matches this convention; `@LH` reads it scrambled.

```
Wrong: read the SLMP subheader as little-endian because "the rest of the
       frame is little-endian".
Correct: the subheader specifically is big-endian - every other field in
       the frame (routing, length, device number, point count, word data)
       is little-endian. This split is confirmed against a real client's
       own wire behavior, not an artifact of one implementation.
```

---

## What this means practically

### "My reassembler either buffers forever or throws away valid frames - what's wrong with my length math?"
Confirm which convention the length field uses: does it count the whole frame (S7comm's TPKT-style, include-self) or only what follows a fixed prefix (SLMP's style, exclude-prefix)? Applying the wrong one either under-counts (truncating frames) or over-counts (never completing a frame) by exactly the size of the fixed prefix/header.

### "A device driver configured for a newer PLC family times out against my 3E-binary-only implementation - why?"
Check whether that device family/series defaults to a different frame variant (a serial-number-correlated header, or extended subcommands) rather than the plain 3E binary frame with standard subcommands. Downgrading the driver's configured device series to an earlier-generation-compatible mode is the standard fix when the target only serves 3E binary + standard subcommands.

---

## Related

- [fins.md](./fins.md) - shares the low-word-first 32-bit order and the memory-area/word-addressed model, but from the opposite (big-endian) byte-order baseline.
- [s7comm.md](./s7comm.md) - the opposite length-field convention (include-header vs. exclude-prefix) for a length-prefixed TCP frame.
- [endianness-and-framing.md](./endianness-and-framing.md) - the cross-protocol byte-order/framing comparison table.
- [index.md](./index.md) - domain hub.
