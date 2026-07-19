// Tests for the DNP3 outstation handler
// (mobile/lib/protocols/dnp3/dnp3_outstation.dart's `DnpOutstation`) against
// a live project + `DnpMap`. Requests are built by hand from the Task 3
// codec's low-level encoders (encodeObjectHeader/encodeCrob/
// encodeAnalogOutputInt) exactly the way a real DNP3 master would frame an
// application fragment; responses are decoded the same way (there is no
// master-side decoder in this codebase for the static objects — an
// outstation only ever encodes them — so this file's helpers do that
// decoding manually via `decodeObjectHeader` + `ByteData`).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_app.dart';
import 'package:soft_plc_mobile/protocols/dnp3/dnp3_outstation.dart';

PlcProject _buildProject() {
  return PlcProject(
    id: 'x',
    name: 'X',
    controllerName: 'C',
    structDefs: const [],
    programs: const [],
    tasks: const [],
    hmis: const [],
    tags: [
      PlcTag(name: 'BiTag', path: 'BiTag', dataType: 'BOOL', value: true, ioType: 'Internal'),
      PlcTag(name: 'BiTag2', path: 'BiTag2', dataType: 'BOOL', value: true, ioType: 'Internal'),
      PlcTag(name: 'BoTag', path: 'BoTag', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'BoForced', path: 'BoForced', dataType: 'BOOL', value: false, ioType: 'Internal'),
      PlcTag(name: 'AiInt', path: 'AiInt', dataType: 'INT32', value: 1234, ioType: 'Internal'),
      PlcTag(name: 'AiFloat', path: 'AiFloat', dataType: 'FLOAT64', value: 3.5, ioType: 'Internal'),
      PlcTag(name: 'AoInt', path: 'AoInt', dataType: 'INT32', value: 0, ioType: 'Internal'),
      // Task 2 hardening fixtures ------------------------------------------
      // Reserved System tag; its OWN `access` is deliberately left at its
      // default (DNP3 map entries have NO `access` field at all — see
      // `dnp3_map.dart`/`DnpMapEntry` — so this backstop is the ONLY thing
      // that can stop a hand-retargeted `pointType` from writing it).
      PlcTag(name: 'System', path: 'System', dataType: 'BOOL', value: false, ioType: 'Internal'),
      // A SimulatedOutput tag mapped as a control point — the carve-out
      // (decision 1) that must survive: DNP3 has no map-level access field,
      // so ioType=='SimulatedOutput' must still be writable via a control.
      PlcTag(name: 'SimOutBo', path: 'SimOutBo', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput'),
      PlcTag(name: 'SimOutAo', path: 'SimOutAo', dataType: 'INT32', value: 0, ioType: 'SimulatedOutput'),
    ],
    protocols: ProtocolSettings(
      dnp3: DnpProtocolConfig(
        enabled: true,
        map: DnpMap(entries: [
          DnpMapEntry(tag: 'BiTag', pointType: 'binaryInput', index: 0),
          DnpMapEntry(tag: 'BiTag2', pointType: 'binaryInput', index: 2), // leaves index 1 as a gap
          DnpMapEntry(tag: 'BoTag', pointType: 'binaryOutput', index: 0),
          DnpMapEntry(tag: 'BoForced', pointType: 'binaryOutput', index: 1),
          DnpMapEntry(tag: 'AiInt', pointType: 'analogInput', index: 0),
          DnpMapEntry(tag: 'AiFloat', pointType: 'analogInput', index: 1),
          DnpMapEntry(tag: 'AoInt', pointType: 'analogOutput', index: 0),
          // Task 2 hardening fixtures: control points hand-retargeted at the
          // reserved System tag (both a binaryOutput AND an analogOutput
          // point, since _evaluateCrob and _evaluateAnalogOut are separate
          // gates that must BOTH be hardened), and at SimulatedOutput tags.
          DnpMapEntry(tag: 'System', pointType: 'binaryOutput', index: 2),
          DnpMapEntry(tag: 'System', pointType: 'analogOutput', index: 1),
          DnpMapEntry(tag: 'SimOutBo', pointType: 'binaryOutput', index: 3),
          DnpMapEntry(tag: 'SimOutAo', pointType: 'analogOutput', index: 2),
        ]),
      ),
    ),
  );
}

// --- Request builders (mirror what a real DNP3 master sends) ---------------

Uint8List _readClass0Req(int seq) {
  final out = BytesBuilder();
  out.addByte(0xC0 | (seq & 0x0F)); // FIR|FIN
  out.addByte(DnpFunc.read);
  out.add(encodeObjectHeader(group: 60, variation: 1, qualifier: DnpQualifier.allPoints));
  return out.toBytes();
}

Uint8List _crobRequest(int func, int seq, int index, int controlCode) {
  final out = BytesBuilder();
  out.addByte(0xC0 | (seq & 0x0F));
  out.addByte(func);
  out.add(encodeObjectHeader(group: 12, variation: 1, qualifier: DnpQualifier.range8, start: index, stop: index));
  out.add(encodeCrob(controlCode: controlCode, count: 1, onTimeMs: 0, offTimeMs: 0, status: 0));
  return out.toBytes();
}

Uint8List _g41IntDirectOperateReq(int seq, int index, int value) {
  final out = BytesBuilder();
  out.addByte(0xC0 | (seq & 0x0F));
  out.addByte(DnpFunc.directOperate);
  out.add(encodeObjectHeader(group: 41, variation: 1, qualifier: DnpQualifier.range8, start: index, stop: index));
  out.add(encodeAnalogOutputInt(value: value, status: 0));
  return out.toBytes();
}

Uint8List _clearRestartReq(int seq) {
  final out = BytesBuilder();
  out.addByte(0xC0 | (seq & 0x0F));
  out.addByte(2); // WRITE
  out.add(encodeObjectHeader(group: 80, variation: 1, qualifier: DnpQualifier.range8, start: 7, stop: 7));
  out.addByte(0x00); // single point, bit 0 = 0 -> clears IIN1 bit 7 (index 7)
  return out.toBytes();
}

/// Builds one raw application fragment: APP_CONTROL, FUNCTION_CODE, then
/// whatever raw object-header bytes the caller supplies (matching the
/// brief's `frag` helper — callers pass e.g. `[60, 2, 0x06]` for a bare
/// g60v2 all-points object header).
Uint8List frag(int appControl, int func, [List<int> objs = const []]) =>
    Uint8List.fromList([appControl, func, ...objs]);

// --- Response decoders (test-side only; an outstation never decodes its own
// static-object responses in real life, so there's nothing to reuse here) --

class _DecodedObj {
  final int group;
  final int variation;
  final int start;
  final int stop;
  final Uint8List data;
  _DecodedObj(this.group, this.variation, this.start, this.stop, this.data);
}

const _knownSizes = {
  (1, 2): 1,
  (10, 2): 1,
  (30, 1): 5,
  (30, 5): 5,
  (40, 1): 5,
  (40, 3): 5,
};

List<_DecodedObj> _decodeResponseObjects(Uint8List objData) {
  final list = <_DecodedObj>[];
  var offset = 0;
  while (offset < objData.length) {
    final decoded = decodeObjectHeader(objData, offset);
    if (decoded == null) break;
    final h = decoded.header;
    var pos = decoded.nextOffset;
    final size = _knownSizes[(h.group, h.variation)];
    if (size == null) break;
    final count = h.stop! - h.start! + 1;
    final dataLen = count * size;
    final data = Uint8List.fromList(objData.sublist(pos, pos + dataLen));
    list.add(_DecodedObj(h.group, h.variation, h.start!, h.stop!, data));
    pos += dataLen;
    offset = pos;
  }
  return list;
}

Uint8List? _findPoint(List<_DecodedObj> objs, int group, int variation, int index) {
  for (final o in objs) {
    if (o.group == group && o.variation == variation && index >= o.start && index <= o.stop) {
      final size = o.data.length ~/ (o.stop - o.start + 1);
      final off = (index - o.start) * size;
      return o.data.sublist(off, off + size);
    }
  }
  return null;
}

bool _decodeState(Uint8List b) => (b[0] & 0x80) != 0;
int _decodeI32(Uint8List b) => ByteData.sublistView(b, 1, 5).getInt32(0, Endian.little);
double _decodeF32(Uint8List b) => ByteData.sublistView(b, 1, 5).getFloat32(0, Endian.little);

int _crobStatus(Uint8List resp) {
  final objData = resp.sublist(4);
  final decoded = decodeObjectHeader(objData, 0)!;
  final crob = decodeCrob(objData, decoded.nextOffset)!;
  return crob.status;
}

int _g41Status(Uint8List resp) {
  final objData = resp.sublist(4);
  final decoded = decodeObjectHeader(objData, 0)!;
  final dec = decodeAnalogOutputInt(objData, decoded.nextOffset)!;
  return dec.status;
}

/// Decodes the (group, variation) of each object header in an
/// index-prefixed (qualifier 0x28) event-object payload — i.e. what
/// `_encodeEventObjects` produces — by walking `decodeObjectHeader` and
/// skipping each header's `count` points (2-byte LE index prefix + a
/// fixed-size payload per point, per DNP3 group/variation).
const _eventPointSizes = {
  (2, 2): 7, // g2v2 binary input event: 1 flags + 48-bit time
  (11, 2): 7, // g11v2 binary output event: same payload shape as g2v2
  (32, 3): 11, // g32v3 analog input event (int32): 1 flags + 4 value + 6 time
  (42, 3): 11, // g42v3 analog output event (int32): same shape as g32v3
  (32, 7): 11, // g32v7 analog input event (float32): 1 flags + 4 value + 6 time
  (42, 7): 11, // g42v7 analog output event (float32): same shape as g32v7
};

List<(int, int)> _decodeEventObjectGroups(Uint8List objData) {
  final groups = <(int, int)>[];
  var offset = 0;
  while (offset < objData.length) {
    final decoded = decodeObjectHeader(objData, offset);
    if (decoded == null) break;
    final h = decoded.header;
    final size = _eventPointSizes[(h.group, h.variation)];
    if (size == null || h.count == null) break;
    groups.add((h.group, h.variation));
    offset = decoded.nextOffset + h.count! * (2 + size);
  }
  return groups;
}

/// One event point extracted by [_decodeAllEventPoints]: which (group,
/// variation) bucket it landed in, its own index (from the index-prefixed
/// header), and its raw per-point payload (flags + value + time — see
/// [_eventPointSizes]).
class _DecodedEventPoint {
  final int group;
  final int variation;
  final int index;
  final Uint8List payload;
  _DecodedEventPoint(this.group, this.variation, this.index, this.payload);
}

/// Walks a full response object-payload stream that may interleave static
/// range-qualified objects (Class 0) with index-prefixed event objects — the
/// shape a paged Task 4 read produces when it carries both — and extracts
/// every EVENT point's own (group, variation, index, payload). Unlike
/// [_decodeResponseObjects] (which stops the instant it meets an object shape
/// it doesn't recognize), this walker knows how to skip PAST a static object
/// it doesn't care about (via [_knownSizes]) so it can keep going to find the
/// event objects that follow. Never throws on a well-formed stream; stops (as
/// [_decodeResponseObjects] does) the moment it meets a header shape neither
/// map recognizes.
List<_DecodedEventPoint> _decodeAllEventPoints(Uint8List objData) {
  final list = <_DecodedEventPoint>[];
  var offset = 0;
  while (offset < objData.length) {
    final decoded = decodeObjectHeader(objData, offset);
    if (decoded == null) {
      break;
    }
    final h = decoded.header;
    var pos = decoded.nextOffset;
    final eventSize = _eventPointSizes[(h.group, h.variation)];
    if (eventSize != null && h.count != null) {
      for (var i = 0; i < h.count!; i++) {
        final idx = objData[pos] | (objData[pos + 1] << 8);
        pos += 2;
        final payload = Uint8List.fromList(objData.sublist(pos, pos + eventSize));
        pos += eventSize;
        list.add(_DecodedEventPoint(h.group, h.variation, idx, payload));
      }
      offset = pos;
      continue;
    }
    final staticSize = _knownSizes[(h.group, h.variation)];
    if (staticSize == null || h.start == null || h.stop == null) {
      break;
    }
    final count = h.stop! - h.start! + 1;
    offset = pos + count * staticSize;
  }
  return list;
}

void main() {
  late PlcProject project;
  late DnpOutstation outstation;

  setUp(() {
    project = _buildProject();
    outstation = DnpOutstation(projectProvider: () => project);
  });

  test('Class 0 integrity read reflects live BI/BO/AI(int)/AI(float)/AO values', () {
    writePath(project, 'AiInt', 1234);
    writePath(project, 'AiFloat', 3.5);
    writePath(project, 'AoInt', 77);
    final resp = outstation.handleAppRequest(_readClass0Req(1), nowMs: 0);
    final objs = _decodeResponseObjects(resp.sublist(4));

    expect(_decodeState(_findPoint(objs, 1, 2, 0)!), true); // BiTag
    expect(_decodeState(_findPoint(objs, 10, 2, 0)!), false); // BoTag
    expect(_decodeI32(_findPoint(objs, 30, 1, 0)!), 1234); // AiInt
    expect(_decodeF32(_findPoint(objs, 30, 5, 1)!), closeTo(3.5, 0.0001)); // AiFloat
    expect(_decodeI32(_findPoint(objs, 40, 1, 0)!), 77); // AoInt
  });

  test('Class 0 read zero/offline-fills an unmapped gap between two binaryInput indices', () {
    final resp = outstation.handleAppRequest(_readClass0Req(1), nowMs: 0);
    final objs = _decodeResponseObjects(resp.sublist(4));
    final o = objs.firstWhere((x) => x.group == 1 && x.variation == 2);
    expect(o.start, 0);
    expect(o.stop, 2);
    final gapByte = _findPoint(objs, 1, 2, 1)!;
    expect(gapByte[0], 0); // no online flag, no state bit for the unmapped index 1
    expect(_decodeState(_findPoint(objs, 1, 2, 2)!), true); // BiTag2
  });

  test('DIRECT_OPERATE CROB LATCH_ON then LATCH_OFF flips the mapped BOOL', () {
    final onResp = outstation.handleAppRequest(
        _crobRequest(DnpFunc.directOperate, 1, 0, DnpControlCode.latchOn), nowMs: 0);
    expect(readPath(project, 'BoTag'), true);
    expect(_crobStatus(onResp), DnpControlStatus.success);

    final offResp = outstation.handleAppRequest(
        _crobRequest(DnpFunc.directOperate, 2, 0, DnpControlCode.latchOff), nowMs: 0);
    expect(readPath(project, 'BoTag'), false);
    expect(_crobStatus(offResp), DnpControlStatus.success);
  });

  test('SELECT then OPERATE flips the output', () {
    final selResp =
        outstation.handleAppRequest(_crobRequest(DnpFunc.select, 1, 0, DnpControlCode.latchOn), nowMs: 1000);
    expect(readPath(project, 'BoTag'), false); // SELECT never writes
    expect(_crobStatus(selResp), DnpControlStatus.success);

    final opResp =
        outstation.handleAppRequest(_crobRequest(DnpFunc.operate, 2, 0, DnpControlCode.latchOn), nowMs: 1100);
    expect(readPath(project, 'BoTag'), true);
    expect(_crobStatus(opResp), DnpControlStatus.success);
  });

  test('OPERATE without a matching prior SELECT is rejected', () {
    final opResp =
        outstation.handleAppRequest(_crobRequest(DnpFunc.operate, 5, 0, DnpControlCode.latchOn), nowMs: 2000);
    expect(readPath(project, 'BoTag'), false); // unchanged
    expect(_crobStatus(opResp), DnpControlStatus.noSelect);
  });

  test('g41 analog-output-block DIRECT_OPERATE writes a numeric tag', () {
    final resp = outstation.handleAppRequest(_g41IntDirectOperateReq(1, 0, 555), nowMs: 0);
    expect(readPath(project, 'AoInt'), 555);
    expect(_g41Status(resp), DnpControlStatus.success);
  });

  test('DIRECT_OPERATE on a forced binaryOutput point is declined and leaves the tag unchanged', () {
    final tag = project.tags.firstWhere((t) => t.name == 'BoForced');
    tag.isForced = true;
    tag.forcedValue = false;
    final resp = outstation.handleAppRequest(
        _crobRequest(DnpFunc.directOperate, 1, 1, DnpControlCode.latchOn), nowMs: 0);
    expect(readPath(project, 'BoForced'), false); // unchanged: forced value wins
    expect(_crobStatus(resp), DnpControlStatus.notAuthorized);
  });

  test('DEVICE_RESTART IIN is set until a g80v1 index-7 WRITE clears it', () {
    final r1 = outstation.handleAppRequest(_readClass0Req(1), nowMs: 0);
    expect(r1[2] & DnpIin1.deviceRestart, DnpIin1.deviceRestart);

    outstation.handleAppRequest(_clearRestartReq(2), nowMs: 0);

    final r2 = outstation.handleAppRequest(_readClass0Req(3), nowMs: 0);
    expect(r2[2] & DnpIin1.deviceRestart, 0);
  });

  test('unknown function code returns NO_FUNC_CODE_SUPPORT IIN, no throw', () {
    final req = Uint8List.fromList([0xC0, 0x63]); // 0x63 is not a supported function code
    final resp = outstation.handleAppRequest(req, nowMs: 0);
    expect(resp[3] & DnpIin2.noFuncCodeSupport, DnpIin2.noFuncCodeSupport);
  });

  test('handleAppRequest never throws on a garbage-short fragment', () {
    expect(() => outstation.handleAppRequest(Uint8List.fromList([0x01]), nowMs: 0), returnsNormally);
  });

  test('handleAppRequest never throws on an empty fragment', () {
    expect(() => outstation.handleAppRequest(Uint8List(0), nowMs: 0), returnsNormally);
  });

  // --- Task 4: solicited Class reads, unsolicited state, CONFIRM routing ---

  test('solicited Class 1 read returns events with CON set; flush only on CONFIRM', () {
    project.protocols!.dnp3!.map = DnpMap(entries: [
      DnpMapEntry(tag: 'BiTag', pointType: 'binaryInput', index: 0, eventClass: 1),
    ]);
    outstation.detectChanges(0); // baseline (BiTag starts true)
    writePath(project, 'BiTag', false);
    outstation.detectChanges(1000); // one class-1 event buffered

    // Class 1 read: g60v2 all-points. app control FIR|FIN|seq=3 = 0xC3.
    final readClass1 = frag(0xC3, DnpFunc.read, [60, 2, 0x06]);
    final resp = outstation.handleAppRequest(readClass1, nowMs: 1000);
    expect(resp[1], DnpFunc.response);
    expect((resp[0] & 0x20) != 0, isTrue, reason: 'CON bit set (awaiting CONFIRM)');
    // Response carries a g2v2 object (group 2, variation 2) — IIN is 2 bytes then objects.
    expect(resp.sublist(4).contains(2), isTrue);

    // Without a CONFIRM, a re-read still returns the event (not flushed).
    final resp2 = outstation.handleAppRequest(frag(0xC4, DnpFunc.read, [60, 2, 0x06]), nowMs: 1000);
    expect((resp2[0] & 0x20) != 0, isTrue);

    // CONFIRM (fc0) with the sequence matching the most recent solicited
    // response (4, from resp2 — `_pendingSolicitedSeq` tracks the latest
    // Class read that reported these events) flushes it.
    outstation.handleAppRequest(frag(0xC4, DnpFunc.confirm), nowMs: 1000);
    final resp3 = outstation.handleAppRequest(frag(0xC5, DnpFunc.read, [60, 2, 0x06]), nowMs: 1000);
    expect((resp3[0] & 0x20) != 0, isFalse, reason: 'no events left, no CON');
  });

  test('CONFIRM yields no reply (empty fragment)', () {
    final resp = outstation.handleAppRequest(frag(0xC0, DnpFunc.confirm), nowMs: 0);
    expect(resp, isEmpty);
  });

  test('combined g60v1..v4 read returns static AND events', () {
    project.protocols!.dnp3!.map = DnpMap(entries: [
      DnpMapEntry(tag: 'BiTag', pointType: 'binaryInput', index: 0, eventClass: 1),
    ]);
    outstation.detectChanges(0);
    writePath(project, 'BiTag', false);
    outstation.detectChanges(1);
    final resp = outstation.handleAppRequest(
        frag(0xC0, DnpFunc.read, [60, 1, 0x06, 60, 2, 0x06, 60, 3, 0x06, 60, 4, 0x06]),
        nowMs: 1);
    final objs = resp.sublist(4);
    expect(objs.contains(1), isTrue, reason: 'g1v2 static binary input present');
    expect(objs.contains(2), isTrue, reason: 'g2v2 binary event present');
  });

  test('ENABLE_UNSOLICITED sets the class flag and queues a null unsolicited', () {
    outstation.handleAppRequest(frag(0xC0, DnpFunc.enableUnsolicited, [60, 2, 0x06]), nowMs: 0);
    expect(outstation.unsolicitedEnabledClasses.contains(1), isTrue);
    final nullUnsol = outstation.takeNullUnsolicited();
    expect(nullUnsol, isNotNull);
    expect(nullUnsol![1], DnpFunc.unsolicitedResponse);
    expect(nullUnsol.length, 4); // no objects
    expect(outstation.takeNullUnsolicited(), isNull, reason: 'only sent once');
  });

  test('unsolicited push carries events; CONFIRM flushes; failUnsolicited keeps them', () {
    project.protocols!.dnp3!.map = DnpMap(entries: [
      DnpMapEntry(tag: 'BiTag', pointType: 'binaryInput', index: 0, eventClass: 1),
    ]);
    outstation.handleAppRequest(frag(0xC0, DnpFunc.enableUnsolicited, [60, 2, 0x06]), nowMs: 0);
    // Consume the null announcement AND confirm it — only one unsolicited
    // fragment may be in flight at a time, so a compliant master confirms
    // the null before the outstation can push the next (event) fragment.
    final nullResp = outstation.takeNullUnsolicited()!;
    final nullSeq = nullResp[0] & 0x0F;
    outstation.handleAppRequest(frag(0x10 | nullSeq, DnpFunc.confirm), nowMs: 0);
    outstation.detectChanges(0);
    writePath(project, 'BiTag', false);
    outstation.detectChanges(100);
    final push = outstation.takeEventUnsolicited(100);
    expect(push, isNotNull);
    expect(push![1], DnpFunc.unsolicitedResponse);
    expect((push[0] & 0x10) != 0, isTrue, reason: 'UNS bit');
    expect(outstation.hasUnsolicitedInFlight, isTrue);
    // No second push while one is in flight.
    expect(outstation.takeEventUnsolicited(200), isNull);
    // A matching unsolicited CONFIRM flushes it.
    final seq = push[0] & 0x0F;
    outstation.handleAppRequest(frag(0x10 | seq, DnpFunc.confirm), nowMs: 300); // UNS bit set
    expect(outstation.hasUnsolicitedInFlight, isFalse);
    // Next detect with no change -> nothing to send.
    outstation.detectChanges(400);
    expect(outstation.takeEventUnsolicited(400), isNull);
  });

  test('solicited Class read returns output events as g11v2 + g42v3 (not g2/g32)', () {
    project.protocols!.dnp3!.map = DnpMap(entries: [
      DnpMapEntry(tag: 'BoTag', pointType: 'binaryOutput', index: 0, eventClass: 1),
      DnpMapEntry(tag: 'AoInt', pointType: 'analogOutput', index: 0, eventClass: 2),
    ]);
    outstation.detectChanges(0);
    writePath(project, 'BoTag', true);
    writePath(project, 'AoInt', 42);
    outstation.detectChanges(1);

    final resp = outstation.handleAppRequest(
        frag(0xC0, DnpFunc.read, [60, 2, 0x06, 60, 3, 0x06]), nowMs: 1);
    final objs = resp.sublist(4);
    final groups = _decodeEventObjectGroups(objs);
    expect(groups.contains((11, 2)), isTrue, reason: 'g11v2 binary output event group present');
    expect(groups.contains((42, 3)), isTrue, reason: 'g42v3 analog output event group present');
    // A binaryOutput/analogOutput-only event set must NOT be grouped under
    // the input groups (g2v2 binary-input, g32v3 analog-input) — that would
    // indicate misgrouping.
    expect(groups.contains((2, 2)), isFalse, reason: 'no g2v2 (binary-input) group for an output-only event set');
    expect(groups.contains((32, 3)), isFalse, reason: 'no g32v3 (analog-input) group for an output-only event set');
  });

  test('IIN class-available + overflow bits reflect the engine', () {
    project.protocols!.dnp3!.map = DnpMap(entries: [
      DnpMapEntry(tag: 'AiInt', pointType: 'analogInput', index: 0, eventClass: 2),
    ]);
    final os = DnpOutstation(projectProvider: () => project, eventBufferPerClass: 2);
    os.detectChanges(0);
    for (var v = 1; v <= 4; v++) {
      writePath(project, 'AiInt', v);
      os.detectChanges(v);
    }
    // A static (Class 0) read still returns and now carries IIN1 class-2 + IIN2 overflow.
    final resp = os.handleAppRequest(frag(0xC0, DnpFunc.read, [60, 1, 0x06]), nowMs: 5);
    final iin1 = resp[2];
    final iin2 = resp[3];
    expect(iin1 & DnpIin1.class2Events, DnpIin1.class2Events);
    expect(iin2 & DnpIin2.eventBufferOverflow, DnpIin2.eventBufferOverflow);
  });

  group('Task 2 hardening: write-time backstop', () {
    test('CROB DIRECT_OPERATE on a control point hand-retargeted at the System tag is refused, tag unchanged '
        '(DNP3 has no map-level access field — this backstop is the only thing stopping it)', () {
      final resp = outstation.handleAppRequest(
          _crobRequest(DnpFunc.directOperate, 1, 2, DnpControlCode.latchOn), nowMs: 0);
      expect(_crobStatus(resp), DnpControlStatus.notAuthorized);
      expect(readPath(project, 'System'), false);
    });

    test('g41 analog-output-block DIRECT_OPERATE on a point hand-retargeted at the System tag is refused, '
        'tag unchanged', () {
      final resp = outstation.handleAppRequest(_g41IntDirectOperateReq(1, 1, 555), nowMs: 0);
      expect(_g41Status(resp), DnpControlStatus.notAuthorized);
      expect(readPath(project, 'System'), false);
    });

    test('CROB DIRECT_OPERATE on a SimulatedOutput control point still succeeds (deliberate override survives)',
        () {
      final resp = outstation.handleAppRequest(
          _crobRequest(DnpFunc.directOperate, 1, 3, DnpControlCode.latchOn), nowMs: 0);
      expect(_crobStatus(resp), DnpControlStatus.success);
      expect(readPath(project, 'SimOutBo'), true);
    });

    test('g41 analog-output-block DIRECT_OPERATE on a SimulatedOutput point still succeeds', () {
      final resp = outstation.handleAppRequest(_g41IntDirectOperateReq(1, 2, 321), nowMs: 0);
      expect(_g41Status(resp), DnpControlStatus.success);
      expect(readPath(project, 'SimOutAo'), 321);
    });

    test('a normal Internal (non-System, non-SimulatedOutput) control point still writes successfully — '
        'the backstop is not over-broad', () {
      final resp = outstation.handleAppRequest(
          _crobRequest(DnpFunc.directOperate, 1, 0, DnpControlCode.latchOn), nowMs: 0);
      expect(_crobStatus(resp), DnpControlStatus.success);
      expect(readPath(project, 'BoTag'), true);
    });
  });

  // --- Task 4: application-fragment bound + multi-fragment large reads ------
  //
  // A Class 0 read of a large database produces an application fragment that
  // overruns the master's fixed 2048-byte receive buffer (the `dnp3` crate's
  // min+default rx_buffer_size, which a master cannot raise), silently
  // dropping the whole response. The outstation must instead page the response
  // across multiple application fragments, each <= kDnpMaxAppFragment, gated by
  // the master's CONFIRM. There is no scriptable third-party DNP3 master in
  // this repo, so this boundary unit test is the proof: it drives the full
  // CONFIRM-gated exchange and reassembles the paged fragments the way a
  // conformant master would.
  group('Task 4: application-fragment bound + multi-fragment large reads', () {
    // Builds a project of [count] contiguous analogInput INT32 points at
    // indices 0..count-1, each carrying its own index as its value (so the
    // reassembled point set can be checked for order/completeness).
    PlcProject buildAnalogProject(int count) {
      final tags = <PlcTag>[];
      final entries = <DnpMapEntry>[];
      for (var i = 0; i < count; i++) {
        tags.add(PlcTag(name: 'Ai$i', path: 'Ai$i', dataType: 'INT32', value: i, ioType: 'Internal'));
        entries.add(DnpMapEntry(tag: 'Ai$i', pointType: 'analogInput', index: i));
      }
      return PlcProject(
        id: 'big',
        name: 'BIG',
        controllerName: 'C',
        structDefs: const [],
        programs: const [],
        tasks: const [],
        hmis: const [],
        tags: tags,
        protocols: ProtocolSettings(
          dnp3: DnpProtocolConfig(enabled: true, map: DnpMap(entries: entries)),
        ),
      );
    }

    // Builds a project of [count] contiguous analogInput INT32 points (same
    // shape as [buildAnalogProject]) where the indices named as keys in
    // [eventClassByIndex] additionally carry that eventClass (1/2/3) so a
    // change to them is captured by the event engine — used by the paged-read
    // event-flush and read-supersession tests below, which need a read big
    // enough to page AND carrying Class 1/2/3 events in the same fragment set.
    PlcProject buildAnalogEventProject(int count, Map<int, int> eventClassByIndex) {
      final tags = <PlcTag>[];
      final entries = <DnpMapEntry>[];
      for (var i = 0; i < count; i++) {
        tags.add(PlcTag(name: 'Ai$i', path: 'Ai$i', dataType: 'INT32', value: i, ioType: 'Internal'));
        entries.add(DnpMapEntry(
          tag: 'Ai$i',
          pointType: 'analogInput',
          index: i,
          eventClass: eventClassByIndex[i] ?? 0,
        ));
      }
      return PlcProject(
        id: 'bigEvt',
        name: 'BIGEVT',
        controllerName: 'C',
        structDefs: const [],
        programs: const [],
        tasks: const [],
        hmis: const [],
        tags: tags,
        protocols: ProtocolSettings(
          dnp3: DnpProtocolConfig(enabled: true, map: DnpMap(entries: entries)),
        ),
      );
    }

    // Drives the full CONFIRM-gated multi-fragment exchange: sends the read,
    // then a solicited CONFIRM (matching the last fragment's sequence) for each
    // non-final fragment, collecting every emitted fragment in order.
    List<Uint8List> driveRead(DnpOutstation os, Uint8List req, {int nowMs = 0}) {
      final frags = <Uint8List>[];
      var resp = os.handleAppRequest(req, nowMs: nowMs);
      frags.add(resp);
      // FIN (app control bit 6, 0x40) clear means more fragments follow.
      while ((resp[0] & 0x40) == 0) {
        final seq = resp[0] & 0x0F;
        // Solicited CONFIRM: FIR|FIN|seq, UNS(0x10) clear.
        final confirm = Uint8List.fromList([0xC0 | seq, DnpFunc.confirm]);
        resp = os.handleAppRequest(confirm, nowMs: nowMs);
        if (resp.isEmpty) {
          break; // guard against a non-advancing CONFIRM
        }
        frags.add(resp);
      }
      return frags;
    }

    // Reassembles paged g30v1 fragments into an index->value map, asserting no
    // index is delivered twice.
    Map<int, int> reassembleAnalogInts(List<Uint8List> frags) {
      final objBytes = BytesBuilder();
      for (final f in frags) {
        objBytes.add(f.sublist(4)); // strip app control + func + IIN(2)
      }
      final objs = _decodeResponseObjects(objBytes.toBytes());
      final values = <int, int>{};
      for (final o in objs) {
        if (o.group != 30 || o.variation != 1) {
          continue;
        }
        for (var idx = o.start; idx <= o.stop; idx++) {
          expect(values.containsKey(idx), isFalse, reason: 'index $idx delivered twice');
          values[idx] = _decodeI32(_findPoint([o], 30, 1, idx)!);
        }
      }
      return values;
    }

    test('a Class 0 read of 408 analog points pages across fragments, each <= kDnpMaxAppFragment', () {
      final project = buildAnalogProject(408);
      final os = DnpOutstation(projectProvider: () => project);
      final frags = driveRead(os, _readClass0Req(1));

      expect(frags.length, greaterThan(1), reason: '408 points must overrun one fragment');
      for (final f in frags) {
        expect(f.length, lessThanOrEqualTo(kDnpMaxAppFragment));
      }

      final values = reassembleAnalogInts(frags);
      expect(values.length, 408, reason: 'every point delivered exactly once');
      for (var i = 0; i < 408; i++) {
        expect(values[i], i, reason: 'point $i present and in order');
      }
    });

    test('FIR/FIN bits are correct across the paged fragments', () {
      final project = buildAnalogProject(1000);
      final os = DnpOutstation(projectProvider: () => project);
      final frags = driveRead(os, _readClass0Req(1));
      expect(frags.length, greaterThan(2), reason: '1000 points needs 3+ fragments');

      // First: FIR set, FIN clear.
      expect(frags.first[0] & 0x80, 0x80);
      expect(frags.first[0] & 0x40, 0);
      // Last: FIN set, FIR clear.
      expect(frags.last[0] & 0x40, 0x40);
      expect(frags.last[0] & 0x80, 0);
      // Middle(s): neither FIR nor FIN.
      for (var i = 1; i < frags.length - 1; i++) {
        expect(frags[i][0] & 0x80, 0, reason: 'middle fragment $i has FIR clear');
        expect(frags[i][0] & 0x40, 0, reason: 'middle fragment $i has FIN clear');
      }
    });

    test('a CONFIRM advances the cursor and the fragment sequence numbers increment', () {
      final project = buildAnalogProject(1000);
      final os = DnpOutstation(projectProvider: () => project);
      final frags = driveRead(os, _readClass0Req(3));
      for (var i = 0; i < frags.length; i++) {
        expect(frags[i][0] & 0x0F, (3 + i) & 0x0F, reason: 'fragment $i sequence');
      }
      // Non-final fragments set CON (0x20) so the master knows to CONFIRM.
      for (var i = 0; i < frags.length - 1; i++) {
        expect(frags[i][0] & 0x20, 0x20, reason: 'fragment $i requests CONFIRM');
      }
    });

    test('a stale/duplicate CONFIRM does not release a fragment (deterministic cursor)', () {
      final project = buildAnalogProject(408);
      final os = DnpOutstation(projectProvider: () => project);
      final first = os.handleAppRequest(_readClass0Req(1), nowMs: 0);
      final firstSeq = first[0] & 0x0F;
      // A CONFIRM whose sequence does NOT match the in-flight fragment is ignored.
      final wrong = os.handleAppRequest(
          Uint8List.fromList([0xC0 | ((firstSeq + 5) & 0x0F), DnpFunc.confirm]),
          nowMs: 0);
      expect(wrong, isEmpty, reason: 'mismatched CONFIRM releases nothing');
      // The correct CONFIRM releases the next fragment.
      final next = os.handleAppRequest(
          Uint8List.fromList([0xC0 | firstSeq, DnpFunc.confirm]), nowMs: 0);
      expect(next, isNotEmpty);
      expect(next[0] & 0x0F, (firstSeq + 1) & 0x0F);
    });

    test('407 analog points still fit in a single FIR+FIN fragment (just under the bound)', () {
      final project = buildAnalogProject(407);
      final os = DnpOutstation(projectProvider: () => project);
      final resp = os.handleAppRequest(_readClass0Req(1), nowMs: 0);
      expect(resp.length, lessThanOrEqualTo(kDnpMaxAppFragment));
      expect(resp[0] & 0x80, 0x80, reason: 'FIR set');
      expect(resp[0] & 0x40, 0x40, reason: 'FIN set (single fragment)');
      // No continuation: a CONFIRM releases nothing.
      final seq = resp[0] & 0x0F;
      final after = os.handleAppRequest(
          Uint8List.fromList([0xC0 | seq, DnpFunc.confirm]), nowMs: 0);
      expect(after, isEmpty);
    });

    test('408 analog points splits at the tipping point into exactly two fragments', () {
      final project = buildAnalogProject(408);
      final os = DnpOutstation(projectProvider: () => project);
      final frags = driveRead(os, _readClass0Req(1));
      expect(frags.length, 2, reason: '408 is one point over the single-fragment ceiling');
    });

    test('a small Class 0 read is byte-identical to the pre-change single-fragment form', () {
      // The existing fixture (a handful of points) must still be exactly one
      // FIR|FIN, CON-clear response with no continuation state.
      final project = _buildProject();
      final os = DnpOutstation(projectProvider: () => project);
      final resp = os.handleAppRequest(_readClass0Req(1), nowMs: 0);
      expect(resp.length, lessThan(kDnpMaxAppFragment));
      expect(resp[0], 0xC0 | 1, reason: 'FIR|FIN|seq=1, CON clear');
      expect(resp[1], DnpFunc.response);
    });

    test(
        'a paged read carrying Class 1/2/3 events delivers every event exactly once; '
        "the final fragment's CONFIRM flushes them (a later read does not re-deliver)", () {
      // 1000 analogInput points force multi-fragment paging (same bound as the
      // FIR/FIN test above); 5 of them also carry an eventClass spread across
      // all three event classes, so this read's static payload AND its event
      // payload both have to survive being split across fragment boundaries —
      // exercising the "all fragments already sent" CONFIRM branch in
      // `_confirmSolicited`, which every other Task 4 test leaves untouched
      // because they only ever read pure-static data.
      final eventClassByIndex = {10: 1, 250: 2, 500: 3, 750: 1, 999: 2};
      final project = buildAnalogEventProject(1000, eventClassByIndex);
      final os = DnpOutstation(projectProvider: () => project);
      os.detectChanges(0); // baseline (no events yet)
      final newValues = <int, int>{};
      eventClassByIndex.forEach((idx, _) {
        newValues[idx] = 9000 + idx;
        writePath(project, 'Ai$idx', newValues[idx]!);
      });
      os.detectChanges(1); // one event per changed point, in its own class

      // Combined g60v1..v4 read: static (Class 0) AND all three event classes,
      // the same request shape as the "combined g60v1..v4 read" test above.
      final req = frag(0xC3, DnpFunc.read, [60, 1, 0x06, 60, 2, 0x06, 60, 3, 0x06, 60, 4, 0x06]);
      var resp = os.handleAppRequest(req, nowMs: 1);
      final frags = <Uint8List>[resp];
      while ((resp[0] & 0x40) == 0) {
        final seq = resp[0] & 0x0F;
        resp = os.handleAppRequest(Uint8List.fromList([0xC0 | seq, DnpFunc.confirm]), nowMs: 1);
        frags.add(resp);
      }
      expect(frags.length, greaterThan(1), reason: '1000 points + events must overrun one fragment');
      for (final f in frags) {
        expect(f.length, lessThanOrEqualTo(kDnpMaxAppFragment));
      }
      // The final fragment still carries events awaiting flush, so it must
      // still request CONFIRM even though it's the last one.
      expect((frags.last[0] & 0x20) != 0, isTrue, reason: 'final fragment still awaits its flush CONFIRM');

      // Reassemble the static payload (existing helper) and check every point,
      // changed or not, is present exactly once with its current value.
      final values = reassembleAnalogInts(frags);
      expect(values.length, 1000, reason: 'every static point delivered exactly once');
      for (var i = 0; i < 1000; i++) {
        final expected = newValues[i] ?? i;
        expect(values[i], expected, reason: 'point $i present with its current value');
      }

      // Reassemble the events: every changed point must appear exactly once,
      // as a g32v3 (analog input event) point, carrying its new value.
      Uint8List concatObjects(List<Uint8List> fs) {
        final b = BytesBuilder();
        for (final f in fs) {
          b.add(f.sublist(4));
        }
        return b.toBytes();
      }

      final eventPoints =
          _decodeAllEventPoints(concatObjects(frags)).where((p) => p.group == 32 && p.variation == 3).toList();
      final seenIndices = <int>{};
      for (final p in eventPoints) {
        expect(seenIndices.contains(p.index), isFalse, reason: 'event index ${p.index} delivered twice');
        seenIndices.add(p.index);
      }
      expect(seenIndices, newValues.keys.toSet(), reason: 'every changed point delivered exactly once, none dropped');
      for (final p in eventPoints) {
        expect(_decodeI32(p.payload), newValues[p.index], reason: 'event for point ${p.index} carries its new value');
      }

      // The drive loop above stops the instant FIN is seen — it never CONFIRMs
      // the final fragment itself. That CONFIRM is what actually flushes the
      // events (`_confirmSolicited`'s "all fragments already sent" branch).
      final lastSeq = frags.last[0] & 0x0F;
      final afterFinalConfirm =
          os.handleAppRequest(Uint8List.fromList([0xC0 | lastSeq, DnpFunc.confirm]), nowMs: 1);
      expect(afterFinalConfirm, isEmpty, reason: 'a solicited CONFIRM never itself gets a reply');

      // A subsequent read for the same event classes must NOT re-deliver the
      // now-flushed events — proving the flush actually happened, not merely
      // that CON went low on the last fragment.
      final req2 = frag(0xC0, DnpFunc.read, [60, 1, 0x06, 60, 2, 0x06, 60, 3, 0x06, 60, 4, 0x06]);
      final frags2 = driveRead(os, req2, nowMs: 2);
      final eventPoints2 =
          _decodeAllEventPoints(concatObjects(frags2)).where((p) => p.group == 32 && p.variation == 3).toList();
      expect(eventPoints2, isEmpty, reason: 'events already flushed; a later read must not resend them');
    });

    test('a new read supersedes an in-flight paged read without losing or duplicating its data', () {
      // Same shape of project as the event-flush test above: 1000 analog
      // points (forces paging) with a handful carrying events across all
      // three classes.
      final eventClassByIndex = {5: 1, 15: 2, 25: 3, 35: 1};
      final project = buildAnalogEventProject(1000, eventClassByIndex);
      final os = DnpOutstation(projectProvider: () => project);
      os.detectChanges(0);
      final newValues = <int, int>{};
      eventClassByIndex.forEach((idx, _) {
        newValues[idx] = 7000 + idx;
        writePath(project, 'Ai$idx', newValues[idx]!);
      });
      os.detectChanges(1);

      // First read (seq=1): consume only its first fragment plus ONE CONFIRM
      // (releasing fragment 2) — deliberately do NOT drive it to completion,
      // so the paged read is genuinely still in-flight (mid-cursor) when the
      // new read arrives.
      final req1 = frag(0xC1, DnpFunc.read, [60, 1, 0x06, 60, 2, 0x06, 60, 3, 0x06, 60, 4, 0x06]);
      final firstFrag = os.handleAppRequest(req1, nowMs: 2);
      expect(firstFrag[0] & 0x40, 0, reason: 'first read must page (more than one fragment)');
      final firstSeq = firstFrag[0] & 0x0F;
      final secondFrag = os.handleAppRequest(Uint8List.fromList([0xC0 | firstSeq, DnpFunc.confirm]), nowMs: 2);
      expect(secondFrag, isNotEmpty, reason: 'the matching CONFIRM releases the 2nd fragment');
      expect(secondFrag[0] & 0x40, 0, reason: 'still not final — the first read stays genuinely in-flight');

      // A brand-new read (seq=5) arrives while the first is still paged.
      final req2 = frag(0xC5, DnpFunc.read, [60, 1, 0x06, 60, 2, 0x06, 60, 3, 0x06, 60, 4, 0x06]);
      final newFirstFrag = os.handleAppRequest(req2, nowMs: 3);
      expect(newFirstFrag[0] & 0x80, 0x80, reason: 'new read returns a well-formed FIRST fragment (FIR set)');
      expect(newFirstFrag[0] & 0x0F, 5, reason: "new read carries its own sequence, unaffected by the old cursor");

      // Drive the new read to completion by CONFIRMing from the fragment
      // already obtained above (req2 itself must be sent only once — it was
      // already sent, producing newFirstFrag).
      final manualFrags = <Uint8List>[newFirstFrag];
      var resp = newFirstFrag;
      while ((resp[0] & 0x40) == 0) {
        final seq = resp[0] & 0x0F;
        resp = os.handleAppRequest(Uint8List.fromList([0xC0 | seq, DnpFunc.confirm]), nowMs: 3);
        expect(resp, isNotEmpty, reason: 'the new read cursor is not corrupted by the superseded one');
        manualFrags.add(resp);
      }
      expect(manualFrags.length, greaterThan(1), reason: 'the new read itself must still page');
      for (var i = 0; i < manualFrags.length; i++) {
        expect(manualFrags[i][0] & 0x0F, (5 + i) & 0x0F, reason: 'fragment $i sequence increments cleanly from 5');
      }

      // Full static set present exactly once, in order, reflecting current values.
      final values = reassembleAnalogInts(manualFrags);
      expect(values.length, 1000);
      for (var i = 0; i < 1000; i++) {
        final expected = newValues[i] ?? i;
        expect(values[i], expected, reason: 'point $i present with its current value, once');
      }

      // The events from the changes made before the FIRST (superseded) read
      // are still available — `pull()` never removes them from the buffer,
      // and the superseded read's cursor was discarded before it ever reached
      // its flush-on-CONFIRM branch — so the new read must still deliver
      // every one of them, exactly once: nothing lost to the supersession.
      final objBytes = BytesBuilder();
      for (final f in manualFrags) {
        objBytes.add(f.sublist(4));
      }
      final eventPoints =
          _decodeAllEventPoints(objBytes.toBytes()).where((p) => p.group == 32 && p.variation == 3).toList();
      final seenIndices = <int>{};
      for (final p in eventPoints) {
        expect(seenIndices.contains(p.index), isFalse, reason: 'event index ${p.index} delivered twice');
        seenIndices.add(p.index);
      }
      expect(seenIndices, newValues.keys.toSet(), reason: 'no event lost to the superseded read; none duplicated');
      for (final p in eventPoints) {
        expect(_decodeI32(p.payload), newValues[p.index], reason: 'event for point ${p.index} carries its value');
      }
    });
  });
}
