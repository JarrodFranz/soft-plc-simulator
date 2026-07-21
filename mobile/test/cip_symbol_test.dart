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

    test('serves the full LogixDriver attribute set {1,2,3,5,6,8} in ascending order, byte-exact', () {
      // pycomm3's LogixDriver.get_tag_list() requests attrs 1,2,3,5,6,8 and
      // parses each instance as: instance(u32), name(u16 len + ascii),
      // type(u16), symbol_address(u32), symbol_object_address(u32),
      // software_control(u32), dim1/dim2/dim3(u32). This asserts that exact
      // layout for the first instance (id=1, "Running", BOOL).
      const parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2, 3, 5, 6, 8]);
      final resp = buildSymbolInstanceListResponse(buildProject(), buildMap(), parsed, replyBudget: 4096);
      expect(resp.generalStatus, kCipStatusSuccess);
      final d = resp.data;
      var off = 0;
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 1); // instance id
      off += 4;
      expect(ByteData.sublistView(d, off, off + 2).getUint16(0, Endian.little), 7); // name len
      off += 2;
      expect(String.fromCharCodes(d.sublist(off, off + 7)), 'Running');
      off += 7;
      expect(ByteData.sublistView(d, off, off + 2).getUint16(0, Endian.little), kCipTypeBool); // attr 2
      off += 2;
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 0); // attr 3 symbol address
      off += 4;
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 0); // attr 5 object address
      off += 4;
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 1 << 26); // attr 6 BASE_TAG_BIT
      off += 4;
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 0); // attr 8 dim1
      off += 4;
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 0); // dim2
      off += 4;
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 0); // dim3
      off += 4;
      // Next instance (id=2, "Speed", DINT) begins immediately after — no
      // padding, no trailing attribute bytes leaked from instance 1.
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 2);
    });

    test('type attribute (attr 2) keeps bit 15 clear so a scalar reads as ATOMIC, never a struct', () {
      const parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(buildProject(), buildMap(), parsed, replyBudget: 4096);
      // instance 1 "Running" type field at offset 13 (4 id + 2 len + 7 name).
      final typeCode = ByteData.sublistView(resp.data, 13, 15).getUint16(0, Endian.little);
      expect(typeCode & 0x8000, 0); // bit 15 clear = atomic, not a template ref.
      expect(typeCode & 0xFF, kCipTypeBool); // low byte carries the CIP type.
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

    test('paginating with a small budget returns every listable entry exactly once', () {
      // Mirrors the REAL browse: pycomm3's LogixDriver.get_tag_list() requests
      // attrs {1,2,3,5,6,8} (see cip_symbol.dart), not a reduced {1,2} set, so
      // this test drives the actual per-instance byte cost the browse relies
      // on, not a smaller stand-in.
      final tags = [for (var i = 0; i < 10; i++)
          PlcTag(name: 'T$i', path: 'Internal.T$i', dataType: 'INT32', value: i, ioType: 'Internal')];
      final project = PlcProject(id: 'p', name: 'p', controllerName: 'PLC',
          tags: tags, structDefs: [], programs: [], tasks: [], hmis: []);
      final map = CipMap(entries: [for (var i = 0; i < 10; i++) CipMapEntry(tagName: 'T$i')]);
      const attrs = [1, 2, 3, 5, 6, 8];
      final seen = <int>[];
      var start = 0;
      var status = kCipStatusPartialTransfer;
      var guard = 0;
      while (status == kCipStatusPartialTransfer && guard++ < 50) {
        final resp = buildSymbolInstanceListResponse(project, map,
            GetInstanceAttrListRequest(startInstance: start, attributeIds: attrs), replyBudget: 80);
        status = resp.generalStatus;
        var off = 0;
        var lastId = start;
        while (off + 4 <= resp.data.length) {
          final id = ByteData.sublistView(resp.data, off, off + 4).getUint32(0, Endian.little);
          off += 4;
          final nlen = ByteData.sublistView(resp.data, off, off + 2).getUint16(0, Endian.little);
          off += 2;
          off += nlen; // attr 1 name bytes
          off += 2; // attr 2 type
          off += 4; // attr 3 symbol address
          off += 4; // attr 5 symbol object address
          off += 4; // attr 6 software control
          off += 12; // attr 8 array dims (3 x u32)
          seen.add(id);
          lastId = id;
        }
        start = lastId + 1;
      }
      // Terminated because pagination made real progress each page, not
      // because a too-small-for-one-instance budget forced the spin guard.
      expect(guard, lessThan(50));
      expect(seen, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(status, kCipStatusSuccess);
    });

    test('a stale/unresolvable entry between two listable entries burns no instance id', () {
      // 'Label' is a STRING tag: cipTypeForTagType('STRING') is null (Symbol
      // browse v1 serves atomic scalars only), so the map entry pointing at
      // it is skipped by buildSymbolInstanceListResponse and — per the
      // instance-numbering contract — consumes no instance id. 'Speed' (the
      // third map entry) must therefore be instance 2, not 3.
      final project = PlcProject(
        id: 'p', name: 'p', controllerName: 'PLC',
        tags: [
          PlcTag(name: 'Running', path: 'Internal.Running', dataType: 'BOOL', value: true, ioType: 'Internal'),
          PlcTag(name: 'Label', path: 'Internal.Label', dataType: 'STRING', value: '', ioType: 'Internal'),
          PlcTag(name: 'Speed', path: 'Internal.Speed', dataType: 'INT32', value: 100, ioType: 'Internal'),
        ],
        structDefs: [], programs: [], tasks: [], hmis: [],
      );
      final map = CipMap(entries: [
        CipMapEntry(tagName: 'Running'),
        CipMapEntry(tagName: 'Label'), // STRING: no CIP type -- skipped, no id burned.
        CipMapEntry(tagName: 'Speed'),
      ]);
      const parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(project, map, parsed, replyBudget: 4096);
      expect(resp.generalStatus, kCipStatusSuccess);
      final d = resp.data;
      // First instance: id=1, "Running".
      expect(ByteData.sublistView(d, 0, 4).getUint32(0, Endian.little), 1);
      final firstNameLen = ByteData.sublistView(d, 4, 6).getUint16(0, Endian.little);
      final off = 6 + firstNameLen + 2; // name bytes + attr 2 type, then next instance.
      // The only other instance present is "Speed" -- its id is 2, not 3:
      // the skipped STRING entry burned no instance id.
      expect(ByteData.sublistView(d, off, off + 4).getUint32(0, Endian.little), 2);
      final secondNameLen = ByteData.sublistView(d, off + 4, off + 6).getUint16(0, Endian.little);
      expect(String.fromCharCodes(d.sublist(off + 6, off + 6 + secondNameLen)), 'Speed');
      // And there is no third instance -- exactly two listable entries.
      // (off + id[4] + nlen[2] + name + attr-2 type[2] is the end of instance 2.)
      expect(off + 6 + secondNameLen + 2, d.length);
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

    test('Fix 2: a budget smaller than one instance emits exactly ONE over-budget instance, and a resume loop still terminates', () {
      // Single-instance check: budget far below one instance's encoded cost.
      // Instance 1 "Running" with attrs {1,2} costs id(4)+namelen(2)+name(7)+
      // type(2) = 15 bytes; budget 5 is smaller than that.
      const parsed = GetInstanceAttrListRequest(startInstance: 0, attributeIds: [1, 2]);
      final resp = buildSymbolInstanceListResponse(buildProject(), buildMap(), parsed, replyBudget: 5);
      // Status 0x06 (two more instances remain) with EXACTLY ONE instance emitted
      // even though it is over budget — the make-progress override fired.
      expect(resp.generalStatus, kCipStatusPartialTransfer);
      expect(ByteData.sublistView(resp.data, 0, 4).getUint32(0, Endian.little), 1);
      expect(resp.data.length, greaterThan(5)); // over the budget on purpose
      expect(resp.data.length, 15); // and it is exactly one instance, not two

      // Driven resume loop over the real LogixDriver attribute set {1,2,3,5,6,8}
      // with a budget (10) smaller than a single instance (~34 bytes): without
      // the make-progress guard this livelocks (0 instances + 0x06 forever). It
      // must terminate, return every listable instance exactly once, deliver at
      // least one instance per page, and end on 0x00.
      final tags = [
        for (var i = 0; i < 5; i++)
          PlcTag(name: 'T$i', path: 'Internal.T$i', dataType: 'INT32', value: i, ioType: 'Internal'),
      ];
      final project = PlcProject(
          id: 'p', name: 'p', controllerName: 'PLC', tags: tags, structDefs: [], programs: [], tasks: [], hmis: []);
      final map = CipMap(entries: [for (var i = 0; i < 5; i++) CipMapEntry(tagName: 'T$i')]);
      const attrs = [1, 2, 3, 5, 6, 8];
      final seen = <int>[];
      var start = 0;
      var status = kCipStatusPartialTransfer;
      var guard = 0;
      while (status == kCipStatusPartialTransfer && guard++ < 50) {
        final page = buildSymbolInstanceListResponse(
            project, map, GetInstanceAttrListRequest(startInstance: start, attributeIds: attrs), replyBudget: 10);
        status = page.generalStatus;
        var off = 0;
        var lastId = start;
        var thisPage = 0;
        while (off + 4 <= page.data.length) {
          final id = ByteData.sublistView(page.data, off, off + 4).getUint32(0, Endian.little);
          off += 4;
          final nlen = ByteData.sublistView(page.data, off, off + 2).getUint16(0, Endian.little);
          off += 2;
          off += nlen; // attr 1 name bytes
          off += 2; // attr 2 type
          off += 4; // attr 3 symbol address
          off += 4; // attr 5 symbol object address
          off += 4; // attr 6 software control
          off += 12; // attr 8 array dims (3 x u32)
          seen.add(id);
          lastId = id;
          thisPage++;
        }
        // Progress guarantee: every page delivers at least one instance even
        // though the budget is smaller than a single instance's cost.
        expect(thisPage, greaterThanOrEqualTo(1));
        start = lastId + 1;
      }
      expect(guard, lessThan(50)); // terminated by real progress, not the spin guard
      expect(seen, [1, 2, 3, 4, 5]);
      expect(status, kCipStatusSuccess); // the final page's last instance -> 0x00
    });
  });
}
