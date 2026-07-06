// Pure Dart per-project outbound-protocol configuration model (WS17).
//
// Generalizes the WS16 OPC UA bridge's single `PlcProject.opcuaMap` field
// into a `ProtocolSettings` bag: one shared gateway endpoint plus a config
// per outbound protocol (currently just OPC UA). See
// docs/superpowers/specs/2026-07-06-outbound-protocols-config-design.md.
//
// No Flutter dependency — this file must stay pure Dart so it can be used
// from services and widgets alike without pulling Flutter into model code.

import 'opcua_map.dart';
import 'project_model.dart';

/// Default gateway WebSocket endpoint. Canonical home of this const: other
/// files (e.g. `services/gateway_client.dart`) should import and reuse this
/// value rather than re-declaring it, to avoid a clashing duplicate const.
const String kDefaultGatewayUrl = 'ws://localhost:4855';

/// Per-project OPC UA outbound-protocol configuration: whether the bridge is
/// enabled, the namespace URI advertised to OPC UA clients, and the node<->tag
/// map that decides which tags are exposed.
class OpcUaProtocolConfig {
  bool enabled;
  String namespaceUri;
  OpcuaMap map;

  OpcUaProtocolConfig({
    this.enabled = false,
    this.namespaceUri = '',
    required this.map,
  });

  factory OpcUaProtocolConfig.fromJson(Map<String, dynamic> j) => OpcUaProtocolConfig(
        enabled: j['enabled'] == true,
        namespaceUri: (j['namespace_uri'] ?? '').toString(),
        map: j['map'] != null
            ? OpcuaMap.fromJson(j['map'] as Map<String, dynamic>)
            : OpcuaMap(namespaceUri: '', nodes: []),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'namespace_uri': namespaceUri,
        'map': map.toJson(),
      };

  /// Sane defaults for a project that has never configured OPC UA: disabled,
  /// a project-scoped namespace URI, and an auto-generated map from the
  /// project's current scalar tags.
  static OpcUaProtocolConfig defaults(PlcProject p) => OpcUaProtocolConfig(
        enabled: false,
        namespaceUri: 'urn:softplc:${p.id}',
        map: OpcuaMap.autoGenerate(p),
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

  ProtocolSettings({
    this.gatewayUrl = kDefaultGatewayUrl,
    this.opcua,
  });

  Map<String, dynamic> toJson() => {
        'gateway_url': gatewayUrl,
        if (opcua != null) 'opcua': opcua!.toJson(),
      };

  factory ProtocolSettings.fromJson(Map<String, dynamic> j) => ProtocolSettings(
        gatewayUrl: (j['gateway_url'] ?? kDefaultGatewayUrl).toString(),
        opcua: j['opcua'] != null ? OpcUaProtocolConfig.fromJson(j['opcua'] as Map<String, dynamic>) : null,
      );

  static ProtocolSettings defaults(PlcProject p) => ProtocolSettings(
        gatewayUrl: kDefaultGatewayUrl,
        opcua: OpcUaProtocolConfig.defaults(p),
      );
}
