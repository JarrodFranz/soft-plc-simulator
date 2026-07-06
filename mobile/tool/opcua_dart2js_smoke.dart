// Runtime proof that the OPC UA Binary codec is dart2js-safe.
//
// `flutter test --platform chrome` needs a working Chrome + chromedriver
// pairing, which is not always available in every dev/CI environment. When
// that path is unavailable, this is the fallback the WS19 Task 4 review used
// to empirically confirm the original bug: compile this file with
// `dart compile js` and run the resulting JS with `node`, on a *runtime*
// (not compile-time) execution of the codec.
//
// Usage (from `mobile/`):
//   dart compile js -o /path/to/smoke.js tool/opcua_dart2js_smoke.dart
//   node /path/to/smoke.js
//
// Expected output: a sequence of "OK: ..." lines ending with
// "ALL OPCUA DART2JS SMOKE CHECKS PASSED" and a clean (zero) exit code. Any
// `Unsupported operation` throw (the original bug) or a thrown
// `TestFailure`-style assertion means the codec is NOT dart2js-safe.
import 'package:soft_plc_mobile/protocols/opcua/opcua_binary.dart';

void _check(String label, bool Function() body) {
  final bool ok;
  try {
    ok = body();
  } catch (e) {
    // ignore: avoid_print
    print('FAIL: $label threw: $e');
    rethrow;
  }
  if (!ok) {
    // ignore: avoid_print
    print('FAIL: $label returned false');
    throw StateError('smoke check failed: $label');
  }
  // ignore: avoid_print
  print('OK: $label');
}

void main() {
  // int64/uint64 round-trip for small-magnitude values (exact under both
  // dart2js's double-backed int and the native VM's 64-bit int).
  _check('int64 zero round-trip', () {
    final w = OpcUaWriter()..int64(0);
    final r = OpcUaReader(w.take());
    return r.int64() == 0;
  });

  // Non-negative values that fit within 2^32 round-trip exactly even on
  // dart2js: the `hi` half of the lo/hi decomposition is 0 for these, so the
  // 32-bit truncation dart2js applies to `<<`/`>>` (JavaScript bitwise
  // semantics) does not lose any information.
  _check('int64 small non-negative round-trip (exact on dart2js)', () {
    final w = OpcUaWriter()..int64(123456789);
    final r = OpcUaReader(w.take());
    return r.int64() == 123456789;
  });

  // Values whose decomposition needs the `hi` word — ANY negative value
  // (two's-complement sign-extension sets hi=0xFFFFFFFF even for
  // small-magnitude negatives like -42), or any magnitude >= 2^32 — are NOT
  // expected to round-trip to the exact same value on dart2js (bitwise ops
  // there are 32-bit; see the doc comment on OpcUaWriter/OpcUaReader
  // int64/uint64 in opcua_binary.dart). This codec path never executes on
  // web in the shipping app (no ServerSocket in the browser sandbox), so
  // that imprecision is an accepted, documented limitation. The property
  // this smoke test exists to prove is that these calls complete WITHOUT
  // throwing `Unsupported operation` the way `ByteData.setInt64`/
  // `getInt64` did — not that the value is bit-exact on web.
  _check('int64 negative round-trip does not throw '
      '(value itself is not asserted on dart2js)', () {
    final w = OpcUaWriter()..int64(-42);
    final r = OpcUaReader(w.take());
    r.int64(); // must not throw; value may differ from -42 on dart2js.
    return true;
  });

  _check('int64 large-magnitude round-trip does not throw '
      '(value itself is not asserted on dart2js)', () {
    final w = OpcUaWriter()..int64(1234567890123);
    final r = OpcUaReader(w.take());
    r.int64(); // must not throw; value may be truncated on dart2js.
    return true;
  });

  _check('uint64 large-magnitude round-trip does not throw '
      '(value itself is not asserted on dart2js)', () {
    final w = OpcUaWriter()..uint64(9007199254740991); // 2^53 - 1
    final r = OpcUaReader(w.take());
    r.uint64(); // must not throw; value may be truncated on dart2js.
    return true;
  });

  // The HelloMessage/negotiation-style UInt32 + String fields.
  _check('uint32 + string frame round-trip', () {
    final w = OpcUaWriter()
      ..uint32(0)
      ..uint32(65536)
      ..string('opc.tcp://localhost:4840/');
    final r = OpcUaReader(w.take());
    return r.uint32() == 0 &&
        r.uint32() == 65536 &&
        r.string() == 'opc.tcp://localhost:4840/';
  });

  // DateTime round-trip does not throw. NOTE: OPC UA DateTime ticks (100ns
  // since 1601-01-01) for any modern date are ~1.3e17 — always beyond 32
  // bits — so, like the large-magnitude int64/uint64 checks above, the
  // *value* is not asserted equal on dart2js (only that dateTime()/int64()
  // complete without throwing `Unsupported operation`). The exact-byte
  // DateTime fixture lives in the native-VM suite
  // (mobile/test/opcua_binary_test.dart) and is unaffected by this file.
  _check('DateTime round-trip does not throw '
      '(value itself is not asserted on dart2js)', () {
    final now = DateTime.utc(2024, 6, 15, 12, 30);
    final w = OpcUaWriter()..dateTime(now);
    final r = OpcUaReader(w.take());
    r.dateTime(); // must not throw.
    return true;
  });

  // RequestHeader/ResponseHeader: the actual per-message envelope, exercises
  // NodeId + DateTime + UInt32 + String + StatusCode together, end to end,
  // without throwing. requestHandle (a plain UInt32, not int64) IS asserted
  // exactly since it never goes through the 64-bit decomposition.
  _check('RequestHeader round-trip does not throw; requestHandle exact', () {
    final header = RequestHeader(
      authToken: const OpcNodeId.numeric(0, 0),
      timestamp: DateTime.utc(2024, 1, 1),
      requestHandle: 7,
    );
    final w = OpcUaWriter()..requestHeader(header);
    final r = OpcUaReader(w.take());
    final decoded = r.requestHeader();
    return decoded.requestHandle == 7;
  });

  // ignore: avoid_print
  print('ALL OPCUA DART2JS SMOKE CHECKS PASSED');
}
