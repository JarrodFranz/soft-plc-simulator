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
//  Forward Open (0x54) request:
//   - Priority/Time_tick: u8
//   - Timeout_ticks: u8
//   - O->T Network Connection ID: u32 (chosen by the originator; echoed
//     back unchanged in the reply — never reinterpreted by this layer)
//   - T->O Network Connection ID: u32 (the value the originator proposes;
//     IGNORED — the target allocates its own, per the determinism
//     requirement below)
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
//   - O->T Network Connection ID: u32 (echoed from the request)
//   - T->O Network Connection ID: u32 (allocated by this layer)
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
// Determinism: the Target-to-Originator (T->O) connection id — the only
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

/// The first Target-to-Originator connection id allocated by a fresh
/// [CipConnectionManager]. Documented as a named constant (rather than an
/// inline literal) because determinism here is a hard requirement: tests
/// assert exact allocated ids, so this value must never change silently by
/// switching to a random or clock-derived source. `0` is reserved to mean
/// "no connection" on the wire and is therefore never allocated.
const int kInitialTargetConnectionId = 1;

/// Byte length of the fixed-position Forward Open request fields, before
/// the variable-length connection path.
const int _kForwardOpenFixedLen = 36;

/// Byte length of the fixed-position Forward Close request fields, before
/// the variable-length connection path.
const int _kForwardCloseFixedLen = 12;

/// A single established CIP connection, as created by a successful
/// [CipConnectionManager.forwardOpen] and released by a matching
/// [CipConnectionManager.forwardClose].
class CipConnection {
  /// The Originator-to-Target connection id, echoed unchanged from the
  /// Forward Open request that created this connection.
  final int connectionIdOT;

  /// The Target-to-Originator connection id, allocated by
  /// [CipConnectionManager] from its monotonic counter. This is the id a
  /// caller looks connections up by via [CipConnectionManager.byTargetId]
  /// (the id a connected message such as `SendUnitData` is routed by).
  final int connectionIdTO;

  /// Connection Serial Number, from the Forward Open request. Part of the
  /// triple a Forward Close matches against.
  final int connectionSerial;

  /// Originator Vendor ID, from the Forward Open request. Part of the
  /// triple a Forward Close matches against.
  final int vendorId;

  /// Originator Serial Number, from the Forward Open request. Part of the
  /// triple a Forward Close matches against.
  final int originatorSerial;

  /// Connected-message sequence count. Starts at `0`; a later layer
  /// (connected explicit messaging over `SendUnitData`) is responsible for
  /// advancing it — this layer only allocates the field.
  int sequenceCount;

  CipConnection({
    required this.connectionIdOT,
    required this.connectionIdTO,
    required this.connectionSerial,
    required this.vendorId,
    required this.originatorSerial,
    this.sequenceCount = 0,
  });
}

/// Implements the Connection Manager object's Forward Open / Forward Close
/// services: establishes and tears down connected CIP messaging paths.
///
/// One instance owns the T->O connection id counter and the table of open
/// connections; the socket host is expected to own one instance per
/// session (or per socket) and call [releaseAll] when it dies.
class CipConnectionManager {
  int _nextTargetConnectionId = kInitialTargetConnectionId;
  final Map<int, CipConnection> _byTargetId = {};

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
    final connectionIdOT = bd.getUint32(2, Endian.little);
    // Byte offset 6 (the T->O connection id the originator proposes) is
    // intentionally not read: this layer always allocates its own id for
    // that direction, per the determinism requirement documented above.
    final connectionSerial = bd.getUint16(10, Endian.little);
    final vendorId = bd.getUint16(12, Endian.little);
    final originatorSerial = bd.getUint32(14, Endian.little);
    final otRpi = bd.getUint32(22, Endian.little);
    final toRpi = bd.getUint32(28, Endian.little);
    final pathSizeWords = data[35];
    final pathByteLen = pathSizeWords * 2;
    if (data.length < _kForwardOpenFixedLen + pathByteLen) {
      return _errorResponse(request.service, kCipStatusNotEnoughData);
    }

    final connectionIdTO = _nextTargetConnectionId;
    _nextTargetConnectionId += 1;
    _byTargetId[connectionIdTO] = CipConnection(
      connectionIdOT: connectionIdOT,
      connectionIdTO: connectionIdTO,
      connectionSerial: connectionSerial,
      vendorId: vendorId,
      originatorSerial: originatorSerial,
    );

    final reply = ByteData(26);
    reply.setUint32(0, connectionIdOT, Endian.little);
    reply.setUint32(4, connectionIdTO, Endian.little);
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

    int? matchedTargetId;
    for (final entry in _byTargetId.entries) {
      final conn = entry.value;
      if (conn.connectionSerial == connectionSerial &&
          conn.vendorId == vendorId &&
          conn.originatorSerial == originatorSerial) {
        matchedTargetId = entry.key;
        break;
      }
    }
    if (matchedTargetId == null) {
      return _errorResponse(request.service, kCipStatusConnectionFailure);
    }
    _byTargetId.remove(matchedTargetId);

    final reply = ByteData(10);
    reply.setUint16(0, connectionSerial, Endian.little);
    reply.setUint16(2, vendorId, Endian.little);
    reply.setUint32(4, originatorSerial, Endian.little);
    reply.setUint8(8, 0); // Application Reply Size = 0.
    reply.setUint8(9, 0); // Reserved.

    return CipResponse(service: request.service, generalStatus: kCipStatusSuccess, data: reply.buffer.asUint8List());
  }

  /// Looks up an open connection by its Target-to-Originator connection id
  /// — the id [forwardOpen] allocated, and the id a connected message
  /// (`SendUnitData`) is routed by. Returns `null` if no connection with
  /// that id is currently open.
  CipConnection? byTargetId(int targetId) => _byTargetId[targetId];

  /// Drops every open connection, e.g. when the owning session or socket
  /// dies. Does not reset the id-allocation counter: ids allocated by this
  /// manager instance stay unique for its whole lifetime, even across a
  /// `releaseAll` followed by new connections.
  void releaseAll() {
    _byTargetId.clear();
  }

  CipResponse _errorResponse(int service, int generalStatus) =>
      CipResponse(service: service, generalStatus: generalStatus, data: Uint8List(0));
}
