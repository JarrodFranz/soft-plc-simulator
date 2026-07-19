// DNP3 outstation handler (WS26 DNP3 outstation, Task 4) — pure Dart, no
// dart:io / Flutter imports. Turns an inbound DNP3 APPLICATION-layer request
// fragment into a response fragment against the project's `DnpMap` + live
// tags. Operates purely at the application-fragment level (input/output are
// both already-assembled app fragments, exactly what
// `DnpTransportReassembler.addSegment` hands back) — Task 5's host owns
// transport segmentation + link framing + the actual socket.
//
// Scope: Class 0 integrity READ (a full grouped scan) plus Class 1/2/3 event
// reads and unsolicited reporting (Task 4 — see the doc comment on
// [DnpOutstation.handleAppRequest]) and SELECT/OPERATE/DIRECT_OPERATE control
// of a CROB (g12v1, on a binaryOutput point) or an Analog Output Block
// (g41v1/g41v3, on an analogOutput point).
//
// Class 0 response layout: one object header (range8/range16 qualifier) per
// (point type, variation) bucket present in the map, covering that bucket's
// own min..max index with any gap index inside that span (i.e. an index the
// map doesn't assign to this bucket) zero/offline-filled — see
// [_buildRuns]. A bucket only ever advertises indices that don't belong to a
// *different* variation of the same point type (e.g. an analogInput bucket
// mixing INT32 and FLOAT64 tags splits into a g30v1 run set and a g30v5 run
// set that never overlap), so a run never claims a point it doesn't own.
//
// Control status codes ([DnpControlStatus]) follow IEEE 1815's Control
// Status enumeration. This handler's specific choices: a target point that
// doesn't exist (wrong index) or isn't of the control's expected R/W point
// type -> NOT_SUPPORTED(4); a target whose root tag is forced -> the write
// is silently skipped (never applied) and the point's status is
// NOT_AUTHORIZED(9) — "the operator has this point pinned, your command is
// declined"; an OPERATE with no matching prior SELECT (or one that expired,
// or whose objects don't match) -> NO_SELECT(2), the standard code for
// exactly this situation.
//
// IIN: IIN1 bit 7 (DEVICE_RESTART) is set on every response from
// construction until the master issues a WRITE (function code 2) clearing
// g80v1 index 7 to 0 — see [_writeClearsRestart] for why that one WRITE
// payload is hand-parsed here rather than routed through
// `dnp3_app.dart`'s `parseAppRequest` (it doesn't model g80v1's bit-packed
// per-point size, only the byte-per-point static/control objects Task 3
// needed). An unrecognized function code sets IIN2 bit 0
// (NO_FUNC_CODE_SUPPORT). Every entry point is wrapped so a bug here becomes
// an IIN-flagged response, never an uncaught exception.
library dnp3_outstation;

import 'dart:typed_data';

import '../../models/dnp3_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';
import '../../models/tag_write_gate.dart';
import 'dnp3_app.dart';
import 'dnp3_events.dart';

/// WRITE function code (clears IIN bits, e.g. DEVICE_RESTART) — not exposed
/// by [DnpFunc] because Task 3's codec only names the function codes an
/// outstation actively parses objects for; this handler needs it only for
/// the narrow IIN-clear case in [_writeClearsRestart].
const int _funcWrite = 2;

/// Fixed length of a response application-fragment header the way
/// [buildAppResponse] frames it: APP_CONTROL(1) + FUNCTION_CODE(1) + IIN(2).
/// Every paged fragment reserves this before its object payload so the whole
/// fragment (header + objects) stays at or under [kDnpMaxAppFragment].
const int _appHeaderLen = 4;

/// One object to emit in a response: a group/variation plus its per-point
/// payloads, in index order. Two shapes, both with a uniform per-point payload
/// size:
///  - static (range-qualified): [indexPrefixed] false, [indices] is the
///    contiguous run `start..stop` the header covers (gap points are
///    zero/offline-filled into [points] by the builder).
///  - event (index-prefixed, qualifier 0x28): [indexPrefixed] true, [indices]
///    carries each point's own (possibly non-contiguous) index.
///
/// This intermediate form is what lets a large read be *paged*: the packer
/// splits an object across fragment boundaries by emitting a fresh header for
/// each sub-range, and DNP3's application layer processes each fragment's
/// objects independently — so every fragment must carry whole, self-describing
/// object headers, never a header split down the middle.
class _EmitObject {
  final int group;
  final int variation;
  final bool indexPrefixed;
  final List<int> indices;
  final List<Uint8List> points;

  _EmitObject({
    required this.group,
    required this.variation,
    required this.indexPrefixed,
    required this.indices,
    required this.points,
  });

  int get _pointSize => points.isEmpty ? 0 : points.first.length;

  /// Bytes one point contributes on the wire: an index-prefixed point also
  /// carries its 2-byte LE index before the payload.
  int get perPointLen => indexPrefixed ? (2 + _pointSize) : _pointSize;

  /// Object-header length for this object's qualifier. A static run uses a
  /// range16 header (7 bytes) whenever any of its indices exceeds 0xFF, else a
  /// range8 header (5 bytes); an event object always uses the 0x28
  /// count-prefixed header (3 group/var/qual + 2 count = 5 bytes).
  int get headerLen => indexPrefixed ? 5 : ((indices.isNotEmpty && indices.last > 0xFF) ? 7 : 5);

  /// Total serialized length (header + all points).
  int get wireLen => headerLen + indices.length * perPointLen;
}

/// Control Status codes (IEEE 1815 Table: Control Status), used in the
/// status byte of a CROB (g12v1) or Analog Output Block (g41v1/v3) response
/// point.
class DnpControlStatus {
  static const int success = 0;
  static const int timeout = 1;
  static const int noSelect = 2;
  static const int formatError = 3;
  static const int notSupported = 4;
  static const int alreadyActive = 5;
  static const int hardwareError = 6;
  static const int local = 7;
  static const int tooManyOps = 8;
  static const int notAuthorized = 9;
  static const int automationInhibit = 10;
  static const int processingLimited = 11;
  static const int outOfRange = 12;
}

/// A previously-received SELECT, kept until a matching OPERATE consumes it or
/// [expiresAtMs] passes. "Matching" means the OPERATE's control objects are
/// byte-identical to the SELECT's (see [_objectsMatch]) — this mirrors real
/// master behavior (the OPERATE fragment re-sends the exact same object
/// data), and deliberately does NOT require the OPERATE's application
/// sequence number to relate to the SELECT's: real masters increment the app
/// sequence between the two fragments, so tying the match to sequence
/// continuity would reject legitimate SELECT/OPERATE pairs.
class _PendingControl {
  final List<DnpObjectHeader> objects;
  final int expiresAtMs;
  _PendingControl({required this.objects, required this.expiresAtMs});
}

/// Decodes DNP3 application fragments (Class 0 reads and
/// SELECT/OPERATE/DIRECT_OPERATE control) against the project's `DnpMap` +
/// live tags. Reads are force-aware (a forced scalar tag's value surfaces via
/// `readPath`); control writes are force-aware in the other direction (a
/// forced target tag's write is silently discarded and the point reports
/// NOT_AUTHORIZED) and never throw — any internal error becomes an
/// IIN-flagged response instead of an uncaught exception.
class DnpOutstation {
  final PlcProject Function() projectProvider;

  /// Wall-clock-independent SELECT/OPERATE binding window, in the same
  /// millisecond units as the `nowMs` callers pass to [handleAppRequest].
  static const int _selectTimeoutMs = 5000;

  bool _restartPending = true;
  _PendingControl? _pending;

  /// The Task 2 event engine: per-class (1/2/3) bounded event buffers plus
  /// force-aware change detection, driven each tick by [detectChanges].
  final DnpEventEngine _events;

  /// Event classes (1/2/3) currently enabled for unsolicited reporting via
  /// ENABLE_UNSOLICITED (fc 20) / DISABLE_UNSOLICITED (fc 21).
  final Set<int> _unsolEnabled = <int>{};

  /// The application sequence number the NEXT unsolicited response will use;
  /// advances (mod 16) only when the master CONFIRMs the in-flight one.
  int _unsolSeq = 0;

  /// In-flight unsolicited attempt: the exact bytes sent (for a host retry)
  /// and the events it carried (flushed on CONFIRM). Null when nothing is
  /// in flight.
  Uint8List? _unsolInFlightBytes;
  List<DnpEvent>? _unsolInFlightEvents;

  /// Pending null-unsolicited announcement (set on ENABLE_UNSOLICITED).
  bool _pendingNullUnsol = false;

  /// Events reported in the last solicited Class read awaiting a CONFIRM,
  /// keyed by that response's application sequence.
  List<DnpEvent>? _pendingSolicitedFlush;
  int _pendingSolicitedSeq = -1;

  /// Task 4 multi-fragment solicited-read continuation. When a Class 0 (or
  /// combined static+event) read overruns [kDnpMaxAppFragment], every fragment
  /// is built up front — a deterministic snapshot of the database at read time,
  /// no clock and no randomness — and released one at a time: fragment 0 is
  /// returned to the read, and each subsequent fragment is released by the
  /// master's matching CONFIRM (see [_confirmSolicited]). Null when no paged
  /// read is in flight.
  List<Uint8List>? _readContFrags;

  /// How many of [_readContFrags] have been emitted so far (>= 1 once a paged
  /// read starts; the next fragment to release sits at this index).
  int _readContSent = 0;

  /// Events carried by a paged read, flushed only once the final fragment is
  /// CONFIRMed. Null when the paged read carries no events.
  List<DnpEvent>? _readContEvents;

  DnpOutstation({required this.projectProvider, int eventBufferPerClass = 200})
      : _events = DnpEventEngine(capacityPerClass: eventBufferPerClass);

  /// True until the master clears IIN1 bit 7 via the g80v1 WRITE described
  /// in [_writeClearsRestart] — exposed mainly for tests; every response
  /// already carries this as the DEVICE_RESTART IIN bit.
  bool get isRestartPending => _restartPending;

  /// Event classes (1/2/3) currently enabled for unsolicited reporting — for
  /// the host's UI indicator. Read-only view over the internal set.
  Set<int> get unsolicitedEnabledClasses => Set<int>.unmodifiable(_unsolEnabled);

  /// True while an unsolicited fragment has been handed to the host and is
  /// awaiting either a CONFIRM ([_confirmUnsolicited]) or [failUnsolicited].
  bool get hasUnsolicitedInFlight => _unsolInFlightBytes != null;

  /// The currently in-flight unsolicited fragment (for a host retry), or
  /// null when nothing is in flight.
  Uint8List? get inFlightUnsolicitedBytes => _unsolInFlightBytes;

  int _iin1() {
    var v = _restartPending ? DnpIin1.deviceRestart : 0;
    final cls = _events.classesWithEvents;
    if (cls.contains(1)) {
      v |= DnpIin1.class1Events;
    }
    if (cls.contains(2)) {
      v |= DnpIin1.class2Events;
    }
    if (cls.contains(3)) {
      v |= DnpIin1.class3Events;
    }
    return v;
  }

  /// IIN2 bits driven by the event engine (currently just event-buffer
  /// overflow) — OR this into every response's IIN2 alongside whatever
  /// request-specific IIN2 bits that response already carries.
  int _iin2Base() => _events.overflowed ? DnpIin2.eventBufferOverflow : 0;

  /// Runs one force-aware change-detection pass over the current project
  /// map, capturing any Class 1/2/3 point changes into the event engine.
  /// Never throws — a bug here must not break the host's tick loop.
  void detectChanges(int nowMs) {
    try {
      final project = projectProvider();
      final map = _mapFor(project);
      _events.detectChanges(project, map, nowMs);
    } catch (_) {
      // Detection must never throw into the host tick.
    }
  }

  /// Handles one application-layer request fragment (`APP_CONTROL
  /// FUNCTION_CODE [objects...]`, no transport/link framing — that's Task
  /// 5's host layer) and returns the response fragment in the same form.
  ///
  /// [DnpFunc.read] inspects which g60 (Class Objects) variations the
  /// master named: no g60 objects at all, or an explicit g60v1 (Class 0),
  /// gets the full static integrity scan across all 4 point types; g60v2/
  /// v3/v4 additionally append any buffered Class 1/2/3 events (see
  /// [_handleRead]). [DnpFunc.confirm] never gets a reply — see
  /// [_confirmSolicited]/[_confirmUnsolicited].
  ///
  /// Never throws: any parse failure or internal error yields an
  /// IIN2-flagged (PARAMETER_ERROR) response instead.
  Uint8List handleAppRequest(Uint8List requestFragment, {required int nowMs}) {
    try {
      return _dispatch(requestFragment, nowMs);
    } catch (_) {
      final seq = requestFragment.isNotEmpty ? (requestFragment[0] & 0x0F) : 0;
      return buildAppResponse(
        seq: seq,
        fir: true,
        fin: true,
        con: false,
        iin: packIin(_iin1(), DnpIin2.parameterError | _iin2Base()),
        objectData: Uint8List(0),
      );
    }
  }

  Uint8List _dispatch(Uint8List frag, int nowMs) {
    if (frag.length < 2) {
      return buildAppResponse(
        seq: 0,
        fir: true,
        fin: true,
        con: false,
        iin: packIin(_iin1(), DnpIin2.parameterError | _iin2Base()),
        objectData: Uint8List(0),
      );
    }
    final rawSeq = frag[0] & 0x0F;
    final rawFunctionCode = frag[1];

    // CONFIRM (fc 0) carries no response of its own — it acknowledges a
    // prior solicited or unsolicited response and never gets a reply.
    if (rawFunctionCode == DnpFunc.confirm) {
      final uns = (frag[0] & 0x10) != 0;
      if (uns) {
        _confirmUnsolicited(rawSeq);
        return Uint8List(0); // no response fragment for an unsolicited CONFIRM
      }
      // A solicited CONFIRM ordinarily gets no reply, but the one that advances
      // a paged multi-fragment read releases the next fragment — returning it
      // here lets the existing host send path deliver it with no host change.
      return _confirmSolicited(rawSeq) ?? Uint8List(0);
    }

    // WRITE is handled directly off the raw bytes rather than through
    // `parseAppRequest`: that codec has no per-point size for g80v1 (a
    // bit-packed object; see `_writeClearsRestart`), so a range-qualified
    // g80v1 WRITE would make the whole-fragment parse fail before this
    // handler ever saw the function code.
    if (rawFunctionCode == _funcWrite) {
      if (_writeClearsRestart(frag)) {
        _restartPending = false;
      }
      return buildAppResponse(
        seq: rawSeq,
        fir: true,
        fin: true,
        con: false,
        iin: packIin(_iin1(), 0 | _iin2Base()),
        objectData: Uint8List(0),
      );
    }

    final project = projectProvider();
    final req = parseAppRequest(frag);
    if (req == null) {
      return buildAppResponse(
        seq: rawSeq,
        fir: true,
        fin: true,
        con: false,
        iin: packIin(_iin1(), DnpIin2.parameterError | _iin2Base()),
        objectData: Uint8List(0),
      );
    }

    switch (req.functionCode) {
      case DnpFunc.read:
        return _handleRead(project, req);
      case DnpFunc.select:
        return _handleSelect(project, req, nowMs);
      case DnpFunc.operate:
        return _handleOperate(project, req, nowMs);
      case DnpFunc.directOperate:
        return _handleDirectOperate(project, req);
      case DnpFunc.enableUnsolicited:
        return _handleUnsolControl(req, enable: true);
      case DnpFunc.disableUnsolicited:
        return _handleUnsolControl(req, enable: false);
      default:
        return buildAppResponse(
          seq: req.seq,
          fir: true,
          fin: true,
          con: false,
          iin: packIin(_iin1(), DnpIin2.noFuncCodeSupport | _iin2Base()),
          objectData: Uint8List(0),
        );
    }
  }

  // --- WRITE (IIN clear) -----------------------------------------------------

  /// Minimal, purpose-built scan for a WRITE (function code 2) request's
  /// g80v1 (Internal Indications) objects, looking for one clearing index 7
  /// (DEVICE_RESTART) to 0. `dnp3_app.dart`'s `parseAppRequest` doesn't carry
  /// a per-point size for g80v1 (it's a bit-packed Binary-type object, not
  /// one of the byte-per-point static/control objects Task 3 modeled), so
  /// this handler decodes the object header via the still-reusable
  /// `decodeObjectHeader` and then consumes the payload itself, supporting
  /// the range qualifiers (bit-packed, the conventional wire form real
  /// masters use for this exact operation) and, defensively, the
  /// index-prefix qualifiers (one non-packed status byte per prefixed
  /// index — this handler's own choice for objects it doesn't otherwise
  /// know the size of, not a general index-prefixed-binary-object decoder).
  ///
  /// Never throws — any short/malformed data simply stops the scan and
  /// returns whatever was found before the anomaly.
  bool _writeClearsRestart(Uint8List frag) {
    var offset = 2;
    var found = false;
    while (offset < frag.length) {
      final decoded = decodeObjectHeader(frag, offset);
      if (decoded == null) {
        return found;
      }
      final h = decoded.header;
      var pos = decoded.nextOffset;

      if (h.group != 80 || h.variation != 1) {
        // Not the object this handler understands; its point size (and
        // therefore how many bytes to skip) is unknown, so stop scanning
        // rather than risk misreading the rest of the fragment.
        return found;
      }

      switch (h.qualifier) {
        case DnpQualifier.range8:
        case DnpQualifier.range16:
          final start = h.start!;
          final stop = h.stop!;
          final count = stop - start + 1;
          if (count <= 0) {
            return found;
          }
          final byteCount = (count + 7) ~/ 8;
          if (pos + byteCount > frag.length) {
            return found;
          }
          if (start <= 7 && 7 <= stop) {
            final bitPos = 7 - start;
            final byte = frag[pos + bitPos ~/ 8];
            final bit = (byte >> (bitPos % 8)) & 1;
            if (bit == 0) {
              found = true;
            }
          }
          pos += byteCount;
          break;
        case DnpQualifier.indexPrefix8:
        case DnpQualifier.indexPrefix16:
          final count = h.count!;
          final idxSize = h.qualifier == DnpQualifier.indexPrefix8 ? 1 : 2;
          for (var i = 0; i < count; i++) {
            if (pos + idxSize > frag.length) {
              return found;
            }
            final idx = idxSize == 1 ? frag[pos] : (frag[pos] | (frag[pos + 1] << 8));
            pos += idxSize;
            if (pos + 1 > frag.length) {
              return found;
            }
            final bit = frag[pos] & 1;
            pos += 1;
            if (idx == 7 && bit == 0) {
              found = true;
            }
          }
          break;
        case DnpQualifier.allPoints:
          // "All points" WRITE — no per-point data to inspect; treat this as
          // clearing everything, index 7 included.
          found = true;
          break;
        default:
          return found;
      }
      offset = pos;
    }
    return found;
  }

  // --- Read (Class 0 static + Class 1/2/3 events) -------------------------

  /// Serves a READ request: which g60 (Class Objects) variations the master
  /// named decides what's included. No g60 objects at all, or an explicit
  /// g60v1 (Class 0), gets the full static integrity scan (preserving the
  /// original v1 behavior byte-for-byte). g60v2/v3/v4 additionally append
  /// any buffered Class 1/2/3 events, setting CON so the master knows to
  /// CONFIRM before they're flushed (see [_confirmSolicited]).
  Uint8List _handleRead(PlcProject project, DnpAppRequest req) {
    final map = _mapFor(project);

    // Which classes did the request name via g60 objects?
    final requested = <int>{};
    var namedAnyClass = false;
    for (final h in req.objects) {
      if (h.group == 60) {
        final cls = dnpClassOfG60Variation(h.variation);
        if (cls != null) {
          requested.add(cls);
          namedAnyClass = true;
        }
      }
    }

    final includeStatic = !namedAnyClass || requested.contains(0);
    final eventClasses = requested.where((c) => c >= 1 && c <= 3).toSet();

    final objects = <_EmitObject>[];
    if (includeStatic) {
      objects.addAll(_classZeroObjects(project, map));
    }
    List<DnpEvent>? pulledEvents;
    if (eventClasses.isNotEmpty) {
      final events = _events.pull(eventClasses);
      if (events.isNotEmpty) {
        objects.addAll(_eventObjects(events));
        pulledEvents = events;
      }
    }

    final iin = packIin(_iin1(), _iin2Base());
    var payloadLen = 0;
    for (final o in objects) {
      payloadLen += o.wireLen;
    }

    // The common case: the whole response fits in one application fragment.
    // This path is byte-identical to the pre-Task-4 single-fragment form — a
    // response under the bound is never paged, and a solicited event read still
    // sets CON and defers its flush to the matching CONFIRM exactly as before.
    if (_appHeaderLen + payloadLen <= kDnpMaxAppFragment) {
      final con = pulledEvents != null;
      if (con) {
        _pendingSolicitedFlush = pulledEvents;
        _pendingSolicitedSeq = req.seq;
      }
      return buildAppResponse(
        seq: req.seq,
        fir: true,
        fin: true,
        con: con,
        iin: iin,
        objectData: _serializeObjects(objects),
      );
    }

    // Overrun: page the response across fragments, each at or under the bound.
    // First fragment FIR|!FIN, last !FIR|FIN, any middle neither; a CONFIRM of
    // each non-final fragment releases the next (see [_confirmSolicited]).
    final payloads = _packObjects(objects);
    final n = payloads.length;
    final frags = <Uint8List>[];
    for (var i = 0; i < n; i++) {
      final fir = i == 0;
      final fin = i == n - 1;
      // Non-final fragments MUST set CON so the master's CONFIRM releases the
      // next one. The final fragment sets CON only when it still carries events
      // awaiting a flush-on-CONFIRM.
      final con = fin ? (pulledEvents != null) : true;
      frags.add(buildAppResponse(
        seq: (req.seq + i) & 0x0F,
        fir: fir,
        fin: fin,
        con: con,
        iin: iin,
        objectData: payloads[i],
      ));
    }
    _readContFrags = frags;
    _readContSent = 1; // fragment 0 is returned to this read now
    _readContEvents = pulledEvents;
    return frags[0];
  }

  /// Encodes [events] into DNP3 event objects, grouped by type and by
  /// input-vs-output into 6 buckets: binaryInput -> g2v2, binaryOutput ->
  /// g11v2, analogInput-int -> g32v3, analogOutput-int -> g42v3,
  /// analogInput-float -> g32v7, analogOutput-float -> g42v7. Each uses
  /// qualifier 0x28 (2-byte count + a 2-byte LE index prefix before each
  /// point), since events carry their own point index. FIFO order is
  /// preserved within each group; empty buckets emit nothing, so an
  /// all-input event set produces exactly the 3 groups it always did.
  /// Byte form of the event objects for [events] — used by the unsolicited
  /// push path ([takeEventUnsolicited]/[takeNullUnsolicited]), which is
  /// single-fragment by design. The solicited read path builds the same
  /// objects via [_eventObjects] so it can page them alongside static objects
  /// (see [_handleRead]); this wrapper keeps that one source of truth.
  Uint8List _encodeEventObjects(List<DnpEvent> events) => _serializeObjects(_eventObjects(events));

  /// Groups [events] into the 6 event object buckets — binaryInput -> g2v2,
  /// binaryOutput -> g11v2, analogInput-int -> g32v3, analogOutput-int ->
  /// g42v3, analogInput-float -> g32v7, analogOutput-float -> g42v7 — as
  /// index-prefixed (qualifier 0x28) [_EmitObject]s. FIFO order is preserved
  /// within each group and empty buckets emit nothing, so an all-input event
  /// set produces exactly the groups it always did.
  List<_EmitObject> _eventObjects(List<DnpEvent> events) {
    bool isOut(DnpEvent e) => e.pointType == 'binaryOutput' || e.pointType == 'analogOutput';
    final binIn = events.where((e) => e.isBinary && !isOut(e)).toList();
    final binOut = events.where((e) => e.isBinary && isOut(e)).toList();
    final aIntIn = events.where((e) => !e.isBinary && !e.isFloat && !isOut(e)).toList();
    final aIntOut = events.where((e) => !e.isBinary && !e.isFloat && isOut(e)).toList();
    final aFloatIn = events.where((e) => !e.isBinary && e.isFloat && !isOut(e)).toList();
    final aFloatOut = events.where((e) => !e.isBinary && e.isFloat && isOut(e)).toList();

    final objs = <_EmitObject>[];
    void addGroup(int group, int variation, List<DnpEvent> es, Uint8List Function(DnpEvent) encodeOne) {
      if (es.isEmpty) {
        return;
      }
      objs.add(_EmitObject(
        group: group,
        variation: variation,
        indexPrefixed: true,
        indices: [for (final e in es) e.index],
        points: [for (final e in es) encodeOne(e)],
      ));
    }

    addGroup(2, 2, binIn, (e) => encodeG2V2(value: e.boolValue, flags: e.flags, timeMs: e.timeMs));
    addGroup(11, 2, binOut, (e) => encodeG11V2(value: e.boolValue, flags: e.flags, timeMs: e.timeMs));
    addGroup(32, 3, aIntIn, (e) => encodeG32V3(value: e.intValue, flags: e.flags, timeMs: e.timeMs));
    addGroup(42, 3, aIntOut, (e) => encodeG42V3(value: e.intValue, flags: e.flags, timeMs: e.timeMs));
    addGroup(32, 7, aFloatIn, (e) => encodeG32V7(value: e.floatValue, flags: e.flags, timeMs: e.timeMs));
    addGroup(42, 7, aFloatOut, (e) => encodeG42V7(value: e.floatValue, flags: e.flags, timeMs: e.timeMs));
    return objs;
  }

  /// Builds the Class 0 (static integrity) objects in the fixed report order —
  /// binaryInput (g1v2), binaryOutput (g10v2), analogInput (g30v1 ints then
  /// g30v5 floats), analogOutput (g40v1 ints then g40v3 floats) — each as a
  /// range-qualified [_EmitObject]. Serializing this list is byte-identical to
  /// the previous monolithic payload; representing it as objects is what lets
  /// [_packObjects] page it when it overruns [kDnpMaxAppFragment].
  List<_EmitObject> _classZeroObjects(PlcProject project, DnpMap map) {
    final objs = <_EmitObject>[];
    objs.addAll(_binaryBucketObjects(project, map, 'binaryInput', 1, 2));
    objs.addAll(_binaryBucketObjects(project, map, 'binaryOutput', 10, 2));
    objs.addAll(_analogBucketObjects(project, map, 'analogInput'));
    objs.addAll(_analogBucketObjects(project, map, 'analogOutput'));
    return objs;
  }

  List<_EmitObject> _binaryBucketObjects(PlcProject project, DnpMap map, String pointType, int group, int variation) {
    final entries = <int, DnpMapEntry>{};
    for (final e in map.entries) {
      if (e.pointType == pointType) {
        entries[e.index] = e;
      }
    }
    if (entries.isEmpty) {
      return const <_EmitObject>[];
    }
    final indices = entries.keys.toList()..sort();
    final runs = _buildRuns(indices, const <int>{});
    final objs = <_EmitObject>[];
    for (final run in runs) {
      final pts = <Uint8List>[];
      for (var idx = run.start; idx <= run.stop; idx++) {
        final entry = entries[idx];
        if (entry == null) {
          pts.add(group == 1 ? encodeG1V2(value: false, flags: 0) : encodeG10V2(value: false, flags: 0));
          continue;
        }
        final value = readPath(project, entry.tag) == true;
        pts.add(group == 1
            ? encodeG1V2(value: value, flags: DnpFlags.online)
            : encodeG10V2(value: value, flags: DnpFlags.online));
      }
      objs.add(_staticRunObject(group, variation, run.start, pts));
    }
    return objs;
  }

  List<_EmitObject> _analogBucketObjects(PlcProject project, DnpMap map, String pointType) {
    final intEntries = <int, DnpMapEntry>{};
    final floatEntries = <int, DnpMapEntry>{};
    for (final e in map.entries) {
      if (e.pointType != pointType) {
        continue;
      }
      final dt = dataTypeOfPath(project, e.tag);
      if (dt == 'FLOAT64') {
        floatEntries[e.index] = e;
      } else {
        intEntries[e.index] = e;
      }
    }
    final group = pointType == 'analogInput' ? 30 : 40;
    final floatVariation = pointType == 'analogInput' ? 5 : 3;
    const intVariation = 1; // g30v1 / g40v1

    final objs = <_EmitObject>[];
    objs.addAll(_numericSubBucketObjects(project, intEntries, floatEntries.keys.toSet(), group, intVariation, isFloat: false));
    objs.addAll(_numericSubBucketObjects(project, floatEntries, intEntries.keys.toSet(), group, floatVariation, isFloat: true));
    return objs;
  }

  List<_EmitObject> _numericSubBucketObjects(
    PlcProject project,
    Map<int, DnpMapEntry> bucket,
    Set<int> exclude,
    int group,
    int variation, {
    required bool isFloat,
  }) {
    if (bucket.isEmpty) {
      return const <_EmitObject>[];
    }
    final indices = bucket.keys.toList()..sort();
    final runs = _buildRuns(indices, exclude);
    final objs = <_EmitObject>[];
    for (final run in runs) {
      final pts = <Uint8List>[];
      for (var idx = run.start; idx <= run.stop; idx++) {
        final entry = bucket[idx];
        if (entry == null) {
          pts.add(isFloat ? _encodeFloatPoint(group, 0.0, 0) : _encodeIntPoint(group, 0, 0));
          continue;
        }
        final raw = readPath(project, entry.tag);
        if (isFloat) {
          final v = raw is double ? raw : (raw is int ? raw.toDouble() : 0.0);
          pts.add(_encodeFloatPoint(group, v, DnpFlags.online));
        } else {
          final v = raw is int ? raw : (raw is double ? raw.round() : 0);
          pts.add(_encodeIntPoint(group, v, DnpFlags.online));
        }
      }
      objs.add(_staticRunObject(group, variation, run.start, pts));
    }
    return objs;
  }

  /// Wraps a contiguous run of static points (the payload at successive indices
  /// starting from [start]) as a range-qualified [_EmitObject].
  _EmitObject _staticRunObject(int group, int variation, int start, List<Uint8List> points) {
    return _EmitObject(
      group: group,
      variation: variation,
      indexPrefixed: false,
      indices: [for (var i = 0; i < points.length; i++) start + i],
      points: points,
    );
  }

  // --- Object serialization + fragment packing ----------------------------

  /// Serializes [objects] to a single contiguous object-payload byte stream —
  /// the whole-object, unpaged form used when a response fits in one fragment.
  Uint8List _serializeObjects(List<_EmitObject> objects) {
    final out = BytesBuilder();
    for (final obj in objects) {
      if (obj.indices.isEmpty) {
        continue;
      }
      out.add(_serializeSub(obj, 0, obj.indices.length));
    }
    return out.toBytes();
  }

  /// Serializes [count] points of [obj] starting at point offset [start] as one
  /// self-contained object (its own header + those points). For a split static
  /// run this emits a fresh range header covering just the sub-range; for an
  /// event object a fresh 0x28 header with just this slice's count.
  Uint8List _serializeSub(_EmitObject obj, int start, int count) {
    final out = BytesBuilder();
    if (obj.indexPrefixed) {
      out.add(encodeObjectHeader(
          group: obj.group, variation: obj.variation, qualifier: DnpQualifier.indexPrefix16, count: count));
      for (var j = start; j < start + count; j++) {
        out.addByte(obj.indices[j] & 0xFF);
        out.addByte((obj.indices[j] >> 8) & 0xFF);
        out.add(obj.points[j]);
      }
    } else {
      // Match the object's chosen header width (see [_EmitObject.headerLen]):
      // range16 whenever any index exceeds 0xFF, else range8. Using the whole
      // object's max index keeps the qualifier uniform across all of its
      // sub-ranges and byte-identical to the unpaged form for a whole run.
      final qualifier = obj.indices.last > 0xFF ? DnpQualifier.range16 : DnpQualifier.range8;
      out.add(encodeObjectHeader(
          group: obj.group,
          variation: obj.variation,
          qualifier: qualifier,
          start: obj.indices[start],
          stop: obj.indices[start + count - 1]));
      for (var j = start; j < start + count; j++) {
        out.add(obj.points[j]);
      }
    }
    return out.toBytes();
  }

  /// Packs [objects] into one-or-more object-payload byte blocks, each at or
  /// under `kDnpMaxAppFragment - _appHeaderLen` so the finished application
  /// fragment stays within the bound. An object larger than a fragment is split
  /// across fragments at point boundaries, each slice re-emitting its own
  /// header (DNP3 processes each fragment's objects independently, so a header
  /// may never straddle a boundary). Deterministic: greedy left-to-right, no
  /// clock or randomness.
  List<Uint8List> _packObjects(List<_EmitObject> objects) {
    const budget = kDnpMaxAppFragment - _appHeaderLen;
    final frags = <Uint8List>[];
    var cur = BytesBuilder();
    for (final obj in objects) {
      final total = obj.indices.length;
      if (total == 0) {
        continue;
      }
      final headerLen = obj.headerLen;
      final perPoint = obj.perPointLen;
      var i = 0;
      while (i < total) {
        var avail = budget - cur.length - headerLen;
        if (avail < perPoint) {
          // Not enough room for even one point of this object here: seal the
          // current fragment and start a fresh one.
          if (cur.length > 0) {
            frags.add(cur.toBytes());
            cur = BytesBuilder();
          }
          avail = budget - headerLen;
        }
        var maxCount = avail ~/ perPoint;
        if (maxCount < 1) {
          maxCount = 1; // a fresh fragment's budget always admits >= 1 point
        }
        final remaining = total - i;
        final count = maxCount < remaining ? maxCount : remaining;
        cur.add(_serializeSub(obj, i, count));
        i += count;
      }
    }
    if (cur.length > 0) {
      frags.add(cur.toBytes());
    }
    return frags;
  }

  Uint8List _encodeIntPoint(int group, int value, int flags) =>
      group == 30 ? encodeG30V1(value: value, flags: flags) : encodeG40V1(value: value, flags: flags);

  Uint8List _encodeFloatPoint(int group, double value, int flags) =>
      group == 30 ? encodeG30V5(value: value, flags: flags) : encodeG40V3(value: value, flags: flags);

  /// Coalesces [sortedIndices] into maximal runs suitable for a single
  /// range-qualified object header: consecutive present indices are merged
  /// into one run (any index gap between them zero/offline-filled by the
  /// caller) as long as no index in that gap belongs to [excludeIndices] —
  /// an index reserved for a different variation of the same point type
  /// must never be silently claimed by this bucket's range.
  List<({int start, int stop})> _buildRuns(List<int> sortedIndices, Set<int> excludeIndices) {
    final runs = <({int start, int stop})>[];
    int? runStart;
    int? runEnd;
    for (final idx in sortedIndices) {
      if (runStart == null) {
        runStart = idx;
        runEnd = idx;
        continue;
      }
      var bridgeable = true;
      for (var g = runEnd! + 1; g < idx; g++) {
        if (excludeIndices.contains(g)) {
          bridgeable = false;
          break;
        }
      }
      if (bridgeable) {
        runEnd = idx;
      } else {
        runs.add((start: runStart, stop: runEnd));
        runStart = idx;
        runEnd = idx;
      }
    }
    if (runStart != null) {
      runs.add((start: runStart, stop: runEnd!));
    }
    return runs;
  }

  // --- CONFIRM routing + ENABLE/DISABLE_UNSOLICITED -----------------------

  /// Handles ENABLE_UNSOLICITED (fc 20) / DISABLE_UNSOLICITED (fc 21): each
  /// g60 object in the request names a class (via its variation) to enable
  /// or disable. Enabling queues a one-shot null unsolicited announcement
  /// (see [takeNullUnsolicited]) — standard DNP3 restart/enable semantics,
  /// telling the master this outstation is now actively reporting.
  Uint8List _handleUnsolControl(DnpAppRequest req, {required bool enable}) {
    for (final h in req.objects) {
      if (h.group == 60) {
        final cls = dnpClassOfG60Variation(h.variation);
        if (cls != null && cls >= 1 && cls <= 3) {
          if (enable) {
            _unsolEnabled.add(cls);
          } else {
            _unsolEnabled.remove(cls);
          }
        }
      }
    }
    if (enable) {
      _pendingNullUnsol = true;
    }
    return buildAppResponse(
      seq: req.seq,
      fir: true,
      fin: true,
      con: false,
      iin: packIin(_iin1(), _iin2Base()),
      objectData: Uint8List(0),
    );
  }

  /// Handles a solicited CONFIRM. Two jobs, in priority order:
  ///
  ///  1. If a paged multi-fragment read is in flight (see [_handleRead]) and
  ///     [seq] matches the last fragment emitted, release the NEXT fragment
  ///     (returned to the caller so the host can send it). When the final
  ///     fragment is confirmed, any events it carried are flushed. A
  ///     stale/mismatched CONFIRM during a paged read releases nothing —
  ///     deterministic, so a duplicate never double-advances the cursor.
  ///  2. Otherwise, if [seq] matches a single-fragment solicited event read,
  ///     flush those events from the engine. A stale/mismatched CONFIRM is
  ///     ignored (the events stay buffered).
  ///
  /// Returns the next paged fragment to send, or `null` when the CONFIRM
  /// produces no fragment (the ordinary case — a CONFIRM gets no reply).
  Uint8List? _confirmSolicited(int seq) {
    final cont = _readContFrags;
    if (cont != null) {
      final lastSent = cont[_readContSent - 1];
      if (seq != (lastSent[0] & 0x0F)) {
        return null; // stale/mismatched CONFIRM during a paged read
      }
      if (_readContSent < cont.length) {
        final next = cont[_readContSent];
        _readContSent++;
        // If that was the final fragment and no events need a flush-CONFIRM,
        // the paged exchange is complete the moment this fragment is released.
        if (_readContSent >= cont.length && _readContEvents == null) {
          _clearReadContinuation();
        }
        return next;
      }
      // All fragments already sent; this CONFIRM acknowledges the final one and
      // flushes any events it carried.
      if (_readContEvents != null) {
        _events.flush(_readContEvents!);
        _events.clearOverflow();
      }
      _clearReadContinuation();
      return null;
    }
    if (_pendingSolicitedFlush != null && seq == _pendingSolicitedSeq) {
      _events.flush(_pendingSolicitedFlush!);
      _events.clearOverflow();
      _pendingSolicitedFlush = null;
      _pendingSolicitedSeq = -1;
    }
    return null;
  }

  void _clearReadContinuation() {
    _readContFrags = null;
    _readContSent = 0;
    _readContEvents = null;
  }

  /// Confirms the in-flight unsolicited fragment (see [takeNullUnsolicited]/
  /// [takeEventUnsolicited]), flushing any events it carried and advancing
  /// [_unsolSeq] — but only if [seq] matches the in-flight fragment's
  /// sequence.
  void _confirmUnsolicited(int seq) {
    if (_unsolInFlightBytes != null && seq == _unsolSeq) {
      if (_unsolInFlightEvents != null) {
        _events.flush(_unsolInFlightEvents!);
      }
      _events.clearOverflow();
      _unsolSeq = (_unsolSeq + 1) & 0x0F;
      _unsolInFlightBytes = null;
      _unsolInFlightEvents = null;
    }
  }

  // --- Host-facing unsolicited push API ------------------------------------

  /// If an ENABLE_UNSOLICITED queued a null announcement and nothing is in
  /// flight, returns that null unsolicited fragment (fc 130, no objects) and
  /// marks it in-flight; else null.
  Uint8List? takeNullUnsolicited() {
    if (!_pendingNullUnsol || _unsolInFlightBytes != null) {
      return null;
    }
    _pendingNullUnsol = false;
    final bytes = buildUnsolicitedResponse(
        seq: _unsolSeq, iin: packIin(_iin1(), _iin2Base()), objectData: Uint8List(0));
    _unsolInFlightBytes = bytes;
    _unsolInFlightEvents = <DnpEvent>[]; // null carries no events to flush
    return bytes;
  }

  /// If unsolicited is enabled for a class with pending events and nothing
  /// is in flight, builds an unsolicited response (fc 130, UNS+CON) carrying
  /// those events, marks it in-flight, and returns it; else null.
  Uint8List? takeEventUnsolicited(int nowMs) {
    if (_unsolInFlightBytes != null || _unsolEnabled.isEmpty) {
      return null;
    }
    final events = _events.pull(_unsolEnabled);
    if (events.isEmpty) {
      return null;
    }
    final bytes = buildUnsolicitedResponse(
        seq: _unsolSeq, iin: packIin(_iin1(), _iin2Base()), objectData: _encodeEventObjects(events));
    _unsolInFlightBytes = bytes;
    _unsolInFlightEvents = events;
    return bytes;
  }

  /// Abandon the in-flight unsolicited attempt after the host exhausts its
  /// retries: events stay buffered (retried on the next change/tick), and
  /// the unsolicited sequence is NOT advanced.
  void failUnsolicited() {
    _unsolInFlightBytes = null;
    _unsolInFlightEvents = null;
  }

  // --- Control (SELECT / OPERATE / DIRECT_OPERATE) ------------------------

  Uint8List _handleDirectOperate(PlcProject project, DnpAppRequest req) {
    final map = _mapFor(project);
    final result = _processControlObjects(req.objects, execute: true, project: project, map: map);
    return buildAppResponse(
      seq: req.seq,
      fir: true,
      fin: true,
      con: false,
      iin: packIin(_iin1(), result.iin2 | _iin2Base()),
      objectData: result.objectData,
    );
  }

  Uint8List _handleSelect(PlcProject project, DnpAppRequest req, int nowMs) {
    final map = _mapFor(project);
    final result = _processControlObjects(req.objects, execute: false, project: project, map: map);
    _pending = _PendingControl(objects: req.objects, expiresAtMs: nowMs + _selectTimeoutMs);
    return buildAppResponse(
      seq: req.seq,
      fir: true,
      fin: true,
      con: false,
      iin: packIin(_iin1(), result.iin2 | _iin2Base()),
      objectData: result.objectData,
    );
  }

  Uint8List _handleOperate(PlcProject project, DnpAppRequest req, int nowMs) {
    final pending = _pending;
    final matches = pending != null && nowMs <= pending.expiresAtMs && _objectsMatch(pending.objects, req.objects);
    if (!matches) {
      final result = _processControlObjects(req.objects, execute: false, forcedStatus: DnpControlStatus.noSelect);
      return buildAppResponse(
        seq: req.seq,
        fir: true,
        fin: true,
        con: false,
        iin: packIin(_iin1(), result.iin2 | _iin2Base()),
        objectData: result.objectData,
      );
    }
    _pending = null; // the SELECT is consumed whether or not this OPERATE fully succeeds.
    final map = _mapFor(project);
    final result = _processControlObjects(req.objects, execute: true, project: project, map: map);
    return buildAppResponse(
      seq: req.seq,
      fir: true,
      fin: true,
      con: false,
      iin: packIin(_iin1(), result.iin2 | _iin2Base()),
      objectData: result.objectData,
    );
  }

  /// True if every header in [a] and [b] carries the same group/variation/
  /// qualifier/range/indices/payload bytes, in order — the byte-identical
  /// SELECT/OPERATE match real masters perform.
  bool _objectsMatch(List<DnpObjectHeader> a, List<DnpObjectHeader> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      final ha = a[i];
      final hb = b[i];
      if (ha.group != hb.group || ha.variation != hb.variation || ha.qualifier != hb.qualifier) {
        return false;
      }
      if (ha.start != hb.start || ha.stop != hb.stop || ha.count != hb.count) {
        return false;
      }
      if (ha.indices.length != hb.indices.length) {
        return false;
      }
      for (var j = 0; j < ha.indices.length; j++) {
        if (ha.indices[j] != hb.indices[j]) {
          return false;
        }
      }
      if (ha.objectData.length != hb.objectData.length) {
        return false;
      }
      for (var j = 0; j < ha.objectData.length; j++) {
        if (ha.objectData[j] != hb.objectData[j]) {
          return false;
        }
      }
    }
    return true;
  }

  /// Walks a control request's object headers, evaluating (and, when
  /// [execute] is true, applying) each CROB (g12v1) or Analog Output Block
  /// (g41v1/v3) point, and builds the echoed response object data with each
  /// point's status byte filled in.
  ///
  /// When [forcedStatus] is set (the OPERATE-without-SELECT rejection path),
  /// every point is reported with that status and [project]/[map] are
  /// unused — nothing is looked up or written, only the request's control
  /// objects are echoed back with the rejection status.
  ({Uint8List objectData, int iin2}) _processControlObjects(
    List<DnpObjectHeader> objects, {
    required bool execute,
    int? forcedStatus,
    PlcProject? project,
    DnpMap? map,
  }) {
    final out = BytesBuilder();
    var iin2 = 0;
    for (final h in objects) {
      if (h.group == 12 && h.variation == 1) {
        final ptBytes = <Uint8List>[];
        for (var i = 0; i < h.indices.length; i++) {
          final crob = decodeCrob(h.objectData, i * 11);
          if (crob == null) {
            iin2 |= DnpIin2.parameterError;
            ptBytes.add(encodeCrob(controlCode: 0, count: 0, onTimeMs: 0, offTimeMs: 0, status: DnpControlStatus.formatError));
            continue;
          }
          final status = forcedStatus ?? _evaluateCrob(project!, map!, h.indices[i], crob, execute: execute);
          ptBytes.add(encodeCrob(
            controlCode: crob.controlCode,
            count: crob.count,
            onTimeMs: crob.onTimeMs,
            offTimeMs: crob.offTimeMs,
            status: status,
          ));
        }
        out.add(_buildEchoObject(
          group: h.group,
          variation: h.variation,
          qualifier: h.qualifier,
          start: h.start,
          stop: h.stop,
          count: h.count,
          indices: h.indices,
          pointBytes: ptBytes,
        ));
      } else if (h.group == 41 && (h.variation == 1 || h.variation == 3)) {
        final ptBytes = <Uint8List>[];
        for (var i = 0; i < h.indices.length; i++) {
          if (h.variation == 1) {
            final dec = decodeAnalogOutputInt(h.objectData, i * 5);
            if (dec == null) {
              iin2 |= DnpIin2.parameterError;
              ptBytes.add(encodeAnalogOutputInt(value: 0, status: DnpControlStatus.formatError));
              continue;
            }
            final status = forcedStatus ?? _evaluateAnalogOut(project!, map!, h.indices[i], dec.value, execute: execute);
            ptBytes.add(encodeAnalogOutputInt(value: dec.value, status: status));
          } else {
            final dec = decodeAnalogOutputFloat(h.objectData, i * 5);
            if (dec == null) {
              iin2 |= DnpIin2.parameterError;
              ptBytes.add(encodeAnalogOutputFloat(value: 0.0, status: DnpControlStatus.formatError));
              continue;
            }
            final status = forcedStatus ?? _evaluateAnalogOut(project!, map!, h.indices[i], dec.value, execute: execute);
            ptBytes.add(encodeAnalogOutputFloat(value: dec.value, status: status));
          }
        }
        out.add(_buildEchoObject(
          group: h.group,
          variation: h.variation,
          qualifier: h.qualifier,
          start: h.start,
          stop: h.stop,
          count: h.count,
          indices: h.indices,
          pointBytes: ptBytes,
        ));
      } else {
        // Not a control object this v1 outstation understands.
        iin2 |= DnpIin2.objectUnknown;
      }
    }
    return (objectData: out.toBytes(), iin2: iin2);
  }

  /// Builds the echoed response bytes for one control object header: the
  /// header itself, followed by each point's payload — with an index prefix
  /// re-emitted before each payload for the index-prefixed qualifiers,
  /// matching the wire shape [DnpAppRequest] originally decoded it from.
  Uint8List _buildEchoObject({
    required int group,
    required int variation,
    required int qualifier,
    int? start,
    int? stop,
    int? count,
    required List<int> indices,
    required List<Uint8List> pointBytes,
  }) {
    final out = BytesBuilder();
    out.add(encodeObjectHeader(group: group, variation: variation, qualifier: qualifier, start: start, stop: stop, count: count));
    if (qualifier == DnpQualifier.indexPrefix8 || qualifier == DnpQualifier.indexPrefix16) {
      final idxSize = qualifier == DnpQualifier.indexPrefix8 ? 1 : 2;
      for (var i = 0; i < indices.length; i++) {
        out.addByte(indices[i] & 0xFF);
        if (idxSize == 2) {
          out.addByte((indices[i] >> 8) & 0xFF);
        }
        out.add(pointBytes[i]);
      }
    } else {
      for (final b in pointBytes) {
        out.add(b);
      }
    }
    return out.toBytes();
  }

  /// Evaluates (and, when [execute] is true, applies) one CROB against the
  /// binaryOutput point at [index]. Returns the point's response status.
  int _evaluateCrob(PlcProject project, DnpMap map, int index, DnpCrob crob, {required bool execute}) {
    final entry = _findEntry(map, 'binaryOutput', index);
    if (entry == null) {
      return DnpControlStatus.notSupported;
    }
    bool? desired;
    switch (crob.controlCode) {
      case DnpControlCode.latchOn:
      case DnpControlCode.pulseOn:
        desired = true;
        break;
      case DnpControlCode.latchOff:
      case DnpControlCode.pulseOff:
        desired = false;
        break;
      case DnpControlCode.nul:
        desired = null; // a legitimate no-op control: success, no write.
        break;
      default:
        return DnpControlStatus.notSupported;
    }
    if (desired == null) {
      return DnpControlStatus.success;
    }
    // Write-time hard backstop (protocol-hardening workstream, Task 2): DNP3
    // map entries have NO `access` field at all (see `DnpMapEntry`), so a
    // hand-retargeted `pointType` pointing at the reserved System tag has
    // nothing else stopping it — `isExternallyWritable` re-checks the
    // underlying ROOT tag itself, independent of the map. Never a
    // replacement for the forced-tag check beside it.
    if (_isForcedSkip(project, entry.tag) || !isExternallyWritable(project, entry.tag)) {
      return DnpControlStatus.notAuthorized;
    }
    if (execute) {
      writePath(project, entry.tag, desired);
    }
    return DnpControlStatus.success;
  }

  /// Evaluates (and, when [execute] is true, applies) one Analog Output
  /// Block value against the analogOutput point at [index]. Returns the
  /// point's response status.
  int _evaluateAnalogOut(PlcProject project, DnpMap map, int index, num value, {required bool execute}) {
    final entry = _findEntry(map, 'analogOutput', index);
    if (entry == null) {
      return DnpControlStatus.notSupported;
    }
    // Write-time hard backstop (protocol-hardening workstream, Task 2): see
    // the identical comment in `_evaluateCrob` above.
    if (_isForcedSkip(project, entry.tag) || !isExternallyWritable(project, entry.tag)) {
      return DnpControlStatus.notAuthorized;
    }
    if (execute) {
      final dt = dataTypeOfPath(project, entry.tag) ?? 'INT32';
      if (dt == 'FLOAT64') {
        writePath(project, entry.tag, value is double ? value : value.toDouble());
      } else {
        writePath(project, entry.tag, value is int ? value : value.round());
      }
    }
    return DnpControlStatus.success;
  }

  // --- Map/project helpers -------------------------------------------------

  DnpMap _mapFor(PlcProject project) => project.protocols?.dnp3?.map ?? DnpMap(entries: []);

  DnpMapEntry? _findEntry(DnpMap map, String pointType, int index) {
    for (final e in map.entries) {
      if (e.pointType == pointType && e.index == index) {
        return e;
      }
    }
    return null;
  }

  /// The root tag of a (possibly dotted/indexed) path — mirrors
  /// `modbus_pdu.dart`'s `_findRootTag`: the tag name is everything before
  /// the first `.` or `[`.
  PlcTag? _findRootTag(PlcProject project, String path) {
    final rootName = path.split('.').first.split('[').first;
    for (final t in project.tags) {
      if (t.name == rootName) {
        return t;
      }
    }
    return null;
  }

  /// Force-aware write guard: mirrors `modbus_pdu.dart`'s `_isForcedSkip` —
  /// find the ROOT tag of the (possibly dotted) path and honor its
  /// `isForced` flag, so forcing a struct tag skips writes to any of its
  /// members, not just a bare top-level write. Unlike Modbus (which skips
  /// silently and still echoes success), a DNP3 control on a forced point
  /// reports the skip via the NOT_AUTHORIZED status.
  bool _isForcedSkip(PlcProject project, String path) {
    final root = _findRootTag(project, path);
    return root != null && root.isForced && root.value is! Map && root.value is! List;
  }
}
