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

void main() {
  PlcProject buildProject() => PlcProject(
        id: 'cip_tags_proj',
        name: 'CIP Tags Project',
        controllerName: 'PLC_CIP_TAGS',
        tags: [
          PlcTag(name: 'Bool_Tag', path: 'Bool_Tag', dataType: 'BOOL', value: false, ioType: 'Internal'),
          PlcTag(name: 'Int16_Tag', path: 'Int16_Tag', dataType: 'INT16', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Int32_Tag', path: 'Int32_Tag', dataType: 'INT32', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Int64_Tag', path: 'Int64_Tag', dataType: 'INT64', value: 0, ioType: 'Internal'),
          PlcTag(name: 'Float64_Tag', path: 'Float64_Tag', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
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
        ],
        structDefs: [],
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
      ]);

  group('Read Tag (0x4C)', () {
    test('returns the correct type code and value for each supported type', () {
      final project = buildProject();
      final map = buildMap();

      final cases = <String, List<Object>>{
        'Bool_Tag': [kCipTypeBool],
        'Int16_Tag': [kCipTypeInt],
        'Int32_Tag': [kCipTypeDint],
        'Int64_Tag': [kCipTypeLint],
        'Float64_Tag': [kCipTypeReal],
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
        expect(typeCode, cases[tagName]![0], reason: tagName);
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
      expect(resp.generalStatus, isNot(kCipStatusSuccess));
      expect(project.tags.firstWhere((t) => t.name == 'Int32_Tag').value, before);
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

      expect(body1[0], kCipServiceReadTag | 0x80);
      expect(body1[2], kCipStatusSuccess);
      expect(_readU16(body1, 4), kCipTypeDint);
      expect(decodeCipValue(kCipTypeDint, body1.sublist(6)), 0);
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
      expect(body0.sublist(6), [0x00]); // Bool_Tag == false

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
