// Tests for the CIP tag services (mobile/lib/protocols/enip/cip_tags.dart):
// Read Tag (0x4C), Write Tag (0x4D), and the Multiple Service Packet (0x0A),
// dispatched against a fixture PlcProject through a CipMap exposure model.
//
// The three rules that matter most, each with its own dedicated test:
//  1. A write to a FORCED tag is refused with 0x0F (privilege violation) and
//     the tag is left unchanged — never a silent success.
//  2. A write to a ReadOnly CipMap entry is refused with 0x0F, unchanged.
//  3. An unknown OR unexposed tag name returns 0x05 (path destination
//     unknown) — indistinguishable from each other.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/cip_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_tags.dart';

Uint8List _u16le(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);

int _readU16(Uint8List d, int o) => d[o] | (d[o + 1] << 8);

/// Builds a Read Tag request's data payload: element count (u16) = 1.
Uint8List _readData() => _u16le(1);

/// Builds a Write Tag request's data payload: type code (u16) + element
/// count (u16) = 1 + value bytes.
Uint8List _writeData(int typeCode, Uint8List valueBytes) =>
    Uint8List.fromList([..._u16le(typeCode), ..._u16le(1), ...valueBytes]);

/// Builds one embedded CIP request's raw wire bytes (service u8, pathWords
/// u8, path bytes, service data) for use inside a Multiple Service Packet.
Uint8List _embeddedRequest(int service, List<CipPathSegment> path, Uint8List data) {
  final pathBytes = buildEpath(path);
  final pathWords = pathBytes.length ~/ 2;
  return Uint8List.fromList([service, pathWords, ...pathBytes, ...data]);
}

/// Builds a Multiple Service Packet request payload from [embedded] requests:
/// count (u16), the offset list (u16 each, relative to the offset-list start),
/// then the embedded requests. Mirrors the wire layout in `cip_tags.dart`'s
/// header.
Uint8List _buildMsp(List<Uint8List> embedded) {
  final count = embedded.length;
  final out = BytesBuilder();
  out.add(_u16le(count));
  // Offsets are relative to the offset-list start; the embedded requests begin
  // right after the (count * 2)-byte offset list itself.
  var running = count * 2;
  for (final e in embedded) {
    out.add(_u16le(running));
    running += e.length;
  }
  for (final e in embedded) {
    out.add(e);
  }
  return out.toBytes();
}

void main() {
  PlcProject buildProject() => PlcProject(
        id: 'cip_tags_proj',
        name: 'CIP Tags Project',
        controllerName: 'PLC_CIP_TAGS',
        tags: [
          // Distinct, non-zero fixture values (see Fix 3): a per-type test
          // that only checks the type code can't tell a correctly-decoded
          // value apart from the wrong number of zero bytes.
          PlcTag(name: 'Bool_Tag', path: 'Bool_Tag', dataType: 'BOOL', value: true, ioType: 'Internal'),
          PlcTag(name: 'Int16_Tag', path: 'Int16_Tag', dataType: 'INT16', value: 1234, ioType: 'Internal'),
          PlcTag(name: 'Int32_Tag', path: 'Int32_Tag', dataType: 'INT32', value: 98765, ioType: 'Internal'),
          PlcTag(name: 'Int64_Tag', path: 'Int64_Tag', dataType: 'INT64', value: 5000000000, ioType: 'Internal'),
          PlcTag(name: 'Float64_Tag', path: 'Float64_Tag', dataType: 'FLOAT64', value: 12.5, ioType: 'Internal'),
          // Map-level ReadOnly (tag's own `access` field is left ReadWrite on
          // purpose, to prove it's the MAP entry that gates the write, not
          // the tag itself).
          PlcTag(name: 'Locked_Tag', path: 'Locked_Tag', dataType: 'INT16', value: 5, ioType: 'Internal'),
          // Forced: a write must be refused even though the map entry is
          // ReadWrite.
          PlcTag(
            name: 'Forced_Tag',
            path: 'Forced_Tag',
            dataType: 'INT32',
            value: 10,
            ioType: 'Internal',
            isForced: true,
            forcedValue: 999,
          ),
          // Present in the project but deliberately NOT added to the CipMap
          // below.
          PlcTag(name: 'Unexposed_Tag', path: 'Unexposed_Tag', dataType: 'BOOL', value: true, ioType: 'Internal'),
          // Fix 1 regression fixture: a composite ROOT tag that is forced.
          // `rootTagOf` (tag_resolver.dart) resolves a member path like
          // `Tank.Level` to this root by its first path segment, so a write
          // to the MEMBER must be refused exactly like a write to the root
          // itself would be.
          PlcTag(
            name: 'Tank',
            path: 'Tank',
            dataType: 'TankType',
            value: {'Level': 55},
            ioType: 'Internal',
            isForced: true,
          ),
          // Fix B regression fixture: a composite ROOT tag that is NOT forced.
          // This tests that a member path beneath a non-forced root can be
          // written successfully, in contrast to Tank (which is forced and
          // must refuse all writes).
          PlcTag(
            name: 'Tank2',
            path: 'Tank2',
            dataType: 'TankType',
            value: {'Level': 100},
            ioType: 'Internal',
            isForced: false,
          ),
          // Task 2 hardening fixtures ------------------------------------
          // The reserved System tag, with its OWN `access` deliberately left
          // 'ReadWrite' (NOT 'ReadOnly') — isolating the write-time backstop's
          // NAME-based rule from the ordinary access-field rule. The map
          // entry below is ALSO deliberately 'ReadWrite'. Today (pre-Task-2)
          // this write SUCCEEDS; the backstop must refuse it with 0x0F.
          PlcTag(
            name: 'System',
            path: 'System',
            dataType: 'SystemType',
            value: {'Cmd': 0},
            ioType: 'Internal',
            access: 'ReadWrite',
          ),
          // A SimulatedOutput tag whose map entry is deliberately set
          // 'ReadWrite' — the carve-out (decision 1) that must survive the
          // backstop: a user may override a SimulatedOutput to be driven by
          // an external client.
          PlcTag(name: 'SimOut', path: 'SimOut', dataType: 'INT16', value: 7, ioType: 'SimulatedOutput'),
        ],
        structDefs: [
          PlcStructDef(name: 'TankType', fields: [
            StructFieldDef(name: 'Level', dataType: 'INT32', defaultValue: 0),
          ]),
          PlcStructDef(name: 'SystemType', fields: [
            StructFieldDef(name: 'Cmd', dataType: 'INT16', defaultValue: 0),
          ]),
        ],
        programs: [],
        tasks: [],
        hmis: [],
      );

  CipMap buildMap() => CipMap(entries: [
        CipMapEntry(tagName: 'Bool_Tag', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Int16_Tag', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Int32_Tag', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Int64_Tag', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Float64_Tag', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Locked_Tag', access: 'ReadOnly'),
        CipMapEntry(tagName: 'Forced_Tag', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Tank.Level', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Tank2.Level', access: 'ReadWrite'),
        // Task 2 hardening fixtures: both deliberately 'ReadWrite' at the
        // MAP level (see buildProject for why this matters for each).
        CipMapEntry(tagName: 'System.Cmd', access: 'ReadWrite'),
        CipMapEntry(tagName: 'SimOut', access: 'ReadWrite'),
      ]);

  group('Read Tag (0x4C)', () {
    test('returns the correct type code AND value for each supported type', () {
      final project = buildProject();
      final map = buildMap();

      // Each fixture tag (see buildProject) holds a DISTINCT NON-ZERO value,
      // so an implementation that returns the right type code but the wrong
      // number of (or wrong) value bytes cannot pass by coincidence with an
      // all-zero fixture.
      final cases = <String, List<Object>>{
        'Bool_Tag': [kCipTypeBool, true],
        'Int16_Tag': [kCipTypeInt, 1234],
        'Int32_Tag': [kCipTypeDint, 98765],
        'Int64_Tag': [kCipTypeLint, 5000000000],
        'Float64_Tag': [kCipTypeReal, 12.5], // exactly representable in float32 — no narrowing here.
      };

      for (final tagName in cases.keys) {
        final req = CipRequest(
          service: kCipServiceReadTag,
          path: [CipPathSegment.symbol(tagName)],
          data: _readData(),
        );
        final resp = dispatchCipService(project, map, req);
        expect(resp.generalStatus, kCipStatusSuccess, reason: tagName);
        final typeCode = _readU16(resp.data, 0);
        final expectedTypeCode = cases[tagName]![0] as int;
        final expectedValue = cases[tagName]![1];
        expect(typeCode, expectedTypeCode, reason: tagName);
        final decoded = decodeCipValue(typeCode, resp.data.sublist(2));
        if (tagName == 'Float64_Tag') {
          expect(decoded, closeTo(expectedValue as double, 0.0001), reason: tagName);
        } else {
          expect(decoded, expectedValue, reason: tagName);
        }
      }
    });

    test('unknown tag name (does not exist in the project) returns 0x05', () {
      final project = buildProject();
      final map = buildMap();
      final req = CipRequest(
        service: kCipServiceReadTag,
        path: [CipPathSegment.symbol('Ghost_Tag')],
        data: _readData(),
      );
      final resp = dispatchCipService(project, map, req);
      expect(resp.generalStatus, kCipStatusPathDestinationUnknown);
    });

    test('unexposed tag (exists in the project, absent from the CipMap) returns 0x05', () {
      final project = buildProject();
      final map = buildMap();
      expect(project.tags.any((t) => t.name == 'Unexposed_Tag'), isTrue);
      final req = CipRequest(
        service: kCipServiceReadTag,
        path: [CipPathSegment.symbol('Unexposed_Tag')],
        data: _readData(),
      );
      final resp = dispatchCipService(project, map, req);
      expect(resp.generalStatus, kCipStatusPathDestinationUnknown);
    });
  });

  group('Write Tag (0x4D)', () {
    test('updates the tag, and a subsequent read returns the new value', () {
      final project = buildProject();
      final map = buildMap();

      final writeReq = CipRequest(
        service: kCipServiceWriteTag,
        path: [CipPathSegment.symbol('Int32_Tag')],
        data: _writeData(kCipTypeDint, encodeCipValue(kCipTypeDint, 4242)!),
      );
      final writeResp = dispatchCipService(project, map, writeReq);
      expect(writeResp.generalStatus, kCipStatusSuccess);

      final readReq = CipRequest(
        service: kCipServiceReadTag,
        path: [CipPathSegment.symbol('Int32_Tag')],
        data: _readData(),
      );
      final readResp = dispatchCipService(project, map, readReq);
      expect(readResp.generalStatus, kCipStatusSuccess);
      final value = decodeCipValue(kCipTypeDint, readResp.data.sublist(2));
      expect(value, 4242);
    });

    test('a write to a ReadOnly CipMap entry is refused with 0x0F, tag unchanged', () {
      final project = buildProject();
      final map = buildMap();
      final before = project.tags.firstWhere((t) => t.name == 'Locked_Tag').value;

      final req = CipRequest(
        service: kCipServiceWriteTag,
        path: [CipPathSegment.symbol('Locked_Tag')],
        data: _writeData(kCipTypeInt, encodeCipValue(kCipTypeInt, 999)!),
      );
      final resp = dispatchCipService(project, map, req);
      expect(resp.generalStatus, kCipStatusPrivilegeViolation);
      expect(project.tags.firstWhere((t) => t.name == 'Locked_Tag').value, before);
    });

    test('a write to a FORCED tag is refused with 0x0F, tag unchanged — visible, never silent', () {
      final project = buildProject();
      final map = buildMap();
      final tag = project.tags.firstWhere((t) => t.name == 'Forced_Tag');
      expect(tag.isForced, isTrue);
      final before = tag.value;

      final req = CipRequest(
        service: kCipServiceWriteTag,
        path: [CipPathSegment.symbol('Forced_Tag')],
        data: _writeData(kCipTypeDint, encodeCipValue(kCipTypeDint, 555)!),
      );
      final resp = dispatchCipService(project, map, req);
      expect(resp.generalStatus, kCipStatusPrivilegeViolation);
      expect(project.tags.firstWhere((t) => t.name == 'Forced_Tag').value, before);
      expect(project.tags.firstWhere((t) => t.name == 'Forced_Tag').forcedValue, 999);
    });

    test('a type-mismatched write is rejected with an error status, tag unchanged', () {
      final project = buildProject();
      final map = buildMap();
      final before = project.tags.firstWhere((t) => t.name == 'Int32_Tag').value;

      // Int32_Tag expects DINT (0xC4); send a BOOL (0xC1) type code instead.
      final req = CipRequest(
        service: kCipServiceWriteTag,
        path: [CipPathSegment.symbol('Int32_Tag')],
        data: _writeData(kCipTypeBool, Uint8List.fromList([0xFF])),
      );
      final resp = dispatchCipService(project, map, req);
      // Pinned to the actual constant (Fix 4) rather than `isNot(kCipStatusSuccess)`
      // so a future change to this status is visible instead of silently absorbed.
      expect(resp.generalStatus, kCipStatusInvalidAttributeValue);
      expect(project.tags.firstWhere((t) => t.name == 'Int32_Tag').value, before);
    });

    test('write round-trips BOOL, INT16, and INT64 through their CIP types', () {
      final project = buildProject();
      final map = buildMap();

      // Fix 3: only INT32 had write coverage before; this fills in the rest
      // of the exact-equality types (FLOAT64 gets its own narrowing-aware
      // test below).
      final writes = <String, List<Object>>{
        'Bool_Tag': [kCipTypeBool, false],
        'Int16_Tag': [kCipTypeInt, -4321],
        'Int64_Tag': [kCipTypeLint, 9000000000],
      };

      for (final tagName in writes.keys) {
        final typeCode = writes[tagName]![0] as int;
        final newValue = writes[tagName]![1];

        final writeReq = CipRequest(
          service: kCipServiceWriteTag,
          path: [CipPathSegment.symbol(tagName)],
          data: _writeData(typeCode, encodeCipValue(typeCode, newValue)!),
        );
        final writeResp = dispatchCipService(project, map, writeReq);
        expect(writeResp.generalStatus, kCipStatusSuccess, reason: tagName);

        final readReq = CipRequest(
          service: kCipServiceReadTag,
          path: [CipPathSegment.symbol(tagName)],
          data: _readData(),
        );
        final readResp = dispatchCipService(project, map, readReq);
        expect(readResp.generalStatus, kCipStatusSuccess, reason: tagName);
        final decoded = decodeCipValue(typeCode, readResp.data.sublist(2));
        expect(decoded, newValue, reason: tagName);
      }
    });

    test('a FLOAT64 write narrows through CIP REAL (single precision) — read back is close, not exact', () {
      final project = buildProject();
      final map = buildMap();

      // A value with a fractional part not exactly representable in a
      // 32-bit float exposes the narrowing conversion (see cip.dart's
      // encodeCipValue/decodeCipValue docs on REAL 0xCA). The value 3.14159
      // has a float32 round-trip error of approximately 1.2e-8, confirming
      // that the narrowing genuinely occurred.
      const newValue = 3.14159;
      final writeReq = CipRequest(
        service: kCipServiceWriteTag,
        path: [CipPathSegment.symbol('Float64_Tag')],
        data: _writeData(kCipTypeReal, encodeCipValue(kCipTypeReal, newValue)!),
      );
      final writeResp = dispatchCipService(project, map, writeReq);
      expect(writeResp.generalStatus, kCipStatusSuccess);

      final readReq = CipRequest(
        service: kCipServiceReadTag,
        path: [CipPathSegment.symbol('Float64_Tag')],
        data: _readData(),
      );
      final readResp = dispatchCipService(project, map, readReq);
      expect(readResp.generalStatus, kCipStatusSuccess);
      final decoded = decodeCipValue(kCipTypeReal, readResp.data.sublist(2)) as double;
      // Tightened tolerance: 1e-6 is small enough to be meaningful for a
      // float32 round-trip, yet large enough for safe floating-point comparison.
      // The looseness of the old 0.0001 tolerance (1e-4) could not distinguish
      // a real narrowing conversion from no narrowing at all.
      expect(decoded, closeTo(newValue, 1e-6));
      // Explicit proof that narrowing occurred: the round-tripped value must
      // differ from the original double. A non-narrowing implementation (one
      // that preserved the full 64-bit double) would fail this assertion.
      expect(decoded, isNot(equals(newValue)));
    });

    test('malformed (too-short) write data never throws and leaves the tag unchanged', () {
      final project = buildProject();
      final map = buildMap();
      final before = project.tags.firstWhere((t) => t.name == 'Bool_Tag').value;

      final req = CipRequest(
        service: kCipServiceWriteTag,
        path: [CipPathSegment.symbol('Bool_Tag')],
        data: Uint8List.fromList([0x01]), // only 1 byte; header alone needs 4
      );
      late CipResponse resp;
      expect(() => resp = dispatchCipService(project, map, req), returnsNormally);
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
      expect(project.tags.firstWhere((t) => t.name == 'Bool_Tag').value, before);
    });

    test(
        'Fix 1 regression: a write to a MEMBER path beneath a forced ROOT tag is refused with 0x0F, member unchanged',
        () {
      final project = buildProject();
      final map = buildMap();

      // `Tank` is a composite root tag with `isForced: true` (see
      // buildProject). `rootTagOf(project, 'Tank.Level')` resolves to the
      // `Tank` tag by its first path segment — NOT an exact-name match — so
      // the forced-write refusal must fire for a write to the MEMBER path
      // `Tank.Level` exactly as it would for a write to `Tank` itself.
      final tankTag = project.tags.firstWhere((t) => t.name == 'Tank');
      expect(tankTag.isForced, isTrue);
      final before = (tankTag.value as Map)['Level'];
      expect(before, 55); // fixture value, sanity-checked before the write attempt

      final req = CipRequest(
        service: kCipServiceWriteTag,
        path: [CipPathSegment.symbol('Tank'), CipPathSegment.symbol('Level')],
        data: _writeData(kCipTypeDint, encodeCipValue(kCipTypeDint, 12345)!),
      );
      final resp = dispatchCipService(project, map, req);
      expect(resp.generalStatus, kCipStatusPrivilegeViolation);
      final after = (project.tags.firstWhere((t) => t.name == 'Tank').value as Map)['Level'];
      expect(after, before, reason: 'member write into a forced root must never land');
    });

    test(
        'Fix B regression: a write to a MEMBER path beneath a non-forced ROOT tag succeeds and updates the member',
        () {
      final project = buildProject();
      final map = buildMap();

      // `Tank2` is a composite root tag with `isForced: false` (see
      // buildProject). This contrasts with the forced `Tank` tag above:
      // a write to the MEMBER path `Tank2.Level` should succeed, not be
      // refused. The forced-write refusal in Fix 1 must not over-broadly
      // reject legitimate member writes beneath non-forced roots.
      final tank2Tag = project.tags.firstWhere((t) => t.name == 'Tank2');
      expect(tank2Tag.isForced, isFalse);
      final before = (tank2Tag.value as Map)['Level'];
      expect(before, 100); // fixture value, sanity-checked before the write attempt

      const newMemberValue = 42;
      final writeReq = CipRequest(
        service: kCipServiceWriteTag,
        path: [CipPathSegment.symbol('Tank2'), CipPathSegment.symbol('Level')],
        data: _writeData(kCipTypeDint, encodeCipValue(kCipTypeDint, newMemberValue)!),
      );
      final writeResp = dispatchCipService(project, map, writeReq);
      expect(writeResp.generalStatus, kCipStatusSuccess,
          reason: 'write to non-forced composite member must succeed');

      // Verify the member value changed by reading it back.
      final readReq = CipRequest(
        service: kCipServiceReadTag,
        path: [CipPathSegment.symbol('Tank2'), CipPathSegment.symbol('Level')],
        data: _readData(),
      );
      final readResp = dispatchCipService(project, map, readReq);
      expect(readResp.generalStatus, kCipStatusSuccess);
      final decoded = decodeCipValue(kCipTypeDint, readResp.data.sublist(2));
      expect(decoded, newMemberValue,
          reason: 'subsequent read must return the newly-written value');
    });

    group('Task 2 hardening: write-time backstop', () {
      test(
          'a write to a WRITABLE map entry pointing at a System member is refused with 0x0F, member unchanged '
          '(the map entry alone would otherwise allow this write)', () {
        final project = buildProject();
        final map = buildMap();
        final systemTag = project.tags.firstWhere((t) => t.name == 'System');
        expect(systemTag.access, 'ReadWrite', reason: "the tag's OWN access is deliberately not ReadOnly");
        final before = (systemTag.value as Map)['Cmd'];

        final req = CipRequest(
          service: kCipServiceWriteTag,
          path: [CipPathSegment.symbol('System'), CipPathSegment.symbol('Cmd')],
          data: _writeData(kCipTypeInt, encodeCipValue(kCipTypeInt, 999)!),
        );
        final resp = dispatchCipService(project, map, req);
        expect(resp.generalStatus, kCipStatusPrivilegeViolation);
        final after = (project.tags.firstWhere((t) => t.name == 'System').value as Map)['Cmd'];
        expect(after, before, reason: 'a refused write must never land, even partially');
      });

      test('a WRITABLE map entry pointing at a SimulatedOutput tag still succeeds (deliberate override survives)',
          () {
        final project = buildProject();
        final map = buildMap();
        final writeReq = CipRequest(
          service: kCipServiceWriteTag,
          path: [CipPathSegment.symbol('SimOut')],
          data: _writeData(kCipTypeInt, encodeCipValue(kCipTypeInt, 321)!),
        );
        final writeResp = dispatchCipService(project, map, writeReq);
        expect(writeResp.generalStatus, kCipStatusSuccess,
            reason: 'a deliberate ReadWrite override on a SimulatedOutput tag must still write');

        final readReq = CipRequest(
          service: kCipServiceReadTag,
          path: [CipPathSegment.symbol('SimOut')],
          data: _readData(),
        );
        final readResp = dispatchCipService(project, map, readReq);
        expect(decodeCipValue(kCipTypeInt, readResp.data.sublist(2)), 321);
      });

      test('a normal Internal ReadWrite tag still writes successfully — the backstop is not over-broad', () {
        final project = buildProject();
        final map = buildMap();
        final writeReq = CipRequest(
          service: kCipServiceWriteTag,
          path: [CipPathSegment.symbol('Int16_Tag')],
          data: _writeData(kCipTypeInt, encodeCipValue(kCipTypeInt, 4321)!),
        );
        final writeResp = dispatchCipService(project, map, writeReq);
        expect(writeResp.generalStatus, kCipStatusSuccess);
        expect(readPath(project, 'Int16_Tag'), 4321);
      });
    });
  });

  group('Multiple Service Packet (0x0A)', () {
    final routerPath = [CipPathSegment.classId(0x02), CipPathSegment.instanceId(0x01)];

    test('two embedded Read Tag requests return both replies in order', () {
      final project = buildProject();
      final map = buildMap();

      final req0 = _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Bool_Tag')], _readData());
      final req1 = _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Int32_Tag')], _readData());
      const offsetListStart = 2;
      // Offsets are relative to offsetListStart; the embedded requests begin
      // right after the (2-entry, 4-byte) offset list itself.
      final offsets = [4, 4 + req0.length];
      final data = Uint8List.fromList([
        ..._u16le(2),
        ..._u16le(offsets[0]),
        ..._u16le(offsets[1]),
        ...req0,
        ...req1,
      ]);

      final resp = dispatchCipService(
        project,
        map,
        CipRequest(service: kCipServiceMultipleServicePacket, path: routerPath, data: data),
      );
      expect(resp.generalStatus, kCipStatusSuccess);

      final count = _readU16(resp.data, 0);
      expect(count, 2);
      final off0 = _readU16(resp.data, 2);
      final off1 = _readU16(resp.data, 4);
      final body0 = resp.data.sublist(offsetListStart + off0, offsetListStart + off1);
      final body1 = resp.data.sublist(offsetListStart + off1);

      expect(body0[0], kCipServiceReadTag | 0x80);
      expect(body0[2], kCipStatusSuccess);
      expect(_readU16(body0, 4), kCipTypeBool);
      expect(decodeCipValue(kCipTypeBool, body0.sublist(6)), true); // Bool_Tag's fixture value

      expect(body1[0], kCipServiceReadTag | 0x80);
      expect(body1[2], kCipStatusSuccess);
      expect(_readU16(body1, 4), kCipTypeDint);
      expect(decodeCipValue(kCipTypeDint, body1.sublist(6)), 98765); // Int32_Tag's fixture value

      // Fix 2 regression: exact reply length. header(2) + offset list
      // (count * 2 = 4) + body0 (4-byte CIP response header + 2-byte type +
      // 1-byte BOOL = 7) + body1 (4-byte header + 2-byte type + 4-byte DINT
      // = 10) = 23. The pre-fix allocation counted the 4-byte offset list
      // TWICE (`2 + count * 2 + cursor` where `cursor` already included
      // `count * 2`), producing a 27-byte reply — 4 trailing junk bytes
      // appended after body1, which `body1`'s own bounded slice above can't
      // catch because `resp.data.sublist(offsetListStart + off1)` runs to
      // whatever `resp.data.length` happens to be.
      expect(resp.data.length, 23);
    });

    test('one bad embedded request does not fail the batch — the good one still returns its data', () {
      final project = buildProject();
      final map = buildMap();

      // First: a good read. Second: an unexposed/unknown tag -> 0x05.
      final goodReq = _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Bool_Tag')], _readData());
      final badReq = _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Ghost_Tag')], _readData());
      // Offsets are relative to the offset-list start; the embedded requests
      // begin right after the (2-entry, 4-byte) offset list itself.
      final offsets = [4, 4 + goodReq.length];
      final data = Uint8List.fromList([
        ..._u16le(2),
        ..._u16le(offsets[0]),
        ..._u16le(offsets[1]),
        ...goodReq,
        ...badReq,
      ]);

      final resp = dispatchCipService(
        project,
        map,
        CipRequest(service: kCipServiceMultipleServicePacket, path: routerPath, data: data),
      );
      // The envelope itself parsed fine; per-item statuses carry the failure.
      expect(resp.generalStatus, kCipStatusSuccess);

      final count = _readU16(resp.data, 0);
      expect(count, 2);
      final off0 = _readU16(resp.data, 2);
      final off1 = _readU16(resp.data, 4);
      final body0 = resp.data.sublist(2 + off0, 2 + off1);
      final body1 = resp.data.sublist(2 + off1);

      expect(body0[2], kCipStatusSuccess);
      expect(_readU16(body0, 4), kCipTypeBool);
      expect(body0.sublist(6), [0xFF]); // Bool_Tag == true

      expect(body1[2], kCipStatusPathDestinationUnknown);
    });

    test('a request not addressed to the Message Router object is rejected, never throws', () {
      final project = buildProject();
      final map = buildMap();
      late CipResponse resp;
      expect(
        () => resp = dispatchCipService(
          project,
          map,
          CipRequest(
            service: kCipServiceMultipleServicePacket,
            path: [CipPathSegment.symbol('Not_The_Router')],
            data: _u16le(0),
          ),
        ),
        returnsNormally,
      );
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
    });

    test('a malformed envelope (declared count exceeds available offset bytes) never throws', () {
      final project = buildProject();
      final map = buildMap();
      late CipResponse resp;
      final data = Uint8List.fromList([..._u16le(5), 0x00, 0x00]); // count=5 but no offsets follow
      expect(
        () => resp = dispatchCipService(
          project,
          map,
          CipRequest(service: kCipServiceMultipleServicePacket, path: routerPath, data: data),
        ),
        returnsNormally,
      );
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
    });
  });

  group('Multiple Service Packet connection-size budget', () {
    final routerPath = [CipPathSegment.classId(0x02), CipPathSegment.instanceId(0x01)];

    test('a connected batch over a 500-byte connection is trimmed to <= 500 bytes; over-budget items carry 0x11; UCMM is unbounded', () {
      final project = buildProject();
      final map = buildMap();
      // 50 embedded Read Tag requests for an 8-byte LINT tag: each success
      // reply body is 14 bytes, so the whole unbounded reply is ~806 bytes
      // (the audit measured ~792 for its own fill) — far over 500.
      final embedded = List.generate(
        50,
        (_) => _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Int64_Tag')], _readData()),
      );
      final data = _buildMsp(embedded);
      final req = CipRequest(service: kCipServiceMultipleServicePacket, path: routerPath, data: data);

      // Unconnected (UCMM / no budget): unchanged and unbounded — every item
      // succeeds and the reply exceeds 500 bytes.
      final unbounded = dispatchCipService(project, map, req);
      expect(unbounded.generalStatus, kCipStatusSuccess);
      expect(buildCipResponse(unbounded).length, greaterThan(500));
      expect(_readU16(unbounded.data, 0), 50);
      final uOffLast = _readU16(unbounded.data, 2 + (50 - 1) * 2);
      expect(unbounded.data.sublist(2 + uOffLast)[2], kCipStatusSuccess);

      // Connected over a 500-byte connection: the emitted CIP response must fit
      // the negotiated connection size.
      final bounded = dispatchCipService(project, map, req, responseBudget: 500);
      expect(bounded.generalStatus, kCipStatusSuccess);
      final replyLen = buildCipResponse(bounded).length;
      expect(replyLen, lessThanOrEqualTo(500));
      expect(replyLen, greaterThan(400)); // not trivially empty
      // The reply's item count still matches the request's — no item dropped.
      expect(_readU16(bounded.data, 0), 50);
      // The first item still succeeds; the last (over-budget) item is 0x11.
      final off0 = _readU16(bounded.data, 2);
      expect(bounded.data.sublist(2 + off0)[2], kCipStatusSuccess);
      final offLast = _readU16(bounded.data, 2 + (50 - 1) * 2);
      expect(bounded.data.sublist(2 + offLast)[2], kCipStatusReplyDataTooLarge);
    });

    test('a connected batch that fits the budget is byte-identical to the unbudgeted reply', () {
      final project = buildProject();
      final map = buildMap();
      final req0 = _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Bool_Tag')], _readData());
      final req1 = _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Int32_Tag')], _readData());
      final data = _buildMsp([req0, req1]);
      final req = CipRequest(service: kCipServiceMultipleServicePacket, path: routerPath, data: data);

      final unbounded = dispatchCipService(project, map, req);
      final bounded = dispatchCipService(project, map, req, responseBudget: 500);

      expect(bounded.generalStatus, unbounded.generalStatus);
      expect(bounded.data, unbounded.data); // exact same bytes under budget
      expect(unbounded.data.length, 23); // matches the exact-length test above
    });

    test('the reply-cursor guard refuses a batch whose cursor reaches 0xFFFF - 5 (u16 offset-frame tighten)', () {
      // Two 1-char-named tags so each embedded request (8 bytes) is SMALLER
      // than its reply body, letting the reply cursor grow to the u16 boundary
      // before the request-side offsets (also u16) would overflow. 4090 LINT
      // reads (body 14) + 9 INT reads (body 8):
      //   cursor = count*2 + sum(bodies)
      //          = 4099*2 + (4090*14 + 9*8) = 8198 + 57332 = 65530 = 0xFFFF - 5
      // The pre-tighten guard (`cursor > 0xFFFF`) admitted 65530; the tightened
      // guard (`cursor > 0xFFFF - 6`) refuses it, because the emitted CIP
      // response is `cursor + 6` bytes and would otherwise be self-inconsistent.
      final project = PlcProject(
        id: 'cip_u16',
        name: 'u16',
        controllerName: 'PLC',
        tags: [
          PlcTag(name: 'A', path: 'A', dataType: 'INT64', value: 1, ioType: 'Internal'),
          PlcTag(name: 'B', path: 'B', dataType: 'INT16', value: 1, ioType: 'Internal'),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );
      final map = CipMap(entries: [
        CipMapEntry(tagName: 'A', access: 'ReadWrite'),
        CipMapEntry(tagName: 'B', access: 'ReadWrite'),
      ]);
      final embedded = <Uint8List>[
        for (var i = 0; i < 4090; i++)
          _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('A')], _readData()),
        for (var i = 0; i < 9; i++)
          _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('B')], _readData()),
      ];
      final data = _buildMsp(embedded);
      // Unbounded (no budget): the u16 reply-cursor guard alone decides.
      final resp = dispatchCipService(
        project,
        map,
        CipRequest(service: kCipServiceMultipleServicePacket, path: routerPath, data: data),
      );
      expect(resp.generalStatus, kCipStatusEmbeddedListError);
    });
  });

  group('non-throwing contract', () {
    test('an unrecognized service code returns 0x08 (service not supported), never throws', () {
      final project = buildProject();
      final map = buildMap();
      late CipResponse resp;
      expect(
        () => resp = dispatchCipService(
          project,
          map,
          CipRequest(service: 0x99, path: const [], data: Uint8List(0)),
        ),
        returnsNormally,
      );
      expect(resp.generalStatus, kCipStatusServiceNotSupported);
    });

    test('a Read Tag request with an empty path returns an error, never throws', () {
      final project = buildProject();
      final map = buildMap();
      late CipResponse resp;
      expect(
        () => resp = dispatchCipService(
          project,
          map,
          CipRequest(service: kCipServiceReadTag, path: const [], data: _readData()),
        ),
        returnsNormally,
      );
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
    });
  });
}
