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
}
