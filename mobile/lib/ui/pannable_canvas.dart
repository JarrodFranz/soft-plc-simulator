/// CANVAS PAN/SCROLL AFFORDANCES (QA §3.3).
///
/// The FBD lane canvas and the LD editor's compact ladder canvas are
/// [InteractiveViewer]s. They clip at the pane boundary, and the only way to
/// reach content outside that boundary was an undiscoverable click/touch-drag
/// on the background — there was no scrollbar, no minimap and no hint that
/// anything had been cut off.
///
/// A bare `InteractiveViewer` also turns a mouse wheel into a *zoom*
/// (`_receivedPointerSignal`), which on a diagram canvas reads as "the wheel
/// does nothing useful" and, when the canvas sits inside a scrolling page,
/// silently fights that page's own scroll (the viewer never claims the pointer
/// signal, so the enclosing `Scrollable` acts on it too).
///
/// [PannableCanvas] wraps the viewer and gives it desktop-idiomatic wheel
/// behaviour plus a visible "there is more canvas that way" hint:
///
///   * **wheel** pans the canvas vertically — see [wheelPansVertically], which
///     is off where the canvas is stacked inside a vertical scroller that
///     legitimately owns that axis (the FBD lane list);
///   * **Shift+wheel**, and a trackpad's own horizontal delta, pans
///     horizontally;
///   * **Ctrl/⌘+wheel** zooms about the pointer, so the mouse can still reach
///     every zoom level the pinch gesture can;
///   * a pan with nothing left to travel in that direction is deliberately
///     *not* consumed, so an enclosing `Scrollable` picks it up — ordinary
///     scroll chaining;
///   * every edge past which real content continues gets a subtle fade, so
///     clipping is visible instead of silent.
///
/// Pinch-to-zoom and drag-to-pan are untouched: they are still the viewer's,
/// with every viewer parameter left at its natural value.
///
/// Neutralising the viewer's own wheel-zoom takes one trick, because
/// `Listener.onPointerSignal` has no "consume" and every listener on the hit
/// path fires. Hit paths run deepest-first, so a listener wrapping the viewer's
/// CHILD runs before the viewer and one wrapping the VIEWER runs after it: the
/// inner one snapshots the transform, the outer one restores that snapshot and
/// then applies the pan (or zoom) this widget actually wants. Clearing
/// `scaleEnabled` instead would have taken pinch-zoom with it, and detuning
/// `scaleFactor` would have leaked into the viewer's pinch-inertia maths.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keys on the four clipped-content edge fades, for tests.
const Key kPannableEdgeLeftKey = Key('pannable_edge_left');
const Key kPannableEdgeRightKey = Key('pannable_edge_right');
const Key kPannableEdgeTopKey = Key('pannable_edge_top');
const Key kPannableEdgeBottomKey = Key('pannable_edge_bottom');

/// Width/height of an edge fade strip.
const double kPannableEdgeFadeExtent = 22;

/// Wheel-scale sensitivity for [PannableCanvas]'s own Ctrl+wheel zoom. Same
/// value Flutter uses for `InteractiveViewer.scaleFactor` by default, so a
/// Ctrl+wheel notch zooms by exactly as much as a bare viewer's wheel did.
const double _kZoomScrollFactor = 200;

/// An [InteractiveViewer] with mouse-wheel panning, scroll chaining and
/// clipped-content edge fades. See the library doc comment for the rationale.
class PannableCanvas extends StatefulWidget {
  const PannableCanvas({
    super.key,
    required this.child,
    required this.contentSize,
    this.occupiedBounds,
    this.minScale = 0.4,
    this.maxScale = 2.5,
    this.boundaryMargin = const EdgeInsets.all(double.infinity),
    this.wheelPansVertically = true,
    this.transformationController,
  });

  /// The canvas content, laid out unconstrained inside the viewer.
  final Widget child;

  /// Logical size of [child] in scene coordinates. Bounds how far a *wheel*
  /// pan may travel (drag-panning still obeys [boundaryMargin] alone).
  final Size contentSize;

  /// The part of the canvas that actually holds something, in scene
  /// coordinates. Only edges past which THIS rect continues get a fade, so an
  /// oversized-but-empty canvas margin does not raise a false "more content
  /// this way" hint. Defaults to the whole [contentSize].
  final Rect? occupiedBounds;

  final double minScale;
  final double maxScale;
  final EdgeInsets boundaryMargin;

  /// Whether a plain (unmodified) wheel pans this canvas vertically. Set false
  /// where the canvas is one of several stacked inside a vertical scroller
  /// that should keep the wheel — the FBD lane list. Shift+wheel and
  /// Ctrl+wheel are unaffected.
  final bool wheelPansVertically;

  /// Optional externally-owned controller. When null the canvas creates (and
  /// disposes) its own.
  final TransformationController? transformationController;

  @override
  State<PannableCanvas> createState() => _PannableCanvasState();
}

class _PannableCanvasState extends State<PannableCanvas> {
  TransformationController? _ownController;
  TransformationController get _controller =>
      widget.transformationController ?? (_ownController ??= TransformationController());

  /// Last laid-out viewport size, needed by the wheel handler (which runs
  /// outside build). Zero until the first layout.
  Size _viewport = Size.zero;

  /// Transform as it stood immediately BEFORE the wrapped viewer got its hands
  /// on the in-flight wheel notch, plus the notch it belongs to. See the
  /// library doc comment.
  PointerEvent? _preSignalEvent;
  Matrix4? _preSignalValue;

  @override
  void dispose() {
    _ownController?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- wheel

  /// Deepest listener: runs before the viewer's own signal handler.
  void _capturePreSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _preSignalEvent = event.original;
    _preSignalValue = _controller.value.clone();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    // Roll back the viewer's wheel-zoom. If the capture layer never saw this
    // notch (the pointer was inside the viewport but off the canvas content)
    // leave the viewer's zoom alone rather than guessing — zooming empty space
    // is harmless, and is what the bare viewer always did.
    final pre = identical(_preSignalEvent, event.original) ? _preSignalValue : null;
    _preSignalEvent = null;
    _preSignalValue = null;
    if (pre == null) return;
    if (_controller.value != pre) {
      _controller.value = pre;
    }

    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      if (_zoomAt(event.localPosition, event.scrollDelta.dy)) {
        _claim(event);
      }
      return;
    }

    // A trackpad reports a real horizontal delta; a wheel mouse only has dy,
    // so Shift re-aims it at the horizontal axis (the Figma/draw.io idiom).
    var dx = event.scrollDelta.dx;
    var dy = event.scrollDelta.dy;
    if (dx == 0 && keys.isShiftPressed) {
      dx = dy;
      dy = 0;
    }
    if (!widget.wheelPansVertically) {
      dy = 0;
    }
    if (dx == 0 && dy == 0) return;

    // Scrolling "down"/"right" reveals content further down/right, i.e. moves
    // the content up/left under the viewport.
    if (_panBy(Offset(-dx, -dy))) {
      _claim(event);
    }
  }

  /// Claim the pointer signal so an enclosing `Scrollable` does not act on the
  /// same wheel notch. Deliberately skipped when the pan had nowhere to go, so
  /// the ancestor scroller takes over at the edge (scroll chaining).
  void _claim(PointerSignalEvent event) {
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
  }

  /// Translates the view by [viewportDelta] logical pixels, refusing to travel
  /// further past a content edge than it already is. Returns whether anything
  /// moved.
  bool _panBy(Offset viewportDelta) {
    if (_viewport.isEmpty) return false;
    final m = _controller.value;
    final scale = m.getMaxScaleOnAxis();
    final t = m.getTranslation();

    final scaledW = widget.contentSize.width * scale;
    final scaledH = widget.contentSize.height * scale;
    // Translation of the scene origin in viewport pixels. Fully scrolled to the
    // start is 0; fully scrolled to the end is viewport - content (negative
    // when the content overflows, otherwise there is simply no room).
    final minTx = math.min(0.0, _viewport.width - scaledW);
    final minTy = math.min(0.0, _viewport.height - scaledH);

    final nx = _travelTowards(t.x, t.x + viewportDelta.dx, minTx, 0);
    final ny = _travelTowards(t.y, t.y + viewportDelta.dy, minTy, 0);
    if (nx == t.x && ny == t.y) return false;

    _controller.value = m.clone()..setTranslationRaw(nx, ny, t.z);
    return true;
  }

  /// Moves [current] toward [target] but never further outside `[lo, hi]` than
  /// it already is — a drag (which honours [PannableCanvas.boundaryMargin], not
  /// this range) may legitimately have parked the view outside it, and a wheel
  /// notch must not yank it back.
  static double _travelTowards(double current, double target, double lo, double hi) {
    if (target > current) return math.min(target, math.max(current, hi));
    if (target < current) return math.max(target, math.min(current, lo));
    return current;
  }

  bool _zoomAt(Offset focalPoint, double scrollDy) {
    if (scrollDy == 0) return false;
    final m = _controller.value;
    final scale = m.getMaxScaleOnAxis();
    final target =
        (scale * math.exp(-scrollDy / _kZoomScrollFactor)).clamp(widget.minScale, widget.maxScale);
    if (target == scale) return false;
    final k = target / scale;
    final about = Matrix4.identity()
      ..translateByDouble(focalPoint.dx, focalPoint.dy, 0, 1)
      ..scaleByDouble(k, k, k, 1)
      ..translateByDouble(-focalPoint.dx, -focalPoint.dy, 0, 1);
    _controller.value = about.multiplied(m);
    return true;
  }

  // ----------------------------------------------------------- edge fades

  List<Widget> _edgeFades() {
    if (_viewport.isEmpty) return const [];
    final bounds = widget.occupiedBounds ??
        Rect.fromLTWH(0, 0, widget.contentSize.width, widget.contentSize.height);
    if (bounds.isEmpty) return const [];

    final m = _controller.value;
    final scale = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    // Content bounds projected into viewport pixels.
    final left = t.x + bounds.left * scale;
    final top = t.y + bounds.top * scale;
    final right = t.x + bounds.right * scale;
    final bottom = t.y + bounds.bottom * scale;
    // A hair of slack so a pixel of rounding never flickers a fade on.
    const slack = 1.0;

    return [
      if (left < -slack) _fade(kPannableEdgeLeftKey, Alignment.centerLeft),
      if (right > _viewport.width + slack) _fade(kPannableEdgeRightKey, Alignment.centerRight),
      if (top < -slack) _fade(kPannableEdgeTopKey, Alignment.topCenter),
      if (bottom > _viewport.height + slack) _fade(kPannableEdgeBottomKey, Alignment.bottomCenter),
    ];
  }

  Widget _fade(Key key, Alignment edge) {
    final horizontal = edge == Alignment.centerLeft || edge == Alignment.centerRight;
    return Align(
      alignment: edge,
      child: IgnorePointer(
        child: Container(
          key: key,
          width: horizontal ? kPannableEdgeFadeExtent : null,
          height: horizontal ? null : kPannableEdgeFadeExtent,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: edge,
              end: -edge,
              colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
            ),
          ),
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        return Listener(
          onPointerSignal: _onPointerSignal,
          child: Stack(
            fit: StackFit.expand,
            children: [
              InteractiveViewer(
                transformationController: _controller,
                constrained: false,
                minScale: widget.minScale,
                maxScale: widget.maxScale,
                boundaryMargin: widget.boundaryMargin,
                child: Listener(
                  // Opaque so the snapshot layer covers the whole canvas rect,
                  // not just whatever happens to be painted under the cursor.
                  behavior: HitTestBehavior.opaque,
                  onPointerSignal: _capturePreSignal,
                  child: widget.child,
                ),
              ),
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => Stack(fit: StackFit.expand, children: _edgeFades()),
              ),
            ],
          ),
        );
      },
    );
  }
}
