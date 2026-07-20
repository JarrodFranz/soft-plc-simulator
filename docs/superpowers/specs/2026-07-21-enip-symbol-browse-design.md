# EtherNet/IP CIP Symbol Object (class 0x6B) tag-directory browse — design

**Date:** 2026-07-21
**Status:** Approved (design)
**Program:** Protocol interop follow-ups (EtherNet/IP v1 shipped in Phase 14; this closes the deferred browse gap)

## Problem

The app's in-app EtherNet/IP device side serves symbolic **Read Tag (0x4C)** /
**Write Tag (0x4D)** and the **Multiple Service Packet (0x0A)** — a client that
already knows a tag's name can read and write it. But a Logix-style client
(pycomm3 `LogixDriver`, Ignition's Allen-Bradley Logix driver) **discovers**
tags by uploading a tag directory at connect time from the CIP **Symbol Object
(class 0x6B)**. The app does not serve that object (deliberately deferred in
v1), so those clients connect successfully — the Identity Object answers, the
device shows *Connected* — but their tag browser is **empty**. The diagnostic
tags a browsing client does show (DeviceType, ProductName, …) come from the
Identity Object and describe the *connection*, not the PLC's tags.

Confirmed against a live Ignition 8.3 session: connection healthy, one client,
zero tags visible.

## Goal

Serve the CIP Symbol Object so a Logix-style client auto-discovers the app's
mapped tags. Success is `pycomm3`'s `LogixDriver.open()` + `get_tag_list()`
returning the project's mapped tags, and a subsequent read of a browsed tag
succeeding — proven by the existing Python probe lane. Ignition is the
real-world target; pycomm3 is the automated wire authority (same CIP spec).

## Key simplification: everything exposed is atomic

`CipMap.autoPopulate` already pre-expands composite/array tags into **one
scalar leaf per entry**, keyed by its dotted/indexed resolver path
(`Tank.Level`, `System.Fault`, `Arr[0]`), and **skips `STRING`**. Every
`CipMapEntry` therefore maps to an **elementary** CIP type
(`cipTypeForTagType` → BOOL/INT/DINT/LINT/REAL). Because no *structured* type
is ever exposed, the browse advertises only atomic symbols and the heavy
**Template Object (class 0x6C) is NOT built** in this version. This is the
core scope decision (approved): **flat atomic symbols**, one Symbol Object
instance per `CipMapEntry`, named by the entry's exact `tagName` (dotted names
included), typed by its elementary CIP code. The browsed name is always the
same string Read/Write Tag already resolve, so a browsed tag is always
readable.

The alternative — modelling composites as structured symbols with the Template
Object describing UDT memory layout so tags nest like a real Logix controller
— was rejected as a much larger scope (a whole second CIP object plus
member/offset math) that buys nothing for the atomic values the app actually
holds.

## Architecture

One new elementary CIP service — **Get Instance Attribute List (0x55)** —
answered only when the request path addresses the Symbol class (logical Class
0x6B). It is added to the single existing dispatch seam,
`dispatchCipService`, which both the unconnected (`SendRRData`) and connected
(`SendUnitData`) host paths already call. Everything is additive; no existing
wire behaviour changes, and a project that never enables EtherNet/IP is
unaffected.

### Components

- **`mobile/lib/protocols/enip/cip_symbol.dart`** (new; pure Dart, no
  `dart:io`/Flutter; never throws). Two responsibilities:
  - Parse a Get Instance Attribute List request: the **start instance** from
    the request path's Instance segment (0 if none), and the **requested
    attribute id list** (count u16 + that many u16 ids) from the request data.
  - Build the instance-attribute-list reply from a `CipMap`: for each entry in
    ascending instance-id order starting at the start instance, emit the
    instance id (u32) then each requested attribute, filling until the next
    instance would overrun the reply budget, then stopping. Returns the reply
    bytes plus the CIP general status to use (0x00 complete / 0x06 partial).
  - **Instance ids** are a stable **1-based index into `map.entries`** in
    stored order — deterministic, so pagination "resume at last + 1" maps
    cleanly onto list position.
  - **Attribute encodings**: attr **1 (symbol name)** = CIP string (u16 byte
    length + ASCII bytes); attr **2 (symbol type)** = u16 elementary type code
    (`cipTypeForTagType(entry)`), structure and dimension bits clear. An entry
    whose type has no CIP mapping (a stale `STRING` map entry) is skipped from
    the listing rather than emitted with a bogus type. The exact per-attribute
    byte layout is verified against `pycomm3`'s own Symbol-Object parser — the
    wire authority — not assumed.
- **`mobile/lib/protocols/enip/cip_tags.dart`** (`dispatchCipService`): add a
  `case kCipServiceGetInstanceAttributeList (0x55):` branch that checks the
  request path targets **Class 0x6B** and delegates to `cip_symbol.dart`. A
  0x55 addressed to any other class returns the existing not-supported /
  path-unknown status. The function already receives `responseBudget` (the
  Forward Open T→O connection size on a connected send, else `null`); the
  Symbol browse reuses it for pagination.
- **`tool/py/enip_probe.py`**: extend to also drive `LogixDriver.open()` +
  `get_tag_list()` (browse) and a read of a browsed tag, in addition to the
  existing low-level `CIPDriver` read/write coverage.
- **`docs/protocols/ethernet-ip.md`**: move the Symbol Object out of the
  "deliberately deferred" list; document flat-atomic browse, the pagination
  behaviour, and what remains deferred (Template Object / UDT structure,
  `STRING`, arrays as multi-element symbols).

## Wire flow — Get Instance Attribute List over class 0x6B

- **Request:** path = logical Class 0x6B + Instance `<start>` (0 on the first
  call); data = attribute-count (u16) then that many attribute ids (u16 each).
  A Logix-style client asks for **1 = symbol name** and **2 = symbol type**.
- **Reply data:** for each returned instance, in ascending id order from
  `<start>`: instance id (u32), then the requested attributes in the order
  asked — attr 1 as CIP string, attr 2 as u16 type code. Emit instances until
  the next one will not fit the reply budget.
- **Pagination / status:** if instances remain unsent, the general status is
  **0x06 (partial transfer)** and the client re-issues from
  `last_returned_id + 1`; when the final batch fits, status is **0x00**. This
  is exactly how `get_tag_list` walks the directory and is what lets a large
  map browse across a size-limited reply.
- **Reply budget:** bounded by the negotiated connection size when the request
  arrives over a connected send, and by the UCMM single-reply cap when
  unconnected — pagination respects whichever applies, so even the unconnected
  path never emits an oversized frame.

## The real risk → probe-early gate

The genuine unknown is **what `LogixDriver.open()` requires before it will call
`get_tag_list()`**: pycomm3 reads controller identity/info attributes during
`open()`, and if one is missing, `open()` fails before browse is ever
attempted. Therefore the **first task after the codec is a real-`pycomm3`
gate**: stand up the fixture host, run `LogixDriver(...).open()` +
`get_tag_list()`, and observe what the client actually demands. Any additional
Identity/controller attribute it needs is added **because the client asked for
it**, discovered at the gate, not guessed up front.

The second settled question is whether pycomm3 accepts a **dotted atomic
symbol** (`Tank.Level`) in the tag list — a real controller lists `Tank` as a
structure, not `Tank.Level` as an atomic. The probe proves the mechanism with
a **plain top-level scalar first**, then a **dotted leaf**, to confirm the
representation. If the real client rejects dotted flats, the representation is
adjusted (a sanitized separator, or listing only dot-free top-level scalars in
v1) and the change is reported — the client wins.

## Edge cases & invariants

- `cip_symbol.dart` **never throws** on malformed/truncated/hostile 0x55 data —
  it returns an error status, mirroring `cip.dart`/`enip_encap.dart`.
- **Deterministic**: stable instance-id order, no clock, no randomness.
- **Read-only discovery**: browse touches no tag values; the force / ReadOnly /
  reserved-`System` write refusals in `cip_tags.dart` are entirely unaffected.
- **Additive persistence**: no `CipMap` serialized-shape change; the Symbol
  listing is derived from the existing map on each request.
- **Empty map** browses cleanly (status 0x00, zero instances) rather than
  erroring.

## Testing

- **Pure unit tests** for `cip_symbol.dart`: request parse (start instance from
  path, attribute-id list from data); reply byte layout for each atomic type
  (BOOL/INT/DINT/LINT/REAL) asserted against **literal bytes**, not only
  round-trips; the pagination boundary emitting **0x06** with resume, and the
  final batch emitting **0x00**; an empty map; a dotted-name entry
  (`Tank.Level`); a stale-`STRING` entry skipped; malformed request data →
  error status.
- **Dispatch routing test**: `0x55` addressed to Class 0x6B routes to browse;
  `0x55` to another class returns the existing not-supported status; existing
  Read/Write/MSP routing is unchanged.
- **Full pycomm3 `LogixDriver` E2E** (`tool/enip_e2e.sh`): `open()` →
  `get_tag_list()` returns the mapped tags → read one browsed tag back. Records
  what the gate settled about `open()`'s requirements and the dotted-name
  representation.
- Zero `flutter analyze` warnings; no competitor programming-software branding.

## Task breakdown (preview for the plan)

1. `cip_symbol.dart` codec (request parse + reply build + pagination) with pure
   unit tests.
2. Wire `0x55@0x6B` into `dispatchCipService`, then the **early `LogixDriver`
   browse gate** against the fixture host — settles `open()`'s requirements and
   the dotted-name representation before more logic is built on top.
3. Pagination + reply-budget correctness across connected/unconnected sends,
   plus any Identity/controller attribute the gate surfaced.
4. Full pycomm3 `LogixDriver` E2E, docs, and final review.

## Out of scope (deferred, documented at the source)

- **Template Object (class 0x6C) / UDT structure** — not needed while only
  atomic leaves are exposed; composites browse as flat dotted symbols.
- **`STRING`** — still a structured type needing the Template Object.
- **Arrays as multi-element symbols** — array leaves already browse as
  per-element flat symbols (`Arr[0]`), consistent with the map.
- **Implicit (Class 1 I/O) messaging, Large Forward Open, ListIdentity** —
  unchanged from EtherNet/IP v1's deferrals.
