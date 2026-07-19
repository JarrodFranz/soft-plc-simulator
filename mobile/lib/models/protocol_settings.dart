// Pure Dart per-project outbound-protocol configuration model (WS17).
//
// Generalizes the WS16 OPC UA bridge's single `PlcProject.opcuaMap` field
// into a `ProtocolSettings` bag: one shared gateway endpoint plus a config
// per outbound protocol (currently just OPC UA). See
// docs/superpowers/specs/2026-07-06-outbound-protocols-config-design.md.
//
// No Flutter dependency — this file must stay pure Dart so it can be used
// from services and widgets alike without pulling Flutter into model code.

import 'cip_map.dart';
import 'dnp3_map.dart';
import 'modbus_map.dart';
import 'mqtt_map.dart';
import 'opcua_map.dart';
import 'project_model.dart';
import 's7_map.dart';

/// Default gateway WebSocket endpoint. Retained for back-compat with the
/// legacy `ProtocolSettings.gatewayUrl` field's serialized default — the
/// ws-sync path itself (the WS16 `GatewayClient`) was retired per ADR-010
/// in favor of the in-app OPC UA host (WS19); this const and field are no
/// longer read by any UI, but stay for old saved projects that still carry
/// a `gateway_url` value.
const String kDefaultGatewayUrl = 'ws://localhost:4855';

/// A single username/password credential the in-app OPC UA host accepts for
/// UserNameIdentityToken authentication. The password is held in memory only
/// while a project is loaded — it is INTENTIONALLY never serialized (see
/// [toJson], which emits the username alone). A saved project therefore
/// records only which usernames exist; the operator re-enters passwords out of
/// band (or they are provisioned at runtime). This keeps plaintext passwords
/// out of the project JSON on disk.
class OpcUaUserCredential {
  String username;
  String password;

  OpcUaUserCredential({required this.username, this.password = ''});

  factory OpcUaUserCredential.fromJson(Map<String, dynamic> j) =>
      OpcUaUserCredential(
        username: (j['username'] ?? '').toString(),
        // Passwords are never persisted; a loaded credential starts blank and
        // is populated at runtime. Tolerate (but ignore) a legacy 'password'
        // key if some external tool ever wrote one.
        password: '',
      );

  /// Emits the username ONLY — never the password (see the class doc).
  Map<String, dynamic> toJson() => {'username': username};
}

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

  /// The security modes this host advertises, as `Policy/Mode` tokens. Each
  /// enabled entry becomes one advertised EndpointDescription. Recognized
  /// values (OPC UA security workstream, WS19 Task 5):
  ///   - `'None'`                              -> securityMode 1, policy None
  ///   - `'Basic256Sha256/Sign'`              -> securityMode 2, Basic256Sha256
  ///   - `'Basic256Sha256/SignAndEncrypt'`    -> securityMode 3, Basic256Sha256
  /// Defaults to `['None']` so an unconfigured/older project behaves
  /// byte-identically to the pre-security host (None + Anonymous only).
  List<String> securityModes;

  /// Username/password credentials accepted for UserNameIdentityToken auth.
  /// Passwords are not persisted (see [OpcUaUserCredential]).
  List<OpcUaUserCredential> credentials;

  /// Whether anonymous authentication is accepted. Defaults to `true` (the
  /// pre-security behavior). When `false`, a client MUST present valid
  /// username/password credentials.
  bool allowAnonymous;

  OpcUaProtocolConfig({
    this.enabled = false,
    this.namespaceUri = '',
    required this.map,
    this.port = 4840,
    List<String>? securityModes,
    List<OpcUaUserCredential>? credentials,
    this.allowAnonymous = true,
  })  : securityModes = securityModes ?? <String>['None'],
        credentials = credentials ?? <OpcUaUserCredential>[];

  factory OpcUaProtocolConfig.fromJson(Map<String, dynamic> j) => OpcUaProtocolConfig(
        enabled: j['enabled'] == true,
        namespaceUri: (j['namespace_uri'] ?? '').toString(),
        map: j['map'] != null
            ? OpcuaMap.fromJson(j['map'] as Map<String, dynamic>)
            : OpcuaMap(namespaceUri: '', nodes: []),
        port: (j['port'] as num?)?.toInt() ?? 4840,
        securityModes: j['security_modes'] is List
            ? (j['security_modes'] as List)
                .map((e) => e.toString())
                .toList(growable: true)
            : <String>['None'],
        credentials: j['credentials'] is List
            ? (j['credentials'] as List)
                .whereType<Map<String, dynamic>>()
                .map(OpcUaUserCredential.fromJson)
                .toList(growable: true)
            : <OpcUaUserCredential>[],
        allowAnonymous: j['allow_anonymous'] == null ? true : j['allow_anonymous'] == true,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'namespace_uri': namespaceUri,
        'map': map.toJson(),
        'port': port,
        'security_modes': securityModes,
        'credentials': credentials.map((c) => c.toJson()).toList(),
        'allow_anonymous': allowAnonymous,
      };

  /// Sane defaults for a project that has never configured OPC UA: disabled,
  /// a project-scoped namespace URI, the default port, and an auto-generated
  /// map from the project's current scalar tags.
  static OpcUaProtocolConfig defaults(PlcProject p) => OpcUaProtocolConfig(
        enabled: false,
        namespaceUri: 'urn:softplc:${p.id}',
        map: OpcuaMap.autoGenerate(p),
        port: 4840,
        securityModes: <String>['None'],
        credentials: <OpcUaUserCredential>[],
        allowAnonymous: true,
      );
}

/// Per-project Modbus TCP outbound-protocol configuration: whether the
/// in-app Modbus TCP server is enabled, the TCP port it binds to, and the
/// tag<->register map that decides which tags are exposed and where.
class ModbusProtocolConfig {
  bool enabled;
  int port;
  ModbusMap map;

  /// Word order for multi-register values (INT32 = 2 registers, FLOAT64 = 4
  /// registers). `false` (the default) is the current/original behavior:
  /// big-endian, HIGH word first ("ABCD"). `true` reverses the register
  /// ORDER — low word first ("CDAB") — the #1 Modbus interop mismatch
  /// between masters/outstations; the bytes WITHIN each 16-bit register stay
  /// big-endian either way. Additive field (server word-order option) —
  /// older saved projects simply don't have `word_swap` in their JSON and
  /// fall back to `false` (unchanged wire behavior) on read.
  bool wordSwap;

  /// Byte order WITHIN each 16-bit register. `false` (the default) is the
  /// current/original behavior: big-endian bytes within each register. `true`
  /// swaps the two bytes of every register (e.g. register 0xABCD becomes
  /// 0xCDAB). Combined with `wordSwap` this gives all four common Modbus
  /// multi-register orderings: ABCD (both false), CDAB (wordSwap only), BADC
  /// (byteSwap only), DCBA (both true). Additive field — older saved
  /// projects simply don't have `byte_swap` in their JSON and fall back to
  /// `false` (unchanged wire behavior) on read.
  bool byteSwap;

  /// Unit id this server responds as. `255` (the default) means "any" — the
  /// server ignores the requested unit id entirely, matching the original
  /// permissive behavior. Set to 1-247 to make the server only answer
  /// requests addressed to that unit id (unit 0 broadcast is still
  /// answered). Additive field — older saved projects simply don't have
  /// `unit_id` in their JSON and fall back to `255` (unchanged behavior) on
  /// read.
  int unitId;

  /// Wire framing mode: `'tcp'` (the default — classic Modbus TCP with an
  /// MBAP header) or `'rtuOverTcp'` (Modbus RTU framing — no MBAP header,
  /// CRC-16 framed, function-code-derived length — carried over a TCP byte
  /// stream, for masters that expect a serial-style frame, e.g. behind a
  /// terminal server). Stored as the raw string literal rather than the
  /// `kModbusFramingTcp`/`kModbusFramingRtuOverTcp` constants from
  /// `protocols/modbus/modbus_rtu.dart` so this pure-Dart model file doesn't
  /// need to import the protocol layer (mirrors how `wordSwap`/`byteSwap`
  /// are declared). Additive field — older saved projects simply don't have
  /// `framing` in their JSON and fall back to `'tcp'` (unchanged wire
  /// behavior) on read.
  String framing;

  ModbusProtocolConfig({
    this.enabled = false,
    this.port = 502,
    required this.map,
    this.wordSwap = false,
    this.byteSwap = false,
    this.unitId = 255,
    this.framing = 'tcp',
  });

  factory ModbusProtocolConfig.fromJson(Map<String, dynamic> j) => ModbusProtocolConfig(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? 502,
        map: j['map'] != null
            ? ModbusMap.fromJson(j['map'] as Map<String, dynamic>)
            : ModbusMap(entries: []),
        wordSwap: j['word_swap'] == true,
        byteSwap: j['byte_swap'] == true,
        unitId: (j['unit_id'] as num?)?.toInt() ?? 255,
        framing: j['framing'] is String ? j['framing'] as String : 'tcp',
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'port': port,
        'map': map.toJson(),
        'word_swap': wordSwap,
        'byte_swap': byteSwap,
        'unit_id': unitId,
        'framing': framing,
      };

  /// Sane defaults for a project that has never configured Modbus: disabled,
  /// the standard Modbus TCP port, an auto-generated map from the project's
  /// current scalar tags, high-word-first register order, big-endian byte
  /// order within registers, "any" unit id, and classic Modbus TCP framing.
  static ModbusProtocolConfig defaults(PlcProject p) => ModbusProtocolConfig(
        enabled: false,
        port: 502,
        map: ModbusMap.autoGenerate(p),
        wordSwap: false,
        byteSwap: false,
        unitId: 255,
        framing: 'tcp',
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

  /// Interval (ms) between `changedPublishes`/heartbeat host ticks. Default
  /// 250 — a deliberate throttle-down from the original hardcoded 50ms tick
  /// (event-loop-flood fix, WS-perf task): 100 tags at 20Hz previously
  /// re-evaluated `changedPublishes` every 50ms regardless of how many tags
  /// actually changed. Additive field — older saved projects simply don't
  /// have `publish_interval_ms` in their JSON and fall back to this default
  /// on read. The host (`mqtt_host.dart`) clamps this to a minimum of 20ms
  /// before arming its tick timer.
  int publishIntervalMs;

  /// Analog report-by-exception deadband: a NUMERIC mapped metric whose
  /// value has moved by no more than this amount since the last published
  /// baseline is skipped by `changedPublishes` (see mqtt_publisher.dart).
  /// `0.0` (the default) disables the gate entirely — every change publishes,
  /// exactly as before this field existed. BOOL/STRING metrics are never
  /// gated by this value. Additive field — older saved projects simply don't
  /// have `deadband` in their JSON and fall back to `0.0` (unchanged
  /// behavior) on read.
  double deadband;

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
    this.publishIntervalMs = 250,
    this.deadband = 0.0,
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
        publishIntervalMs: (j['publish_interval_ms'] as num?)?.toInt() ?? 250,
        deadband: (j['deadband'] as num?)?.toDouble() ?? 0.0,
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
        'publish_interval_ms': publishIntervalMs,
        'deadband': deadband,
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

  /// Unsolicited CONFIRM-wait timeout (ms) before a retry. DNP3 default 5000.
  int unsolConfirmTimeoutMs;

  /// Max unsolicited retries before giving up (events stay buffered). Default 3.
  int unsolMaxRetries;

  /// Per-class event ring-buffer capacity; oldest dropped + overflow flagged
  /// when full. Default 200.
  int eventBufferPerClass;

  DnpProtocolConfig({
    this.enabled = false,
    this.port = 20000,
    this.outstationAddress = 1024,
    this.masterAddress = 1,
    required this.map,
    this.unsolConfirmTimeoutMs = 5000,
    this.unsolMaxRetries = 3,
    this.eventBufferPerClass = 200,
  });

  factory DnpProtocolConfig.fromJson(Map<String, dynamic> j) => DnpProtocolConfig(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? 20000,
        outstationAddress: (j['outstation_address'] as num?)?.toInt() ?? 1024,
        masterAddress: (j['master_address'] as num?)?.toInt() ?? 1,
        map: j['map'] != null
            ? DnpMap.fromJson(j['map'] as Map<String, dynamic>)
            : DnpMap(entries: []),
        unsolConfirmTimeoutMs: (j['unsol_confirm_timeout_ms'] as num?)?.toInt() ?? 5000,
        unsolMaxRetries: (j['unsol_max_retries'] as num?)?.toInt() ?? 3,
        eventBufferPerClass: (j['event_buffer_per_class'] as num?)?.toInt() ?? 200,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'port': port,
        'outstation_address': outstationAddress,
        'master_address': masterAddress,
        'map': map.toJson(),
        'unsol_confirm_timeout_ms': unsolConfirmTimeoutMs,
        'unsol_max_retries': unsolMaxRetries,
        'event_buffer_per_class': eventBufferPerClass,
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
        unsolConfirmTimeoutMs: 5000,
        unsolMaxRetries: 3,
        eventBufferPerClass: 200,
      );
}

/// Per-project EtherNet/IP + CIP explicit-messaging outbound-protocol
/// configuration: whether the in-app EtherNet/IP host is enabled, the TCP
/// port it listens on, and the symbolic tag<->exposure map that decides
/// which tags are exposed and whether each accepts writes.
class CipProtocolConfig {
  bool enabled;
  int port;
  CipMap map;

  CipProtocolConfig({
    this.enabled = false,
    this.port = 44818,
    required this.map,
  });

  factory CipProtocolConfig.fromJson(Map<String, dynamic> j) => CipProtocolConfig(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? 44818,
        map: j['map'] != null
            ? CipMap.fromJson(j['map'] as Map<String, dynamic>)
            : CipMap(entries: []),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'port': port,
        'map': map.toJson(),
      };

  /// Sane defaults for a project that has never configured EtherNet/IP:
  /// disabled, the standard EtherNet/IP TCP port, and an auto-generated map
  /// from the project's current scalar tags.
  static CipProtocolConfig defaults(PlcProject p) => CipProtocolConfig(
        enabled: false,
        port: 44818,
        map: CipMap.autoPopulate(p),
      );
}

/// Per-project S7comm outbound-protocol configuration: whether the in-app
/// S7comm host is enabled, the TCP port it listens on, and the tag <-> memory
/// area/byte-offset map that decides which tags appear at which address and
/// whether each accepts writes.
///
/// *** PORT 102 IS PRIVILEGED ON Linux AND macOS *** (any port below 1024
/// is). Binding it there needs elevation, and a start attempt without it
/// fails with a permission error rather than starting — which the Outbound
/// Protocols card surfaces verbatim. The port is user-editable precisely so
/// an unprivileged run can move to a high port instead; see
/// `docs/protocols/s7comm.md`.
class S7ProtocolConfig {
  bool enabled;
  int port;
  S7Map map;

  S7ProtocolConfig({
    this.enabled = false,
    this.port = 102,
    required this.map,
  });

  factory S7ProtocolConfig.fromJson(Map<String, dynamic> j) => S7ProtocolConfig(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? 102,
        map: j['map'] != null
            ? S7Map.fromJson(j['map'] as Map<String, dynamic>)
            : S7Map(entries: []),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'port': port,
        'map': map.toJson(),
      };

  /// Sane defaults for a project that has never configured S7comm: disabled,
  /// the standard S7comm TCP port, and an auto-generated map packing the
  /// project's current scalar tags into one data block.
  static S7ProtocolConfig defaults(PlcProject p) => S7ProtocolConfig(
        enabled: false,
        port: 102,
        map: S7Map.autoGenerate(p),
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
  CipProtocolConfig? ethernetIp;
  S7ProtocolConfig? s7;

  ProtocolSettings({
    this.gatewayUrl = kDefaultGatewayUrl,
    this.opcua,
    this.modbus,
    this.mqtt,
    this.dnp3,
    this.ethernetIp,
    this.s7,
  });

  Map<String, dynamic> toJson() => {
        'gateway_url': gatewayUrl,
        if (opcua != null) 'opcua': opcua!.toJson(),
        if (modbus != null) 'modbus': modbus!.toJson(),
        if (mqtt != null) 'mqtt': mqtt!.toJson(),
        if (dnp3 != null) 'dnp3': dnp3!.toJson(),
        if (ethernetIp != null) 'ethernet_ip': ethernetIp!.toJson(),
        if (s7 != null) 's7comm': s7!.toJson(),
      };

  factory ProtocolSettings.fromJson(Map<String, dynamic> j) => ProtocolSettings(
        gatewayUrl: (j['gateway_url'] ?? kDefaultGatewayUrl).toString(),
        opcua: j['opcua'] != null ? OpcUaProtocolConfig.fromJson(j['opcua'] as Map<String, dynamic>) : null,
        modbus: j['modbus'] != null ? ModbusProtocolConfig.fromJson(j['modbus'] as Map<String, dynamic>) : null,
        mqtt: j['mqtt'] != null ? MqttProtocolConfig.fromJson(j['mqtt'] as Map<String, dynamic>) : null,
        dnp3: j['dnp3'] != null ? DnpProtocolConfig.fromJson(j['dnp3'] as Map<String, dynamic>) : null,
        ethernetIp: j['ethernet_ip'] != null
            ? CipProtocolConfig.fromJson(j['ethernet_ip'] as Map<String, dynamic>)
            : null,
        s7: j['s7comm'] != null ? S7ProtocolConfig.fromJson(j['s7comm'] as Map<String, dynamic>) : null,
      );

  static ProtocolSettings defaults(PlcProject p) => ProtocolSettings(
        gatewayUrl: kDefaultGatewayUrl,
        opcua: OpcUaProtocolConfig.defaults(p),
        modbus: ModbusProtocolConfig.defaults(p),
        mqtt: MqttProtocolConfig.defaults(p),
        dnp3: DnpProtocolConfig.defaults(p),
        ethernetIp: CipProtocolConfig.defaults(p),
        s7: S7ProtocolConfig.defaults(p),
      );
}
