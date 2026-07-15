import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Breakpoints (logical px). Adaptation keys on viewport SIZE, never platform.
abstract class Breakpoints {
  static const double compact = 640; // < 640: phone / narrow window
  static const double expanded = 840; // >= 840 wide: desktop / web-on-monitor
  // The 3-pane desktop IDE also needs vertical room. A viewport that is wide
  // enough but too SHORT — a phone held in landscape (e.g. 900x410) — must NOT
  // get the 3-pane layout (all three panes squeeze into a few hundred px of
  // height and become unusable); it falls back to the adaptive/drawer layout.
  static const double expandedMinHeight = 600;
  // Below this height the vertical chrome (app bar + scan-speed bar) is
  // compacted to reclaim space — this is the short landscape-phone regime.
  static const double shortHeight = 500;
}

enum WidthClass { compact, medium, expanded }

/// Whether a viewport of [size] is large enough for the 3-pane desktop IDE:
/// wide enough AND tall enough. Pure (no BuildContext) so it is unit-testable.
bool isExpandedSize(Size size) =>
    size.width >= Breakpoints.expanded && size.height >= Breakpoints.expandedMinHeight;

/// Whether a viewport of [size] is short enough to warrant compacted vertical
/// chrome (a phone in landscape). Pure so it is unit-testable.
bool isShortSize(Size size) => size.height < Breakpoints.shortHeight;

extension ResponsiveContext on BuildContext {
  Size get _viewport => MediaQuery.sizeOf(this);
  double get widthPx => _viewport.width;

  WidthClass get widthClass {
    if (widthPx < Breakpoints.compact) {
      return WidthClass.compact;
    }
    if (!isExpandedSize(_viewport)) {
      return WidthClass.medium;
    }
    return WidthClass.expanded;
  }

  bool get isCompact => widthPx < Breakpoints.compact;
  bool get isExpanded => isExpandedSize(_viewport);
  bool get isShort => isShortSize(_viewport);
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
      // Every caller passes an AlertDialog, which is itself a dialog surface
      // that vertically centers itself via an expanding Align. Wrapping it in
      // a second Dialog painted that expansion as a full-height sheet behind
      // the real content — so only cap the width here and let the child be
      // the one and only dialog surface.
      return Align(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: child,
        ),
      );
    },
  );
}
