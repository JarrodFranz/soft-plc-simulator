import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/services/notify_throttle.dart';

void main() {
  test('coalesces rapid requests to one trailing fire per window', () {
    fakeAsync((async) {
      var fires = 0;
      final t = NotifyThrottle(() => fires++, window: const Duration(milliseconds: 250));
      for (var i = 0; i < 20; i++) {
        t.request();
      }
      expect(fires, 0); // trailing — nothing yet
      async.elapse(const Duration(milliseconds: 260));
      expect(fires, 1); // exactly one coalesced fire
      t.dispose();
    });
  });

  test('immediate() fires at once', () {
    fakeAsync((async) {
      var fires = 0;
      final t = NotifyThrottle(() => fires++, window: const Duration(milliseconds: 250));
      t.immediate();
      expect(fires, 1);
      t.dispose();
    });
  });

  test('dispose cancels a pending trailing fire', () {
    fakeAsync((async) {
      var fires = 0;
      final t = NotifyThrottle(() => fires++, window: const Duration(milliseconds: 250));
      t.request();
      t.dispose();
      async.elapse(const Duration(milliseconds: 300));
      expect(fires, 0);
    });
  });
}
