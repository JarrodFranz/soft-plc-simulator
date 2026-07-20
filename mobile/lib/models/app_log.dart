// Pure log core: entry, bounded ring buffer, and filter.
//
// This file is intentionally pure Dart — no Flutter, no `dart:io`, no clock.
// `LogEntry.tMs` is supplied by the caller (the future logger service owns
// the real clock), exactly as `TagHistorian.sample(..., int nowMs)` takes
// time as a parameter (see `mobile/lib/services/tag_historian.dart`). That
// is what makes eviction and filtering deterministic and unit-testable.
//
// Nothing here is persisted: the log appears in no project JSON, and this
// file deliberately has no `toJson`/`fromJson`.

/// Severity of a log entry, lowest to highest.
enum LogLevel { trace, debug, info, warn, error }

/// Default capacity of a [LogRingBuffer] when none is specified.
const int kLogDefaultCapacity = 2000;

/// Maximum length of [LogEntry.detail]. Anything longer is truncated with a
/// visible marker so a single large frame dump cannot dominate the buffer.
const int kLogMaxDetailChars = 4096;

// Source constants so every subsystem names itself identically.
const String kLogSourceOpcUa = 'OPC UA';
const String kLogSourceModbus = 'Modbus';
const String kLogSourceMqtt = 'MQTT';
const String kLogSourceDnp3 = 'DNP3';
const String kLogSourceEnip = 'EtherNet/IP';
const String kLogSourceS7 = 'S7';
const String kLogSourceScan = 'Scan';
const String kLogSourceProject = 'Project';
const String kLogSourceSim = 'Sim';
const String kLogSourceHistorian = 'Historian';
const String kLogSourceScheduler = 'Scheduler';
const String kLogSourceFins = 'FINS';

/// One log record. `seq` is assigned by the [LogRingBuffer] that stores it
/// (0 until added); `tMs` is always supplied by the caller, never read from
/// a clock in this file.
class LogEntry {
  final int seq;
  final int tMs;
  final LogLevel level;
  final String source;
  final String message;
  final String? detail;

  const LogEntry({
    this.seq = 0,
    required this.tMs,
    required this.level,
    required this.source,
    required this.message,
    this.detail,
  });

  /// Returns a copy with [seq] set and [detail] truncated if needed. Used
  /// internally by [LogRingBuffer.add] — entries are otherwise immutable.
  LogEntry _withSeqAndTruncatedDetail(int newSeq) {
    return LogEntry(
      seq: newSeq,
      tMs: tMs,
      level: level,
      source: source,
      message: message,
      detail: _truncateDetail(detail),
    );
  }
}

const String _kTruncateMarkerPrefix = '… [truncated, ';
const String _kTruncateMarkerSuffix = ' more chars]';

String? _truncateDetail(String? detail) {
  if (detail == null || detail.length <= kLogMaxDetailChars) {
    return detail;
  }
  // The marker embeds `droppedChars`, so its length is variable — it grows
  // with the digit count of however much got dropped. `droppedChars` can
  // never exceed `detail.length` (we never drop more than the input has),
  // so the digit count of `detail.length` is a safe upper bound on the
  // marker's digit count. Reserve the marker at that worst-case width up
  // front; the real marker (computed from the actual `droppedChars` below)
  // is never wider than reserved, so `kept.length + marker.length` always
  // fits within the cap, no iteration required.
  final maxDroppedDigits = detail.length.toString().length;
  final reservedMarkerLen =
      _kTruncateMarkerPrefix.length + maxDroppedDigits + _kTruncateMarkerSuffix.length;
  var keptLen = kLogMaxDetailChars - reservedMarkerLen;
  if (keptLen < 0) {
    keptLen = 0;
  }
  final kept = detail.substring(0, keptLen);
  final droppedChars = detail.length - keptLen;
  return '$kept$_kTruncateMarkerPrefix$droppedChars$_kTruncateMarkerSuffix';
}

/// A bounded, oldest-first ring buffer of [LogEntry]. At capacity, the
/// oldest entry is evicted on `add`. `seq` is a monotonic identity assigned
/// by this buffer — it keeps increasing across eviction (and across
/// `clear()`), it is never derived from the current list length, so it
/// never lies about relative ordering.
class LogRingBuffer {
  final int capacity;
  final List<LogEntry> _entries = <LogEntry>[];
  int _nextSeq = 1;

  LogRingBuffer({this.capacity = kLogDefaultCapacity});

  /// Appends [e] (assigning it the next `seq` and truncating an oversized
  /// `detail`), evicting the oldest entry first if at capacity.
  void add(LogEntry e) {
    final stamped = e._withSeqAndTruncatedDetail(_nextSeq);
    _nextSeq++;
    _entries.add(stamped);
    if (_entries.length > capacity) {
      _entries.removeAt(0);
    }
  }

  /// A defensive copy, oldest-first. Callers may not mutate the buffer's
  /// internal storage through the returned list.
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  /// Empties the buffer. `seq` numbering is NOT reset — the next entry
  /// added after `clear()` continues from where it left off, preserving
  /// its role as a monotonic identity.
  void clear() {
    _entries.clear();
  }
}

/// Pure filter over a list of entries (oldest-first in, oldest-first out).
///
/// - `minLevel` keeps entries whose `level.index >= minLevel.index`.
/// - `sources`: `null` or empty means "all sources" — NOT "no sources".
/// - `textFilter`: case-insensitive substring match against `message` OR
///   `detail`; empty/blank means no text filtering.
List<LogEntry> filterLogEntries(
  List<LogEntry> entries, {
  LogLevel minLevel = LogLevel.trace,
  Set<String>? sources,
  String textFilter = '',
}) {
  final wantAllSources = sources == null || sources.isEmpty;
  final needle = textFilter.trim().toLowerCase();
  final wantText = needle.isNotEmpty;

  return entries.where((e) {
    if (e.level.index < minLevel.index) {
      return false;
    }
    if (!wantAllSources && !sources.contains(e.source)) {
      return false;
    }
    if (wantText) {
      final inMessage = e.message.toLowerCase().contains(needle);
      final inDetail = e.detail?.toLowerCase().contains(needle) ?? false;
      if (!inMessage && !inDetail) {
        return false;
      }
    }
    return true;
  }).toList();
}
