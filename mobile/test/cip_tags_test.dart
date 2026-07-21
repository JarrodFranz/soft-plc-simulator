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

/// Wraps [embedded] (a raw CIP request's bytes) in a CIP Unconnected Send
/// (0x52) request data payload, mirroring pycomm3's `wrap_unconnected_send`:
/// priority u8, timeout u8, embedded-message size u16, the embedded bytes, one
/// 0x00 pad byte iff the size is odd, then the route path (size u8 words +
/// reserved u8 + [routePathWords]). Default route path is a single port
/// segment (port 1) — the host ignores it, but a realistic wrapper carries one.
Uint8List _wrapUnconnectedSend(Uint8List embedded, {List<int> routePathWords = const [0x01, 0x00]}) {
  final out = BytesBuilder();
  out.addByte(0x0a); // priority / time_tick
  out.addByte(0x05); // timeout ticks
  out.add(_u16le(embedded.length));
  out.add(embedded);
  if (embedded.length.isOdd) {
    out.addByte(0x00); // pad so the route path starts on a word boundary
  }
  out.addByte(routePathWords.length ~/ 2); // route path size, in 16-bit words
  out.addByte(0x00); // reserved
  out.add(routePathWords);
  return out.toBytes();
}

/// A small fixture for the Symbol Object browse routing tests, mirroring
/// Task 1's `buildProject()` / `buildMap()` in `cip_symbol_test.dart`: three
/// scalar leaves, each a flat atomic symbol the browse enumerates.
PlcProject _browseProject() => PlcProject(
      id: 'browse_proj',
      name: 'browse',
      controllerName: 'PLC',
      tags: [
        PlcTag(name: 'Running', path: 'Internal.Running', dataType: 'BOOL', value: true, ioType: 'Internal'),
        PlcTag(name: 'Speed', path: 'Internal.Speed', dataType: 'INT32', value: 100, ioType: 'Internal'),
        PlcTag(name: 'Level', path: 'Internal.Level', dataType: 'FLOAT64', value: 1.5, ioType: 'Internal'),
      ],
      structDefs: [],
      programs: [],
      tasks: [],
      hmis: [],
    );

CipMap _browseMap() => CipMap(entries: [
      CipMapEntry(tagName: 'Running', access: 'ReadWrite'),
      CipMapEntry(tagName: 'Speed', access: 'ReadWrite'),
      CipMapEntry(tagName: 'Level', access: 'ReadWrite'),
    ]);

void main() {
  _diagnosticsTests();
  _getAttributeListTests();

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

  group('dispatchCipService — Symbol Object browse routing', () {
    test('0x55 addressed to class 0x6B returns a Symbol instance list', () {
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(kCipSymbolObjectClassId), CipPathSegment.instanceId(0)],
        data: Uint8List.fromList([0x02, 0x00, 0x01, 0x00, 0x02, 0x00]),
      );
      final resp = dispatchCipService(_browseProject(), _browseMap(), req);
      expect(resp.service, kCipServiceGetInstanceAttributeList);
      expect(resp.generalStatus, anyOf(kCipStatusSuccess, kCipStatusPartialTransfer));
      expect(resp.data, isNotEmpty);
    });

    test('0x55 addressed to a non-Symbol class is Service Not Supported', () {
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(0x04), CipPathSegment.instanceId(0)],
        data: Uint8List.fromList([0x01, 0x00, 0x01, 0x00]),
      );
      final resp = dispatchCipService(_browseProject(), _browseMap(), req);
      expect(resp.generalStatus, kCipStatusServiceNotSupported);
    });
  });

  group('dispatchCipService — Unconnected Send (0x52) transparent wrapper', () {
    test('unwraps and dispatches the embedded request, returning its response verbatim', () {
      final project = buildProject();
      final map = buildMap();
      final embedded = _embeddedRequest(
          kCipServiceReadTag, [CipPathSegment.symbol('Int32_Tag')], _readData());
      final wrapped = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        data: _wrapUnconnectedSend(embedded),
      );
      final viaWrapper = dispatchCipService(project, map, wrapped);
      // Transparent: byte-identical to dispatching the embedded request
      // directly as UCMM — no wrapper is added to the reply.
      final direct = dispatchCipService(buildProject(), buildMap(), parseCipRequest(embedded)!);
      expect(viaWrapper.service, kCipServiceReadTag);
      expect(viaWrapper.service, direct.service);
      expect(viaWrapper.generalStatus, kCipStatusSuccess);
      expect(viaWrapper.data, direct.data);
      // The embedded Read actually round-tripped: type DINT + value 98765.
      expect(_readU16(viaWrapper.data, 0), kCipTypeDint);
      expect(ByteData.sublistView(viaWrapper.data, 2, 6).getInt32(0, Endian.little), 98765);
    });

    test('carries an embedded Identity Get Attributes All through unchanged', () {
      final embedded = _embeddedRequest(
        kCipServiceGetAttributesAll,
        [CipPathSegment.classId(kCipIdentityObjectClassId), CipPathSegment.instanceId(1)],
        Uint8List(0),
      );
      final wrapped = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        data: _wrapUnconnectedSend(embedded),
      );
      final resp = dispatchCipService(buildProject(), buildMap(), wrapped);
      expect(resp.service, kCipServiceGetAttributesAll);
      expect(resp.generalStatus, kCipStatusSuccess);
      expect(_readU16(resp.data, 0), 0); // Vendor ID 0 (honest, no vendor).
      expect(_readU16(resp.data, 2), 0x000E); // Device Type: PLC.
    });

    test('an odd-length embedded message (route path preceded by a pad byte) is parsed exactly', () {
      // 3-byte embedded data makes the embedded request odd-length, so the
      // wrapper inserts a pad byte before the route path. The host must read
      // exactly `size` bytes and never let the pad/route-path bleed in.
      final embedded = _embeddedRequest(
          kCipServiceReadTag, [CipPathSegment.symbol('Int32_Tag')], Uint8List.fromList([1, 0, 0]));
      expect(embedded.length.isOdd, isTrue);
      final wrapped = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        data: _wrapUnconnectedSend(embedded),
      );
      final resp = dispatchCipService(buildProject(), buildMap(), wrapped);
      expect(resp.service, kCipServiceReadTag);
      expect(resp.generalStatus, kCipStatusSuccess);
      expect(_readU16(resp.data, 0), kCipTypeDint);
    });

    test('a wrapper addressed to a non-Connection-Manager class is refused, never throws', () {
      final embedded = _embeddedRequest(
          kCipServiceReadTag, [CipPathSegment.symbol('Int32_Tag')], _readData());
      final wrapped = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(0x02), CipPathSegment.instanceId(1)], // Message Router, not Conn Mgr
        data: _wrapUnconnectedSend(embedded),
      );
      late CipResponse resp;
      expect(() => resp = dispatchCipService(buildProject(), buildMap(), wrapped), returnsNormally);
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
    });

    test('a nested Unconnected Send (0x52 inside 0x52) is rejected, never deep-recurses or throws', () {
      // Craft a 0x52 whose embedded request is ANOTHER 0x52. Re-dispatch routes
      // 0x52 back into the handler, so without a guard a nested frame would
      // recurse once per level (a resource-exhaustion DoS). The handler must
      // reject the nested wrapper with an error status at exactly one level.
      final innerReal = _embeddedRequest(
          kCipServiceReadTag, [CipPathSegment.symbol('Int32_Tag')], _readData());
      final inner52 = _embeddedRequest(
        kCipServiceUnconnectedSend,
        [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        _wrapUnconnectedSend(innerReal),
      );
      final wrapped = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        data: _wrapUnconnectedSend(inner52),
      );
      late CipResponse resp;
      expect(() => resp = dispatchCipService(buildProject(), buildMap(), wrapped), returnsNormally);
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
      expect(resp.generalStatus, kCipStatusServiceNotSupported);
    });

    test('a malformed wrapper (declared embedded size exceeds the data) returns an error, never throws', () {
      // Header claims a 200-byte embedded message but only a few bytes follow.
      final data = Uint8List.fromList([0x0a, 0x05, 0xC8, 0x00, 0x01, 0x02]);
      final wrapped = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        data: data,
      );
      late CipResponse resp;
      expect(() => resp = dispatchCipService(buildProject(), buildMap(), wrapped), returnsNormally);
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
    });

    test('an embedded request that itself fails only sets THAT status, still no throw', () {
      // Embedded read of an unmapped tag → 0x05 comes back through the wrapper
      // verbatim (the wrapper is transparent, not a batch that could fail).
      final embedded = _embeddedRequest(
          kCipServiceReadTag, [CipPathSegment.symbol('Unexposed_Tag')], _readData());
      final wrapped = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        data: _wrapUnconnectedSend(embedded),
      );
      final resp = dispatchCipService(buildProject(), buildMap(), wrapped);
      expect(resp.service, kCipServiceReadTag);
      expect(resp.generalStatus, kCipStatusPathDestinationUnknown);
    });
  });

  group('Fix 1: embedded re-dispatch depth cap (0x52 <-> 0x0A cycle)', () {
    final routerPath = [CipPathSegment.classId(0x02), CipPathSegment.instanceId(0x01)];
    final connMgrPath = [
      CipPathSegment.classId(kCipConnectionManagerClassId),
      CipPathSegment.instanceId(1),
    ];

    /// A leaf Read Tag embedded-request byte blob.
    Uint8List leafRead() =>
        _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Int32_Tag')], _readData());

    /// Wraps [inner] request bytes in an Unconnected Send (0x52) embedded request.
    Uint8List wrap52(Uint8List inner) =>
        _embeddedRequest(kCipServiceUnconnectedSend, connMgrPath, _wrapUnconnectedSend(inner));

    /// Wraps [inner] request bytes in a single-item Multiple Service Packet (0x0A)
    /// embedded request.
    Uint8List wrap0A(Uint8List inner) =>
        _embeddedRequest(kCipServiceMultipleServicePacket, routerPath, _buildMsp([inner]));

    test(
        'a 0x52 -> 0x0A -> 0x52 -> ... interleaved frame far deeper than the cap '
        'never throws and never deep-recurses', () {
      // Build from the leaf outward, alternating MSP (0x0A) and Unconnected Send
      // (0x52) so re-dispatch bounces through the 0x52 <-> 0x0A cycle the depth
      // counter exists to bound. 40 wraps is far past cap 8; with the cap, the
      // dispatch only ever recurses 8 levels deep no matter how deep the frame.
      var inner = leafRead();
      for (var level = 0; level < 40; level++) {
        inner = level.isEven ? wrap0A(inner) : wrap52(inner);
      }
      // After 40 wraps (last is odd -> wrap52) the outermost blob is a 0x52.
      final top = parseCipRequest(inner)!;
      expect(top.service, kCipServiceUnconnectedSend);

      late CipResponse resp;
      expect(() => resp = dispatchCipService(buildProject(), buildMap(), top), returnsNormally);
      // The outer 0x52 is a transparent wrapper around a 0x0A whose envelope
      // parses fine, so the top-level general status is success — the depth
      // guard fired deep inside and its error is carried in a nested embedded
      // body (an MSP never fails its envelope for a bad item). What this proves
      // is bounded recursion: the call RETURNS instead of overflowing the stack.
      expect(resp.generalStatus, kCipStatusSuccess);
    });

    test('the depth guard refuses either recursive service AT the cap with an error status', () {
      // depth is additive, so a caller can drive it directly. At depth == cap,
      // BOTH recursive services are refused with an error general status rather
      // than recursing.
      final send52 = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: connMgrPath,
        data: _wrapUnconnectedSend(leafRead()),
      );
      final mspReq = CipRequest(
        service: kCipServiceMultipleServicePacket,
        path: routerPath,
        data: _buildMsp([leafRead()]),
      );

      late CipResponse resp52;
      expect(
        () => resp52 = dispatchCipService(buildProject(), buildMap(), send52, depth: kMaxEmbeddedDispatchDepth),
        returnsNormally,
      );
      expect(resp52.generalStatus, kCipStatusServiceNotSupported);

      late CipResponse respMsp;
      expect(
        () => respMsp = dispatchCipService(buildProject(), buildMap(), mspReq, depth: kMaxEmbeddedDispatchDepth),
        returnsNormally,
      );
      expect(respMsp.generalStatus, kCipStatusServiceNotSupported);

      // One below the cap still processes normally: the 0x52 unwraps its leaf
      // read at depth cap-1 and the embedded read (not recursive) succeeds.
      final resp52Ok =
          dispatchCipService(buildProject(), buildMap(), send52, depth: kMaxEmbeddedDispatchDepth - 1);
      expect(resp52Ok.service, kCipServiceReadTag);
      expect(resp52Ok.generalStatus, kCipStatusSuccess);
    });

    test('a legit 0x52 wrapping a 0x0A of leaf reads still succeeds (cap must not break 2-level nesting)', () {
      // The real LogixDriver path: Unconnected Send (depth 0) wrapping a Multiple
      // Service Packet (depth 1) of leaf reads (depth 2) — all below cap 8. Cap 1
      // would have broken this; cap 8 leaves it untouched.
      final read0 = _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Bool_Tag')], _readData());
      final read1 = _embeddedRequest(kCipServiceReadTag, [CipPathSegment.symbol('Int32_Tag')], _readData());
      final msp = _embeddedRequest(kCipServiceMultipleServicePacket, routerPath, _buildMsp([read0, read1]));
      final top = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: connMgrPath,
        data: _wrapUnconnectedSend(msp),
      );
      final resp = dispatchCipService(buildProject(), buildMap(), top);
      // Transparent 0x52 -> the MSP reply verbatim; envelope success, both items
      // succeed.
      expect(resp.service, kCipServiceMultipleServicePacket);
      expect(resp.generalStatus, kCipStatusSuccess);
      expect(_readU16(resp.data, 0), 2);
      final off0 = _readU16(resp.data, 2);
      final off1 = _readU16(resp.data, 4);
      final body0 = resp.data.sublist(2 + off0, 2 + off1);
      final body1 = resp.data.sublist(2 + off1);
      expect(body0[2], kCipStatusSuccess);
      expect(body1[2], kCipStatusSuccess);
    });
  });

  group('dispatchCipService — Program Name Object (0x64) Get Attributes All', () {
    test('returns the controller name as a Logix STRING (u16 len + ascii)', () {
      final project = buildProject(); // controllerName: 'PLC_CIP_TAGS'
      final req = CipRequest(
        service: kCipServiceGetAttributesAll,
        path: [CipPathSegment.classId(kCipProgramNameObjectClassId), CipPathSegment.instanceId(1)],
        data: Uint8List(0),
      );
      final resp = dispatchCipService(project, buildMap(), req);
      expect(resp.service, kCipServiceGetAttributesAll);
      expect(resp.generalStatus, kCipStatusSuccess);
      const expected = 'PLC_CIP_TAGS';
      expect(_readU16(resp.data, 0), expected.length);
      expect(String.fromCharCodes(resp.data.sublist(2, 2 + expected.length)), expected);
      expect(resp.data.length, 2 + expected.length);
    });

    test('Get Attributes All on an unhandled class is Service Not Supported', () {
      final req = CipRequest(
        service: kCipServiceGetAttributesAll,
        path: [CipPathSegment.classId(0x77), CipPathSegment.instanceId(1)],
        data: Uint8List(0),
      );
      final resp = dispatchCipService(buildProject(), buildMap(), req);
      expect(resp.generalStatus, kCipStatusServiceNotSupported);
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

void _diagnosticsTests() {
  group('describeCipRequest (Logs diagnostics)', () {
    test('a plain service names the target class', () {
      final req = CipRequest(
        service: kCipServiceGetAttributesAll,
        path: [CipPathSegment.classId(kCipIdentityObjectClassId), CipPathSegment.instanceId(1)],
        data: Uint8List(0),
      );
      expect(describeCipRequest(req), 'service 0x01 to class 0x01');
    });

    test('an Unconnected Send decodes the EMBEDDED service + class it wraps', () {
      // Embedded: Get Attributes All (0x01) to Identity (class 0x01), instance 1.
      final embedded = <int>[0x01, 0x02, 0x20, 0x01, 0x24, 0x01];
      final wrapper = <int>[
        0x0A, 0x05, // priority/tick, timeout_ticks
        embedded.length, 0x00, // embedded message size (u16 LE)
        ...embedded,
        0x01, 0x00, 0x01, 0x00, // route path size(1 word) + reserved + path
      ];
      final req = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        data: Uint8List.fromList(wrapper),
      );
      expect(describeCipRequest(req), 'Unconnected Send (0x52) wrapping service 0x01 to class 0x01');
    });

    test('an Unconnected Send with an unparseable embedded request says so, never throws', () {
      final req = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId)],
        data: Uint8List.fromList([0x0A, 0x05, 0x40, 0x00]), // size 0x40 but no embedded bytes
      );
      expect(describeCipRequest(req), 'Unconnected Send (0x52) wrapping an unparseable embedded request');
    });
  });
}

void _getAttributeListTests() {
  // A minimal project — Get Attribute List for Identity/0xAC ignores the tag DB.
  PlcProject proj() => PlcProject(
        id: 'gal', name: 'gal', controllerName: 'PLC',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
      );
  CipMap emptyMap() => CipMap(entries: []);

  group('Get Attribute List (0x03)', () {
    test('Identity (class 0x01) returns the requested attributes with honest values', () {
      // Request attrs 1 (Vendor ID) and 4 (Revision).
      final req = CipRequest(
        service: kCipServiceGetAttributeList,
        path: [CipPathSegment.classId(kCipIdentityObjectClassId), CipPathSegment.instanceId(1)],
        data: Uint8List.fromList([0x02, 0x00, 0x01, 0x00, 0x04, 0x00]),
      );
      final resp = dispatchCipService(proj(), emptyMap(), req);
      expect(resp.generalStatus, kCipStatusSuccess);
      final d = resp.data;
      // count == 2
      expect(ByteData.sublistView(d, 0, 2).getUint16(0, Endian.little), 2);
      // attr 1: id, status 0, Vendor ID u16 == 0 (honest, non-impersonating).
      expect(ByteData.sublistView(d, 2, 4).getUint16(0, Endian.little), 1);
      expect(ByteData.sublistView(d, 4, 6).getUint16(0, Endian.little), kCipStatusSuccess);
      expect(ByteData.sublistView(d, 6, 8).getUint16(0, Endian.little), 0);
      // attr 4: id, status 0, Revision major.minor == 1.1 (2 bytes).
      expect(ByteData.sublistView(d, 8, 10).getUint16(0, Endian.little), 4);
      expect(ByteData.sublistView(d, 10, 12).getUint16(0, Endian.little), kCipStatusSuccess);
      expect(d[12], 1);
      expect(d[13], 1);
    });

    test('Identity: an unknown attribute id is reported per-attribute as 0x14, not a blanket failure', () {
      final req = CipRequest(
        service: kCipServiceGetAttributeList,
        path: [CipPathSegment.classId(kCipIdentityObjectClassId), CipPathSegment.instanceId(1)],
        data: Uint8List.fromList([0x01, 0x00, 0x63, 0x00]), // attr 0x63 (unknown)
      );
      final resp = dispatchCipService(proj(), emptyMap(), req);
      expect(resp.generalStatus, kCipStatusSuccess);
      expect(ByteData.sublistView(resp.data, 0, 2).getUint16(0, Endian.little), 1);
      expect(ByteData.sublistView(resp.data, 2, 4).getUint16(0, Endian.little), 0x63);
      expect(ByteData.sublistView(resp.data, 4, 6).getUint16(0, Endian.little),
          kCipStatusAttributeNotSupported);
    });

    test('class 0xAC change-detection returns the DOCUMENTED attribute widths (INT/INT/DINT/DINT/DINT)', () {
      // Per Rockwell 1756-PM020: attrs 1,2 are INT (2B); attrs 3,4,10 are DINT
      // (4B). A Logix SCADA driver (Ignition) reads {1,2,3,4,10}; a wrong width
      // walks its parser off the end. Request the 5 documented attrs.
      final req = CipRequest(
        service: kCipServiceGetAttributeList,
        path: [CipPathSegment.classId(0xAC), CipPathSegment.instanceId(1)],
        data: Uint8List.fromList([0x05, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x0A, 0x00]),
      );
      // A project + map with 3 listable tags so the symbol count is a known 3.
      final project = PlcProject(
        id: 'p', name: 'p', controllerName: 'PLC',
        tags: [
          PlcTag(name: 'A', path: 'Internal.A', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'B', path: 'Internal.B', dataType: 'INT32', value: 0, ioType: 'Internal'),
          PlcTag(name: 'C', path: 'Internal.C', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [],
      );
      final map = CipMap(entries: [
        CipMapEntry(tagName: 'A'), CipMapEntry(tagName: 'B'), CipMapEntry(tagName: 'C'),
      ]);
      final resp = dispatchCipService(project, map, req);
      expect(resp.generalStatus, kCipStatusSuccess);
      final d = resp.data;
      // count == 5 (one tuple per requested attribute).
      expect(ByteData.sublistView(d, 0, 2).getUint16(0, Endian.little), 5);
      // attr 1 (INT, 2B) = symbol count 3, status success.
      var off = 2;
      expect(ByteData.sublistView(d, off, off + 2).getUint16(0, Endian.little), 1);
      expect(ByteData.sublistView(d, off + 2, off + 4).getUint16(0, Endian.little), kCipStatusSuccess);
      expect(ByteData.sublistView(d, off + 4, off + 6).getUint16(0, Endian.little), 3);
      off += 6; // 2(id)+2(status)+2(INT value)
      // attr 2 (INT, 2B) = template count 0.
      expect(ByteData.sublistView(d, off, off + 2).getUint16(0, Endian.little), 2);
      expect(ByteData.sublistView(d, off + 4, off + 6).getUint16(0, Endian.little), 0);
      off += 6;
      // attr 3 (DINT, 4B): a nonzero directory hash.
      expect(ByteData.sublistView(d, off, off + 2).getUint16(0, Endian.little), 3);
      final hash3 = ByteData.sublistView(d, off + 4, off + 8).getUint32(0, Endian.little);
      expect(hash3, isNot(0));
      off += 8; // 2+2+4(DINT)
      // attr 4 (DINT, 4B) == attr 3's hash.
      expect(ByteData.sublistView(d, off, off + 2).getUint16(0, Endian.little), 4);
      expect(ByteData.sublistView(d, off + 4, off + 8).getUint32(0, Endian.little), hash3);
      off += 8;
      // attr 10 (DINT, 4B): the distinct second hash.
      expect(ByteData.sublistView(d, off, off + 2).getUint16(0, Endian.little), 10);
      expect(ByteData.sublistView(d, off + 4, off + 8).getUint32(0, Endian.little), hash3 ^ 0xFFFFFFFF);
      off += 8;
      // Total length: count(2) + INT tuple(6)*2 + DINT tuple(8)*3 = 2+12+24 = 38.
      expect(d.length, 38);
      expect(off, 38);
    });

    test('class 0xAC change-detection hash is STABLE for an unchanged directory but CHANGES when a tag changes', () {
      CipRequest req() => CipRequest(
            service: kCipServiceGetAttributeList,
            path: [CipPathSegment.classId(0xAC), CipPathSegment.instanceId(1)],
            data: Uint8List.fromList([0x01, 0x00, 0x03, 0x00]), // attr 3 (the DINT hash)
          );
      PlcProject projectWith(String secondTagType) => PlcProject(
            id: 'p', name: 'p', controllerName: 'PLC',
            tags: [
              PlcTag(name: 'A', path: 'Internal.A', dataType: 'INT32', value: 0, ioType: 'Internal'),
              PlcTag(name: 'B', path: 'Internal.B', dataType: secondTagType, value: 0, ioType: 'Internal'),
            ],
            structDefs: [], programs: [], tasks: [], hmis: [],
          );
      final map = CipMap(entries: [CipMapEntry(tagName: 'A'), CipMapEntry(tagName: 'B')]);
      int hashOf(PlcProject p) {
        final d = dispatchCipService(p, map, req()).data;
        return ByteData.sublistView(d, 6, 10).getUint32(0, Endian.little);
      }

      final h1 = hashOf(projectWith('INT32'));
      final h1again = hashOf(projectWith('INT32'));
      final h2 = hashOf(projectWith('FLOAT64')); // B re-typed
      expect(h1, h1again, reason: 'same directory -> identical hash (no false change)');
      expect(h1, isNot(h2), reason: 're-typing a tag must change the hash so the client re-browses');
    });

    test('a malformed request (count claims more ids than present) returns an error, never throws', () {
      final req = CipRequest(
        service: kCipServiceGetAttributeList,
        path: [CipPathSegment.classId(kCipIdentityObjectClassId)],
        data: Uint8List.fromList([0x04, 0x00, 0x01, 0x00]), // count 4 but 1 id
      );
      late CipResponse resp;
      expect(() => resp = dispatchCipService(proj(), emptyMap(), req), returnsNormally);
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
    });

    test('Ignition path: Get Attribute List wrapped in Unconnected Send is unwrapped and answered', () {
      // Embedded: 0x03 to Identity (class 0x01, instance 1), attrs [1].
      // service, pathWords=2 (class+instance = 4 bytes), path, then count+id.
      final embedded = <int>[0x03, 0x02, 0x20, 0x01, 0x24, 0x01, 0x01, 0x00, 0x01, 0x00];
      final wrapper = <int>[
        0x0A, 0x05, embedded.length, 0x00, ...embedded, 0x01, 0x00, 0x01, 0x00,
      ];
      final req = CipRequest(
        service: kCipServiceUnconnectedSend,
        path: [CipPathSegment.classId(kCipConnectionManagerClassId), CipPathSegment.instanceId(1)],
        data: Uint8List.fromList(wrapper),
      );
      final resp = dispatchCipService(proj(), emptyMap(), req);
      // Transparent unwrap: the embedded 0x03 reply comes back (service 0x03).
      expect(resp.service, kCipServiceGetAttributeList);
      expect(resp.generalStatus, kCipStatusSuccess);
      expect(ByteData.sublistView(resp.data, 0, 2).getUint16(0, Endian.little), 1); // count
    });
  });
}
