// CIP Connection Manager — pure Dart, no dart:io / Flutter imports.
// Implements the Connection Manager object (class `0x06`, instance 1)
// services used to establish and tear down a *connected* CIP messaging path
// over UCMM (`SendRRData`): **Forward Open** (service `0x54`) and
// **Forward Close** (service `0x4E`), per public CIP specification
// material. This layer sits ABOVE `cip.dart`: it consumes an
// already-parsed `CipRequest` — the outer CIP request envelope and the
// EPATH addressing the Connection Manager object have already been decoded
// by `parseCipRequest` — and only interprets the Forward Open / Forward
// Close *service data* carried in `CipRequest.data`. It returns a
// `CipResponse` for the caller to serialize with `buildCipResponse`; this
// file never touches the outer wire envelope and does not import
// `enip_encap.dart`.
//
// Wire reference (Forward Open / Forward Close service data — all
// multi-byte fields little-endian; read/written via `ByteData` rather than
// hand-rolled shifts, per this codebase's dart2js-safety convention for
// wide values):
//
// WHICH SIDE ALLOCATES WHICH CONNECTION ID — the single most important
// thing in this file, and the one detail this codec originally had
// BACKWARDS (caught by the Task 6 real-client E2E, `tool/py/enip_probe.py`,
// not by any of this project's own unit tests, which only ever proved the
// codec self-consistent). The rule is: **the CONSUMER of a direction's data
// allocates that direction's connection id.**
//   - The TARGET (this host) consumes O->T traffic, so the TARGET allocates
//     the **O->T** Network Connection ID. The originator sends `0` as a
//     placeholder in the request and reads the real value out of the reply.
//     That allocated O->T id is the id every subsequent connected message
//     (`SendUnitData`) from the originator is addressed to, and therefore
//     the id [CipConnectionManager.byConnectionId] looks connections up by.
//   - The ORIGINATOR consumes T->O traffic, so the ORIGINATOR allocates the
//     **T->O** Network Connection ID and sends it in the request; the target
//     echoes it back unchanged.
// Getting this backwards is silently survivable in a self-test (both sides
// agree with themselves) and fatal against a real client: it hands the
// originator a connection id of `0` and every connected message it then
// sends is unroutable.
//
//  Forward Open (0x54) request:
//   - Priority/Time_tick: u8
//   - Timeout_ticks: u8
//   - O->T Network Connection ID: u32 (a placeholder — typically `0` — that
//     this layer IGNORES: the target allocates this direction's id itself,
//     per the rule above and the determinism requirement below)
//   - T->O Network Connection ID: u32 (allocated by the originator; echoed
//     back unchanged in the reply — never reinterpreted by this layer)
//   - Connection Serial Number: u16
//   - Originator Vendor ID: u16
//   - Originator Serial Number: u32
//   - Connection Timeout Multiplier: u8
//   - Reserved: 3 bytes
//   - O->T Requested Packet Interval: u32
//   - O->T Network Connection Parameters: u16 (this is the regular Forward
//     Open, service `0x54` — not the Large Forward Open, `0x5B`, whose
//     connection-parameters fields are u32)
//   - T->O Requested Packet Interval: u32
//   - T->O Network Connection Parameters: u16
//   - Transport Type/Trigger: u8
//   - Connection Path Size: u8 (in 16-bit words)
//   - Connection Path: `pathSize * 2` bytes — the path to the object being
//     connected to. This layer only needs to consume its byte length
//     correctly to find the end of the request; decoding its segments is
//     out of scope for the connection manager itself.
//
//  Forward Open reply (success) — 26 bytes, no application reply data:
//   - O->T Network Connection ID: u32 (**allocated by this layer** — the id
//     the originator will address its connected messages to)
//   - T->O Network Connection ID: u32 (echoed from the request)
//   - Connection Serial Number: u16 (echoed)
//   - Originator Vendor ID: u16 (echoed)
//   - Originator Serial Number: u32 (echoed)
//   - O->T Actual Packet Interval: u32 (this codec accepts the requested
//     O->T RPI unchanged — there is no scanner-side timing constraint to
//     negotiate against — rather than computing a different actual value)
//   - T->O Actual Packet Interval: u32 (same: echoes the requested T->O RPI)
//   - Application Reply Size: u8 (always `0`)
//   - Reserved: u8 (`0x00`)
//
//  Forward Close (0x4E) request:
//   - Priority/Time_tick: u8
//   - Timeout_ticks: u8
//   - Connection Serial Number: u16
//   - Originator Vendor ID: u16
//   - Originator Serial Number: u32
//   - Connection Path Size: u8 (words)
//   - Reserved: u8
//   - Connection Path: `pathSize * 2` bytes
//
//  Forward Close reply (success) — 10 bytes, no application reply data:
//   - Connection Serial Number: u16 (echoed)
//   - Originator Vendor ID: u16 (echoed)
//   - Originator Serial Number: u32 (echoed)
//   - Application Reply Size: u8 (always `0`)
//   - Reserved: u8 (`0x00`)
//
// A Forward **Close** is matched against an open connection by the triple
// (Connection Serial Number, Originator Vendor ID, Originator Serial
// Number) — never by connection id, since a Forward Close request does not
// carry either connection id. Closing a triple that does not match any
// open connection returns a non-zero general status; it never throws and
// never silently succeeds.
//
// Non-throwing contract: `forwardOpen` and `forwardClose` are fed arbitrary
// bytes off the wire (via the socket host, ultimately) and must never throw
// on malformed, truncated, or hostile input — they always return a
// `CipResponse`, using a non-zero `generalStatus` to signal failure,
// mirroring `cip.dart`'s convention.
//
// Determinism: the Originator-to-Target (O->T) connection id — the only
// connection id this layer allocates, per the echo semantics above — comes
// from a monotonic counter seeded at `kInitialTargetConnectionId`. It is
// never derived from `Random`, a hash, or the clock, so tests can assert
// exact allocated ids and repeated runs are byte-for-byte reproducible.
library cip_connection;

import 'dart:typed_data';

import 'cip.dart';

// --- Service codes this layer handles -------------------------------------
//
// Not defined in `cip.dart` (Task 2's scope was limited to the Read/Write
// Tag service codes) — the Connection Manager object's own two services.
// A caller (the socket host) routing a `SendRRData` UCMM request needs these
// to decide whether a request goes to [forwardOpen]/[forwardClose] or to the
// tag-service dispatcher (`cip_tags.dart`'s `dispatchCipService`).
const int kCipServiceForwardOpen = 0x54;
const int kCipServiceForwardClose = 0x4E;
//
// `kCipStatusConnectionFailure` (general status `0x01`, "Connection
// failure") — used both for a Forward Open that cannot be honored and for a
// Forward Close that does not match any open connection — now lives in
// `cip.dart` alongside the rest of the CIP general-status codes (moved
// there for consolidation; see that file's doc comment). This codec does
// not emit extended status words (mirroring `cip.dart`'s
// `buildCipResponse`, which always writes `additionalStatusWords = 0`), so
// the specific sub-reason is not distinguished on the wire.

/// The first connection id allocated by a fresh [CipConnectionManager] —
/// i.e. the first **Originator-to-Target** id, the direction whose data
/// this target consumes and whose id it therefore allocates (see the file
/// header). Documented as a named constant (rather than an inline literal)
/// because determinism here is a hard requirement: tests assert exact
/// allocated ids, so this value must never change silently by switching to
/// a random or clock-derived source. `0` is reserved to mean "no
/// connection" on the wire and is therefore never allocated — a real client
/// treats a returned id of `0` as a failed Forward Open.
const int kInitialTargetConnectionId = 1;

/// Byte length of the fixed-position Forward Open request fields, before
/// the variable-length connection path.
const int _kForwardOpenFixedLen = 36;

/// Mask selecting the Connection Size (in bytes) from a regular Forward Open
/// Network Connection Parameters u16 word: the low 9 bits (bits 0-8). The
/// remaining bits carry the connection type, priority, size type (fixed vs
/// variable) and redundant-owner flag — none of which this target needs to
/// bound a reply, which depends only on the byte count. (The Large Forward
/// Open, service `0x5B`, whose parameters are u32 with a wider size field, is
/// deliberately not implemented — see the file header and the E2E, which
/// proves the regular-`0x54` fallback path.)
const int _kNetworkConnectionSizeMask = 0x01FF;

/// Byte length of the fixed-position Forward Close request fields, before
/// the variable-length connection path.
const int _kForwardCloseFixedLen = 12;

/// A single established CIP connection, as created by a successful
/// [CipConnectionManager.forwardOpen] and released by a matching
/// [CipConnectionManager.forwardClose].
class CipConnection {
  /// The Originator-to-Target connection id, **allocated by**
  /// [CipConnectionManager] from its monotonic counter (this target
  /// consumes O->T traffic, so this target allocates its id — see the file
  /// header). This is the id a caller looks connections up by via
  /// [CipConnectionManager.byConnectionId]: it is the id the originator
  /// puts in the Connected Address item of every connected message
  /// (`SendUnitData`) it sends.
  final int connectionIdOT;

  /// The Target-to-Originator connection id, echoed unchanged from the
  /// Forward Open request that created this connection (the originator
  /// consumes T->O traffic, so the originator allocates its id).
  final int connectionIdTO;

  /// The **Target-to-Originator** connection size in bytes, decoded from the
  /// T->O Network Connection Parameters word of the Forward Open request.
  /// This is the size of the replies the TARGET sends, so it is the budget a
  /// connected [dispatchCipService] must keep a Multiple Service Packet reply
  /// within — a client that negotiates this size must never be handed a
  /// larger connected frame. See `cip_tags.dart`'s MSP budget.
  final int connectionSizeTO;

  /// The **Originator-to-Target** connection size in bytes, decoded from the
  /// O->T Network Connection Parameters word. This bounds the size of the
  /// requests the originator sends; the target does not enforce it (it only
  /// bounds what it SENDS, via [connectionSizeTO]), but it is decoded and
  /// retained alongside its T->O counterpart for completeness.
  final int connectionSizeOT;

  /// Connection Serial Number, from the Forward Open request. Part of the
  /// triple a Forward Close matches against.
  final int connectionSerial;

  /// Originator Vendor ID, from the Forward Open request. Part of the
  /// triple a Forward Close matches against.
  final int vendorId;

  /// Originator Serial Number, from the Forward Open request. Part of the
  /// triple a Forward Close matches against.
  final int originatorSerial;

  CipConnection({
    required this.connectionIdOT,
    required this.connectionIdTO,
    required this.connectionSizeTO,
    required this.connectionSizeOT,
    required this.connectionSerial,
    required this.vendorId,
    required this.originatorSerial,
  });
}

/// Implements the Connection Manager object's Forward Open / Forward Close
/// services: establishes and tears down connected CIP messaging paths.
///
/// One instance owns the T->O connection id counter and the table of open
/// connections; the socket host is expected to own one instance per
/// session (or per socket) and call [releaseAll] when it dies.
class CipConnectionManager {
  int _nextConnectionId = kInitialTargetConnectionId;

  /// Open connections, keyed by the **O->T** connection id this manager
  /// allocated — the id an incoming connected message is addressed to.
  final Map<int, CipConnection> _byConnectionId = {};

  /// Handles a Forward Open (`0x54`) request. Always returns a
  /// [CipResponse] — never throws — using [kCipStatusNotEnoughData] if
  /// `request.data` is too short to hold the fixed Forward Open fields or
  /// the declared connection path.
  CipResponse forwardOpen(CipRequest request) {
    final data = request.data;
    if (data.length < _kForwardOpenFixedLen) {
      return _errorResponse(request.service, kCipStatusNotEnoughData);
    }
    final bd = ByteData.sublistView(data);
    // Byte offset 2 (the O->T connection id) is intentionally NOT read: the
    // originator only sends a placeholder there (pycomm3, and real clients
    // generally, send `0`) because THIS side allocates that direction's id.
    // Reading it and echoing it back was the original bug this codec had —
    // see the file header.
    final connectionIdTO = bd.getUint32(6, Endian.little);
    final connectionSerial = bd.getUint16(10, Endian.little);
    final vendorId = bd.getUint16(12, Endian.little);
    final originatorSerial = bd.getUint32(14, Endian.little);
    final otRpi = bd.getUint32(22, Endian.little);
    // O->T (offset 26) and T->O (offset 32) Network Connection Parameters —
    // the connection-size words this codec previously skipped. The low 9 bits
    // of each are the connection size in bytes (see
    // `_kNetworkConnectionSizeMask`). The T->O size is the one that matters
    // for response budgeting: it is the size of the frames THIS target sends,
    // so it bounds a connected Multiple Service Packet reply.
    final otParams = bd.getUint16(26, Endian.little);
    final toRpi = bd.getUint32(28, Endian.little);
    final toParams = bd.getUint16(32, Endian.little);
    final connectionSizeOT = otParams & _kNetworkConnectionSizeMask;
    final connectionSizeTO = toParams & _kNetworkConnectionSizeMask;
    final pathSizeWords = data[35];
    final pathByteLen = pathSizeWords * 2;
    if (data.length < _kForwardOpenFixedLen + pathByteLen) {
      return _errorResponse(request.service, kCipStatusNotEnoughData);
    }

    final connectionIdOT = _nextConnectionId;
    _nextConnectionId += 1;
    _byConnectionId[connectionIdOT] = CipConnection(
      connectionIdOT: connectionIdOT,
      connectionIdTO: connectionIdTO,
      connectionSizeTO: connectionSizeTO,
      connectionSizeOT: connectionSizeOT,
      connectionSerial: connectionSerial,
      vendorId: vendorId,
      originatorSerial: originatorSerial,
    );

    final reply = ByteData(26);
    reply.setUint32(0, connectionIdOT, Endian.little); // Allocated by this target.
    reply.setUint32(4, connectionIdTO, Endian.little); // Echoed from the request.
    reply.setUint16(8, connectionSerial, Endian.little);
    reply.setUint16(10, vendorId, Endian.little);
    reply.setUint32(12, originatorSerial, Endian.little);
    reply.setUint32(16, otRpi, Endian.little);
    reply.setUint32(20, toRpi, Endian.little);
    reply.setUint8(24, 0); // Application Reply Size = 0.
    reply.setUint8(25, 0); // Reserved.

    return CipResponse(service: request.service, generalStatus: kCipStatusSuccess, data: reply.buffer.asUint8List());
  }

  /// Handles a Forward Close (`0x4E`) request. Matches the open connection
  /// by (Connection Serial Number, Originator Vendor ID, Originator Serial
  /// Number) — never by connection id, since a Forward Close request does
  /// not carry either connection id. Never throws: an unmatched triple or a
  /// truncated request both return a non-zero [CipResponse.generalStatus]
  /// rather than throwing or silently succeeding.
  CipResponse forwardClose(CipRequest request) {
    final data = request.data;
    if (data.length < _kForwardCloseFixedLen) {
      return _errorResponse(request.service, kCipStatusNotEnoughData);
    }
    final bd = ByteData.sublistView(data);
    final connectionSerial = bd.getUint16(2, Endian.little);
    final vendorId = bd.getUint16(4, Endian.little);
    final originatorSerial = bd.getUint32(6, Endian.little);
    final pathSizeWords = data[10];
    final pathByteLen = pathSizeWords * 2;
    if (data.length < _kForwardCloseFixedLen + pathByteLen) {
      return _errorResponse(request.service, kCipStatusNotEnoughData);
    }

    int? matchedConnectionId;
    for (final entry in _byConnectionId.entries) {
      final conn = entry.value;
      if (conn.connectionSerial == connectionSerial &&
          conn.vendorId == vendorId &&
          conn.originatorSerial == originatorSerial) {
        matchedConnectionId = entry.key;
        break;
      }
    }
    if (matchedConnectionId == null) {
      return _errorResponse(request.service, kCipStatusConnectionFailure);
    }
    _byConnectionId.remove(matchedConnectionId);

    final reply = ByteData(10);
    reply.setUint16(0, connectionSerial, Endian.little);
    reply.setUint16(2, vendorId, Endian.little);
    reply.setUint32(4, originatorSerial, Endian.little);
    reply.setUint8(8, 0); // Application Reply Size = 0.
    reply.setUint8(9, 0); // Reserved.

    return CipResponse(service: request.service, generalStatus: kCipStatusSuccess, data: reply.buffer.asUint8List());
  }

  /// Looks up an open connection by the **Originator-to-Target** connection
  /// id — the id [forwardOpen] allocated and returned to the originator, and
  /// therefore the id the originator puts in the Connected Address item of
  /// every connected message (`SendUnitData`) it sends. Returns `null` if no
  /// connection with that id is currently open.
  CipConnection? byConnectionId(int connectionId) => _byConnectionId[connectionId];

  /// Drops every open connection, e.g. when the owning session or socket
  /// dies. Does not reset the id-allocation counter: ids allocated by this
  /// manager instance stay unique for its whole lifetime, even across a
  /// `releaseAll` followed by new connections.
  void releaseAll() {
    _byConnectionId.clear();
  }

  CipResponse _errorResponse(int service, int generalStatus) =>
      CipResponse(service: service, generalStatus: generalStatus, data: Uint8List(0));
}
