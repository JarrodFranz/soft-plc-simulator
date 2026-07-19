import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/app_log.dart';
import 'package:soft_plc_mobile/services/app_logger.dart';

void main() {
  group('AppLogger level gating', () {
    test('entry at or above source level is recorded; one below is not', () {
      final logger = AppLogger();
      // Default min level is info. debug should be dropped, info recorded.
      logger.log(kLogSourceModbus, LogLevel.debug, 'dropped');
      logger.log(kLogSourceModbus, LogLevel.info, 'kept');

      expect(logger.entries.length, 1);
      expect(logger.entries.single.message, 'kept');
    });

    test('isEnabled reflects the per-source minimum', () {
      final logger = AppLogger();
      expect(logger.isEnabled(kLogSourceModbus, LogLevel.debug), isFalse);
      expect(logger.isEnabled(kLogSourceModbus, LogLevel.info), isTrue);
      expect(logger.isEnabled(kLogSourceModbus, LogLevel.error), isTrue);
    });
  });

  group('THE PERFORMANCE CONTRACT: logLazy builder invocation', () {
    test('logLazy does NOT invoke the builder when the level is disabled', () {
      final logger = AppLogger();
      var called = false;
      // Default min level is info; debug is disabled.
      logger.logLazy(kLogSourceS7, LogLevel.debug, () {
        called = true;
        return 'raw=deadbeef';
      });

      expect(called, isFalse);
      expect(logger.entries, isEmpty);
    });

    test('logLazy DOES invoke the builder when the level is enabled', () {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceS7, LogLevel.debug);
      var called = false;
      logger.logLazy(kLogSourceS7, LogLevel.debug, () {
        called = true;
        return 'raw=deadbeef';
      });

      expect(called, isTrue);
      expect(logger.entries.single.message, 'raw=deadbeef');
    });

    test('logLazy detail builder is also skipped when disabled', () {
      final logger = AppLogger();
      var detailCalled = false;
      logger.logLazy(
        kLogSourceS7,
        LogLevel.trace,
        () => 'never',
        detail: () {
          detailCalled = true;
          return 'never detail';
        },
      );

      expect(detailCalled, isFalse);
      expect(logger.entries, isEmpty);
    });
  });

  group('per-source independence', () {
    test('raising S7 to debug does not make Modbus verbose', () {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceS7, LogLevel.debug);

      logger.log(kLogSourceS7, LogLevel.debug, 's7 debug');
      logger.log(kLogSourceModbus, LogLevel.debug, 'modbus debug');

      expect(logger.entries.length, 1);
      expect(logger.entries.single.source, kLogSourceS7);
    });
  });

  group('setSourceLevel / sourceLevel round-trip', () {
    test('unconfigured source reports the default (info)', () {
      final logger = AppLogger();
      expect(logger.sourceLevel(kLogSourceDnp3), LogLevel.info);
    });

    test('round-trips a configured level', () {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceDnp3, LogLevel.trace);
      expect(logger.sourceLevel(kLogSourceDnp3), LogLevel.trace);

      logger.setSourceLevel(kLogSourceDnp3, LogLevel.error);
      expect(logger.sourceLevel(kLogSourceDnp3), LogLevel.error);
    });
  });

  group('throwing message builder is contained', () {
    test('logLazy never rethrows and does not corrupt the buffer', () {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceMqtt, LogLevel.debug);

      expect(
        () => logger.logLazy(kLogSourceMqtt, LogLevel.debug, () {
          throw StateError('boom');
        }),
        returnsNormally,
      );

      // Subsequent entries still record — the buffer is not corrupted.
      logger.log(kLogSourceMqtt, LogLevel.info, 'still works');
      final messages = logger.entries.map((e) => e.message).toList();
      expect(messages.contains('still works'), isTrue);
    });

    test('a throwing detail builder is also contained', () {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceMqtt, LogLevel.debug);

      expect(
        () => logger.logLazy(
          kLogSourceMqtt,
          LogLevel.debug,
          () => 'fine message',
          detail: () => throw StateError('detail boom'),
        ),
        returnsNormally,
      );

      logger.log(kLogSourceMqtt, LogLevel.info, 'after detail throw');
      final messages = logger.entries.map((e) => e.message).toList();
      expect(messages.contains('after detail throw'), isTrue);
    });

    test(
      'a throwing detail builder still records the primary message '
      '(the built message must survive)',
      () {
        final logger = AppLogger();
        logger.setSourceLevel(kLogSourceMqtt, LogLevel.debug);

        expect(
          () => logger.logLazy(
            kLogSourceMqtt,
            LogLevel.debug,
            () => 'unsupported ROSCTR 0x07',
            detail: () => throw StateError('hex formatter boom'),
          ),
          returnsNormally,
        );

        final messages = logger.entries.map((e) => e.message).toList();
        expect(messages.contains('unsupported ROSCTR 0x07'), isTrue);
      },
    );
  });

  group('successful detail lands on LogEntry.detail', () {
    test('log(...) threads a supplied detail through', () {
      final logger = AppLogger();
      logger.log(
        kLogSourceModbus,
        LogLevel.info,
        'frame received',
        detail: 'aa bb cc dd',
      );
      expect(logger.entries.single.detail, 'aa bb cc dd');
    });

    test('logLazy(...) threads a successful detail builder result through', () {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceModbus, LogLevel.debug);
      logger.logLazy(
        kLogSourceModbus,
        LogLevel.debug,
        () => 'frame received',
        detail: () => 'aa bb cc dd',
      );
      expect(logger.entries.single.detail, 'aa bb cc dd');
    });
  });

  group('tMs hook', () {
    test('a supplied tMs lands on the entry verbatim', () {
      final logger = AppLogger();
      logger.log(kLogSourceScan, LogLevel.info, 'tick', tMs: 123456);
      expect(logger.entries.single.tMs, 123456);
    });

    test('logLazy also honours a supplied tMs', () {
      final logger = AppLogger();
      logger.setSourceLevel(kLogSourceScan, LogLevel.debug);
      logger.logLazy(kLogSourceScan, LogLevel.debug, () => 'tick', tMs: 999);
      expect(logger.entries.single.tMs, 999);
    });
  });

  group('clear()', () {
    test('empties the buffer', () {
      final logger = AppLogger();
      logger.log(kLogSourceProject, LogLevel.info, 'one');
      logger.log(kLogSourceProject, LogLevel.info, 'two');
      expect(logger.entries.length, 2);

      logger.clear();
      expect(logger.entries, isEmpty);
    });
  });

  group('capacity', () {
    test('is respected end to end through the service', () {
      final logger = AppLogger(capacity: 3);
      for (var i = 0; i < 5; i++) {
        logger.log(kLogSourceProject, LogLevel.info, 'msg$i');
      }
      expect(logger.entries.length, 3);
      final messages = logger.entries.map((e) => e.message).toList();
      expect(messages, ['msg2', 'msg3', 'msg4']);
    });
  });
}
