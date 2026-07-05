import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Width breakpoints (logical px). Adaptation keys on WIDTH, never platform.
abstract class Breakpoints {
  static const double compact = 640; // < 640: phone / narrow window
  static const double expanded = 840; // >= 840: desktop / web-on-monitor
}

enum WidthClass { compact, medium, expanded }

extension ResponsiveContext on BuildContext {
  double get widthPx => MediaQuery.sizeOf(this).width;

  WidthClass get widthClass {
    final w = widthPx;
    if (w < Breakpoints.compact) {
      return WidthClass.compact;
    }
    if (w < Breakpoints.expanded) {
      return WidthClass.medium;
    }
    return WidthClass.expanded;
  }

  bool get isCompact => widthPx < Breakpoints.compact;
  bool get isExpanded => widthPx >= Breakpoints.expanded;
}

/// Minimum finger hit-target (Material spec).
const double kMinTouch = 44.0;

/// Guarantees a >= [kMinTouch] hit area around [child] without changing its
/// visual size — for small icon buttons on touch screens.
Widget touchable(Widget child, {VoidCallback? onTap}) {
  final box = ConstrainedBox(
    constraints: const BoxConstraints(minWidth: kMinTouch, minHeight: kMinTouch),
    child: Center(child: child),
  );
  if (onTap == null) {
    return box;
  }
  return InkWell(onTap: onTap, child: box);
}

/// Shows a dialog whose content width never exceeds the viewport (min of
/// [desiredWidth] and screen width minus inset). Replaces hardcoded dialog
/// widths so nothing overflows on a phone.
Future<T?> showAdaptiveWidthDialog<T>(
  BuildContext context, {
  required Widget child,
  double desiredWidth = 440,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) {
      final maxW = math.min(desiredWidth, MediaQuery.sizeOf(ctx).width - 32);
      return Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: child,
        ),
      );
    },
  );
}
