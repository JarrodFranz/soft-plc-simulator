import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/task_scheduler.dart';

PlcTask _t(String name, String type,
        {int period = 100, List<String>? progs, String trigger = '', bool enabled = true, int wd = 0}) =>
    PlcTask(
      name: name,
      type: type,
      periodMs: period,
      programNames: progs ?? [name.toLowerCase()],
      enabled: enabled,
      triggerTag: trigger,
      watchdogMs: wd,
    );

List<String> _names(List<DueTask> d) => d.expand((t) => t.programs).toList();

void main() {
  bool noTags(String _) => false;

  test('startup fires once on the first tick, never again', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('Boot', 'Startup', progs: ['b']), _t('Main', 'Continuous', progs: ['m'])];
    // First tick: startup due -> continuous skipped.
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['b']);
    // Second tick: startup done -> continuous runs.
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['m']);
    // Third tick: still continuous.
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['m']);
  });

  test('periodic fires at period boundary and carries remainder', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('P', 'Periodic', period: 250, progs: ['p']), _t('C', 'Continuous', progs: ['c'])];
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']); // 100 < 250
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']); // 200 < 250
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['p']); // 300 >= 250 -> periodic, continuous skipped
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']); // carry 50, 150 < 250
  });

  test('periodic remainder is clamped: a large dt does not cause burst catch-up', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('P', 'Periodic', period: 100, progs: ['p']), _t('C', 'Continuous', progs: ['c'])];

    // A single tick 10x the period fires the task exactly once this tick (a
    // task can appear at most once per tick), and the accumulator is CLAMPED
    // to periodMs (100) rather than left at the true remainder (900).
    expect(_names(scheduleTick(tasks, 1000, rt, noTags)), ['p']);

    // Because the remainder was clamped to 100 (not 900), the next tick only
    // needs to cross the boundary once: 100 + 1 = 101 >= 100 -> fires once.
    expect(_names(scheduleTick(tasks, 1, rt, noTags)), ['p']);

    // And then it falls straight back to the normal cadence: 1 + 1 = 2 < 100,
    // so Continuous runs. WITHOUT the clamp the accumulator would still hold
    // ~800 ms here and the task would keep burst-firing every tick to "catch
    // up" — this assertion is what proves the clamp.
    expect(_names(scheduleTick(tasks, 1, rt, noTags)), ['c']);
  });

  test('event fires only on rising edge of its BOOL tag', () {
    final rt = TaskSchedulerRuntime();
    var trig = false;
    bool look(String p) => p == 'Btn' ? trig : false;
    final tasks = [_t('E', 'Event', trigger: 'Btn', progs: ['e']), _t('C', 'Continuous', progs: ['c'])];
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['c']); // false
    trig = true;
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['e']); // rising edge -> event, continuous skipped
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['c']); // sustained true -> no edge
    trig = false;
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['c']); // falling edge -> nothing
    trig = true;
    expect(_names(scheduleTick(tasks, 100, rt, look)), ['e']); // rising again
  });

  test('disabled task never fires', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('P', 'Periodic', period: 50, progs: ['p'], enabled: false), _t('C', 'Continuous', progs: ['c'])];
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']);
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['c']);
  });

  test('program in two due tasks is deduped, priority order', () {
    final rt = TaskSchedulerRuntime();
    // Safety in Startup + Continuous. First tick: startup claims 'safety'; continuous skipped anyway.
    final tasks = [
      _t('Boot', 'Startup', progs: ['safety']),
      _t('Main', 'Continuous', progs: ['safety', 'motor']),
    ];
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['safety']); // startup only
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['safety', 'motor']); // continuous
  });

  test('multiple periodic due same tick both run; continuous skipped', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [
      _t('P1', 'Periodic', period: 100, progs: ['a']),
      _t('P2', 'Periodic', period: 100, progs: ['b']),
      _t('C', 'Continuous', progs: ['c']),
    ];
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['a', 'b']);
  });

  test('DueTask carries watchdogMs from its task', () {
    final rt = TaskSchedulerRuntime();
    final due = scheduleTick([_t('C', 'Continuous', progs: ['c'], wd: 42)], 100, rt, noTags);
    expect(due.single.watchdogMs, 42);
    expect(due.single.taskName, 'C');
  });

  test('reset re-arms startup', () {
    final rt = TaskSchedulerRuntime();
    final tasks = [_t('Boot', 'Startup', progs: ['b']), _t('C', 'Continuous', progs: ['c'])];
    scheduleTick(tasks, 100, rt, noTags);
    scheduleTick(tasks, 100, rt, noTags);
    rt.reset();
    expect(_names(scheduleTick(tasks, 100, rt, noTags)), ['b']); // startup fires again
  });

  test('deterministic: same inputs -> same output', () {
    final a = TaskSchedulerRuntime();
    final b = TaskSchedulerRuntime();
    final tasks = [_t('P', 'Periodic', period: 300, progs: ['p']), _t('C', 'Continuous', progs: ['c'])];
    for (var i = 0; i < 10; i++) {
      expect(_names(scheduleTick(tasks, 100, a, noTags)), _names(scheduleTick(tasks, 100, b, noTags)));
    }
  });
}
