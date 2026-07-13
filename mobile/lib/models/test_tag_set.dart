// Pure Dart bulk test-tag-set builder + protocol-map appenders.
//
// A "test set" is a batch of simulated-output tags sharing one signal type
// (ramp/sine/square/triangle/random/counter/toggle), used to quickly stand up
// N phase-staggered signals (e.g. for load-testing a protocol client) without
// hand-adding tags one at a time. `buildTestSet` produces the `PlcTag`s +
// their driving `SignalGen`s; the four `appendTo*Map` functions then place
// those tags onto a protocol map at the next-free address/index/slot, after
// any existing entries, without ever duplicating or overlapping one.
//
// No Flutter dependency — this file must stay pure Dart, matching the other
// model files under lib/models/.

import 'project_model.dart';
import 'signal_gen.dart';
import 'signal_engine.dart';
import 'modbus_map.dart';
import 'dnp3_map.dart';
import 'opcua_map.dart';
import 'mqtt_map.dart';

/// Parameters for a bulk-generated set of `count` simulated-output test tags,
/// all sharing one signal `type`, one `[minValue, maxValue]` range, and one
/// `periodMs`, phase-staggered evenly across the period.
class TestSetSpec {
  String folder;
  String baseName;
  int count;
  String type; // ramp | sine | square | triangle | random | counter | toggle
  double minValue;
  double maxValue;
  int periodMs;

  TestSetSpec({
    required this.folder,
    required this.baseName,
    required this.count,
    required this.type,
    required this.minValue,
    required this.maxValue,
    required this.periodMs,
  });
}

/// dataType for a test-set signal `type`: `counter` -> INT32, `toggle` ->
/// BOOL, everything else (ramp/sine/square/triangle/random) -> FLOAT64.
String _dataTypeForType(String type) {
  if (type == 'counter') {
    return 'INT32';
  }
  if (type == 'toggle') {
    return 'BOOL';
  }
  return 'FLOAT64';
}

/// The tag's initial (t=0) value for a just-built `gen`: `counter` seeds at
/// its rounded `minValue`, `toggle` starts low, everything else takes the
/// analog waveform's value at t=0 via `signalValueAt` (this mirrors
/// `applySignalGens` in signal_engine.dart, which special-cases
/// counter/toggle/random and otherwise calls `signalValueAt`).
dynamic _initialValueFor(SignalGen gen) {
  if (gen.type == 'counter') {
    return gen.minValue.round();
  }
  if (gen.type == 'toggle') {
    return false;
  }
  return signalValueAt(gen, 0);
}

/// Builds `spec.count` simulated-output tags named `baseName` + a 1-based,
/// zero-padded index (padded to the width of `count`, e.g. count=3 ->
/// `R1..R3`, count=100 -> `S001..S100`), plus one `SignalGen` per tag whose
/// `phase` evenly staggers the signals across the period (`i / count`).
///
/// `PlcTag.path` follows the existing `folder/name` display convention seen
/// in data/default_projects.dart; the *addressable* identifier the sim
/// engine and gen resolve against is the tag `name` (see
/// `tag_resolver.dart._rootTag`, which matches by name), so `SignalGen
/// .targetPath` is set to the bare tag name, not the folder-qualified path.
({List<PlcTag> tags, List<SignalGen> gens}) buildTestSet(TestSetSpec spec) {
  final width = spec.count.toString().length;
  final dataType = _dataTypeForType(spec.type);
  final tags = <PlcTag>[];
  final gens = <SignalGen>[];
  for (int i = 0; i < spec.count; i++) {
    final name = '${spec.baseName}${(i + 1).toString().padLeft(width, '0')}';
    final gen = SignalGen(
      id: '${spec.folder}/$name',
      targetPath: name,
      type: spec.type,
      minValue: spec.minValue,
      maxValue: spec.maxValue,
      periodMs: spec.periodMs,
      phase: i / spec.count,
      enabled: true,
    );
    tags.add(PlcTag(
      name: name,
      path: '${spec.folder}/$name',
      dataType: dataType,
      value: _initialValueFor(gen),
      ioType: 'SimulatedOutput',
      folder: spec.folder,
    ));
    gens.add(gen);
  }
  return (tags: tags, gens: gens);
}

const _skipDataTypes = {'TIMER', 'COUNTER', 'STRING'};
const _scalarDataTypes = {'BOOL', 'INT16', 'INT32', 'FLOAT64'};

/// True if [tag] is representable on any of the four protocol maps: a scalar
/// leaf (not a struct/array value) whose dataType isn't TIMER/COUNTER/STRING.
/// Mirrors the shared skip rule in ModbusMap/DnpMap/MqttMap.autoGenerate.
bool _isMappable(PlcTag tag) {
  if (tag.value is Map || tag.value is List) {
    return false;
  }
  return !_skipDataTypes.contains(tag.dataType) && _scalarDataTypes.contains(tag.dataType);
}

/// Appends [tags] onto [map] as read-only Modbus entries at the next-free
/// address in the appropriate table (`discrete` for BOOL, `input` for
/// numeric — test-set tags are always `SimulatedOutput`, i.e. read-only).
/// Tags already present in the map (by tag name) are skipped, as are tags the
/// Modbus map can't represent (composite values, STRING/TIMER/COUNTER).
///
/// Address bookkeeping note: `ModbusMapEntry` doesn't store the bound tag's
/// dataType, so scanning *existing* entries can't know an existing
/// register-table (holding/input) entry's true size — a stored `address`
/// alone doesn't say whether it occupies 1, 2, or 4 registers. To guarantee
/// the newly-appended entries can never overlap an existing one regardless of
/// its real (unknown) size, every existing register-table entry is
/// conservatively assumed to occupy the worst-case width, i.e.
/// `ModbusMap.regsForType('FLOAT64')` (4 registers). Bit tables (coil/
/// discrete) have no such ambiguity — every entry there is exactly 1 bit —
/// so they always advance by 1. Newly-appended entries within this same call
/// use their tag's real (known) dataType size for their own subsequent
/// spacing.
void appendToModbusMap(ModbusMap map, List<PlcTag> tags) {
  final existingNames = map.entries.map((e) => e.tag).toSet();
  final worstCaseRegs = ModbusMap.regsForType('FLOAT64');
  final nextAddr = <String, int>{'coil': 0, 'discrete': 0, 'holding': 0, 'input': 0};
  for (final e in map.entries) {
    final isBitTable = e.table == 'coil' || e.table == 'discrete';
    final end = e.address + (isBitTable ? 1 : worstCaseRegs);
    if (end > (nextAddr[e.table] ?? 0)) {
      nextAddr[e.table] = end;
    }
  }
  for (final tag in tags) {
    if (existingNames.contains(tag.name) || !_isMappable(tag)) {
      continue;
    }
    final String table;
    final int advance;
    if (tag.dataType == 'BOOL') {
      table = 'discrete';
      advance = 1;
    } else {
      table = 'input';
      advance = ModbusMap.regsForType(tag.dataType);
    }
    final address = nextAddr[table]!;
    nextAddr[table] = address + advance;
    map.entries.add(ModbusMapEntry(tag: tag.name, table: table, address: address, access: 'ReadOnly'));
    existingNames.add(tag.name);
  }
}

/// Appends [tags] onto [map] as read-only DNP3 entries at the next-free index
/// in the appropriate point type (`binaryInput` for BOOL, `analogInput` for
/// numeric). Tags already present in the map (by tag name) are skipped, as
/// are tags the DNP3 map can't represent.
void appendToDnpMap(DnpMap map, List<PlcTag> tags) {
  final existingNames = map.entries.map((e) => e.tag).toSet();
  final nextIndex = <String, int>{
    'binaryInput': 0,
    'binaryOutput': 0,
    'analogInput': 0,
    'analogOutput': 0,
  };
  for (final e in map.entries) {
    final n = e.index + 1;
    if (n > (nextIndex[e.pointType] ?? 0)) {
      nextIndex[e.pointType] = n;
    }
  }
  for (final tag in tags) {
    if (existingNames.contains(tag.name) || !_isMappable(tag)) {
      continue;
    }
    final pointType = tag.dataType == 'BOOL' ? 'binaryInput' : 'analogInput';
    final index = nextIndex[pointType]!;
    nextIndex[pointType] = index + 1;
    map.entries.add(DnpMapEntry(tag: tag.name, pointType: pointType, index: index, eventClass: 0));
    existingNames.add(tag.name);
  }
}

/// Appends [tags] onto [map] as read-only OPC UA nodes. The OPC UA map has a
/// single flat address space (no per-table/point-type slotting), so there's
/// no "next free address" bookkeeping beyond not duplicating a tag. Tags
/// already present in the map (by tag name) are skipped, as are tags with a
/// composite (struct/array) value — matching `OpcuaMap.autoGenerate`, which
/// is the only skip rule OPC UA applies (unlike Modbus/DNP3/MQTT it doesn't
/// skip by dataType).
void appendToOpcuaMap(OpcuaMap map, List<PlcTag> tags) {
  final existingNames = map.nodes.map((n) => n.tag).toSet();
  for (final tag in tags) {
    if (existingNames.contains(tag.name) || tag.value is Map || tag.value is List) {
      continue;
    }
    map.nodes.add(OpcuaNode(nodeId: 'ns=1;s=${tag.path}', tag: tag.name, access: 'ReadOnly'));
    existingNames.add(tag.name);
  }
}

/// Appends [tags] onto [map] as read-only (non-writable) MQTT metric entries.
/// Tags already present in the map (by tag name) are skipped, as are tags the
/// MQTT map can't represent.
void appendToMqttMap(MqttMap map, List<PlcTag> tags) {
  final existingNames = map.entries.map((e) => e.tag).toSet();
  for (final tag in tags) {
    if (existingNames.contains(tag.name) || !_isMappable(tag)) {
      continue;
    }
    map.entries.add(MqttMapEntry(
      tag: tag.name,
      metric: tag.folder.isEmpty ? tag.name : '${tag.folder}/${tag.name}',
      writable: false,
    ));
    existingNames.add(tag.name);
  }
}
