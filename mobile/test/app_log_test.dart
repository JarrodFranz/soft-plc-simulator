import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/app_log.dart';

LogEntry _entry({
  int t = 0,
  LogLevel level = LogLevel.info,
  String source = kLogSourceModbus,
  String message = 'hello',
  String? detail,
}) {
  return LogEntry(tMs: t, level: level, source: source, message: message, detail: detail);
}

void main() {
  group('LogRingBuffer', () {
    test('holds entries oldest-first and evicts the oldest at capacity', () {
      final buf = LogRingBuffer(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        buf.add(_entry(t: i, message: 'm$i'));
      }
      expect(buf.entries.length, 3);
      expect(buf.entries.map((e) => e.message).toList(), ['m3', 'm4', 'm5']);
    });

    test('seq is monotonic and continues increasing after eviction', () {
      final buf = LogRingBuffer(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        buf.add(_entry(t: i, message: 'm$i'));
      }
      expect(buf.entries.map((e) => e.seq).toList(), [3, 4, 5]);
    });

    test('clear() empties it; adding after clear() still yields monotonic seq', () {
      final buf = LogRingBuffer(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        buf.add(_entry(t: i, message: 'm$i'));
      }
      buf.clear();
      expect(buf.entries, isEmpty);
      buf.add(_entry(t: 6, message: 'm6'));
      expect(buf.entries.single.seq, 6);
    });

    test('detail longer than kLogMaxDetailChars is truncated', () {
      final buf = LogRingBuffer(capacity: 3);
      final longDetail = 'x' * (kLogMaxDetailChars + 500);
      buf.add(_entry(t: 1, detail: longDetail));
      final stored = buf.entries.single.detail!;
      expect(stored.length, lessThanOrEqualTo(kLogMaxDetailChars));
      expect(stored.length, lessThan(longDetail.length));
      expect(stored.contains('truncated'), isTrue);

      // droppedChars must equal what was actually dropped: everything
      // before the marker is what was kept.
      final markerStart = stored.indexOf('… [truncated,');
      expect(markerStart, greaterThanOrEqualTo(0));
      final match = RegExp(r'truncated, (\d+) more chars\]$').firstMatch(stored)!;
      final reportedDropped = int.parse(match.group(1)!);
      expect(reportedDropped, longDetail.length - markerStart);
    });

    test('detail at exactly kLogMaxDetailChars is stored verbatim with no marker', () {
      final buf = LogRingBuffer(capacity: 3);
      final exactDetail = 'y' * kLogMaxDetailChars;
      buf.add(_entry(t: 1, detail: exactDetail));
      final stored = buf.entries.single.detail!;
      expect(stored, exactDetail);
      expect(stored.length, kLogMaxDetailChars);
      expect(stored.contains('truncated'), isFalse);
    });

    test('detail far larger than the cap (10x) is still truncated to fit, with an accurate marker', () {
      final buf = LogRingBuffer(capacity: 3);
      final hugeDetail = 'z' * (kLogMaxDetailChars * 10);
      buf.add(_entry(t: 1, detail: hugeDetail));
      final stored = buf.entries.single.detail!;
      expect(stored.length, lessThanOrEqualTo(kLogMaxDetailChars));
      expect(stored.contains('truncated'), isTrue);

      final markerStart = stored.indexOf('… [truncated,');
      expect(markerStart, greaterThanOrEqualTo(0));
      final keptLen = markerStart;
      final match = RegExp(r'truncated, (\d+) more chars\]$').firstMatch(stored)!;
      final reportedDropped = int.parse(match.group(1)!);
      expect(reportedDropped, hugeDetail.length - keptLen);
      // The digit count here (5 digits, ~40960) differs from the small
      // overflow case above (3 digits, ~500) — this is the case that would
      // break a fixed-width marker assumption.
      expect(match.group(1)!.length, greaterThan(3));
    });

    test('empty buffer returns empty entries without throwing', () {
      final buf = LogRingBuffer(capacity: 3);
      expect(buf.entries, isEmpty);
    });
  });

  group('filterLogEntries', () {
    test('by minLevel excludes lower levels and includes equal/higher', () {
      final entries = [
        _entry(t: 1, level: LogLevel.trace, message: 'a'),
        _entry(t: 2, level: LogLevel.debug, message: 'b'),
        _entry(t: 3, level: LogLevel.info, message: 'c'),
        _entry(t: 4, level: LogLevel.warn, message: 'd'),
        _entry(t: 5, level: LogLevel.error, message: 'e'),
      ];
      final result = filterLogEntries(entries, minLevel: LogLevel.warn);
      expect(result.map((e) => e.message).toList(), ['d', 'e']);
    });

    test('by sources with one source', () {
      final entries = [
        _entry(t: 1, source: kLogSourceModbus, message: 'a'),
        _entry(t: 2, source: kLogSourceOpcUa, message: 'b'),
        _entry(t: 3, source: kLogSourceMqtt, message: 'c'),
      ];
      final result = filterLogEntries(entries, sources: {kLogSourceOpcUa});
      expect(result.map((e) => e.message).toList(), ['b']);
    });

    test('by sources with two sources', () {
      final entries = [
        _entry(t: 1, source: kLogSourceModbus, message: 'a'),
        _entry(t: 2, source: kLogSourceOpcUa, message: 'b'),
        _entry(t: 3, source: kLogSourceMqtt, message: 'c'),
      ];
      final result = filterLogEntries(entries, sources: {kLogSourceOpcUa, kLogSourceMqtt});
      expect(result.map((e) => e.message).toList(), ['b', 'c']);
    });

    test('sources null means all', () {
      final entries = [
        _entry(t: 1, source: kLogSourceModbus, message: 'a'),
        _entry(t: 2, source: kLogSourceOpcUa, message: 'b'),
      ];
      final result = filterLogEntries(entries, sources: null);
      expect(result.length, 2);
    });

    test('sources empty set means all (not none)', () {
      final entries = [
        _entry(t: 1, source: kLogSourceModbus, message: 'a'),
        _entry(t: 2, source: kLogSourceOpcUa, message: 'b'),
      ];
      final result = filterLogEntries(entries, sources: <String>{});
      expect(result.length, 2);
    });

    test('textFilter is case-insensitive and matches message', () {
      final entries = [
        _entry(t: 1, message: 'Connection Refused'),
        _entry(t: 2, message: 'all good'),
      ];
      final result = filterLogEntries(entries, textFilter: 'refused');
      expect(result.map((e) => e.message).toList(), ['Connection Refused']);
    });

    test('textFilter matches only detail (not message) and is still returned', () {
      final entries = [
        _entry(t: 1, message: 'top level', detail: 'raw bytes: DEADBEEF'),
        _entry(t: 2, message: 'unrelated', detail: 'nothing here'),
      ];
      final result = filterLogEntries(entries, textFilter: 'deadbeef');
      expect(result.map((e) => e.message).toList(), ['top level']);
    });

    test('combined filter (level AND source AND text) returns only entries satisfying all three', () {
      final entries = [
        _entry(t: 1, level: LogLevel.error, source: kLogSourceModbus, message: 'timeout'),
        _entry(t: 2, level: LogLevel.info, source: kLogSourceModbus, message: 'timeout'),
        _entry(t: 3, level: LogLevel.error, source: kLogSourceOpcUa, message: 'timeout'),
        _entry(t: 4, level: LogLevel.error, source: kLogSourceModbus, message: 'connected'),
      ];
      final result = filterLogEntries(
        entries,
        minLevel: LogLevel.warn,
        sources: {kLogSourceModbus},
        textFilter: 'timeout',
      );
      expect(result.length, 1);
      expect(result.single.tMs, 1);
    });

    test('empty buffer returns empty list without throwing', () {
      final result = filterLogEntries(<LogEntry>[]);
      expect(result, isEmpty);
    });

    test('no-match filter returns empty list without throwing', () {
      final entries = [_entry(t: 1, message: 'hello')];
      final result = filterLogEntries(entries, textFilter: 'zzz-no-match');
      expect(result, isEmpty);
    });
  });
}
