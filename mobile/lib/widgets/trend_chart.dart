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

  TrendChartPainter({
    required this.pens,
    required this.bufferOf,
    required this.windowMs,
    required this.nowMs,
    required this.axisColor,
    required this.gridColor,
  });

  static const double _leftPad = 36;
  static const double _rightPad = 8;
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
    const plotLeft = _leftPad;
    final plotRight = size.width - _rightPad;
    const plotTop = _topPad;
    final plotBottom = size.height - digitalBandH - 4;
    final plotW = (plotRight - plotLeft).clamp(1.0, double.infinity);
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

    double xOf(int t) => plotLeft + plotW * (1 - (nowMs - t) / win);

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
  }

  @override
  bool shouldRepaint(covariant TrendChartPainter old) => true;
}

/// A live trend chart bound to a [TagHistorian]. Repaints on each LiveTick
/// pulse (never via a whole-shell setState). Reused by the Trends preview and
/// the HMI TrendChartDisplay component.
class TrendChartView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (pens.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text('No pens to plot', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: ListenableBuilder(
        listenable: LiveTickScope.of(context),
        builder: (context, _) {
          final now = DateTime.now().millisecondsSinceEpoch;
          return CustomPaint(
            size: Size.infinite,
            painter: TrendChartPainter(
              pens: pens,
              bufferOf: historian.buffer,
              windowMs: windowMs,
              nowMs: now,
              axisColor: Colors.grey.shade300,
              gridColor: Colors.grey.shade600,
            ),
          );
        },
      ),
    );
  }
}
