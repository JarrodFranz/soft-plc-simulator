import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/enip/cip.dart';
import 'package:soft_plc_mobile/protocols/enip/cip_symbol.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/cip_map.dart';

void main() {
  group('parseGetInstanceAttrListRequest', () {
    test('reads the start instance from the path and the attribute id list from data', () {
      // Path: Class 0x6B, Instance 0. Data: attr count 2, ids [1, 2].
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(kCipSymbolObjectClassId), CipPathSegment.instanceId(0)],
        data: Uint8List.fromList([0x02, 0x00, 0x01, 0x00, 0x02, 0x00]),
      );
      final parsed = parseGetInstanceAttrListRequest(req);
      expect(parsed, isNotNull);
      expect(parsed!.startInstance, 0);
      expect(parsed.attributeIds, [1, 2]);
    });

    test('defaults the start instance to 0 when the path has only a class segment', () {
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(kCipSymbolObjectClassId)],
        data: Uint8List.fromList([0x01, 0x00, 0x01, 0x00]),
      );
      final parsed = parseGetInstanceAttrListRequest(req);
      expect(parsed, isNotNull);
      expect(parsed!.startInstance, 0);
      expect(parsed.attributeIds, [1]);
    });

    test('returns null on a truncated attribute list (count claims more ids than present)', () {
      final req = CipRequest(
        service: kCipServiceGetInstanceAttributeList,
        path: [CipPathSegment.classId(kCipSymbolObjectClassId)],
        data: Uint8List.fromList([0x02, 0x00, 0x01, 0x00]), // count 2 but only 1 id
      );
      expect(parseGetInstanceAttrListRequest(req), isNull);
    });
  });

  // A project whose scalar leaves are exactly the map entries below.
  PlcProject buildProject() => PlcProject(
        id: 'p', name: 'p', controllerName: 'PLC',
        tags: [
          PlcTag(name: 'Running', path: 'Internal.Running', dataType: 'BOOL', value: true, ioType: 'Internal'),
          PlcTag(name: 'Speed', path: 'Internal.Speed', dataType: 'INT32', value: 100, ioType: 'Internal'),
          PlcTag(name: 'Level', path: 'Internal.Level', dataType: 'FLOAT64', value: 1.5, ioType: 'Internal'),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [],
      );

  CipMap buildMap() => CipMap(entries: [
        CipMapEntry(tagName: 'Running', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Speed', access: 'ReadWrite'),
        CipMapEntry(tagName: 'Level', access: 'ReadWrite'),
      ]);

  group('buildSymbolInstanceListResponse', () {
    test('emits instance id (u32) + name (u16 len + ascii) + type (u16) per entry, status 0x00 when all fit', () {
      const parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(buildProject(), buildMap(), parsed, replyBudget: 4096);
      expect(resp.generalStatus, kCipStatusSuccess);
      // First instance: id=1, name="Running" (7 bytes), type BOOL 0xC1.
      final d = resp.data;
      expect(ByteData.sublistView(d, 0, 4).getUint32(0, Endian.little), 1);
      expect(ByteData.sublistView(d, 4, 6).getUint16(0, Endian.little), 7); // name len
      expect(String.fromCharCodes(d.sublist(6, 13)), 'Running');
      expect(ByteData.sublistView(d, 13, 15).getUint16(0, Endian.little), kCipTypeBool);
    });

    test('a tiny budget returns only the instances that fit, with status 0x06 (partial)', () {
      const parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      // Budget only large enough for the first instance.
      final resp = buildSymbolInstanceListResponse(buildProject(), buildMap(), parsed, replyBudget: 20);
      expect(resp.generalStatus, kCipStatusPartialTransfer);
      // Only instance 1 present.
      expect(ByteData.sublistView(resp.data, 0, 4).getUint32(0, Endian.little), 1);
      expect(resp.data.length < 40, isTrue);
    });

    test('resuming from startInstance skips already-sent instances', () {
      const parsed = GetInstanceAttrListRequest(startInstance: 2, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(buildProject(), buildMap(), parsed, replyBudget: 4096);
      expect(resp.generalStatus, kCipStatusSuccess);
      // First returned instance id is 2 (Speed), not 1.
      expect(ByteData.sublistView(resp.data, 0, 4).getUint32(0, Endian.little), 2);
    });

    test('empty map returns status 0x00 and zero-length data', () {
      const parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(buildProject(), CipMap(entries: []), parsed, replyBudget: 4096);
      expect(resp.generalStatus, kCipStatusSuccess);
      expect(resp.data, isEmpty);
    });

    test('a dotted-name entry is listed verbatim as one flat symbol', () {
      // 'Tank' is an instance of struct type 'TankType', which has an INT32
      // field 'Level' — dataTypeOfPath resolves the dotted path 'Tank.Level'
      // by walking the root tag's dataType (the struct name) into its field
      // defs (see models/tag_resolver.dart's _rootTag + _field), not by
      // matching a flat tag whose own dataType happens to be a scalar.
      final proj = PlcProject(
        id: 'p', name: 'p', controllerName: 'PLC',
        tags: [PlcTag(name: 'Tank', path: 'Internal.Tank', dataType: 'TankType', value: 0, ioType: 'Internal')],
        structDefs: [
          PlcStructDef(name: 'TankType', fields: [
            StructFieldDef(name: 'Level', dataType: 'INT32', defaultValue: 0),
          ]),
        ],
        programs: [], tasks: [], hmis: [],
      );
      final tagMap = CipMap(entries: [CipMapEntry(tagName: 'Tank.Level', access: 'ReadWrite')]);
      const parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(proj, tagMap, parsed, replyBudget: 4096);
      // dataTypeOfPath resolves 'Tank.Level' to INT32; name is the dotted string.
      expect(ByteData.sublistView(resp.data, 4, 6).getUint16(0, Endian.little), 10); // "Tank.Level"
      expect(String.fromCharCodes(resp.data.sublist(6, 16)), 'Tank.Level');
    });
  });
}
