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
      } else {
        _confirmSolicited(rawSeq);
      }
      return Uint8List(0); // no response fragment for a CONFIRM
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

    final out = BytesBuilder();
    if (includeStatic) {
      out.add(_buildClassZeroPayload(project, map));
    }

    var con = false;
    if (eventClasses.isNotEmpty) {
      final events = _events.pull(eventClasses);
      if (events.isNotEmpty) {
        out.add(_encodeEventObjects(events));
        con = true;
        _pendingSolicitedFlush = events;
        _pendingSolicitedSeq = req.seq;
      }
    }

    return buildAppResponse(
      seq: req.seq,
      fir: true,
      fin: true,
      con: con,
      iin: packIin(_iin1(), _iin2Base()),
      objectData: out.toBytes(),
    );
  }

  /// Encodes [events] into DNP3 event objects, grouped by type and by
  /// input-vs-output into 6 buckets: binaryInput -> g2v2, binaryOutput ->
  /// g11v2, analogInput-int -> g32v3, analogOutput-int -> g42v3,
  /// analogInput-float -> g32v7, analogOutput-float -> g42v7. Each uses
  /// qualifier 0x28 (2-byte count + a 2-byte LE index prefix before each
  /// point), since events carry their own point index. FIFO order is
  /// preserved within each group; empty buckets emit nothing, so an
  /// all-input event set produces exactly the 3 groups it always did.
  Uint8List _encodeEventObjects(List<DnpEvent> events) {
    bool isOut(DnpEvent e) => e.pointType == 'binaryOutput' || e.pointType == 'analogOutput';
    final binIn = events.where((e) => e.isBinary && !isOut(e)).toList();
    final binOut = events.where((e) => e.isBinary && isOut(e)).toList();
    final aIntIn = events.where((e) => !e.isBinary && !e.isFloat && !isOut(e)).toList();
    final aIntOut = events.where((e) => !e.isBinary && !e.isFloat && isOut(e)).toList();
    final aFloatIn = events.where((e) => !e.isBinary && e.isFloat && !isOut(e)).toList();
    final aFloatOut = events.where((e) => !e.isBinary && e.isFloat && isOut(e)).toList();

    final out = BytesBuilder();
    if (binIn.isNotEmpty) {
      out.add(_encodeEventGroup(
          2, 2, binIn, (e) => encodeG2V2(value: e.boolValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (binOut.isNotEmpty) {
      out.add(_encodeEventGroup(
          11, 2, binOut, (e) => encodeG11V2(value: e.boolValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (aIntIn.isNotEmpty) {
      out.add(_encodeEventGroup(
          32, 3, aIntIn, (e) => encodeG32V3(value: e.intValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (aIntOut.isNotEmpty) {
      out.add(_encodeEventGroup(
          42, 3, aIntOut, (e) => encodeG42V3(value: e.intValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (aFloatIn.isNotEmpty) {
      out.add(_encodeEventGroup(
          32, 7, aFloatIn, (e) => encodeG32V7(value: e.floatValue, flags: e.flags, timeMs: e.timeMs)));
    }
    if (aFloatOut.isNotEmpty) {
      out.add(_encodeEventGroup(
          42, 7, aFloatOut, (e) => encodeG42V7(value: e.floatValue, flags: e.flags, timeMs: e.timeMs)));
    }
    return out.toBytes();
  }

  Uint8List _encodeEventGroup(
    int group,
    int variation,
    List<DnpEvent> events,
    Uint8List Function(DnpEvent) encodeOne,
  ) {
    final out = BytesBuilder();
    out.add(encodeObjectHeader(
        group: group, variation: variation, qualifier: DnpQualifier.indexPrefix16, count: events.length));
    for (final e in events) {
      out.addByte(e.index & 0xFF);
      out.addByte((e.index >> 8) & 0xFF);
      out.add(encodeOne(e));
    }
    return out.toBytes();
  }

  Uint8List _buildClassZeroPayload(PlcProject project, DnpMap map) {
    final out = BytesBuilder();
    out.add(_encodeBinaryBucket(project, map, 'binaryInput', 1, 2));
    out.add(_encodeBinaryBucket(project, map, 'binaryOutput', 10, 2));
    out.add(_encodeAnalogBucket(project, map, 'analogInput'));
    out.add(_encodeAnalogBucket(project, map, 'analogOutput'));
    return out.toBytes();
  }

  Uint8List _encodeBinaryBucket(PlcProject project, DnpMap map, String pointType, int group, int variation) {
    final entries = <int, DnpMapEntry>{};
    for (final e in map.entries) {
      if (e.pointType == pointType) {
        entries[e.index] = e;
      }
    }
    if (entries.isEmpty) {
      return Uint8List(0);
    }
    final indices = entries.keys.toList()..sort();
    final runs = _buildRuns(indices, const <int>{});
    final out = BytesBuilder();
    for (final run in runs) {
      final qualifier = run.stop <= 0xFF ? DnpQualifier.range8 : DnpQualifier.range16;
      out.add(encodeObjectHeader(group: group, variation: variation, qualifier: qualifier, start: run.start, stop: run.stop));
      for (var idx = run.start; idx <= run.stop; idx++) {
        final entry = entries[idx];
        if (entry == null) {
          out.add(group == 1 ? encodeG1V2(value: false, flags: 0) : encodeG10V2(value: false, flags: 0));
          continue;
        }
        final value = readPath(project, entry.tag) == true;
        out.add(group == 1
            ? encodeG1V2(value: value, flags: DnpFlags.online)
            : encodeG10V2(value: value, flags: DnpFlags.online));
      }
    }
    return out.toBytes();
  }

  Uint8List _encodeAnalogBucket(PlcProject project, DnpMap map, String pointType) {
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

    final out = BytesBuilder();
    out.add(_encodeNumericSubBucket(project, intEntries, floatEntries.keys.toSet(), group, intVariation, isFloat: false));
    out.add(_encodeNumericSubBucket(project, floatEntries, intEntries.keys.toSet(), group, floatVariation, isFloat: true));
    return out.toBytes();
  }

  Uint8List _encodeNumericSubBucket(
    PlcProject project,
    Map<int, DnpMapEntry> bucket,
    Set<int> exclude,
    int group,
    int variation, {
    required bool isFloat,
  }) {
    if (bucket.isEmpty) {
      return Uint8List(0);
    }
    final indices = bucket.keys.toList()..sort();
    final runs = _buildRuns(indices, exclude);
    final out = BytesBuilder();
    for (final run in runs) {
      final qualifier = run.stop <= 0xFF ? DnpQualifier.range8 : DnpQualifier.range16;
      out.add(encodeObjectHeader(group: group, variation: variation, qualifier: qualifier, start: run.start, stop: run.stop));
      for (var idx = run.start; idx <= run.stop; idx++) {
        final entry = bucket[idx];
        if (entry == null) {
          out.add(isFloat ? _encodeFloatPoint(group, 0.0, 0) : _encodeIntPoint(group, 0, 0));
          continue;
        }
        final raw = readPath(project, entry.tag);
        if (isFloat) {
          final v = raw is double ? raw : (raw is int ? raw.toDouble() : 0.0);
          out.add(_encodeFloatPoint(group, v, DnpFlags.online));
        } else {
          final v = raw is int ? raw : (raw is double ? raw.round() : 0);
          out.add(_encodeIntPoint(group, v, DnpFlags.online));
        }
      }
    }
    return out.toBytes();
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

  /// Confirms the events reported by the last solicited Class read (see
  /// [_handleRead]), flushing them from the event engine — but only if
  /// [seq] matches the sequence of the response that carried them; a stale
  /// or mismatched CONFIRM is silently ignored (the events stay buffered).
  void _confirmSolicited(int seq) {
    if (_pendingSolicitedFlush != null && seq == _pendingSolicitedSeq) {
      _events.flush(_pendingSolicitedFlush!);
      _events.clearOverflow();
      _pendingSolicitedFlush = null;
      _pendingSolicitedSeq = -1;
    }
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
