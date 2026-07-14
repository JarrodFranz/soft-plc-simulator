import 'package:flutter/widgets.dart';

/// A dataless "repaint now" pulse. Widgets that display live tag values listen
/// to it (via [LiveTickScope]) and re-read their value on each pulse, so the
/// scan loop can refresh only on-screen values without rebuilding the whole
/// widget tree. Pulsing is expected to be throttled by the owner (the shell
/// coalesces scan ticks through a NotifyThrottle to a configurable cap).
class LiveTick extends ChangeNotifier {
  void pulse() {
    notifyListeners();
  }
}

/// Exposes a [LiveTick] to the subtree. A descendant obtains it with
/// `LiveTickScope.of(context)` and wraps its value leaf in a
/// `ListenableBuilder(listenable: LiveTickScope.of(context), …)`.
class LiveTickScope extends InheritedNotifier<LiveTick> {
  const LiveTickScope({super.key, required LiveTick notifier, required super.child})
      : super(notifier: notifier);

  // Deliberately a non-dependency lookup (`getInheritedWidgetOfExactType`,
  // not `dependOnInheritedWidgetOfExactType`): callers pass the returned
  // [LiveTick] straight to a `ListenableBuilder`/`AnimatedBuilder`, which
  // already subscribes to it directly via `Listenable.addListener`. If `of`
  // instead registered an InheritedWidget dependency, the *calling* widget
  // (wherever `of(context)` is textually evaluated, which is often an
  // ancestor of the actual value leaf) would also rebuild on every pulse —
  // defeating the whole point of routing repaints through a leaf-only
  // listener instead of the shell's per-scan setState.
  static LiveTick of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<LiveTickScope>();
    assert(scope?.notifier != null, 'No LiveTickScope found in context');
    return scope!.notifier!;
  }
}
