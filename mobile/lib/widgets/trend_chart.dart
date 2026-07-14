import 'package:flutter/material.dart';

import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import '../services/tag_historian.dart';
import 'live_tick.dart';

/// A render-ready pen (color + digital flag resolved).
class TrendPenView {
  final String tagPath;
  final Color color;
  final String label;
  final bool isDigital;
  const TrendPenView({
    required this.tagPath,
    required this.color,
    required this.label,
    required this.isDigital,
  });
}

/// Maps the app's accent-color name vocabulary to a Color (cyan fallback).
Color trendColorFromName(String name) {
  switch (name) {
    case 'green':
      return Colors.greenAccent;
    case 'red':
      return Colors.redAccent;
    case 'amber':
      return Colors.amberAccent;
    case 'teal':
      return Colors.tealAccent;
    case 'blue':
      return Colors.blueAccent;
    case 'cyan':
    default:
      return Colors.cyanAccent;
  }
}

/// Pure horizontal mapping for the strip chart: converts between a timestamp
/// and a pixel x, using the same padding the painter draws with. Shared by the
/// painter and the trace-cursor hit-testing so the two never drift.
class TrendChartGeometry {
  final double width;
  final int nowMs;
  final int windowMs;
  const TrendChartGeometry({
    required this.width,
    required this.nowMs,
    required this.windowMs,
  });

  static const double leftPad = 36;
  static const double rightPad = 8;

  double get plotLeft => leftPad;
  double get plotRight => width - rightPad;
  double get plotW {
    final w = plotRight - plotLeft;
    return w < 1.0 ? 1.0 : w;
  }

  int get _win => windowMs <= 0 ? 1 : windowMs;

  /// Pixel x for a timestamp (newest sample sits at the right edge).
  double xOfTime(int tMs) => plotLeft + plotW * (1 - (nowMs - tMs) / _win);

  /// Timestamp for a pixel x, clamped to the visible window.
  int timeAtX(double x) {
    final frac = ((x - plotLeft) / plotW).clamp(0.0, 1.0);
    final t = nowMs - ((1 - frac) * _win).round();
    if (t < nowMs - _win) {
      return nowMs - _win;
    }
    if (t > nowMs) {
      return nowMs;
    }
    return t;
  }
}

/// The sample in [buf] whose time is closest to [tMs], or null if empty.
TrendSample? nearestSample(List<TrendSample> buf, int tMs) {
  if (buf.isEmpty) {
    return null;
  }
  var best = buf.first;
  var bestD = (best.t - tMs).abs();
  for (final s in buf) {
    final d = (s.t - tMs).abs();
    if (d < bestD) {
      best = s;
      bestD = d;
    }
  }
  return best;
}

/// Relative age of [cursorMs] vs [nowMs] as '-1m 12s' / '-45s' / 'now'.
String relativeAgo(int cursorMs, int nowMs) {
  final secs = ((nowMs - cursorMs) / 1000).round();
  if (secs <= 0) {
    return 'now';
  }
  final m = secs ~/ 60;
  final s = secs % 60;
  if (m > 0) {
    return '-${m}m ${s}s';
  }
  return '-${s}s';
}

/// Wall-clock time of [cursorMs] as 'HH:mm:ss'.
String clockHms(int cursorMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(cursorMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

/// A pen's value at a cursor sample: '—' if none, 'ON'/'OFF' for digital,
/// else a 2-dp number.
String formatPenValue(TrendPenView pen, TrendSample? s) {
  if (s == null) {
    return '—';
  }
  if (pen.isDigital) {
    return s.v >= 0.5 ? 'ON' : 'OFF';
  }
  return s.v.toStringAsFixed(2);
}

/// Hand-painted strip chart. Analog pens share an auto-scaled left value axis
/// and draw as connected polylines; BOOL pens draw as stacked 0/1 square-wave
/// lanes along the bottom. Time axis: [nowMs-windowMs, nowMs], newest on the
/// right. No chart package (consistent with TankGraphicDisplay).
class TrendChartPainter extends CustomPainter {
  final List<TrendPenView> pens;
  final List<TrendSample> Function(String tagPath) bufferOf;
  final int windowMs;
  final int nowMs;
  final Color axisColor;
  final Color gridColor;
  final int? cursorTimeMs;
  final Color cursorColor;

  TrendChartPainter({
    required this.pens,
    required this.bufferOf,
    required this.windowMs,
    required this.nowMs,
    required this.axisColor,
    required this.gridColor,
    this.cursorTimeMs,
    this.cursorColor = const Color(0xFFECEFF1),
  });

  static const double _topPad = 8;
  static const double _laneHeight = 16;
  static const double _laneGap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final digital = pens.where((p) => p.isDigital).toList();
    final analog = pens.where((p) => !p.isDigital).toList();

    final digitalBandH = digital.isEmpty
        ? 0.0
        : digital.length * (_laneHeight + _laneGap) + _laneGap;
    final geo = TrendChartGeometry(width: size.width, nowMs: nowMs, windowMs: windowMs);
    final plotLeft = geo.plotLeft;
    final plotRight = geo.plotRight;
    const plotTop = _topPad;
    final plotBottom = size.height - digitalBandH - 4;
    final plotH = (plotBottom - plotTop).clamp(1.0, double.infinity);
    final win = windowMs <= 0 ? 1 : windowMs;

    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    // Frame.
    canvas.drawRect(
      Rect.fromLTRB(plotLeft, plotTop, plotRight, plotBottom),
      gridPaint..style = PaintingStyle.stroke,
    );

    double xOf(int t) => geo.xOfTime(t);

    // --- Analog auto-scale across all visible analog samples ---
    double? lo, hi;
    for (final p in analog) {
      for (final s in bufferOf(p.tagPath)) {
        if (s.t < nowMs - win) {
          continue;
        }
        lo = (lo == null || s.v < lo) ? s.v : lo;
        hi = (hi == null || s.v > hi) ? s.v : hi;
      }
    }
    if (lo != null && hi != null) {
      final loVal = lo;
      final hiVal = hi;
      double lo2 = loVal;
      double hi2 = hiVal;
      if ((hi2 - lo2).abs() < 1e-9) {
        lo2 -= 1;
        hi2 += 1;
      }
      final span = hi2 - lo2;
      final pad = span * 0.08;
      lo2 -= pad;
      hi2 += pad;
      final loFinal = lo2;
      final hiFinal = hi2;
      double yOf(double v) => plotTop + plotH * (1 - (v - loFinal) / (hiFinal - loFinal));

      // Value-axis labels (lo, mid, hi).
      void tp(double v, double y) {
        final t = TextPainter(
          text: TextSpan(text: v.toStringAsFixed(1), style: TextStyle(color: axisColor, fontSize: 9)),
          textDirection: TextDirection.ltr,
        )..layout();
        t.paint(canvas, Offset(2, y - t.height / 2));
      }

      tp(hiFinal, plotTop);
      tp((hiFinal + loFinal) / 2, plotTop + plotH / 2);
      tp(loFinal, plotBottom);

      for (final p in analog) {
        final buf = bufferOf(p.tagPath).where((s) => s.t >= nowMs - win).toList();
        if (buf.isEmpty) {
          continue;
        }
        final path = Path();
        for (var i = 0; i < buf.length; i++) {
          final x = xOf(buf[i].t);
          final y = yOf(buf[i].v);
          if (i == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = p.color
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      }
    }

    // --- Digital lanes ---
    var laneTop = plotBottom + _laneGap;
    for (final p in digital) {
      final laneBottom = laneTop + _laneHeight;
      final buf = bufferOf(p.tagPath).where((s) => s.t >= nowMs - win).toList();
      final onY = laneTop + 2;
      final offY = laneBottom - 2;
      if (buf.isNotEmpty) {
        final path = Path();
        double prevY = buf.first.v >= 0.5 ? onY : offY;
        path.moveTo(xOf(buf.first.t), prevY);
        for (var i = 1; i < buf.length; i++) {
          final x = xOf(buf[i].t);
          final y = buf[i].v >= 0.5 ? onY : offY;
          path.lineTo(x, prevY); // horizontal hold
          path.lineTo(x, y); // step
          prevY = y;
        }
        path.lineTo(xOf(nowMs), prevY);
        canvas.drawPath(
          path,
          Paint()
            ..color = p.color
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      }
      // Lane label.
      final t = TextPainter(
        text: TextSpan(text: p.label, style: TextStyle(color: p.color, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(canvas, Offset(plotLeft + 2, laneTop + 1));
      laneTop = laneBottom + _laneGap;
    }

    // --- Legend for analog pens (top-right) ---
    var lx = plotRight;
    for (final p in analog.reversed) {
      final t = TextPainter(
        text: TextSpan(text: p.label, style: TextStyle(color: p.color, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      lx -= t.width + 14;
      canvas.drawRect(Rect.fromLTWH(lx, plotTop + 1, 8, 8), Paint()..color = p.color);
      t.paint(canvas, Offset(lx + 11, plotTop));
    }

    // --- Trace cursor (optional) ---
    final cursor = cursorTimeMs;
    if (cursor != null && cursor >= nowMs - win && cursor <= nowMs) {
      final cx = geo.xOfTime(cursor);
      final cursorBottom = plotBottom + digitalBandH;
      canvas.drawLine(
        Offset(cx, plotTop),
        Offset(cx, cursorBottom),
        Paint()
          ..color = cursorColor.withValues(alpha: 0.9)
          ..strokeWidth = 1,
      );
      // Dot at each analog pen's nearest sample (reuse the same scale as above).
      if (lo != null && hi != null) {
        double lo2 = lo;
        double hi2 = hi;
        if ((hi2 - lo2).abs() < 1e-9) {
          lo2 -= 1;
          hi2 += 1;
        }
        final span0 = hi2 - lo2;
        lo2 -= span0 * 0.08;
        hi2 += span0 * 0.08;
        double yOf2(double v) => plotTop + plotH * (1 - (v - lo2) / (hi2 - lo2));
        for (final p in analog) {
          final s = nearestSample(bufferOf(p.tagPath).where((s) => s.t >= nowMs - win).toList(), cursor);
          if (s == null) {
            continue;
          }
          canvas.drawCircle(Offset(cx, yOf2(s.v)), 2.5, Paint()..color = p.color);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant TrendChartPainter old) => true;
}

/// A live trend chart bound to a [TagHistorian]. Repaints on each LiveTick
/// pulse (never via a whole-shell setState). Reused by the Trends preview and
/// the HMI TrendChartDisplay component.
class TrendChartView extends StatefulWidget {
  final PlcProject project;
  final TagHistorian historian;
  final List<TrendPenView> pens;
  final int windowMs;
  final double height;

  const TrendChartView({
    super.key,
    required this.project,
    required this.historian,
    required this.pens,
    required this.windowMs,
    this.height = 220,
  });

  /// Resolve a project pen to a render-ready [TrendPenView]. A BOOL leaf (by
  /// [dataTypeOfPath]) is digital; everything else is analog.
  static TrendPenView viewForPen(PlcProject project, TrendPen pen, {String? colorOverride}) {
    final type = dataTypeOfPath(project, pen.tagPath);
    return TrendPenView(
      tagPath: pen.tagPath,
      color: trendColorFromName(colorOverride ?? pen.color),
      label: pen.tagPath,
      isDigital: type == 'BOOL',
    );
  }

  @override
  State<TrendChartView> createState() => _TrendChartViewState();
}

class _TrendChartViewState extends State<TrendChartView> {
  int? _cursorTimeMs;

  @override
  Widget build(BuildContext context) {
    if (widget.pens.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text('No pens to plot', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        ),
      );
    }
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return ListenableBuilder(
            listenable: LiveTickScope.of(context),
            builder: (context, _) {
              final now = DateTime.now().millisecondsSinceEpoch;
              final win = widget.windowMs <= 0 ? 1 : widget.windowMs;
              final geo = TrendChartGeometry(width: width, nowMs: now, windowMs: widget.windowMs);
              final cursor = _cursorTimeMs;
              final inWindow = cursor != null && cursor >= now - win && cursor <= now;
              // Auto-hide: reset the state cleanly once the anchored time has
              // scrolled off the left edge (never mutate state during build).
              if (cursor != null && !inWindow) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _cursorTimeMs == cursor) {
                    setState(() => _cursorTimeMs = null);
                  }
                });
              }
              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => setState(() => _cursorTimeMs = geo.timeAtX(d.localPosition.dx)),
                      onHorizontalDragStart: (d) => setState(() => _cursorTimeMs = geo.timeAtX(d.localPosition.dx)),
                      onHorizontalDragUpdate: (d) => setState(() => _cursorTimeMs = geo.timeAtX(d.localPosition.dx)),
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: TrendChartPainter(
                          pens: widget.pens,
                          bufferOf: widget.historian.buffer,
                          windowMs: widget.windowMs,
                          nowMs: now,
                          axisColor: Colors.grey.shade300,
                          gridColor: Colors.grey.shade600,
                          cursorTimeMs: inWindow ? cursor : null,
                        ),
                      ),
                    ),
                  ),
                  if (inWindow) _buildReadout(geo, cursor, now),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildReadout(TrendChartGeometry geo, int cursor, int now) {
    final cursorX = geo.xOfTime(cursor);
    final onRight = cursorX > geo.width / 2;
    final rows = <Widget>[];
    for (final p in widget.pens) {
      final s = nearestSample(widget.historian.buffer(p.tagPath), cursor);
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, color: p.color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '${p.label}: ${formatPenValue(p, s)}',
                style: const TextStyle(fontSize: 10, color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ));
    }
    return Positioned(
      top: 6,
      left: onRight ? 6 : null,
      right: onRight ? null : 6,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 170),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade700),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    '${relativeAgo(cursor, now)}  ${clockHms(cursor)}',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => setState(() => _cursorTimeMs = null),
                  child: Icon(Icons.close, size: 14, color: Colors.grey.shade400),
                ),
              ],
            ),
            ...rows,
          ],
        ),
      ),
    );
  }
}
