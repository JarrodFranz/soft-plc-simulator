import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/noise_model.dart';

void main() {
  test('uniformNoise endpoints and midpoint', () {
    expect(uniformNoise(0.0, 5.0), -5.0);
    expect(uniformNoise(1.0, 5.0), 5.0);
    expect(uniformNoise(0.5, 5.0), 0.0);
  });

  test('gaussianNoise is deterministic and scales linearly with sigma', () {
    final a = gaussianNoise(0.3, 0.7, 2.0);
    final b = gaussianNoise(0.3, 0.7, 4.0);
    expect(b, closeTo(a * 2, 1e-9));
    // exact value for a fixed (u1,u2,sigma)
    final r = math.sqrt(-2 * math.log(0.3)) * math.cos(2 * math.pi * 0.7) * 2.0;
    expect(gaussianNoise(0.3, 0.7, 2.0), closeTo(r, 1e-9));
  });

  test('gaussianNoise guards u1==0 (finite, no -Inf)', () {
    expect(gaussianNoise(0.0, 0.5, 1.0).isFinite, isTrue);
  });

  test('gaussianNoise sample mean ~0, std ~sigma over a pseudo-sequence', () {
    const n = 4000;
    final samples = <double>[];
    for (var i = 0; i < n; i++) {
      final u1 = (i * 2 + 1) / (2 * n + 1);
      final u2 = (i * 3 + 1) % (2 * n + 1) / (2 * n + 1);
      samples.add(gaussianNoise(u1, u2, 3.0));
    }
    final mean = samples.reduce((a, b) => a + b) / n;
    final variance = samples.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) / n;
    expect(mean.abs(), lessThan(0.4));
    expect(math.sqrt(variance), closeTo(3.0, 0.6));
  });

  test('driftStep is a convex blend, strictly bounded, EMA identities', () {
    expect(driftStep(2.0, 6.0, 1.0), closeTo(6.0, 1e-9)); // alpha=1 -> target
    expect(driftStep(2.0, 6.0, 0.0), closeTo(2.0, 1e-9)); // alpha=0 -> prev
    // sequence with targets in [-A,A] stays in [-A,A]
    const a = 5.0;
    var prev = 0.0;
    for (var i = 0; i < 200; i++) {
      final target = uniformNoise((i * 7 % 100) / 100.0, a); // in [-a,a]
      prev = driftStep(prev, target, 0.1);
      expect(prev, inInclusiveRange(-a, a));
    }
  });

  test('driftAlpha: tau<=0 -> 1.0, monotonic decreasing in tau', () {
    expect(driftAlpha(100, 0), 1.0);
    expect(driftAlpha(100, -5), 1.0);
    final a1 = driftAlpha(100, 1.0);
    final a2 = driftAlpha(100, 10.0);
    expect(a1, greaterThan(a2)); // larger tau -> smaller alpha (slower)
    expect(a1, inInclusiveRange(0.0, 1.0));
  });

  group('pink', () {
    List<double> st() => List<double>.filled(kPinkStateLen, 0.0);

    // The pink tests below need a genuinely WHITE input. A naive sawtooth
    // like `((i * 2654435761) % 9973) / 9973` is equidistributed (correct
    // std) but spectrally a single high-frequency tone, not white — the
    // Kellet cascade is low-pass weighted and heavily attenuates that band,
    // which would badly understate the raw std. Instead drive a pure
    // xorshift32 stream mirroring exactly what sim_engine.dart feeds
    // pinkNoise with in production, so the measured std/spectral properties
    // reflect real usage.
    int xs32(int x) {
      x = (x ^ ((x << 13) & 0xffffffff)) & 0xffffffff;
      x = (x ^ (x >> 17)) & 0xffffffff;
      x = (x ^ ((x << 5) & 0xffffffff)) & 0xffffffff;
      return x & 0xffffffff;
    }

    /// Pure white-noise uniform stream generator (no Random — deterministic).
    /// Seeded with a fixed non-zero constant; each call advances the state.
    double Function() whiteStream({int seed = 1}) {
      var state = seed;
      return () {
        state = xs32(state);
        return state / 0xffffffff;
      };
    }

    test('pinkStep is deterministic and evolves the state', () {
      final a = st();
      final b = st();
      final ra = pinkStep(a, 0.5);
      final rb = pinkStep(b, 0.5);
      expect(ra, rb); // same state + input -> same output
      expect(a.any((x) => x != 0.0), isTrue, reason: 'filter state must evolve');
      expect(a, b); // state evolves identically
    });

    test('pinkStep stays finite and stable over 10k steps', () {
      final b = st();
      final white = whiteStream();
      var last = 0.0;
      for (var i = 0; i < 10000; i++) {
        last = pinkStep(b, 2 * white() - 1);
        expect(last.isFinite, isTrue);
      }
      for (final x in b) {
        expect(x.isFinite, isTrue);
      }
    });

    test('pinkNoise sample std ~= amplitude (locks kPinkNormalise)', () {
      const n = 20000;
      const amp = 3.0;
      final b = st();
      final white = whiteStream();
      final xs = <double>[];
      for (var i = 0; i < n; i++) {
        xs.add(pinkNoise(b, white(), amp));
      }
      final mean = xs.reduce((p, q) => p + q) / n;
      final variance = xs.map((x) => (x - mean) * (x - mean)).reduce((p, q) => p + q) / n;
      final std = math.sqrt(variance);
      expect(std, closeTo(amp, amp * 0.10), reason: 'amplitude must mean output std');
    });

    test('pinkNoise scales linearly with amplitude', () {
      final b1 = st();
      final b2 = st();
      final white = whiteStream();
      for (var i = 0; i < 50; i++) {
        final uu = white();
        final x1 = pinkNoise(b1, uu, 1.0);
        final x2 = pinkNoise(b2, uu, 4.0);
        expect(x2, closeTo(x1 * 4.0, 1e-9));
      }
    });

    test('pink is genuinely 1/f: block-averaging retains more variance than white', () {
      const n = 20000;
      const block = 50;
      final b = st();
      final white0 = whiteStream();
      final pink = <double>[];
      final white = <double>[];
      for (var i = 0; i < n; i++) {
        final uu = white0();
        pink.add(pinkNoise(b, uu, 1.0));
        white.add(uniformNoise(uu, 1.0));
      }
      double retainedRatio(List<double> xs) {
        double varOf(List<double> v) {
          final m = v.reduce((p, q) => p + q) / v.length;
          return v.map((x) => (x - m) * (x - m)).reduce((p, q) => p + q) / v.length;
        }

        final blocks = <double>[];
        for (var i = 0; i + block <= xs.length; i += block) {
          final slice = xs.sublist(i, i + block);
          blocks.add(slice.reduce((p, q) => p + q) / block);
        }
        return varOf(blocks) / varOf(xs);
      }

      // White block-means collapse (~1/block); pink retains far more LF energy.
      expect(retainedRatio(pink), greaterThan(retainedRatio(white) * 5),
          reason: 'pink must retain substantially more low-frequency energy than white');
    });
  });
}
