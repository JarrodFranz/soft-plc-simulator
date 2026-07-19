// Tests for the per-project ProtocolSettings model (WS17 Task 1):
// - OpcUaProtocolConfig / ProtocolSettings toJson<->fromJson round-trips.
// - Back-compat migration of the old top-level `opcua_map` field into
//   `protocols.opcua`.
// - PlcProject.protocols round-trips losslessly.
// - ProtocolSettings.defaults(project) builds sane defaults.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/cip_map.dart';
import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/opcua_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';

void main() {
  group('OpcUaProtocolConfig.toJson / fromJson', () {
    test('round-trips enabled=true with namespaceUri and nodes', () {
      final cfg = OpcUaProtocolConfig(
        enabled: true,
        namespaceUri: 'urn:softplc:test',
        map: OpcuaMap(
          namespaceUri: 'urn:softplc:test',
          nodes: [
            OpcuaNode(nodeId: 'ns=1;s=Start_PB', tag: 'Start_PB', access: 'ReadWrite'),
            OpcuaNode(nodeId: 'ns=1;s=Motor_Run', tag: 'Motor_Run', access: 'ReadOnly'),
          ],
        ),
      );

      final rt = OpcUaProtocolConfig.fromJson(cfg.toJson());

      expect(rt.enabled, isTrue);
      expect(rt.namespaceUri, 'urn:softplc:test');
      expect(rt.map.namespaceUri, cfg.map.namespaceUri);
      expect(rt.map.nodes.length, 2);
      expect(rt.map.nodes[0].nodeId, 'ns=1;s=Start_PB');
      expect(rt.map.nodes[0].tag, 'Start_PB');
      expect(rt.map.nodes[0].access, 'ReadWrite');
      expect(rt.map.nodes[1].nodeId, 'ns=1;s=Motor_Run');
      expect(rt.map.nodes[1].tag, 'Motor_Run');
      expect(rt.map.nodes[1].access, 'ReadOnly');
    });

    test('round-trips enabled=false with an empty map', () {
      final cfg = OpcUaProtocolConfig(
        enabled: false,
        namespaceUri: '',
        map: OpcuaMap(namespaceUri: '', nodes: []),
      );

      final rt = OpcUaProtocolConfig.fromJson(cfg.toJson());

      expect(rt.enabled, isFalse);
      expect(rt.namespaceUri, '');
      expect(rt.map.nodes, isEmpty);
    });

    test('fromJson tolerates a missing map key', () {
      final cfg = OpcUaProtocolConfig.fromJson({'enabled': true, 'namespace_uri': 'urn:x'});
      expect(cfg.enabled, isTrue);
      expect(cfg.namespaceUri, 'urn:x');
      expect(cfg.map.nodes, isEmpty);
    });

    test('port defaults to 4840 and round-trips a custom value (WS19 Task 4, additive field)', () {
      final defaultCfg = OpcUaProtocolConfig(
        namespaceUri: 'urn:x',
        map: OpcuaMap(namespaceUri: 'urn:x', nodes: []),
      );
      expect(defaultCfg.port, 4840);

      final custom = OpcUaProtocolConfig(
        namespaceUri: 'urn:x',
        map: OpcuaMap(namespaceUri: 'urn:x', nodes: []),
        port: 48401,
      );
      final rt = OpcUaProtocolConfig.fromJson(custom.toJson());
      expect(rt.port, 48401);
      expect(custom.toJson()['port'], 48401);
    });

    test('fromJson on a legacy record with no "port" key back-fills the default 4840', () {
      final cfg = OpcUaProtocolConfig.fromJson({
        'enabled': true,
        'namespace_uri': 'urn:x',
        'map': {
          'opcua_map': {'namespace_uri': 'urn:x', 'nodes': []},
        },
      });
      expect(cfg.port, 4840);
    });

    test('security fields default (None, no creds, anonymous allowed) on a '
        'legacy record', () {
      final cfg = OpcUaProtocolConfig.fromJson({
        'enabled': true,
        'namespace_uri': 'urn:x',
        'map': {
          'opcua_map': {'namespace_uri': 'urn:x', 'nodes': []},
        },
      });
      expect(cfg.securityModes, ['None']);
      expect(cfg.credentials, isEmpty);
      expect(cfg.allowAnonymous, isTrue);
    });

    test('security fields round-trip; credentials persist the username ONLY '
        '(never the password)', () {
      final custom = OpcUaProtocolConfig(
        namespaceUri: 'urn:x',
        map: OpcuaMap(namespaceUri: 'urn:x', nodes: []),
        securityModes: ['None', 'Basic256Sha256/SignAndEncrypt'],
        credentials: [OpcUaUserCredential(username: 'operator', password: 's3cret')],
        allowAnonymous: false,
      );
      final json = custom.toJson();
      // The serialized credential carries no password key.
      final creds = json['credentials'] as List;
      expect(creds.single, {'username': 'operator'});

      final rt = OpcUaProtocolConfig.fromJson(json);
      expect(rt.securityModes, ['None', 'Basic256Sha256/SignAndEncrypt']);
      expect(rt.allowAnonymous, isFalse);
      expect(rt.credentials.single.username, 'operator');
      expect(rt.credentials.single.password, ''); // password not persisted
    });
  });

  group('ProtocolSettings.toJson / fromJson', () {
    test('round-trips gatewayUrl and opcua config', () {
      final settings = ProtocolSettings(
        gatewayUrl: 'ws://localhost:9999',
        opcua: OpcUaProtocolConfig(
          enabled: true,
          namespaceUri: 'urn:softplc:test',
          map: OpcuaMap(namespaceUri: 'urn:softplc:test', nodes: [
            OpcuaNode(nodeId: 'ns=1;s=Tag1', tag: 'Tag1', access: 'ReadWrite'),
          ]),
        ),
      );

      final rt = ProtocolSettings.fromJson(settings.toJson());

      expect(rt.gatewayUrl, 'ws://localhost:9999');
      expect(rt.opcua, isNotNull);
      expect(rt.opcua!.enabled, isTrue);
      expect(rt.opcua!.map.nodes.length, 1);
    });

    test('fromJson defaults gatewayUrl when missing', () {
      final settings = ProtocolSettings.fromJson({});
      expect(settings.gatewayUrl, kDefaultGatewayUrl);
      expect(settings.opcua, isNull);
    });

    test('kDefaultGatewayUrl is the expected default endpoint', () {
      expect(kDefaultGatewayUrl, 'ws://localhost:4855');
    });
  });

  group('PlcProject.fromJson migration of legacy top-level opcua_map', () {
    PlcProject buildProject() => PlcProject(
          id: 'migrate_proj',
          name: 'Migrate Project',
          controllerName: 'PLC_MIGRATE',
          tags: [],
          structDefs: [],
          programs: [],
          tasks: [],
          hmis: [],
        );

    test('legacy opcua_map with no protocols migrates into protocols.opcua', () {
      final legacyJson = {
        'project': {
          'id': 'legacy_proj',
          'name': 'Legacy Project',
          'controller': {'name': 'PLC_01', 'scan_period_ms': 100},
          'tags': [],
          'struct_defs': [],
          'programs': [],
          'tasks': [],
          'hmis': [],
          'opcua_map': {
            'namespace_uri': 'urn:softplc:legacy_proj',
            'nodes': [
              {'node_id': 'ns=1;s=Start_PB', 'tag': 'Start_PB', 'access': 'ReadWrite'},
              {'node_id': 'ns=1;s=Stop_PB', 'tag': 'Stop_PB', 'access': 'ReadWrite'},
              {'node_id': 'ns=1;s=Motor_Run', 'tag': 'Motor_Run', 'access': 'ReadOnly'},
            ],
          },
        },
      };

      final project = PlcProject.fromJson(legacyJson);

      expect(project.protocols, isNotNull);
      expect(project.protocols!.opcua, isNotNull);
      expect(project.protocols!.opcua!.enabled, isTrue);
      expect(project.protocols!.opcua!.namespaceUri, 'urn:softplc:legacy_proj');
      expect(project.protocols!.opcua!.map.nodes.length, 3);
      expect(project.protocols!.opcua!.map.nodes[0].tag, 'Start_PB');
      expect(project.protocols!.opcua!.map.nodes[2].access, 'ReadOnly');
      // A legacy project migrated from the old top-level `opcua_map` has no
      // `port` key anywhere -> back-fills the default (WS19 Task 4).
      expect(project.protocols!.opcua!.port, 4840);
    });

    test('neither protocols nor opcua_map present -> protocols is null', () {
      final project = buildProject();
      final restored = PlcProject.fromJson(jsonDecode(jsonEncode(project.toJson())));
      expect(restored.protocols, isNull);
    });

    test('project with protocols already present parses as-is (no migration)', () {
      final json = {
        'project': {
          'id': 'proto_proj',
          'name': 'Protocols Project',
          'controller': {'name': 'PLC_01', 'scan_period_ms': 100},
          'tags': [],
          'struct_defs': [],
          'programs': [],
          'tasks': [],
          'hmis': [],
          'protocols': {
            'gateway_url': 'ws://localhost:1234',
            'opcua': {
              'enabled': false,
              'namespace_uri': 'urn:softplc:proto_proj',
              'map': {
                'opcua_map': {'namespace_uri': 'urn:softplc:proto_proj', 'nodes': []},
              },
            },
          },
        },
      };

      final project = PlcProject.fromJson(json);

      expect(project.protocols, isNotNull);
      expect(project.protocols!.gatewayUrl, 'ws://localhost:1234');
      expect(project.protocols!.opcua!.enabled, isFalse);
    });
  });

  group('PlcProject.protocols round-trip', () {
    PlcProject buildProject() => PlcProject(
          id: 'rt_proj',
          name: 'Round Trip Project',
          controllerName: 'PLC_RT',
          tags: [
            PlcTag(
              name: 'Start_PB',
              path: 'Inputs/Start_PB',
              dataType: 'BOOL',
              value: false,
              ioType: 'SimulatedInput',
            ),
            PlcTag(
              name: 'Motor_Run',
              path: 'Outputs/Motor_Run',
              dataType: 'BOOL',
              value: false,
              ioType: 'SimulatedOutput',
            ),
          ],
          structDefs: [],
          programs: [],
          tasks: [],
          hmis: [],
        );

    test('populated protocols round-trips losslessly through jsonEncode/decode', () {
      final project = buildProject();
      project.protocols = ProtocolSettings(
        gatewayUrl: 'ws://localhost:4855',
        opcua: OpcUaProtocolConfig(
          enabled: true,
          namespaceUri: 'urn:softplc:rt_proj',
          map: OpcuaMap.autoGenerate(project),
          port: 48402,
        ),
      );

      final restored = PlcProject.fromJson(jsonDecode(jsonEncode(project.toJson())));

      expect(restored.protocols, isNotNull);
      expect(restored.protocols!.gatewayUrl, project.protocols!.gatewayUrl);
      expect(restored.protocols!.opcua!.enabled, project.protocols!.opcua!.enabled);
      expect(restored.protocols!.opcua!.map.nodes.length, project.protocols!.opcua!.map.nodes.length);
      expect(restored.protocols!.opcua!.port, 48402);
    });

    test('protocols == null round-trips to null and omits the key (back-compat)', () {
      final project = buildProject();
      expect(project.protocols, isNull);

      final json = project.toJson();
      expect((json['project'] as Map).containsKey('protocols'), isFalse);
      expect((json['project'] as Map).containsKey('opcua_map'), isFalse);

      final restored = PlcProject.fromJson(jsonDecode(jsonEncode(json)));
      expect(restored.protocols, isNull);
    });
  });

  group('ProtocolSettings.defaults', () {
    test('builds disabled opcua config with urn namespace and non-empty map', () {
      final project = PlcProject(
        id: 'def_proj',
        name: 'Defaults Project',
        controllerName: 'PLC_DEF',
        tags: [
          PlcTag(
            name: 'Start_PB',
            path: 'Inputs/Start_PB',
            dataType: 'BOOL',
            value: false,
            ioType: 'SimulatedInput',
          ),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );

      final settings = ProtocolSettings.defaults(project);

      expect(settings.gatewayUrl, kDefaultGatewayUrl);
      expect(settings.opcua, isNotNull);
      expect(settings.opcua!.enabled, isFalse);
      expect(settings.opcua!.namespaceUri, 'urn:softplc:def_proj');
      expect(settings.opcua!.map.nodes, isNotEmpty);
      expect(settings.opcua!.port, 4840);
    });
  });

  group('MqttProtocolConfig / ProtocolSettings.mqtt', () {
    test('MqttProtocolConfig round-trips through toJson/fromJson', () {
      final cfg = MqttProtocolConfig(
        enabled: true,
        host: 'broker.example.com',
        port: 8883,
        tls: true,
        format: 'sparkplug',
        baseTopic: 'plant1',
        groupId: 'GroupA',
        edgeNodeId: 'Line1',
        qos: 1,
        heartbeatSeconds: 30,
        allowRemoteWrites: true,
        username: 'plc_user',
        map: MqttMap(entries: [MqttMapEntry(tag: 'Run', metric: 'Run', writable: true)]),
        publishIntervalMs: 500,
        deadband: 1.5,
      );

      final rt = MqttProtocolConfig.fromJson(cfg.toJson());

      expect(rt.enabled, isTrue);
      expect(rt.host, 'broker.example.com');
      expect(rt.port, 8883);
      expect(rt.tls, isTrue);
      expect(rt.format, 'sparkplug');
      expect(rt.baseTopic, 'plant1');
      expect(rt.groupId, 'GroupA');
      expect(rt.edgeNodeId, 'Line1');
      expect(rt.qos, 1);
      expect(rt.heartbeatSeconds, 30);
      expect(rt.allowRemoteWrites, isTrue);
      expect(rt.username, 'plc_user');
      expect(rt.map.entries.single.tag, 'Run');
      expect(rt.publishIntervalMs, 500);
      expect(rt.deadband, 1.5);
    });

    test('MqttProtocolConfig.fromJson tolerates missing keys with sane defaults', () {
      final cfg = MqttProtocolConfig.fromJson({});
      expect(cfg.enabled, isFalse);
      expect(cfg.host, '');
      expect(cfg.port, 1883);
      expect(cfg.tls, isFalse);
      expect(cfg.format, 'json');
      expect(cfg.baseTopic, 'softplc');
      expect(cfg.groupId, 'SoftPLC');
      expect(cfg.qos, 0);
      expect(cfg.heartbeatSeconds, 5);
      expect(cfg.allowRemoteWrites, isFalse);
      expect(cfg.map.entries, isEmpty);
      // Additive fields (configurable publish interval + analog deadband,
      // WS-perf event-loop-flood fix): older saved projects have neither key
      // and must fall back to defaults that preserve the ORIGINAL behavior
      // (a fixed ~50ms host tick, no deadband suppression).
      expect(cfg.publishIntervalMs, 250);
      expect(cfg.deadband, 0.0);
    });

    test('ProtocolSettings carrying an MqttProtocolConfig round-trips losslessly', () {
      final settings = ProtocolSettings(
        gatewayUrl: kDefaultGatewayUrl,
        mqtt: MqttProtocolConfig(
          enabled: true,
          host: 'localhost',
          port: 1883,
          map: MqttMap(entries: [MqttMapEntry(tag: 'A', metric: 'A', writable: true)]),
        ),
      );

      final rt = ProtocolSettings.fromJson(settings.toJson());

      expect(rt.mqtt, isNotNull);
      expect(rt.mqtt!.enabled, isTrue);
      expect(rt.mqtt!.host, 'localhost');
      expect(rt.mqtt!.map.entries.length, 1);
    });

    test('ProtocolSettings with mqtt == null omits the mqtt key entirely', () {
      final settings = ProtocolSettings(); // no mqtt
      expect(settings.mqtt, isNull);
      expect(settings.toJson().containsKey('mqtt'), isFalse);
    });

    test('serialized MqttProtocolConfig / ProtocolSettings JSON never contains a password key', () {
      final cfg = MqttProtocolConfig(
        enabled: true,
        host: 'localhost',
        username: 'plc_user',
        map: MqttMap.autoGenerate(PlcProject(
          id: 'pw_proj',
          name: 'Password Project',
          controllerName: 'PLC_PW',
          tags: const [],
          structDefs: const [],
          programs: const [],
          tasks: const [],
          hmis: const [],
        )),
      );
      final cfgJson = cfg.toJson();
      expect(cfgJson.containsKey('password'), isFalse);

      final settings = ProtocolSettings(mqtt: cfg);
      final settingsJson = settings.toJson();
      expect(settingsJson.containsKey('password'), isFalse);
      expect(jsonEncode(settingsJson).contains('password'), isFalse);
    });
  });

  group('ModbusProtocolConfig / ProtocolSettings.modbus', () {
    test('ModbusProtocolConfig.fromJson tolerates missing keys with sane defaults', () {
      final cfg = ModbusProtocolConfig.fromJson({});
      expect(cfg.enabled, isFalse);
      expect(cfg.port, 502);
      expect(cfg.map.entries, isEmpty);
      // Additive fields (server word-order + byte-order + unit-id options):
      // older saved projects have none of these keys, and must fall back to
      // the defaults that preserve the ORIGINAL wire behavior (no swap,
      // accept any unit id).
      expect(cfg.wordSwap, isFalse);
      expect(cfg.byteSwap, isFalse);
      expect(cfg.unitId, 255);
    });

    test('ModbusProtocolConfig round-trips wordSwap, byteSwap and unitId through toJson/fromJson', () {
      final cfg = ModbusProtocolConfig(
        enabled: true,
        port: 5020,
        map: ModbusMap(entries: [ModbusMapEntry(tag: 'Run', table: 'holding', address: 0, access: 'ReadWrite')]),
        wordSwap: true,
        byteSwap: true,
        unitId: 12,
      );

      final rt = ModbusProtocolConfig.fromJson(cfg.toJson());

      expect(rt.enabled, isTrue);
      expect(rt.port, 5020);
      expect(rt.map.entries.single.tag, 'Run');
      expect(rt.wordSwap, isTrue);
      expect(rt.byteSwap, isTrue);
      expect(rt.unitId, 12);
      expect(cfg.toJson()['word_swap'], isTrue);
      expect(cfg.toJson()['byte_swap'], isTrue);
      expect(cfg.toJson()['unit_id'], 12);
    });

    test('ModbusProtocolConfig.fromJson with byteSwap true but no word_swap key defaults wordSwap false', () {
      final cfg = ModbusProtocolConfig.fromJson({'byte_swap': true});
      expect(cfg.byteSwap, isTrue);
      expect(cfg.wordSwap, isFalse);
    });

    test('ModbusProtocolConfig.defaults sets wordSwap=false, byteSwap=false and unitId=255', () {
      final project = PlcProject(
        id: 'modbus_def_proj',
        name: 'Modbus Defaults Project',
        controllerName: 'PLC_MODBUS_DEF',
        tags: const [],
        structDefs: const [],
        programs: const [],
        tasks: const [],
        hmis: const [],
      );
      final cfg = ModbusProtocolConfig.defaults(project);
      expect(cfg.wordSwap, isFalse);
      expect(cfg.byteSwap, isFalse);
      expect(cfg.unitId, 255);
    });

    test('ProtocolSettings carrying a ModbusProtocolConfig round-trips wordSwap/byteSwap/unitId losslessly', () {
      final settings = ProtocolSettings(
        modbus: ModbusProtocolConfig(
          enabled: true,
          port: 502,
          map: ModbusMap(entries: []),
          wordSwap: true,
          byteSwap: true,
          unitId: 7,
        ),
      );

      final rt = ProtocolSettings.fromJson(settings.toJson());

      expect(rt.modbus, isNotNull);
      expect(rt.modbus!.wordSwap, isTrue);
      expect(rt.modbus!.byteSwap, isTrue);
      expect(rt.modbus!.unitId, 7);
    });

    test('ProtocolSettings with modbus == null omits the modbus key entirely', () {
      final settings = ProtocolSettings(); // no modbus
      expect(settings.modbus, isNull);
      expect(settings.toJson().containsKey('modbus'), isFalse);
    });

    test('ModbusProtocolConfig.fromJson with no framing key defaults to tcp (additive field)', () {
      final cfg = ModbusProtocolConfig.fromJson({});
      expect(cfg.framing, 'tcp');
    });

    test('ModbusProtocolConfig.fromJson with a non-string framing value degrades to tcp '
        'instead of throwing', () {
      // A corrupted/foreign project file could carry any JSON type here
      // (e.g. a stray 0 from a bad merge/migration) — this must NOT throw a
      // TypeError and fail the whole project load, unlike an unguarded
      // `j['framing'] ?? 'tcp'` would for a non-null non-String value.
      expect(() => ModbusProtocolConfig.fromJson({'framing': 0}), returnsNormally);
      expect(ModbusProtocolConfig.fromJson({'framing': 0}).framing, 'tcp');
      expect(ModbusProtocolConfig.fromJson({'framing': true}).framing, 'tcp');
      expect(ModbusProtocolConfig.fromJson({'framing': <String, dynamic>{}}).framing, 'tcp');
      expect(ModbusProtocolConfig.fromJson({'framing': <dynamic>[]}).framing, 'tcp');
    });

    test('ModbusProtocolConfig round-trips framing: rtuOverTcp through toJson/fromJson', () {
      final cfg = ModbusProtocolConfig(
        enabled: true,
        port: 502,
        map: ModbusMap(entries: []),
        framing: 'rtuOverTcp',
      );

      expect(cfg.toJson()['framing'], 'rtuOverTcp');

      final rt = ModbusProtocolConfig.fromJson(cfg.toJson());
      expect(rt.framing, 'rtuOverTcp');
    });
  });

  group('DnpProtocolConfig / ProtocolSettings.dnp3', () {
    test('DnpProtocolConfig.fromJson tolerates missing keys with sane defaults', () {
      final cfg = DnpProtocolConfig.fromJson({});
      expect(cfg.enabled, isFalse);
      expect(cfg.port, 20000);
      expect(cfg.outstationAddress, 1024);
      expect(cfg.masterAddress, 1);
      expect(cfg.map.entries, isEmpty);
    });

    test('DnpProtocolConfig round-trips through toJson/fromJson', () {
      final cfg = DnpProtocolConfig(
        enabled: true,
        port: 20001,
        outstationAddress: 5,
        masterAddress: 2,
        map: DnpMap(entries: [DnpMapEntry(tag: 'Run', pointType: 'binaryInput', index: 0)]),
      );

      final rt = DnpProtocolConfig.fromJson(cfg.toJson());

      expect(rt.enabled, isTrue);
      expect(rt.port, 20001);
      expect(rt.outstationAddress, 5);
      expect(rt.masterAddress, 2);
      expect(rt.map.entries.single.tag, 'Run');
    });

    test('ProtocolSettings carrying a DnpProtocolConfig round-trips losslessly', () {
      final settings = ProtocolSettings(
        gatewayUrl: kDefaultGatewayUrl,
        dnp3: DnpProtocolConfig(
          enabled: true,
          port: 20000,
          outstationAddress: 1024,
          masterAddress: 1,
          map: DnpMap(entries: [DnpMapEntry(tag: 'A', pointType: 'analogOutput', index: 0)]),
        ),
      );

      final rt = ProtocolSettings.fromJson(settings.toJson());

      expect(rt.dnp3, isNotNull);
      expect(rt.dnp3!.enabled, isTrue);
      expect(rt.dnp3!.port, 20000);
      expect(rt.dnp3!.outstationAddress, 1024);
      expect(rt.dnp3!.masterAddress, 1);
      expect(rt.dnp3!.map.entries.length, 1);
    });

    test('ProtocolSettings with dnp3 == null omits the dnp3 key entirely', () {
      final settings = ProtocolSettings(); // no dnp3
      expect(settings.dnp3, isNull);
      expect(settings.toJson().containsKey('dnp3'), isFalse);
    });

    test('DnpProtocolConfig carries unsol/buffer fields and defaults them', () {
      final c = DnpProtocolConfig(
        map: DnpMap(entries: []),
        unsolConfirmTimeoutMs: 7000,
        unsolMaxRetries: 5,
        eventBufferPerClass: 50,
      );
      final round = DnpProtocolConfig.fromJson(c.toJson());
      expect(round.unsolConfirmTimeoutMs, 7000);
      expect(round.unsolMaxRetries, 5);
      expect(round.eventBufferPerClass, 50);
      // Legacy JSON (no new keys) falls back to spec defaults.
      final legacy = DnpProtocolConfig.fromJson({'enabled': true, 'port': 20000});
      expect(legacy.unsolConfirmTimeoutMs, 5000);
      expect(legacy.unsolMaxRetries, 3);
      expect(legacy.eventBufferPerClass, 200);
    });

    test('existing opcua/modbus/mqtt keys are untouched when dnp3 is present', () {
      final settings = ProtocolSettings(
        opcua: OpcUaProtocolConfig.defaults(PlcProject(
          id: 'dnp_mix_proj',
          name: 'DNP Mix Project',
          controllerName: 'PLC_DNP_MIX',
          tags: const [],
          structDefs: const [],
          programs: const [],
          tasks: const [],
          hmis: const [],
        )),
        dnp3: DnpProtocolConfig(map: DnpMap(entries: [])),
      );

      final json = settings.toJson();
      expect(json.containsKey('opcua'), isTrue);
      expect(json.containsKey('modbus'), isFalse);
      expect(json.containsKey('mqtt'), isFalse);
      expect(json.containsKey('dnp3'), isTrue);

      final rt = ProtocolSettings.fromJson(json);
      expect(rt.opcua, isNotNull);
      expect(rt.modbus, isNull);
      expect(rt.mqtt, isNull);
      expect(rt.dnp3, isNotNull);
    });
  });

  group('CipProtocolConfig / ProtocolSettings.ethernetIp (EtherNet/IP + CIP)', () {
    test('defaults to disabled, port 44818, and an empty map', () {
      final cfg = CipProtocolConfig(map: CipMap(entries: []));
      expect(cfg.enabled, isFalse);
      expect(cfg.port, 44818);
      expect(cfg.map.entries, isEmpty);
    });

    test('CipProtocolConfig round-trips through toJson/fromJson', () {
      final cfg = CipProtocolConfig(
        enabled: true,
        port: 44819,
        map: CipMap(entries: [CipMapEntry(tagName: 'Tank.Level', access: 'ReadOnly')]),
      );

      final rt = CipProtocolConfig.fromJson(cfg.toJson());

      expect(rt.enabled, isTrue);
      expect(rt.port, 44819);
      expect(rt.map.entries.single.tagName, 'Tank.Level');
      expect(rt.map.entries.single.access, 'ReadOnly');
    });

    test('a project JSON without ethernet_ip loads with the feature disabled and port 44818 '
        '(additive/back-compat)', () {
      final settings = ProtocolSettings.fromJson({'gateway_url': kDefaultGatewayUrl});
      expect(settings.ethernetIp, isNull);
    });

    test('CipProtocolConfig.fromJson tolerates a missing map key', () {
      final cfg = CipProtocolConfig.fromJson({'enabled': true});
      expect(cfg.enabled, isTrue);
      expect(cfg.port, 44818);
      expect(cfg.map.entries, isEmpty);
    });

    test('CipProtocolConfig.fromJson on a legacy record with no "port" key back-fills 44818', () {
      final cfg = CipProtocolConfig.fromJson({'enabled': true, 'map': {'entries': []}});
      expect(cfg.port, 44818);
    });

    test('ProtocolSettings carrying a CipProtocolConfig round-trips losslessly', () {
      final settings = ProtocolSettings(
        gatewayUrl: kDefaultGatewayUrl,
        ethernetIp: CipProtocolConfig(
          enabled: true,
          port: 44818,
          map: CipMap(entries: [CipMapEntry(tagName: 'A', access: 'ReadWrite')]),
        ),
      );

      final rt = ProtocolSettings.fromJson(settings.toJson());

      expect(rt.ethernetIp, isNotNull);
      expect(rt.ethernetIp!.enabled, isTrue);
      expect(rt.ethernetIp!.port, 44818);
      expect(rt.ethernetIp!.map.entries.length, 1);
    });

    test('ProtocolSettings with ethernetIp == null omits the ethernet_ip key entirely', () {
      final settings = ProtocolSettings(); // no ethernetIp
      expect(settings.ethernetIp, isNull);
      expect(settings.toJson().containsKey('ethernet_ip'), isFalse);
    });

    test('existing opcua/modbus/mqtt/dnp3 keys are untouched when ethernet_ip is present', () {
      final project = PlcProject(
        id: 'enip_mix_proj',
        name: 'ENIP Mix Project',
        controllerName: 'PLC_ENIP_MIX',
        tags: const [],
        structDefs: const [],
        programs: const [],
        tasks: const [],
        hmis: const [],
      );
      final settings = ProtocolSettings(
        opcua: OpcUaProtocolConfig.defaults(project),
        ethernetIp: CipProtocolConfig(map: CipMap(entries: [])),
      );

      final json = settings.toJson();
      expect(json.containsKey('opcua'), isTrue);
      expect(json.containsKey('modbus'), isFalse);
      expect(json.containsKey('mqtt'), isFalse);
      expect(json.containsKey('dnp3'), isFalse);
      expect(json.containsKey('ethernet_ip'), isTrue);

      final rt = ProtocolSettings.fromJson(json);
      expect(rt.opcua, isNotNull);
      expect(rt.modbus, isNull);
      expect(rt.mqtt, isNull);
      expect(rt.dnp3, isNull);
      expect(rt.ethernetIp, isNotNull);
    });

    test('ProtocolSettings.defaults builds a disabled ethernetIp config with port 44818', () {
      final project = PlcProject(
        id: 'enip_def_proj',
        name: 'ENIP Defaults Project',
        controllerName: 'PLC_ENIP_DEF',
        tags: [
          PlcTag(
            name: 'Level',
            path: 'Internal.Level',
            dataType: 'INT16',
            value: 0,
            ioType: 'Internal',
          ),
        ],
        structDefs: [],
        programs: [],
        tasks: [],
        hmis: [],
      );

      final settings = ProtocolSettings.defaults(project);

      expect(settings.ethernetIp, isNotNull);
      expect(settings.ethernetIp!.enabled, isFalse);
      expect(settings.ethernetIp!.port, 44818);
      expect(settings.ethernetIp!.map.entries, isNotEmpty);
    });
  });
}
