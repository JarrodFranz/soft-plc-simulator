// Tests for the pure DNP3 event engine
// (mobile/lib/protocols/dnp3/dnp3_events.dart's `DnpEventEngine`): per-class
// (1/2/3) bounded ring buffers + force-aware change detection over a
// project's `DnpMap`. Mirrors the project-building pattern used by
// dnp3_outstation_test.dart (a `PlcProject` constructed directly with
// `PlcTag`/`ProtocolSettings`/`DnpProtocolConfig`/`DnpMap` entries), adapted
// here into a small tuple-keyed builder since these tests each need a
// different single-tag project.
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_events.dart';

/// Builds a minimal single-purpose `PlcProject` from a map of
/// `tagName -> (dataType, ioType, initialValue)`. The DNP3 map itself is
/// supplied separately by each test (so the point-type/index/eventClass
/// wiring is visible right next to the assertions it drives).
PlcProject _buildProject(Map<String, (String, String, dynamic)> tagSpecs) {
  final tags = <PlcTag>[
    for (final entry in tagSpecs.entries)
      PlcTag(
        name: entry.key,
        path: entry.key,
        dataType: entry.value.$1,
        ioType: entry.value.$2,
        value: entry.value.$3,
      ),
  ];
  return PlcProject(
    id: 'x',
    name: 'X',
    controllerName: 'C',
    structDefs: const [],
    programs: const [],
    tasks: const [],
    hmis: const [],
    tags: tags,
    protocols: ProtocolSettings(
      dnp3: DnpProtocolConfig(enabled: true, map: DnpMap(entries: [])),
    ),
  );
}

/// Mutates a live tag's value in place (the "process/HMI writes a new
/// value" path) via the same `writePath` the rest of the app uses.
void _setTag(PlcProject project, String name, dynamic value) {
  writePath(project, name, value);
}

/// Forces a tag: sets `isForced` + `forcedValue` directly on the `PlcTag`,
/// exactly what the Force UI (tag_inspector_dock) does. `readPath` then
/// resolves the forced value instead of the live one.
void _forceTag(PlcProject project, String name, dynamic value) {
  final tag = project.tags.firstWhere((t) => t.name == name);
  tag.isForced = true;
  tag.forcedValue = value;
}

void main() {
  // A Class-1 binary input change appends exactly one binary event.
  test('class 1 binary change -> one g2-style event', () {
    final project = _buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 1),
    ]);
    final eng = DnpEventEngine(capacityPerClass: 200);
    eng.detectChanges(project, map, 1000); // baseline, no event
    expect(eng.hasAnyEvents, isFalse);
    _setTag(project, 'Run', true);
    eng.detectChanges(project, map, 2000);
    final events = eng.pull({1});
    expect(events.length, 1);
    expect(events.single.isBinary, isTrue);
    expect(events.single.boolValue, isTrue);
    expect(events.single.index, 0);
    expect(events.single.eventClass, 1);
    expect(events.single.timeMs, 2000);
  });

  // A Class-2 analog change appends a g32 event with the new value.
  test('class 2 analog change -> analog event with value + time', () {
    final project = _buildProject({'Level': ('FLOAT64', 'SimulatedInput', 1.0)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'Level', pointType: 'analogInput', index: 5, eventClass: 2),
    ]);
    final eng = DnpEventEngine();
    eng.detectChanges(project, map, 0);
    _setTag(project, 'Level', 42.5);
    eng.detectChanges(project, map, 12345);
    final events = eng.pull({2});
    expect(events.length, 1);
    expect(events.single.isBinary, isFalse);
    expect(events.single.isFloat, isTrue);
    expect(events.single.floatValue, 42.5);
    expect(events.single.index, 5);
    expect(events.single.timeMs, 12345);
  });

  // Class 0 (default) points never generate events.
  test('class 0 point generates no events', () {
    final project = _buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 0),
    ]);
    final eng = DnpEventEngine();
    eng.detectChanges(project, map, 0);
    _setTag(project, 'Run', true);
    eng.detectChanges(project, map, 1000);
    expect(eng.hasAnyEvents, isFalse);
  });

  // Buffer caps at capacity, dropping oldest and flagging overflow.
  test('ring buffer caps at capacity and flags overflow', () {
    final project = _buildProject({'N': ('INT32', 'SimulatedInput', 0)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'N', pointType: 'analogInput', index: 0, eventClass: 1),
    ]);
    final eng = DnpEventEngine(capacityPerClass: 3);
    eng.detectChanges(project, map, 0);
    for (var v = 1; v <= 5; v++) {
      _setTag(project, 'N', v);
      eng.detectChanges(project, map, v);
    }
    final events = eng.pull({1});
    expect(events.length, 3); // capped
    expect(events.first.intValue, 3); // oldest two (1,2) dropped
    expect(events.last.intValue, 5);
    expect(eng.overflowed, isTrue);
  });

  // pull() is a snapshot; flush(confirmed) removes only those, newer stay.
  test('flush removes confirmed events only', () {
    final project = _buildProject({'N': ('INT32', 'SimulatedInput', 0)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'N', pointType: 'analogInput', index: 0, eventClass: 1),
    ]);
    final eng = DnpEventEngine();
    eng.detectChanges(project, map, 0);
    _setTag(project, 'N', 1);
    eng.detectChanges(project, map, 1);
    final first = eng.pull({1});
    expect(first.length, 1);
    _setTag(project, 'N', 2); // new event arrives after the pull
    eng.detectChanges(project, map, 2);
    eng.flush(first); // confirm only the first
    final remaining = eng.pull({1});
    expect(remaining.length, 1);
    expect(remaining.single.intValue, 2);
  });

  // Force-aware: a forced input's forced value is what gets captured.
  test('forced input captures forced value', () {
    final project = _buildProject({'Run': ('BOOL', 'SimulatedInput', false)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0, eventClass: 1),
    ]);
    final eng = DnpEventEngine();
    eng.detectChanges(project, map, 0);
    _forceTag(project, 'Run', true); // force overrides the live value
    eng.detectChanges(project, map, 1000);
    expect(eng.pull({1}).single.boolValue, isTrue);
  });

  // A Class-1 binaryOutput change appends exactly one binary output event.
  test('class 1 binaryOutput change -> one binary output event', () {
    final project = _buildProject({'Motor': ('BOOL', 'Internal', false)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'Motor', pointType: 'binaryOutput', index: 0, eventClass: 1),
    ]);
    final eng = DnpEventEngine();
    eng.detectChanges(project, map, 0); // baseline, no event
    expect(eng.hasAnyEvents, isFalse);
    _setTag(project, 'Motor', true);
    eng.detectChanges(project, map, 1000);
    final events = eng.pull({1});
    expect(events.length, 1);
    expect(events.single.isBinary, isTrue);
    expect(events.single.pointType, 'binaryOutput');
    expect(events.single.boolValue, isTrue);
    expect(events.single.index, 0);
  });

  // A Class-2 analogOutput change appends an analog event with the new value.
  test('class 2 analogOutput change -> analog output event with value + time', () {
    final project = _buildProject({'Setpoint': ('INT32', 'Internal', 1000)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'Setpoint', pointType: 'analogOutput', index: 0, eventClass: 2),
    ]);
    final eng = DnpEventEngine();
    eng.detectChanges(project, map, 0);
    _setTag(project, 'Setpoint', 1234);
    eng.detectChanges(project, map, 5);
    final events = eng.pull({2});
    expect(events.length, 1);
    expect(events.single.isBinary, isFalse);
    expect(events.single.isFloat, isFalse);
    expect(events.single.intValue, 1234);
    expect(events.single.pointType, 'analogOutput');
  });

  // Class 0 output generates no events.
  test('class 0 output generates no events', () {
    final project = _buildProject({'Motor': ('BOOL', 'Internal', false)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'Motor', pointType: 'binaryOutput', index: 0, eventClass: 0),
    ]);
    final eng = DnpEventEngine();
    eng.detectChanges(project, map, 0);
    _setTag(project, 'Motor', true);
    eng.detectChanges(project, map, 1);
    expect(eng.hasAnyEvents, isFalse); // class 0 = no events
  });

  // Force-aware: a forced binaryOutput's forced value is what gets captured,
  // exactly like forced inputs (mirrors 'forced input captures forced value').
  test('forced output captures forced value', () {
    final project = _buildProject({'Motor': ('BOOL', 'Internal', false)});
    final map = DnpMap(entries: [
      DnpMapEntry(tag: 'Motor', pointType: 'binaryOutput', index: 0, eventClass: 1),
    ]);
    final eng = DnpEventEngine();
    eng.detectChanges(project, map, 0); // baseline, no event
    expect(eng.hasAnyEvents, isFalse);
    _forceTag(project, 'Motor', true); // force overrides the live value
    eng.detectChanges(project, map, 1000);
    final events = eng.pull({1});
    expect(events.length, 1);
    expect(events.single.isBinary, isTrue);
    expect(events.single.pointType, 'binaryOutput');
    expect(events.single.boolValue, isTrue);
  });
}
