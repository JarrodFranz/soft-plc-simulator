// Pure Dart DNP3 event engine (DNP3 events + unsolicited workstream, Task 2).
// No dart:io / Flutter imports. Holds per-class (1/2/3) bounded event ring
// buffers and performs force-aware change detection over a project's DnpMap:
// each tick, every Class-1/2/3 binaryInput/analogInput point's current value
// (via readPath — forced values win) is compared to its last-reported value;
// on change an event is appended to that class's buffer. Static-only (Class 0)
// points never generate events. The buffer is bounded: when full, the oldest
// event is dropped and an overflow flag is raised (surfaced as IIN2.3 by the
// outstation). pull() returns a snapshot; flush() removes confirmed events by
// identity — so events survive until a master CONFIRMs them.
library dnp3_events;

import '../../models/dnp3_map.dart';
import '../../models/project_model.dart';
import '../../models/tag_resolver.dart';

/// One captured input-point change. `isBinary` selects g2v2 (binary) vs the
/// analog g32 family; for analog, `isFloat` selects g32v7 (float, value in
/// [floatValue]) vs g32v3 (32-bit int, value in [intValue]).
class DnpEvent {
  final String pointType; // 'binaryInput' | 'analogInput'
  final int index;
  final int eventClass; // 1 | 2 | 3
  final bool isBinary;
  final bool isFloat;
  final bool boolValue;
  final int intValue;
  final double floatValue;
  final int flags; // DnpFlags bits (ONLINE etc.)
  final int timeMs; // wall-clock UTC ms (host supplies)

  DnpEvent({
    required this.pointType,
    required this.index,
    required this.eventClass,
    required this.isBinary,
    required this.isFloat,
    required this.boolValue,
    required this.intValue,
    required this.floatValue,
    required this.flags,
    required this.timeMs,
  });
}

class DnpEventEngine {
  final int capacityPerClass;

  // Class 1/2/3 buffers, FIFO (oldest first).
  final Map<int, List<DnpEvent>> _buffers = {
    1: <DnpEvent>[],
    2: <DnpEvent>[],
    3: <DnpEvent>[],
  };

  // Last-reported value per point key ('pointType#index'); establishes the
  // change-detection baseline. A key present here has a baseline; a key absent
  // has never been seen (first detect records baseline, emits no event).
  final Map<String, Object?> _lastReported = {};

  bool _overflowed = false;

  DnpEventEngine({this.capacityPerClass = 200});

  bool get overflowed => _overflowed;
  void clearOverflow() {
    _overflowed = false;
  }

  bool get hasAnyEvents => _buffers.values.any((b) => b.isNotEmpty);
  bool hasEventsForClass(int cls) => (_buffers[cls]?.isNotEmpty) ?? false;
  int countForClass(int cls) => _buffers[cls]?.length ?? 0;

  Set<int> get classesWithEvents => {
        for (final c in const [1, 2, 3])
          if (hasEventsForClass(c)) c,
      };

  /// Snapshot (does NOT remove) of buffered events for [classes], class 1
  /// then 2 then 3, FIFO within each class.
  List<DnpEvent> pull(Set<int> classes) {
    final out = <DnpEvent>[];
    for (final c in const [1, 2, 3]) {
      if (classes.contains(c)) {
        out.addAll(_buffers[c] ?? const <DnpEvent>[]);
      }
    }
    return out;
  }

  /// Removes exactly the [confirmed] event instances (identity match) from
  /// their class buffers. Events not present are ignored.
  void flush(List<DnpEvent> confirmed) {
    final set = Set<DnpEvent>.identity()..addAll(confirmed);
    for (final b in _buffers.values) {
      b.removeWhere(set.contains);
    }
  }

  /// One change-detection pass. Only `binaryInput`/`analogInput` entries with
  /// `eventClass` in {1,2,3} participate; the first time a point is seen its
  /// baseline is recorded WITHOUT emitting an event (so startup does not
  /// flood). Thereafter any value change emits one event into that class.
  void detectChanges(PlcProject project, DnpMap map, int nowMs) {
    for (final e in map.entries) {
      final cls = e.eventClass;
      if (cls < 1 || cls > 3) {
        continue;
      }
      final isBinary = e.pointType == 'binaryInput';
      final isAnalog = e.pointType == 'analogInput';
      if (!isBinary && !isAnalog) {
        continue; // outputs don't generate events
      }
      final key = '${e.pointType}#${e.index}';
      final raw = readPath(project, e.tag);

      if (isBinary) {
        final v = raw == true;
        final had = _lastReported.containsKey(key);
        final prev = _lastReported[key];
        _lastReported[key] = v;
        if (!had || prev == v) {
          continue;
        }
        _append(
          cls,
          DnpEvent(
            pointType: e.pointType,
            index: e.index,
            eventClass: cls,
            isBinary: true,
            isFloat: false,
            boolValue: v,
            intValue: 0,
            floatValue: 0.0,
            flags: 0x01, // DnpFlags.online — bit 7 (state) is applied by the encoder
            timeMs: nowMs,
          ),
        );
      } else {
        final dt = dataTypeOfPath(project, e.tag) ?? 'INT32';
        final isFloat = dt == 'FLOAT64';
        if (isFloat) {
          final v = raw is double ? raw : (raw is int ? raw.toDouble() : 0.0);
          final had = _lastReported.containsKey(key);
          final prev = _lastReported[key];
          _lastReported[key] = v;
          if (!had || prev == v) {
            continue;
          }
          _append(
            cls,
            DnpEvent(
              pointType: e.pointType,
              index: e.index,
              eventClass: cls,
              isBinary: false,
              isFloat: true,
              boolValue: false,
              intValue: 0,
              floatValue: v,
              flags: 0x01,
              timeMs: nowMs,
            ),
          );
        } else {
          final v = raw is int ? raw : (raw is double ? raw.round() : 0);
          final had = _lastReported.containsKey(key);
          final prev = _lastReported[key];
          _lastReported[key] = v;
          if (!had || prev == v) {
            continue;
          }
          _append(
            cls,
            DnpEvent(
              pointType: e.pointType,
              index: e.index,
              eventClass: cls,
              isBinary: false,
              isFloat: false,
              boolValue: false,
              intValue: v,
              floatValue: 0.0,
              flags: 0x01,
              timeMs: nowMs,
            ),
          );
        }
      }
    }
  }

  void _append(int cls, DnpEvent ev) {
    final buf = _buffers[cls]!;
    buf.add(ev);
    while (buf.length > capacityPerClass) {
      buf.removeAt(0); // drop oldest
      _overflowed = true;
    }
  }
}
