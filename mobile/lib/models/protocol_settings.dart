// Pure Dart per-project outbound-protocol configuration model (WS17).
//
// Generalizes the WS16 OPC UA bridge's single `PlcProject.opcuaMap` field
// into a `ProtocolSettings` bag: one shared gateway endpoint plus a config
// per outbound protocol (currently just OPC UA). See
// docs/superpowers/specs/2026-07-06-outbound-protocols-config-design.md.
//
// No Flutter dependency — this file must stay pure Dart so it can be used
// from services and widgets alike without pulling Flutter into model code.

import 'dnp3_map.dart';
import 'modbus_map.dart';
import 'mqtt_map.dart';
import 'opcua_map.dart';
import 'project_model.dart';

/// Default gateway WebSocket endpoint. Retained for back-compat with the
/// legacy `ProtocolSettings.gatewayUrl` field's serialized default — the
/// ws-sync path itself (the WS16 `GatewayClient`) was retired per ADR-010
/// in favor of the in-app OPC UA host (WS19); this const and field are no
/// longer read by any UI, but stay for old saved projects that still carry
/// a `gateway_url` value.
const String kDefaultGatewayUrl = 'ws://localhost:4855';

/// Per-project OPC UA outbound-protocol configuration: whether the bridge is
/// enabled, the namespace URI advertised to OPC UA clients, and the node<->tag
/// map that decides which tags are exposed.
class OpcUaProtocolConfig {
  bool enabled;
  String namespaceUri;
  OpcuaMap map;

  /// TCP port the in-app OPC UA host binds to (`opc.tcp://<host>:<port>`).
  /// Default 4840 is the IANA-registered OPC UA port. Additive field (WS19
  /// Task 4) — older saved projects simply don't have `port` in their JSON
  /// and fall back to this default on read.
  int port;

  OpcUaProtocolConfig({
    this.enabled = false,
    this.namespaceUri = '',
    required this.map,
    this.port = 4840,
  });

  factory OpcUaProtocolConfig.fromJson(Map<String, dynamic> j) => OpcUaProtocolConfig(
        enabled: j['enabled'] == true,
        namespaceUri: (j['namespace_uri'] ?? '').toString(),
        map: j['map'] != null
            ? OpcuaMap.fromJson(j['map'] as Map<String, dynamic>)
            : OpcuaMap(namespaceUri: '', nodes: []),
        port: (j['port'] as num?)?.toInt() ?? 4840,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'namespace_uri': namespaceUri,
        'map': map.toJson(),
        'port': port,
      };

  /// Sane defaults for a project that has never configured OPC UA: disabled,
  /// a project-scoped namespace URI, the default port, and an auto-generated
  /// map from the project's current scalar tags.
  static OpcUaProtocolConfig defaults(PlcProject p) => OpcUaProtocolConfig(
        enabled: false,
        namespaceUri: 'urn:softplc:${p.id}',
        map: OpcuaMap.autoGenerate(p),
        port: 4840,
      );
}

/// Per-project Modbus TCP outbound-protocol configuration: whether the
/// in-app Modbus TCP server is enabled, the TCP port it binds to, and the
/// tag<->register map that decides which tags are exposed and where.
class ModbusProtocolConfig {
  bool enabled;
  int port;
  ModbusMap map;

  ModbusProtocolConfig({
    this.enabled = false,
    this.port = 502,
    required this.map,
  });

  factory ModbusProtocolConfig.fromJson(Map<String, dynamic> j) => ModbusProtocolConfig(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? 502,
        map: j['map'] != null
            ? ModbusMap.fromJson(j['map'] as Map<String, dynamic>)
            : ModbusMap(entries: []),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'port': port,
        'map': map.toJson(),
      };

  /// Sane defaults for a project that has never configured Modbus: disabled,
  /// the standard Modbus TCP port, and an auto-generated map from the
  /// project's current scalar tags.
  static ModbusProtocolConfig defaults(PlcProject p) => ModbusProtocolConfig(
        enabled: false,
        port: 502,
        map: ModbusMap.autoGenerate(p),
      );
}

/// Per-project MQTT / Sparkplug B outbound-protocol configuration: whether
/// the publisher is enabled, the broker connection details, the Sparkplug B
/// identity fields, and the tag<->metric map that decides which tags are
/// published and under what name.
///
/// The broker password is deliberately NOT a field here: it must never be
/// persisted to the project file. It is supplied by the user in memory at
/// connect time (see the MQTT connection UI in a later task) and is never
/// part of `toJson`/`fromJson`.
class MqttProtocolConfig {
  bool enabled;
  String host;
  int port;
  bool tls;

  /// Payload format: `'json'` (flat JSON per topic) or `'sparkplug'`
  /// (Sparkplug B protobuf payloads).
  String format;
  String baseTopic;
  String groupId;
  String edgeNodeId;
  int qos;
  int heartbeatSeconds;
  bool allowRemoteWrites;
  String username;
  MqttMap map;

  MqttProtocolConfig({
    this.enabled = false,
    this.host = '',
    this.port = 1883,
    this.tls = false,
    this.format = 'json',
    this.baseTopic = 'softplc',
    this.groupId = 'SoftPLC',
    this.edgeNodeId = '',
    this.qos = 0,
    this.heartbeatSeconds = 5,
    this.allowRemoteWrites = false,
    this.username = '',
    required this.map,
  });

  factory MqttProtocolConfig.fromJson(Map<String, dynamic> j) => MqttProtocolConfig(
        enabled: j['enabled'] == true,
        host: (j['host'] ?? '').toString(),
        port: (j['port'] as num?)?.toInt() ?? 1883,
        tls: j['tls'] == true,
        format: (j['format'] ?? 'json').toString(),
        baseTopic: (j['base_topic'] ?? 'softplc').toString(),
        groupId: (j['group_id'] ?? 'SoftPLC').toString(),
        edgeNodeId: (j['edge_node_id'] ?? '').toString(),
        qos: (j['qos'] as num?)?.toInt() ?? 0,
        heartbeatSeconds: (j['heartbeat_seconds'] as num?)?.toInt() ?? 5,
        allowRemoteWrites: j['allow_remote_writes'] == true,
        username: (j['username'] ?? '').toString(),
        map: j['map'] != null
            ? MqttMap.fromJson(j['map'] as Map<String, dynamic>)
            : MqttMap(entries: []),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'host': host,
        'port': port,
        'tls': tls,
        'format': format,
        'base_topic': baseTopic,
        'group_id': groupId,
        'edge_node_id': edgeNodeId,
        'qos': qos,
        'heartbeat_seconds': heartbeatSeconds,
        'allow_remote_writes': allowRemoteWrites,
        'username': username,
        'map': map.toJson(),
      };

  /// Sane defaults for a project that has never configured MQTT: disabled,
  /// the standard (non-TLS) MQTT port, an empty edge node id (the host
  /// resolves the fallback to the project name at connect time), and an
  /// auto-generated map from the project's current scalar tags.
  static MqttProtocolConfig defaults(PlcProject p) => MqttProtocolConfig(
        enabled: false,
        port: 1883,
        edgeNodeId: '',
        map: MqttMap.autoGenerate(p),
      );
}

/// Per-project DNP3 outstation outbound-protocol configuration: whether the
/// in-app DNP3 outstation is enabled, the TCP port it listens on, the DNP3
/// link-layer outstation/master addresses, and the tag<->point map that
/// decides which tags are exposed and where.
class DnpProtocolConfig {
  bool enabled;
  int port;
  int outstationAddress;
  int masterAddress;
  DnpMap map;

  DnpProtocolConfig({
    this.enabled = false,
    this.port = 20000,
    this.outstationAddress = 1024,
    this.masterAddress = 1,
    required this.map,
  });

  factory DnpProtocolConfig.fromJson(Map<String, dynamic> j) => DnpProtocolConfig(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? 20000,
        outstationAddress: (j['outstation_address'] as num?)?.toInt() ?? 1024,
        masterAddress: (j['master_address'] as num?)?.toInt() ?? 1,
        map: j['map'] != null
            ? DnpMap.fromJson(j['map'] as Map<String, dynamic>)
            : DnpMap(entries: []),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'port': port,
        'outstation_address': outstationAddress,
        'master_address': masterAddress,
        'map': map.toJson(),
      };

  /// Sane defaults for a project that has never configured DNP3: disabled,
  /// the standard DNP3 TCP port, the conventional default outstation/master
  /// addresses, and an auto-generated map from the project's current scalar
  /// tags.
  static DnpProtocolConfig defaults(PlcProject p) => DnpProtocolConfig(
        enabled: false,
        port: 20000,
        outstationAddress: 1024,
        masterAddress: 1,
        map: DnpMap.autoGenerate(p),
      );
}

/// Per-project outbound-protocol settings: the shared gateway endpoint plus
/// one config slot per protocol.
///
/// Extensible: adding a new outbound protocol means adding a new
/// `XProtocolConfig? x` field here (plus its `toJson`/`fromJson` wiring) —
/// no change needed to `PlcProject` itself.
class ProtocolSettings {
  String gatewayUrl;
  OpcUaProtocolConfig? opcua;
  ModbusProtocolConfig? modbus;
  MqttProtocolConfig? mqtt;
  DnpProtocolConfig? dnp3;

  ProtocolSettings({
    this.gatewayUrl = kDefaultGatewayUrl,
    this.opcua,
    this.modbus,
    this.mqtt,
    this.dnp3,
  });

  Map<String, dynamic> toJson() => {
        'gateway_url': gatewayUrl,
        if (opcua != null) 'opcua': opcua!.toJson(),
        if (modbus != null) 'modbus': modbus!.toJson(),
        if (mqtt != null) 'mqtt': mqtt!.toJson(),
        if (dnp3 != null) 'dnp3': dnp3!.toJson(),
      };

  factory ProtocolSettings.fromJson(Map<String, dynamic> j) => ProtocolSettings(
        gatewayUrl: (j['gateway_url'] ?? kDefaultGatewayUrl).toString(),
        opcua: j['opcua'] != null ? OpcUaProtocolConfig.fromJson(j['opcua'] as Map<String, dynamic>) : null,
        modbus: j['modbus'] != null ? ModbusProtocolConfig.fromJson(j['modbus'] as Map<String, dynamic>) : null,
        mqtt: j['mqtt'] != null ? MqttProtocolConfig.fromJson(j['mqtt'] as Map<String, dynamic>) : null,
        dnp3: j['dnp3'] != null ? DnpProtocolConfig.fromJson(j['dnp3'] as Map<String, dynamic>) : null,
      );

  static ProtocolSettings defaults(PlcProject p) => ProtocolSettings(
        gatewayUrl: kDefaultGatewayUrl,
        opcua: OpcUaProtocolConfig.defaults(p),
        modbus: ModbusProtocolConfig.defaults(p),
        mqtt: MqttProtocolConfig.defaults(p),
        dnp3: DnpProtocolConfig.defaults(p),
      );
}
