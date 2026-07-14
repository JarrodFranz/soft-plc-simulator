import 'dart:async';

/// Coalesces high-frequency notifications to at most one trailing call per
/// [window]. State-change callers use [immediate]; per-tick callers use
/// [request]. Pure `dart:async` — no Flutter.
class NotifyThrottle {
  final void Function() _onFire;
  final Duration _window;
  Timer? _timer;

  NotifyThrottle(this._onFire, {Duration window = const Duration(milliseconds: 250)}) : _window = window;

  void request() {
    _timer ??= Timer(_window, () {
      _timer = null;
      _onFire();
    });
  }

  void immediate() {
    _timer?.cancel();
    _timer = null;
    _onFire();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
