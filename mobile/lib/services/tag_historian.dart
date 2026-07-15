/// A single historized data point: monotonic wall-clock [t] (ms) and value [v].
/// BOOLs are stored as 1.0 / 0.0 by the caller before they reach the historian.
class TrendSample {
  final int t;
  final double v;
  const TrendSample(this.t, this.v);
}

/// The pen fields the historian needs. Kept as an interface so the engine has
/// no dependency on the project model (which `TrendPen` lives in). `TrendPen`
/// implements this.
abstract class TrendPenLike {
  String get tagPath;
  int get sampleIntervalMs;
  String get retentionMode; // 'points' | 'time'
  int get maxPoints;
  int get windowMs;
}

/// A memory-only, tick-driven strip-chart historian. Owns one ring buffer per
/// pen keyed by `tagPath`. Sampling is DRIVEN by the scan loop (call [sample]
/// each live tick) rather than self-timed, so it holds no timer and is fully
/// deterministic under test. Never persisted.
class TagHistorian {
  final Map<String, List<TrendSample>> _buffers = {};

  /// Reconcile the buffer map to [pens]: create an empty buffer for a new pen,
  /// drop the buffer for a removed pen, preserve buffers for unchanged pens.
  void syncPens(List<TrendPenLike> pens) {
    final wanted = pens.map((p) => p.tagPath).toSet();
    _buffers.removeWhere((key, _) => !wanted.contains(key));
    for (final p in pens) {
      _buffers.putIfAbsent(p.tagPath, () => <TrendSample>[]);
    }
  }

  /// For each pen, if its sample interval has elapsed since its last sample
  /// (a pen with no samples always captures), read via [readValue] and append,
  /// then trim by the pen's retention rule. A null read is skipped.
  void sample(List<TrendPenLike> pens, double? Function(String tagPath) readValue, int nowMs) {
    for (final p in pens) {
      final buf = _buffers.putIfAbsent(p.tagPath, () => <TrendSample>[]);
      if (buf.isNotEmpty && nowMs - buf.last.t < p.sampleIntervalMs) {
        continue;
      }
      final value = readValue(p.tagPath);
      if (value == null) {
        continue;
      }
      buf.add(TrendSample(nowMs, value));
      _trim(buf, p, nowMs);
    }
  }

  // Trims leading (oldest) samples in a SINGLE `removeRange` shift rather than
  // per-element `removeAt(0)` calls. Samples are always appended in increasing
  // `t` order, so the elements to drop are a contiguous leading run; removing
  // them one at a time is O(n) per removal (each shifts the whole tail), which
  // in steady state costs O(n) every sample. Computing the drop count and doing
  // one `removeRange(0, drop)` is a single O(n) shift instead.
  void _trim(List<TrendSample> buf, TrendPenLike p, int nowMs) {
    if (p.retentionMode == 'points') {
      final maxPts = p.maxPoints < 2 ? 2 : p.maxPoints;
      if (buf.length > maxPts) {
        buf.removeRange(0, buf.length - maxPts);
      }
    } else {
      final cutoff = nowMs - (p.windowMs < 1000 ? 1000 : p.windowMs);
      var drop = 0;
      while (drop < buf.length && buf[drop].t < cutoff) {
        drop++;
      }
      if (drop > 0) {
        buf.removeRange(0, drop);
      }
    }
  }

  /// Read-only view of a pen's buffer (empty for an unknown pen).
  List<TrendSample> buffer(String tagPath) => _buffers[tagPath] ?? const <TrendSample>[];

  /// Empty all buffers (called on project switch).
  void clear() => _buffers.clear();
}
