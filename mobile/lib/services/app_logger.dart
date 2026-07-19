import '../models/app_log.dart';

/// The logger service: owns the ring buffer and per-source level gating.
/// This is the API every subsystem (protocol hosts, scan loop, project
/// load/save, historian, scheduler) calls to emit log entries.
///
/// This is the ONE place in the log stack allowed to read a real clock —
/// `mobile/lib/models/app_log.dart` is pure and never does. `tMs` on every
/// method here defaults to `DateTime.now().millisecondsSinceEpoch` but can
/// be supplied explicitly so tests stay deterministic.
///
/// **Not cleared on project switch.** This deliberately diverges from
/// `TagHistorian` (`mobile/lib/services/tag_historian.dart`), which DOES
/// clear on switch. The historian's samples belong to a project's tags —
/// they're meaningless once that project's gone. Log entries are app-level:
/// they record what the app (and its hosts) did, including the moments
/// around a project switch. Clearing them on switch would throw away the
/// "before" side of exactly the failure this feature exists to diagnose
/// ("it broke when I switched projects"). The shell decides when/whether to
/// ever clear; this service does not do it implicitly.
///
/// Does NOT extend `ChangeNotifier` and does NOT notify per entry. The Logs
/// screen repaints on the app's existing throttled `LiveTick` pulse
/// (`mobile/lib/widgets/live_tick.dart`), not on a per-log-call listener —
/// a per-entry notify would thrash the widget tree exactly the way
/// `LiveTick` was introduced to avoid for the per-scan `setState`.
///
/// **Never throws.** A logging bug must not break a caller — in particular
/// a protocol host mid-scan. Every public method that can execute
/// caller-supplied code (`logLazy`'s `build`/`detail` builders) wraps that
/// call so a throw is contained.
///
/// If `build` throws, the primary message could not be produced at all, so
/// this records a best-effort internal error entry in its place (the
/// original `source`/`level` are kept so filtering still finds it) and
/// returns.
///
/// If `build` already succeeded and `detail` throws, the primary message is
/// NOT discarded — losing it would erase the diagnostic signal the caller
/// was trying to record (e.g. "unsupported ROSCTR 0x07") just because a
/// supplementary hex/frame formatter misbehaved. The entry is recorded with
/// the built message and a short marker in place of the detail noting the
/// detail builder threw.
///
/// Either way, this never rethrows past `logLazy`.
class AppLogger {
  final LogRingBuffer _buffer;
  final Map<String, LogLevel> _sourceLevels = <String, LogLevel>{};

  /// DEBUG/TRACE frame detail is off by default — an explicit product
  /// decision so hosts can log liberally without flooding the buffer.
  static const LogLevel kDefaultMinLevel = LogLevel.info;

  AppLogger({int capacity = kLogDefaultCapacity})
      : _buffer = LogRingBuffer(capacity: capacity);

  /// The effective minimum level for [source] (the configured level, or
  /// [kDefaultMinLevel] if none was set).
  LogLevel sourceLevel(String source) {
    return _sourceLevels[source] ?? kDefaultMinLevel;
  }

  /// Sets the minimum level for [source]. Independent per source — raising
  /// one source's level never affects another's.
  void setSourceLevel(String source, LogLevel min) {
    _sourceLevels[source] = min;
  }

  /// Whether a call at [level] for [source] would actually be recorded.
  bool isEnabled(String source, LogLevel level) {
    return level.index >= sourceLevel(source).index;
  }

  /// Eager log call. Use for lifecycle events where [message] (and
  /// [detail]) are constants or already-cheap strings — the call site pays
  /// the cost of building them regardless of whether the level is enabled,
  /// which is fine for a cold path but NOT for per-frame detail (use
  /// [logLazy] for that).
  void log(
    String source,
    LogLevel level,
    String message, {
    String? detail,
    int? tMs,
  }) {
    if (!isEnabled(source, level)) {
      return;
    }
    _recordSafe(source, level, message, detail, tMs);
  }

  /// Lazy log call — the hot-path API. Checks whether [level] is enabled
  /// for [source] FIRST, and returns without ever invoking [build] (or
  /// [detail]) when it is not. This is what makes a disabled level cost
  /// essentially nothing: no string interpolation, no formatting, no
  /// allocation, even when this is called once per scan frame.
  ///
  /// If [build] throws, the exception is caught and contained here: a
  /// best-effort internal error entry is recorded in place of the message
  /// (using the same [source] so it's still findable when filtering on that
  /// source) and this method returns normally.
  ///
  /// If [build] succeeds but [detail] throws, the built message is still
  /// recorded — only [detail] is replaced with a short marker noting the
  /// detail builder failed. The primary message is the diagnostic signal
  /// callers depend on and must not be lost just because a supplementary
  /// detail formatter misbehaved.
  ///
  /// Either way, it never rethrows and never leaves the buffer in a bad
  /// state — entries logged after a throwing builder still record normally.
  void logLazy(
    String source,
    LogLevel level,
    String Function() build, {
    String Function()? detail,
    int? tMs,
  }) {
    if (!isEnabled(source, level)) {
      return;
    }

    String message;
    try {
      message = build();
    } catch (err) {
      _recordSafe(
        source,
        LogLevel.error,
        'log message builder threw: $err',
        null,
        tMs,
      );
      return;
    }

    String? detailStr;
    if (detail != null) {
      try {
        detailStr = detail();
      } catch (err) {
        // The primary message already built successfully — that is the
        // diagnostic signal callers actually care about (e.g. "unsupported
        // ROSCTR 0x07"), and a broken supplementary hex/frame formatter must
        // not erase it. Record the message with a short marker in place of
        // the detail so the builder failure is still visible on the same
        // entry, rather than losing the whole entry.
        detailStr = 'log detail builder threw: $err';
      }
    }

    _recordSafe(source, level, message, detailStr, tMs);
  }

  /// All entries currently held, oldest-first.
  List<LogEntry> get entries => _buffer.entries;

  /// Empties the buffer. NOT called implicitly on project switch — see the
  /// class doc comment for why.
  void clear() {
    _buffer.clear();
  }

  // Actually appends to the buffer, catching anything unexpected so a
  // logging call can NEVER throw out to a caller (e.g. a protocol host
  // mid-scan). This is the single choke point every public method funnels
  // through.
  void _recordSafe(
    String source,
    LogLevel level,
    String message,
    String? detail,
    int? tMs,
  ) {
    try {
      final stamp = tMs ?? DateTime.now().millisecondsSinceEpoch;
      _buffer.add(
        LogEntry(
          tMs: stamp,
          level: level,
          source: source,
          message: message,
          detail: detail,
        ),
      );
    } catch (_) {
      // Never let a logging failure escape to the caller. There is
      // nowhere safe to report this from inside the logger itself, so it
      // is deliberately swallowed.
    }
  }
}
