// Pure Dart per-project outbound-protocol configuration model (WS17).
//
// Generalizes the WS16 OPC UA bridge's single `PlcProject.opcuaMap` field
// into a `ProtocolSettings` bag: one shared gateway endpoint plus a config
// per outbound protocol (currently just OPC UA). See
// docs/superpowers/specs/2026-07-06-outbound-protocols-config-design.md.
//
// No Flutter dependency — this file must stay pure Dart so it can be used
// from services and widgets alike without pulling Flutter into model code.

import 'modbus_map.dart';
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

  ProtocolSettings({
    this.gatewayUrl = kDefaultGatewayUrl,
    this.opcua,
    this.modbus,
  });

  Map<String, dynamic> toJson() => {
        'gateway_url': gatewayUrl,
        if (opcua != null) 'opcua': opcua!.toJson(),
        if (modbus != null) 'modbus': modbus!.toJson(),
      };

  factory ProtocolSettings.fromJson(Map<String, dynamic> j) => ProtocolSettings(
        gatewayUrl: (j['gateway_url'] ?? kDefaultGatewayUrl).toString(),
        opcua: j['opcua'] != null ? OpcUaProtocolConfig.fromJson(j['opcua'] as Map<String, dynamic>) : null,
        modbus: j['modbus'] != null ? ModbusProtocolConfig.fromJson(j['modbus'] as Map<String, dynamic>) : null,
      );

  static ProtocolSettings defaults(PlcProject p) => ProtocolSettings(
        gatewayUrl: kDefaultGatewayUrl,
        opcua: OpcUaProtocolConfig.defaults(p),
        modbus: ModbusProtocolConfig.defaults(p),
      );
}
