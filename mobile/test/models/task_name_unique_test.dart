import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

PlcTask _t(String name) => PlcTask(name: name, type: 'Continuous', programNames: []);

void main() {
  group('isTaskNameTaken', () {
    test('false when the name is unused', () {
      final tasks = [_t('Main'), _t('Poll')];
      expect(isTaskNameTaken(tasks, 'Startup'), isFalse);
    });

    test('true on an exact-name collision', () {
      final tasks = [_t('Main'), _t('Poll')];
      expect(isTaskNameTaken(tasks, 'Poll'), isTrue);
    });

    test('collision is case-insensitive and whitespace-trimmed', () {
      final tasks = [_t('MainTask')];
      expect(isTaskNameTaken(tasks, 'maintask'), isTrue);
      expect(isTaskNameTaken(tasks, '  MAINTASK  '), isTrue);
    });

    test('excluding lets a task keep its own name (edit case)', () {
      final self = _t('Main');
      final tasks = [self, _t('Poll')];
      // Re-saving 'Main' on the same task instance is allowed.
      expect(isTaskNameTaken(tasks, 'Main', excluding: self), isFalse);
      // But taking a sibling's name is still rejected.
      expect(isTaskNameTaken(tasks, 'Poll', excluding: self), isTrue);
    });

    test('empty task list never collides', () {
      expect(isTaskNameTaken(<PlcTask>[], 'Anything'), isFalse);
    });
  });
}
