// Outbound Protocols section: per-project OPC UA hosting controls (WS19
// Task 4 — Start/Stop the in-app OPC UA server, port, live status/endpoint)
// plus the existing enable toggle, namespace, and node<->tag map editor.
// See docs/superpowers/specs/2026-07-06-in-app-opcua-server-design.md,
// "Architecture" and ADR-010. Purely an opt-in observer — the rest of the
// app runs exactly as it does today whether or not this section is ever
// opened, and whether or not hosting is ever started.
//
// The WebSocket gateway-client connection card (WS16) is retired per
// ADR-010: the app now hosts the OPC UA server in-process instead of
// syncing tags out to a companion process.

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';

import '../models/dnp3_map.dart';
import '../models/modbus_map.dart';
import '../models/mqtt_map.dart';
import '../models/opcua_map.dart';
import '../models/project_model.dart';
import '../models/protocol_settings.dart';
import '../models/tag_resolver.dart';
import '../services/dnp3_host.dart';
import '../services/modbus_host.dart';
import '../services/mqtt_host.dart';
import '../services/opcua_host.dart';
import '../ui/responsive.dart';
import '../widgets/tag_autocomplete_field.dart';

/// Groups outbound-protocol map [entries] by the folder of the tag each
/// entry references, so the map editor can render a subheader per folder
/// (e.g. for a generated test-tag set) instead of one flat list.
///
/// [tagOf] extracts the referenced tag name from an entry; that name is
/// resolved against [p].tags to find the tag's `folder` (default `''`, the
/// project root, when the tag can't be found — e.g. a stale/unmapped name).
///
/// The returned map is ordered with the root folder (`''`) first, if any
/// entries land there, followed by the remaining folders alphabetically.
/// Entry order *within* each bucket preserves the input [entries] order.
/// Pure and side-effect free — safe to unit test without a widget tree.
Map<String, List<T>> groupEntriesByFolder<T>(
  List<T> entries,
  String Function(T) tagOf,
  PlcProject p,
) {
  String folderOf(String tagName) {
    for (final t in p.tags) {
      if (t.name == tagName) {
        return t.folder;
      }
    }
    return '';
  }

  final buckets = <String, List<T>>{};
  for (final entry in entries) {
    buckets.putIfAbsent(folderOf(tagOf(entry)), () => []).add(entry);
  }

  final result = <String, List<T>>{};
  if (buckets.containsKey('')) {
    result[''] = buckets['']!;
  }
  for (final folder in (buckets.keys.where((k) => k != '').toList()..sort())) {
    result[folder] = buckets[folder]!;
  }
  return result;
}

/// Test-only hook (see `test/widgets/gateway_panel_perf_test.dart`):
/// incremented once per `_mqttRow` build. A host's `notifyListeners()`
/// (the MQTT host fires ~4Hz while publishing) must repaint only the
/// connection/status subtree of the MQTT card — never the (virtualized)
/// map rows below it — so a test can assert this counter does not advance
/// across a `mqttHost.notifyListeners()` call. Never read by production
/// code.
@visibleForTesting
int mqttRowBuildCount = 0;

/// One flattened item in a virtualized outbound-protocol map list: either a
/// folder subheader or a single mapped entry. Keeping this as plain data
/// (rather than already-built `Widget`s, as the old `_groupedMapRows`
/// helper returned) is what makes the list lazy — `ListView.builder` only
/// converts the items currently on/near screen into widgets, instead of
/// eagerly building every row up front (as the old `Column` of all rows
/// did, even for a 100+-entry map).
sealed class _MapListItem<T> {}

class _FolderHeaderItem<T> extends _MapListItem<T> {
  _FolderHeaderItem(this.folder, this.count);
  final String folder;
  final int count;
}

class _EntryItem<T> extends _MapListItem<T> {
  _EntryItem(this.entry);
  final T entry;
}

class GatewayScreen extends StatefulWidget {
  final PlcProject currentProject;
  final OpcUaHost host;
  final ModbusHost modbusHost;
  final MqttHost mqttHost;
  final DnpHost dnpHost;
  final VoidCallback onProjectUpdated;

  /// Whether this platform can host the in-app OPC UA/Modbus/DNP3 TCP
  /// servers (or dial out an MQTT connection). Hosting/dialing uses a real
  /// TCP socket, which web browsers do not allow (a start attempt throws
  /// `Unsupported operation: InternetAddress.anyIPv4` for the listen-only
  /// servers, and `Socket.connect` is similarly unavailable), so it's
  /// native-only (Android/iOS/desktop). Defaults to `!kIsWeb`; overridable
  /// for tests.
  final bool hostingSupported;

  const GatewayScreen({
    super.key,
    required this.currentProject,
    required this.host,
    required this.modbusHost,
    required this.mqttHost,
    required this.dnpHost,
    required this.onProjectUpdated,
    this.hostingSupported = !kIsWeb,
  });

  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  late final TextEditingController _portController;
  late final TextEditingController _modbusPortController;
  late final TextEditingController _modbusUnitIdController;
  late final TextEditingController _mqttPortController;
  late final TextEditingController _dnpPortController;
  late final TextEditingController _dnpOutstationAddressController;
  late final TextEditingController _dnpMasterAddressController;

  /// The MQTT broker password: held ONLY here, in ephemeral widget State —
  /// never written to `currentProject`/`MqttProtocolConfig` (see that
  /// class's doc comment). Reset to empty whenever the project identity
  /// changes so a credential typed for one project can never leak into a
  /// Connect attempt against a different one.
  String _mqttPassword = '';

  /// True while an in-flight `host.regenerateCertificate()` call (RSA-2048
  /// keygen — roughly 1-3s) is running, so the "Regenerate certificate"
  /// button can show a brief in-progress state and disable itself against a
  /// double-tap.
  bool _regeneratingOpcuaCert = false;

  @override
  void initState() {
    super.initState();
    _ensureProtocols();
    _portController = TextEditingController(
      text: widget.currentProject.protocols!.opcua!.port.toString(),
    );
    _modbusPortController = TextEditingController(
      text: widget.currentProject.protocols!.modbus!.port.toString(),
    );
    _modbusUnitIdController = TextEditingController(
      text: widget.currentProject.protocols!.modbus!.unitId.toString(),
    );
    _mqttPortController = TextEditingController(
      text: widget.currentProject.protocols!.mqtt!.port.toString(),
    );
    _dnpPortController = TextEditingController(
      text: widget.currentProject.protocols!.dnp3!.port.toString(),
    );
    _dnpOutstationAddressController = TextEditingController(
      text: widget.currentProject.protocols!.dnp3!.outstationAddress.toString(),
    );
    _dnpMasterAddressController = TextEditingController(
      text: widget.currentProject.protocols!.dnp3!.masterAddress.toString(),
    );
  }

  @override
  void didUpdateWidget(covariant GatewayScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Flutter reuses this State across a project switch when the widget
    // type/slot is unchanged, so `_portController` (seeded only once, in
    // initState) can otherwise keep showing the PREVIOUS project's port.
    // Re-sync it whenever the project identity changes.
    if (widget.currentProject.id != oldWidget.currentProject.id) {
      _ensureProtocols();
      final newPort = widget.currentProject.protocols!.opcua!.port.toString();
      if (_portController.text != newPort) {
        _portController.value = TextEditingValue(
          text: newPort,
          selection: TextSelection.collapsed(offset: newPort.length),
        );
      }
      final newModbusPort = widget.currentProject.protocols!.modbus!.port.toString();
      if (_modbusPortController.text != newModbusPort) {
        _modbusPortController.value = TextEditingValue(
          text: newModbusPort,
          selection: TextSelection.collapsed(offset: newModbusPort.length),
        );
      }
      final newModbusUnitId = widget.currentProject.protocols!.modbus!.unitId.toString();
      if (_modbusUnitIdController.text != newModbusUnitId) {
        _modbusUnitIdController.value = TextEditingValue(
          text: newModbusUnitId,
          selection: TextSelection.collapsed(offset: newModbusUnitId.length),
        );
      }
      final newMqttPort = widget.currentProject.protocols!.mqtt!.port.toString();
      if (_mqttPortController.text != newMqttPort) {
        _mqttPortController.value = TextEditingValue(
          text: newMqttPort,
          selection: TextSelection.collapsed(offset: newMqttPort.length),
        );
      }
      final newDnpPort = widget.currentProject.protocols!.dnp3!.port.toString();
      if (_dnpPortController.text != newDnpPort) {
        _dnpPortController.value = TextEditingValue(
          text: newDnpPort,
          selection: TextSelection.collapsed(offset: newDnpPort.length),
        );
      }
      final newDnpOutstationAddress = widget.currentProject.protocols!.dnp3!.outstationAddress.toString();
      if (_dnpOutstationAddressController.text != newDnpOutstationAddress) {
        _dnpOutstationAddressController.value = TextEditingValue(
          text: newDnpOutstationAddress,
          selection: TextSelection.collapsed(offset: newDnpOutstationAddress.length),
        );
      }
      final newDnpMasterAddress = widget.currentProject.protocols!.dnp3!.masterAddress.toString();
      if (_dnpMasterAddressController.text != newDnpMasterAddress) {
        _dnpMasterAddressController.value = TextEditingValue(
          text: newDnpMasterAddress,
          selection: TextSelection.collapsed(offset: newDnpMasterAddress.length),
        );
      }
      _mqttPassword = '';
    }
  }

  @override
  void dispose() {
    _portController.dispose();
    _modbusPortController.dispose();
    _modbusUnitIdController.dispose();
    _mqttPortController.dispose();
    _dnpPortController.dispose();
    _dnpOutstationAddressController.dispose();
    _dnpMasterAddressController.dispose();
    super.dispose();
  }

  String _statusLabel(OpcUaHostStatus s) {
    switch (s) {
      case OpcUaHostStatus.stopped:
        return 'Stopped';
      case OpcUaHostStatus.running:
        return 'Running';
      case OpcUaHostStatus.error:
        return 'Error';
    }
  }

  Color _statusColor(OpcUaHostStatus s) {
    switch (s) {
      case OpcUaHostStatus.stopped:
        return Colors.grey;
      case OpcUaHostStatus.running:
        return Colors.greenAccent;
      case OpcUaHostStatus.error:
        return Colors.redAccent;
    }
  }

  String _modbusStatusLabel(ModbusHostStatus s) {
    switch (s) {
      case ModbusHostStatus.stopped:
        return 'Stopped';
      case ModbusHostStatus.running:
        return 'Running';
      case ModbusHostStatus.error:
        return 'Error';
    }
  }

  Color _modbusStatusColor(ModbusHostStatus s) {
    switch (s) {
      case ModbusHostStatus.stopped:
        return Colors.grey;
      case ModbusHostStatus.running:
        return Colors.greenAccent;
      case ModbusHostStatus.error:
        return Colors.redAccent;
    }
  }

  String _dnpStatusLabel(DnpHostStatus s) {
    switch (s) {
      case DnpHostStatus.stopped:
        return 'Stopped';
      case DnpHostStatus.running:
        return 'Running';
      case DnpHostStatus.error:
        return 'Error';
    }
  }

  Color _dnpStatusColor(DnpHostStatus s) {
    switch (s) {
      case DnpHostStatus.stopped:
        return Colors.grey;
      case DnpHostStatus.running:
        return Colors.greenAccent;
      case DnpHostStatus.error:
        return Colors.redAccent;
    }
  }

  String _mqttStatusLabel(MqttHostStatus s) {
    switch (s) {
      case MqttHostStatus.stopped:
        return 'Stopped';
      case MqttHostStatus.connecting:
        return 'Connecting';
      case MqttHostStatus.running:
        return 'Connected';
      case MqttHostStatus.error:
        return 'Error';
    }
  }

  Color _mqttStatusColor(MqttHostStatus s) {
    switch (s) {
      case MqttHostStatus.stopped:
        return Colors.grey;
      case MqttHostStatus.connecting:
        return Colors.amberAccent;
      case MqttHostStatus.running:
        return Colors.greenAccent;
      case MqttHostStatus.error:
        return Colors.redAccent;
    }
  }

  Future<void> _startHosting() async {
    await widget.host.start(() => widget.currentProject);
  }

  Future<void> _stopHosting() async {
    await widget.host.stop();
  }

  Future<void> _startModbusHosting() async {
    await widget.modbusHost.start(() => widget.currentProject);
  }

  Future<void> _stopModbusHosting() async {
    await widget.modbusHost.stop();
  }

  Future<void> _startDnpHosting() async {
    await widget.dnpHost.start(() => widget.currentProject);
  }

  Future<void> _stopDnpHosting() async {
    await widget.dnpHost.stop();
  }

  Future<void> _connectMqtt() async {
    await widget.mqttHost.connect(() => widget.currentProject, password: _mqttPassword);
  }

  Future<void> _disconnectMqtt() async {
    await widget.mqttHost.disconnect();
  }

  /// Manual "Rebirth" button handler: re-publishes NBIRTH for the current
  /// tag map without disconnecting — see `MqttHost.requestRebirth`'s doc
  /// comment. Only meaningful (and only enabled in the UI) for Sparkplug B;
  /// the host itself is safe to call in any state.
  void _rebirthMqtt() {
    widget.mqttHost.requestRebirth();
  }

  void _autoGenerateMap() {
    setState(() {
      _ensureProtocols();
      widget.currentProject.protocols!.opcua!.map = OpcuaMap.autoGenerate(widget.currentProject);
    });
    widget.onProjectUpdated();
  }

  void _autoGenerateModbusMap() {
    setState(() {
      _ensureModbus();
      widget.currentProject.protocols!.modbus!.map = ModbusMap.autoGenerate(widget.currentProject);
    });
    widget.onProjectUpdated();
  }

  /// Appends a default entry (first available tag option, `holding` table,
  /// address 0, `ReadWrite`) to the Modbus map — the user edits it in place
  /// via the row's tag/table/address/access controls afterward.
  void _addModbusEntry(List<String> tagOptions) {
    setState(() {
      _ensureModbus();
      widget.currentProject.protocols!.modbus!.map.entries.add(ModbusMapEntry(
        tag: tagOptions.isNotEmpty ? tagOptions.first : '',
        table: 'holding',
        address: 0,
        access: 'ReadWrite',
      ));
    });
    widget.onProjectUpdated();
  }

  void _deleteModbusEntry(ModbusMapEntry entry) {
    setState(() {
      widget.currentProject.protocols!.modbus!.map.entries.remove(entry);
    });
    widget.onProjectUpdated();
  }

  void _autoGenerateDnpMap() {
    setState(() {
      _ensureDnp();
      widget.currentProject.protocols!.dnp3!.map = DnpMap.autoGenerate(widget.currentProject);
    });
    widget.onProjectUpdated();
  }

  /// Appends a default entry (first available tag option, `binaryInput`
  /// point type, index 0) to the DNP3 map — mirrors `_addModbusEntry`.
  void _addDnpEntry(List<String> tagOptions) {
    setState(() {
      _ensureDnp();
      widget.currentProject.protocols!.dnp3!.map.entries.add(DnpMapEntry(
        tag: tagOptions.isNotEmpty ? tagOptions.first : '',
        pointType: 'binaryInput',
        index: 0,
      ));
    });
    widget.onProjectUpdated();
  }

  void _deleteDnpEntry(DnpMapEntry entry) {
    setState(() {
      widget.currentProject.protocols!.dnp3!.map.entries.remove(entry);
    });
    widget.onProjectUpdated();
  }

  void _autoGenerateMqttMap() {
    setState(() {
      _ensureMqtt();
      widget.currentProject.protocols!.mqtt!.map = MqttMap.autoGenerate(widget.currentProject);
    });
    widget.onProjectUpdated();
  }

  /// Appends a default entry (first available tag option, metric name blank,
  /// writable) to the MQTT map — mirrors `_addModbusEntry`.
  void _addMqttEntry(List<String> tagOptions) {
    setState(() {
      _ensureMqtt();
      widget.currentProject.protocols!.mqtt!.map.entries.add(MqttMapEntry(
        tag: tagOptions.isNotEmpty ? tagOptions.first : '',
        metric: '',
        writable: true,
      ));
    });
    widget.onProjectUpdated();
  }

  void _deleteMqttEntry(MqttMapEntry entry) {
    setState(() {
      widget.currentProject.protocols!.mqtt!.map.entries.remove(entry);
    });
    widget.onProjectUpdated();
  }

  /// Creates a default `ProtocolSettings` (and its OPC UA config) in place
  /// when the project has none yet, mirroring WS16's `_ensureMap`: mutate in
  /// memory only — do NOT call `onProjectUpdated` here, so an untouched
  /// project stays serialization-clean until the user actually changes
  /// something.
  void _ensureProtocols() {
    widget.currentProject.protocols ??= ProtocolSettings.defaults(widget.currentProject);
    widget.currentProject.protocols!.opcua ??= OpcUaProtocolConfig.defaults(widget.currentProject);
    _ensureModbus();
    _ensureMqtt();
    _ensureDnp();
  }

  /// Creates a default `DnpProtocolConfig` in place when the project has
  /// none yet — mirrors `_ensureModbus`: mutate in memory only, no
  /// `onProjectUpdated` call here.
  void _ensureDnp() {
    widget.currentProject.protocols ??= ProtocolSettings.defaults(widget.currentProject);
    widget.currentProject.protocols!.dnp3 ??= DnpProtocolConfig.defaults(widget.currentProject);
  }

  /// Creates a default `ModbusProtocolConfig` in place when the project has
  /// none yet — mirrors `_ensureProtocols`: mutate in memory only, no
  /// `onProjectUpdated` call here.
  void _ensureModbus() {
    widget.currentProject.protocols ??= ProtocolSettings.defaults(widget.currentProject);
    widget.currentProject.protocols!.modbus ??= ModbusProtocolConfig.defaults(widget.currentProject);
  }

  /// Creates a default `MqttProtocolConfig` in place when the project has
  /// none yet — mirrors `_ensureModbus`: mutate in memory only, no
  /// `onProjectUpdated` call here.
  void _ensureMqtt() {
    widget.currentProject.protocols ??= ProtocolSettings.defaults(widget.currentProject);
    widget.currentProject.protocols!.mqtt ??= MqttProtocolConfig.defaults(widget.currentProject);
  }

  void _setOpcuaEnabled(bool enabled) {
    setState(() {
      _ensureProtocols();
      widget.currentProject.protocols!.opcua!.enabled = enabled;
    });
    // Disabling a protocol while it is hosting must also tear the host down —
    // otherwise the server keeps serving on its socket even though the toggle
    // reads "off" (WS24 review M2).
    if (!enabled && widget.host.status != OpcUaHostStatus.stopped) {
      unawaited(widget.host.stop());
    }
    widget.onProjectUpdated();
  }

  void _setModbusEnabled(bool enabled) {
    setState(() {
      _ensureModbus();
      widget.currentProject.protocols!.modbus!.enabled = enabled;
    });
    if (!enabled && widget.modbusHost.status != ModbusHostStatus.stopped) {
      unawaited(widget.modbusHost.stop());
    }
    widget.onProjectUpdated();
  }

  void _setDnpEnabled(bool enabled) {
    setState(() {
      _ensureDnp();
      widget.currentProject.protocols!.dnp3!.enabled = enabled;
    });
    if (!enabled && widget.dnpHost.status != DnpHostStatus.stopped) {
      unawaited(widget.dnpHost.stop());
    }
    widget.onProjectUpdated();
  }

  void _setDnpPort(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 65535) {
      return; // ignore invalid input; keep the last-valid persisted port
    }
    widget.currentProject.protocols!.dnp3!.port = parsed;
    widget.onProjectUpdated();
  }

  void _setDnpOutstationAddress(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 65535) {
      return; // ignore invalid input; keep the last-valid persisted address
    }
    widget.currentProject.protocols!.dnp3!.outstationAddress = parsed;
    widget.onProjectUpdated();
  }

  void _setDnpMasterAddress(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 65535) {
      return; // ignore invalid input; keep the last-valid persisted address
    }
    widget.currentProject.protocols!.dnp3!.masterAddress = parsed;
    widget.onProjectUpdated();
  }

  void _setOpcuaNamespace(String value) {
    widget.currentProject.protocols!.opcua!.namespaceUri = value;
    widget.onProjectUpdated();
  }

  void _setOpcuaPort(String value) {
    final parsed = int.tryParse(value.trim());
    // 0 is accepted (a valid `ServerSocket.bind` request meaning "let the OS
    // pick a free ephemeral port") in addition to the normal 1-65535 range.
    if (parsed == null || parsed < 0 || parsed > 65535) {
      return; // ignore invalid input; keep the last-valid persisted port
    }
    widget.currentProject.protocols!.opcua!.port = parsed;
    widget.onProjectUpdated();
  }

  /// Recognized `securityModes` tokens (must match exactly what
  /// `OpcUaServerSession._enabledEndpoints` matches on — see
  /// opcua_session.dart). `'None'` is always enabled and non-removable; the
  /// two Basic256Sha256 modes are user-toggleable additions.
  static const String _kSecuritySign = 'Basic256Sha256/Sign';
  static const String _kSecuritySignAndEncrypt = 'Basic256Sha256/SignAndEncrypt';

  void _toggleOpcuaSecurityMode(String mode, bool enabled) {
    setState(() {
      final modes = widget.currentProject.protocols!.opcua!.securityModes;
      if (enabled) {
        if (!modes.contains(mode)) {
          modes.add(mode);
        }
      } else {
        modes.remove(mode);
      }
    });
    widget.onProjectUpdated();
  }

  void _setOpcuaAllowAnonymous(bool value) {
    setState(() {
      widget.currentProject.protocols!.opcua!.allowAnonymous = value;
    });
    widget.onProjectUpdated();
  }

  void _addOpcuaCredential() {
    setState(() {
      widget.currentProject.protocols!.opcua!.credentials
          .add(OpcUaUserCredential(username: '', password: ''));
    });
    widget.onProjectUpdated();
  }

  void _deleteOpcuaCredential(OpcUaUserCredential credential) {
    setState(() {
      widget.currentProject.protocols!.opcua!.credentials.remove(credential);
    });
    widget.onProjectUpdated();
  }

  void _setOpcuaCredentialUsername(OpcUaUserCredential credential, String value) {
    credential.username = value;
    widget.onProjectUpdated();
  }

  void _setOpcuaCredentialPassword(OpcUaUserCredential credential, String value) {
    // In-memory only: `OpcUaUserCredential.toJson` intentionally omits the
    // password (see that class's doc comment), so persisting the project
    // after this edit never writes it to disk.
    credential.password = value;
    widget.onProjectUpdated();
  }

  Future<void> _regenerateOpcuaCertificate() async {
    setState(() => _regeneratingOpcuaCert = true);
    try {
      await widget.host.regenerateCertificate();
    } finally {
      if (mounted) {
        setState(() => _regeneratingOpcuaCert = false);
      }
    }
  }

  void _setModbusPort(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 65535) {
      return; // ignore invalid input; keep the last-valid persisted port
    }
    widget.currentProject.protocols!.modbus!.port = parsed;
    widget.onProjectUpdated();
  }

  void _setModbusWordSwap(bool value) {
    setState(() {
      widget.currentProject.protocols!.modbus!.wordSwap = value;
    });
    widget.onProjectUpdated();
  }

  void _setModbusByteSwap(bool value) {
    setState(() {
      widget.currentProject.protocols!.modbus!.byteSwap = value;
    });
    widget.onProjectUpdated();
  }

  void _setModbusFraming(String value) {
    setState(() {
      widget.currentProject.protocols!.modbus!.framing = value;
    });
    widget.onProjectUpdated();
  }

  void _setModbusUnitId(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 255) {
      return; // ignore invalid input; keep the last-valid persisted unit id
    }
    widget.currentProject.protocols!.modbus!.unitId = parsed;
    widget.onProjectUpdated();
  }

  void _setMqttEnabled(bool enabled) {
    setState(() {
      _ensureMqtt();
      widget.currentProject.protocols!.mqtt!.enabled = enabled;
    });
    // Disabling MQTT while connected/connecting must disconnect the client —
    // otherwise the publisher keeps its broker session open (WS24 review M2).
    if (!enabled && widget.mqttHost.status != MqttHostStatus.stopped) {
      unawaited(widget.mqttHost.disconnect());
    }
    widget.onProjectUpdated();
  }

  void _setMqttHost(String value) {
    widget.currentProject.protocols!.mqtt!.host = value;
    widget.onProjectUpdated();
  }

  void _setMqttPort(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 65535) {
      return; // ignore invalid input; keep the last-valid persisted port
    }
    widget.currentProject.protocols!.mqtt!.port = parsed;
    widget.onProjectUpdated();
  }

  void _setMqttTls(bool value) {
    setState(() {
      widget.currentProject.protocols!.mqtt!.tls = value;
    });
    widget.onProjectUpdated();
  }

  void _setMqttFormat(String value) {
    setState(() {
      widget.currentProject.protocols!.mqtt!.format = value;
    });
    widget.onProjectUpdated();
  }

  void _setMqttBaseTopic(String value) {
    widget.currentProject.protocols!.mqtt!.baseTopic = value;
    widget.onProjectUpdated();
  }

  void _setMqttGroupId(String value) {
    widget.currentProject.protocols!.mqtt!.groupId = value;
    widget.onProjectUpdated();
  }

  void _setMqttEdgeNodeId(String value) {
    widget.currentProject.protocols!.mqtt!.edgeNodeId = value;
    widget.onProjectUpdated();
  }

  void _setMqttQos(int value) {
    setState(() {
      widget.currentProject.protocols!.mqtt!.qos = value;
    });
    widget.onProjectUpdated();
  }

  void _setMqttHeartbeat(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 1) {
      return; // ignore invalid input; keep the last-valid persisted value
    }
    widget.currentProject.protocols!.mqtt!.heartbeatSeconds = parsed;
    widget.onProjectUpdated();
  }

  void _setMqttPublishInterval(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 1) {
      return; // ignore invalid input; keep the last-valid persisted value
    }
    widget.currentProject.protocols!.mqtt!.publishIntervalMs = parsed;
    widget.onProjectUpdated();
  }

  void _setMqttDeadband(String value) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || parsed < 0) {
      return; // ignore invalid input; keep the last-valid persisted value
    }
    widget.currentProject.protocols!.mqtt!.deadband = parsed;
    widget.onProjectUpdated();
  }

  void _setMqttAllowRemoteWrites(bool value) {
    setState(() {
      widget.currentProject.protocols!.mqtt!.allowRemoteWrites = value;
    });
    widget.onProjectUpdated();
  }

  void _setMqttUsername(String value) {
    widget.currentProject.protocols!.mqtt!.username = value;
    widget.onProjectUpdated();
  }

  /// The exposed-tag count: the current map's node count when OPC UA is
  /// enabled (what the address space would/does expose), 0 when disabled.
  int get _displayedExposedCount {
    final opcua = widget.currentProject.protocols?.opcua;
    if (opcua == null || !opcua.enabled) {
      return 0;
    }
    return opcua.map.nodes.length;
  }

  /// Per-protocol tabs (mobile-first — see the design spec referenced at the
  /// top of this file): a scrollable `TabBar` (so four short labels always
  /// fit, even at 320px) plus a `TabBarView` showing the selected protocol's
  /// existing card. Each card builder is reused UNCHANGED — only its
  /// placement moved, from one long vertical list to its own tab — so every
  /// field/toggle/host-wiring/native-only note below is identical to before
  /// this restructuring.
  static const List<Tab> _protocolTabs = [
    Tab(key: Key('protocol_tab_opcua'), text: 'OPC UA'),
    Tab(key: Key('protocol_tab_modbus'), text: 'Modbus'),
    Tab(key: Key('protocol_tab_mqtt'), text: 'MQTT'),
    Tab(key: Key('protocol_tab_dnp3'), text: 'DNP3'),
  ];

  @override
  Widget build(BuildContext context) {
    _ensureProtocols();
    final tagOptions = leafAndNodePaths(widget.currentProject);

    return DefaultTabController(
      length: _protocolTabs.length,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          title: const Text('Outbound Protocols'),
          backgroundColor: const Color(0xFF1E293B),
          bottom: const TabBar(
            isScrollable: true,
            tabs: _protocolTabs,
          ),
        ),
        // No body-wide host listener here (deliberately — see WS-perf task
        // 1): the old `ListenableBuilder(listenable: Listenable.merge([...
        // four hosts]))` around the whole `TabBarView` meant ANY host's
        // `notifyListeners()` (the MQTT host fires ~4Hz while publishing)
        // rebuilt every protocol card, including the (100+-row) map
        // editors. Each card now owns its own narrowly-scoped
        // `ListenableBuilder` around just its status/connection subtree —
        // see `_buildOpcUaCard`/`_buildModbusCard`/`_buildMqttCard`/
        // `_buildDnpCard` — so the map rows are never touched by a host
        // notify.
        body: TabBarView(
          children: [
            _KeepAliveTabBody(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: _buildOpcUaCard(context, tagOptions),
              ),
            ),
            _KeepAliveTabBody(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: _buildModbusCard(context, tagOptions),
              ),
            ),
            _KeepAliveTabBody(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: _buildMqttCard(context, tagOptions),
              ),
            ),
            _KeepAliveTabBody(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: _buildDnpCard(context, tagOptions),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The OPC UA protocol card: header + enable switch, hosting controls
  /// (Start/Stop, port, status, endpoint), and (when enabled) the namespace
  /// field + node-map editor. Adding a future protocol means adding another
  /// `_buildXCard(...)` alongside this one in `build`'s protocol list.
  Widget _buildOpcUaCard(BuildContext context, List<String> tagOptions) {
    final opcua = widget.currentProject.protocols!.opcua!;
    final isCompact = context.isCompact;

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'OPC UA',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                Switch(
                  key: const Key('opcua_enable_switch'),
                  value: opcua.enabled,
                  onChanged: _setOpcuaEnabled,
                ),
              ],
            ),
            if (!opcua.enabled)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Disabled — no tags are exposed to this protocol.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              )
            else ...[
              const SizedBox(height: 12),
              // ── Hosting controls ────────────────────────────────────
              // Scoped to `widget.host` alone (WS-perf task 1) — the status
              // chip, exposed/client/subscription counts, port field's
              // enabled state, Start/Stop buttons, endpoint, and last error
              // are the only things here driven by host notifies, so only
              // this subtree listens. The namespace/security/credentials/
              // cert sections and the (virtualized) node map below are
              // untouched by a host `notifyListeners()`.
              ListenableBuilder(
                listenable: widget.host,
                builder: (context, _) {
                  final status = widget.host.status;
                  final running = status == OpcUaHostStatus.running;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration:
                                    BoxDecoration(color: _statusColor(status), shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _statusLabel(status),
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          Text(
                            'Exposed tags: $_displayedExposedCount',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                          if (widget.host.clientCount > 0)
                            Text(
                              'Clients: ${widget.host.clientCount}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          if (running)
                            Text(
                              'Subscriptions: ${widget.host.subscriptionCount} · Monitored items: ${widget.host.monitoredItemCount}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _portController,
                        enabled: !running,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Port',
                          helperText: 'Default: 4840',
                          filled: true,
                          fillColor: Color(0xFF0F172A),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: _setOpcuaPort,
                      ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: ElevatedButton(
                              onPressed: (running || !widget.hostingSupported) ? null : _startHosting,
                              child: const Text('Start hosting'),
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: OutlinedButton(
                              onPressed: running ? _stopHosting : null,
                              child: const Text('Stop hosting'),
                            ),
                          ),
                        ],
                      ),
                      if (!widget.hostingSupported) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Hosting runs the OPC UA server inside the app on a TCP socket, '
                          'which web browsers do not allow. Run the desktop '
                          '(Windows/macOS/Linux) or mobile (Android/iOS) app to host — '
                          'you can still design the tag map here.',
                          style: TextStyle(fontSize: 11, color: Colors.amber.shade200),
                        ),
                      ],
                      if (running && widget.host.endpointUrl != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          widget.host.endpointUrl!,
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                        ),
                      ],
                      if (widget.host.lastError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Last error: ${widget.host.lastError}',
                          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: opcua.namespaceUri,
                style: const TextStyle(fontSize: 12, color: Colors.white),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Namespace URI',
                  filled: true,
                  fillColor: Color(0xFF0F172A),
                  border: OutlineInputBorder(),
                ),
                onChanged: _setOpcuaNamespace,
              ),
              const SizedBox(height: 12),
              _opcuaSecuritySection(opcua),
              const SizedBox(height: 12),
              _opcuaCredentialsSection(opcua),
              const SizedBox(height: 12),
              _opcuaCertSection(isCompact),
              const SizedBox(height: 12),
              _mapEditorCard(context, opcua.map, tagOptions),
            ],
          ],
        ),
      ),
    );
  }

  /// Security-policy toggles (WS19 Task 6): "None" is always enabled and
  /// shown as a disabled (non-removable) switch; the two Basic256Sha256
  /// modes are user-toggleable and edit `opcua.securityModes` directly. Each
  /// enabled mode becomes one advertised EndpointDescription (see
  /// `OpcUaServerSession._enabledEndpoints`).
  Widget _opcuaSecuritySection(OpcUaProtocolConfig opcua) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Security policy',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 4),
          _opcuaSwitchRow(
            switchKey: const Key('opcua_security_none_switch'),
            title: 'None',
            subtitle: 'Always enabled — unsecured endpoint',
            value: true,
            onChanged: null,
          ),
          _opcuaSwitchRow(
            switchKey: const Key('opcua_security_sign_switch'),
            title: 'Basic256Sha256 — Sign',
            value: opcua.securityModes.contains(_kSecuritySign),
            onChanged: (v) => _toggleOpcuaSecurityMode(_kSecuritySign, v),
          ),
          _opcuaSwitchRow(
            switchKey: const Key('opcua_security_sign_encrypt_switch'),
            title: 'Basic256Sha256 — Sign & Encrypt',
            value: opcua.securityModes.contains(_kSecuritySignAndEncrypt),
            onChanged: (v) => _toggleOpcuaSecurityMode(_kSecuritySignAndEncrypt, v),
          ),
          const SizedBox(height: 4),
          _opcuaSwitchRow(
            switchKey: const Key('opcua_allow_anonymous_switch'),
            title: 'Allow anonymous',
            subtitle: 'When off, clients must authenticate with a username/password below',
            value: opcua.allowAnonymous,
            onChanged: _setOpcuaAllowAnonymous,
          ),
        ],
      ),
    );
  }

  /// A single labeled `Switch` row — deliberately plain `Row`/`Switch`
  /// (rather than `SwitchListTile`) since `SwitchListTile` paints its
  /// background/ink on the nearest `Material` ancestor, which conflicts with
  /// this section's own colored `Container` background (Flutter's "ListTile
  /// background color or ink splashes may be invisible" assertion).
  Widget _opcuaSwitchRow({
    required Key switchKey,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 12)),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
              ],
            ),
          ),
          Switch(key: switchKey, value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// Username/password credential editor (WS19 Task 6): add/remove rows
  /// bound to `opcua.credentials`. Passwords live only in the in-memory
  /// `OpcUaUserCredential` instances — never persisted (see
  /// `OpcUaUserCredential.toJson`).
  Widget _opcuaCredentialsSection(OpcUaProtocolConfig opcua) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              const Text(
                'Credentials',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              TextButton.icon(
                key: const Key('opcua_add_credential_button'),
                icon: const Icon(Icons.add, size: 16, color: Colors.cyanAccent),
                label: const Text('Add credential', style: TextStyle(color: Colors.cyanAccent)),
                onPressed: _addOpcuaCredential,
              ),
            ],
          ),
          if (opcua.credentials.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No username/password credentials configured.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: opcua.credentials.length,
              itemBuilder: (context, i) => _opcuaCredentialRow(opcua.credentials[i], i),
            ),
        ],
      ),
    );
  }

  Widget _opcuaCredentialRow(OpcUaUserCredential credential, int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = context.isCompact;
          final usernameField = TextFormField(
            key: Key('opcua_credential_username_$index'),
            initialValue: credential.username,
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: const InputDecoration(isDense: true, labelText: 'Username'),
            onChanged: (v) => _setOpcuaCredentialUsername(credential, v),
          );
          final passwordField = TextFormField(
            key: Key('opcua_credential_password_$index'),
            initialValue: credential.password,
            obscureText: true,
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: const InputDecoration(isDense: true, labelText: 'Password'),
            onChanged: (v) => _setOpcuaCredentialPassword(credential, v),
          );
          final deleteButton = IconButton(
            key: Key('opcua_credential_delete_$index'),
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
            tooltip: 'Delete credential',
            onPressed: () => _deleteOpcuaCredential(credential),
          );

          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                usernameField,
                const SizedBox(height: 4),
                passwordField,
                Align(alignment: Alignment.centerRight, child: deleteButton),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: usernameField),
              const SizedBox(width: 8),
              Expanded(child: passwordField),
              deleteButton,
            ],
          );
        },
      ),
    );
  }

  /// Read-only app-certificate thumbprint display + Regenerate button (WS19
  /// Task 6): `host.appCertThumbprint` is null until hosting has started at
  /// least once (the identity is loaded in `OpcUaHost.start()`).
  Widget _opcuaCertSection(bool isCompact) {
    final thumbprint = widget.host.appCertThumbprint;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Application certificate',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 8),
          SelectableText(
            key: const Key('opcua_cert_thumbprint_text'),
            thumbprint ?? 'Not yet generated — start hosting to generate the app certificate.',
            style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: isCompact ? double.infinity : null,
            child: OutlinedButton.icon(
              key: const Key('opcua_regenerate_cert_button'),
              icon: _regeneratingOpcuaCert
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.autorenew, size: 16),
              label: Text(_regeneratingOpcuaCert ? 'Regenerating…' : 'Regenerate certificate'),
              onPressed: _regeneratingOpcuaCert ? null : _regenerateOpcuaCertificate,
            ),
          ),
        ],
      ),
    );
  }

  /// Bounded height for a protocol's virtualized map list (WS-perf task 1):
  /// generous enough to show several rows before its own internal scroll
  /// kicks in, but capped so a `ListView.builder` never demands unbounded
  /// height from the card's `Column`/`SingleChildScrollView` ancestor.
  static const double _mapListHeight = 420;

  /// Renders [entries] — grouped by the mapped tag's folder, root bucket
  /// first with no header, via [groupEntriesByFolder] — as a lazy, bounded
  /// `ListView.builder`. Only the on/near-screen rows are ever built, unlike
  /// the old `Column(children: _groupedMapRows(...))`, which eagerly built
  /// every row (100+ for a large map) and kept them all mounted regardless
  /// of scroll position.
  Widget _virtualizedMapList<T>(
    List<T> entries,
    String Function(T) tagOf,
    Widget Function(T) rowBuilder, {
    Key? listKey,
  }) {
    final grouped = groupEntriesByFolder<T>(entries, tagOf, widget.currentProject);
    final items = <_MapListItem<T>>[];
    grouped.forEach((folder, bucket) {
      if (folder.isNotEmpty) {
        items.add(_FolderHeaderItem<T>(folder, bucket.length));
      }
      items.addAll(bucket.map((e) => _EntryItem<T>(e)));
    });

    return SizedBox(
      height: _mapListHeight,
      child: ListView.builder(
        key: listKey,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return switch (item) {
            _FolderHeaderItem<T>() => _folderSubheader(item.folder, item.count),
            _EntryItem<T>() => rowBuilder(item.entry),
          };
        },
      ),
    );
  }

  /// A small subheader row identifying a folder + its entry count within a
  /// grouped map list. Uses Expanded + ellipsis on the folder name so a long
  /// folder name can never push the count off-screen or overflow at narrow
  /// widths (320/360px).
  Widget _folderSubheader(String folder, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 14, color: Colors.grey),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              folder,
              style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Text('($count)', style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _mapEditorCard(BuildContext context, OpcuaMap map, List<String> tagOptions) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'OPC UA Node Map',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.autorenew, size: 16, color: Colors.cyanAccent),
                label: const Text('Regenerate', style: TextStyle(color: Colors.cyanAccent)),
                onPressed: _autoGenerateMap,
              ),
            ],
          ),
          Text(
            'Namespace: ${map.namespaceUri}',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          const SizedBox(height: 8),
          if (map.nodes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No nodes yet. Tap Regenerate to build a default map from the project tags.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            )
          else
            _virtualizedMapList<OpcuaNode>(
              map.nodes,
              (n) => n.tag,
              (n) => _nodeRow(n, tagOptions),
              listKey: const Key('opcua_map_list'),
            ),
        ],
      ),
    );
  }

  Widget _nodeRow(OpcuaNode node, List<String> tagOptions) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = context.isCompact;
          final nodeIdText = Text(
            node.nodeId,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          );
          final tagField = TagAutocompleteField(
            options: tagOptions,
            initialValue: node.tag,
            label: 'Tag',
            onChanged: (v) {
              node.tag = v;
              widget.onProjectUpdated();
            },
          );
          final accessDropdown = DropdownButtonFormField<String>(
            initialValue: node.access,
            decoration: const InputDecoration(isDense: true, labelText: 'Access'),
            style: const TextStyle(fontSize: 12, color: Colors.white),
            dropdownColor: const Color(0xFF1E293B),
            items: const [
              DropdownMenuItem(value: 'ReadOnly', child: Text('ReadOnly')),
              DropdownMenuItem(value: 'ReadWrite', child: Text('ReadWrite')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => node.access = v);
              widget.onProjectUpdated();
            },
          );

          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                nodeIdText,
                const SizedBox(height: 4),
                tagField,
                const SizedBox(height: 4),
                accessDropdown,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: nodeIdText),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: tagField),
              const SizedBox(width: 8),
              SizedBox(width: 160, child: accessDropdown),
            ],
          );
        },
      ),
    );
  }

  /// The Modbus TCP protocol card: header + enable switch, hosting controls
  /// (Start/Stop, port, status, endpoint), and (when enabled) the register
  /// map editor. Mirrors `_buildOpcUaCard`.
  Widget _buildModbusCard(BuildContext context, List<String> tagOptions) {
    final modbus = widget.currentProject.protocols!.modbus!;
    final isCompact = context.isCompact;

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Modbus TCP',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                Switch(
                  key: const Key('modbus_enable_switch'),
                  value: modbus.enabled,
                  onChanged: _setModbusEnabled,
                ),
              ],
            ),
            if (!modbus.enabled)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Disabled — no tags are exposed to this protocol.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              )
            else ...[
              const SizedBox(height: 12),
              // ── Hosting controls ────────────────────────────────────
              // Scoped to `widget.modbusHost` alone (WS-perf task 1): the
              // status chip, client count, port/unit-id fields' enabled
              // state, word/byte-swap switches, Start/Stop buttons,
              // endpoint, and last error are the only things here driven
              // by host notifies. The (virtualized) register map below is
              // untouched by a host `notifyListeners()`.
              ListenableBuilder(
                listenable: widget.modbusHost,
                builder: (context, _) {
                  final status = widget.modbusHost.status;
                  final running = status == ModbusHostStatus.running;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                    color: _modbusStatusColor(status), shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _modbusStatusLabel(status),
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          Text(
                            'Mapped tags: ${modbus.map.entries.length}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                          if (widget.modbusHost.clientCount > 0)
                            Text(
                              'Clients: ${widget.modbusHost.clientCount}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _mqttFlexField(
                            isCompact: isCompact,
                            child: TextField(
                              controller: _modbusPortController,
                              enabled: !running,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Port',
                                helperText: 'Default: 502',
                                filled: true,
                                fillColor: Color(0xFF0F172A),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _setModbusPort,
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          _mqttFlexField(
                            isCompact: isCompact,
                            child: TextField(
                              key: const Key('modbus_unit_id_field'),
                              controller: _modbusUnitIdController,
                              enabled: !running,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Unit ID',
                                helperText: '0-255. Default: 255 (any)',
                                filled: true,
                                fillColor: Color(0xFF0F172A),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _setModbusUnitId,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Reverse word order (word swap) for INT32/FLOAT64 registers',
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ),
                          Switch(
                            key: const Key('modbus_word_swap_switch'),
                            value: modbus.wordSwap,
                            onChanged: running ? null : _setModbusWordSwap,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Reverse byte order (byte swap) within registers',
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ),
                          Switch(
                            key: const Key('modbus_byte_swap_switch'),
                            value: modbus.byteSwap,
                            onChanged: running ? null : _setModbusByteSwap,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: const Key('modbus_framing_dropdown'),
                        // Whitelist fallback: only a recognized framing value
                        // is trusted for display. A project already saved
                        // with 'rtuOverTcp' must show as "RTU over TCP", NOT
                        // be silently coerced to "Modbus TCP" — an unknown
                        // string (future value, corrupted JSON) falls back to
                        // 'tcp' instead of crashing the dropdown.
                        initialValue: modbus.framing == 'rtuOverTcp' ? modbus.framing : 'tcp',
                        decoration: const InputDecoration(isDense: true, labelText: 'Framing'),
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                        dropdownColor: const Color(0xFF1E293B),
                        items: const [
                          DropdownMenuItem(value: 'tcp', child: Text('Modbus TCP')),
                          DropdownMenuItem(value: 'rtuOverTcp', child: Text('RTU over TCP')),
                        ],
                        onChanged: running
                            ? null
                            : (v) {
                                if (v == null) {
                                  return;
                                }
                                _setModbusFraming(v);
                              },
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'RTU over TCP suits masters expecting a serial-style frame '
                        '(e.g. behind a terminal server); Modbus TCP is the standard '
                        'MBAP-framed transport.',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: ElevatedButton(
                              onPressed:
                                  (running || !widget.hostingSupported) ? null : _startModbusHosting,
                              child: const Text('Start hosting'),
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: OutlinedButton(
                              onPressed: running ? _stopModbusHosting : null,
                              child: const Text('Stop hosting'),
                            ),
                          ),
                        ],
                      ),
                      if (!widget.hostingSupported) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Hosting runs the Modbus TCP server inside the app on a TCP '
                          'socket, which web browsers do not allow. Run the desktop '
                          '(Windows/macOS/Linux) or mobile (Android/iOS) app to host — '
                          'you can still design the register map here.',
                          style: TextStyle(fontSize: 11, color: Colors.amber.shade200),
                        ),
                      ],
                      if (running && widget.modbusHost.endpointUrl != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          widget.modbusHost.endpointUrl!,
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                        ),
                      ],
                      if (widget.modbusHost.lastError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Last error: ${widget.modbusHost.lastError}',
                          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              _modbusMapEditorCard(context, modbus.map, tagOptions),
            ],
          ],
        ),
      ),
    );
  }

  Widget _modbusMapEditorCard(BuildContext context, ModbusMap map, List<String> tagOptions) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              const Text(
                'Modbus Register Map',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 16, color: Colors.cyanAccent),
                    label: const Text('Add entry', style: TextStyle(color: Colors.cyanAccent)),
                    onPressed: () => _addModbusEntry(tagOptions),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.autorenew, size: 16, color: Colors.cyanAccent),
                    label: const Text('Regenerate', style: TextStyle(color: Colors.cyanAccent)),
                    onPressed: _autoGenerateModbusMap,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (map.entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No entries yet. Tap Regenerate to build a default map from the project tags.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            )
          else
            _virtualizedMapList<ModbusMapEntry>(
              map.entries,
              (e) => e.tag,
              (e) => _modbusRow(e, tagOptions),
              listKey: const Key('modbus_map_list'),
            ),
        ],
      ),
    );
  }

  Widget _modbusRow(ModbusMapEntry entry, List<String> tagOptions) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = context.isCompact;
          final tagField = TagAutocompleteField(
            options: tagOptions,
            initialValue: entry.tag,
            label: 'Tag',
            onChanged: (v) {
              entry.tag = v;
              widget.onProjectUpdated();
            },
          );
          final tableDropdown = DropdownButtonFormField<String>(
            initialValue: entry.table,
            decoration: const InputDecoration(isDense: true, labelText: 'Table'),
            style: const TextStyle(fontSize: 12, color: Colors.white),
            dropdownColor: const Color(0xFF1E293B),
            items: const [
              DropdownMenuItem(value: 'coil', child: Text('coil')),
              DropdownMenuItem(value: 'discrete', child: Text('discrete')),
              DropdownMenuItem(value: 'holding', child: Text('holding')),
              DropdownMenuItem(value: 'input', child: Text('input')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => entry.table = v);
              widget.onProjectUpdated();
            },
          );
          final addressField = TextFormField(
            initialValue: entry.address.toString(),
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: const InputDecoration(isDense: true, labelText: 'Address'),
            onChanged: (v) {
              final parsed = int.tryParse(v.trim());
              if (parsed == null || parsed < 0) return;
              entry.address = parsed;
              widget.onProjectUpdated();
            },
          );
          final accessDropdown = DropdownButtonFormField<String>(
            initialValue: entry.access,
            decoration: const InputDecoration(isDense: true, labelText: 'Access'),
            style: const TextStyle(fontSize: 12, color: Colors.white),
            dropdownColor: const Color(0xFF1E293B),
            items: const [
              DropdownMenuItem(value: 'ReadOnly', child: Text('ReadOnly')),
              DropdownMenuItem(value: 'ReadWrite', child: Text('ReadWrite')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => entry.access = v);
              widget.onProjectUpdated();
            },
          );
          final deleteButton = IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
            tooltip: 'Delete entry',
            onPressed: () => _deleteModbusEntry(entry),
          );

          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                tagField,
                const SizedBox(height: 4),
                tableDropdown,
                const SizedBox(height: 4),
                addressField,
                const SizedBox(height: 4),
                accessDropdown,
                Align(alignment: Alignment.centerRight, child: deleteButton),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: tagField),
              const SizedBox(width: 8),
              SizedBox(width: 140, child: tableDropdown),
              const SizedBox(width: 8),
              SizedBox(width: 100, child: addressField),
              const SizedBox(width: 8),
              SizedBox(width: 160, child: accessDropdown),
              SizedBox(width: 40, child: deleteButton),
            ],
          );
        },
      ),
    );
  }

  /// The DNP3 outstation protocol card: header + enable switch, hosting
  /// controls (Start/Stop, port, outstation/master link addresses, status,
  /// endpoint), and (when enabled) the point map editor. Mirrors
  /// `_buildModbusCard`.
  Widget _buildDnpCard(BuildContext context, List<String> tagOptions) {
    final dnp3 = widget.currentProject.protocols!.dnp3!;
    final isCompact = context.isCompact;

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'DNP3',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                Switch(
                  key: const Key('dnp_enable_switch'),
                  value: dnp3.enabled,
                  onChanged: _setDnpEnabled,
                ),
              ],
            ),
            if (!dnp3.enabled)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Disabled — no tags are exposed to this protocol.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              )
            else ...[
              const SizedBox(height: 12),
              // ── Hosting controls ────────────────────────────────────
              // Scoped to `widget.dnpHost` alone (WS-perf task 1): the
              // status chip, client count, unsolicited-reporting label,
              // port/address fields' enabled state, Start/Stop buttons,
              // endpoint, and last error are the only things here driven
              // by host notifies. The (virtualized) point map below is
              // untouched by a host `notifyListeners()`.
              ListenableBuilder(
                listenable: widget.dnpHost,
                builder: (context, _) {
                  final status = widget.dnpHost.status;
                  final running = status == DnpHostStatus.running;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration:
                                    BoxDecoration(color: _dnpStatusColor(status), shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _dnpStatusLabel(status),
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          Text(
                            'Mapped tags: ${dnp3.map.entries.length}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                          if (widget.dnpHost.clientCount > 0)
                            Text(
                              'Clients: ${widget.dnpHost.clientCount}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          Text(
                            // Which classes are enabled for unsolicited reporting is
                            // a runtime, master-driven state (ENABLE/DISABLE_UNSOLICITED)
                            // living inside the shared outstation, not project config —
                            // a static "master-controlled" label avoids wiring a live
                            // per-class readout through the host just for display.
                            running ? 'Unsolicited: master-controlled' : 'Unsolicited: off',
                            style: TextStyle(color: Colors.cyanAccent.withValues(alpha: 0.85), fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _mqttFlexField(
                            isCompact: isCompact,
                            child: TextField(
                              controller: _dnpPortController,
                              enabled: !running,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Port',
                                helperText: 'Default: 20000',
                                filled: true,
                                fillColor: Color(0xFF0F172A),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _setDnpPort,
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          _mqttFlexField(
                            isCompact: isCompact,
                            child: TextField(
                              controller: _dnpOutstationAddressController,
                              enabled: !running,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Outstation address',
                                helperText: 'Default: 1024',
                                filled: true,
                                fillColor: Color(0xFF0F172A),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _setDnpOutstationAddress,
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          _mqttFlexField(
                            isCompact: isCompact,
                            child: TextField(
                              controller: _dnpMasterAddressController,
                              enabled: !running,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Master address',
                                helperText: 'Default: 1',
                                filled: true,
                                fillColor: Color(0xFF0F172A),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _setDnpMasterAddress,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: ElevatedButton(
                              onPressed: (running || !widget.hostingSupported) ? null : _startDnpHosting,
                              child: const Text('Start hosting'),
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: OutlinedButton(
                              onPressed: running ? _stopDnpHosting : null,
                              child: const Text('Stop hosting'),
                            ),
                          ),
                        ],
                      ),
                      if (!widget.hostingSupported) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Hosting runs the DNP3 outstation inside the app on a TCP '
                          'socket, which web browsers do not allow. Run the desktop '
                          '(Windows/macOS/Linux) or mobile (Android/iOS) app to host — '
                          'you can still design the point map here.',
                          style: TextStyle(fontSize: 11, color: Colors.amber.shade200),
                        ),
                      ],
                      if (running && widget.dnpHost.endpointUrl != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          widget.dnpHost.endpointUrl!,
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                        ),
                      ],
                      if (widget.dnpHost.lastError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Last error: ${widget.dnpHost.lastError}',
                          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              _dnpMapEditorCard(context, dnp3.map, tagOptions),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dnpMapEditorCard(BuildContext context, DnpMap map, List<String> tagOptions) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              const Text(
                'DNP3 Point Map',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 16, color: Colors.cyanAccent),
                    label: const Text('Add entry', style: TextStyle(color: Colors.cyanAccent)),
                    onPressed: () => _addDnpEntry(tagOptions),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.autorenew, size: 16, color: Colors.cyanAccent),
                    label: const Text('Regenerate', style: TextStyle(color: Colors.cyanAccent)),
                    onPressed: _autoGenerateDnpMap,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (map.entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No entries yet. Tap Regenerate to build a default map from the project tags.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            )
          else
            _virtualizedMapList<DnpMapEntry>(
              map.entries,
              (e) => e.tag,
              (e) => _dnpRow(e, tagOptions),
              listKey: const Key('dnp_map_list'),
            ),
        ],
      ),
    );
  }

  Widget _dnpRow(DnpMapEntry entry, List<String> tagOptions) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = context.isCompact;
          final tagField = TagAutocompleteField(
            options: tagOptions,
            initialValue: entry.tag,
            label: 'Tag',
            onChanged: (v) {
              entry.tag = v;
              widget.onProjectUpdated();
            },
          );
          final pointTypeDropdown = DropdownButtonFormField<String>(
            initialValue: entry.pointType,
            decoration: const InputDecoration(isDense: true, labelText: 'Point type'),
            style: const TextStyle(fontSize: 12, color: Colors.white),
            dropdownColor: const Color(0xFF1E293B),
            items: const [
              DropdownMenuItem(value: 'binaryInput', child: Text('binaryInput')),
              DropdownMenuItem(value: 'binaryOutput', child: Text('binaryOutput')),
              DropdownMenuItem(value: 'analogInput', child: Text('analogInput')),
              DropdownMenuItem(value: 'analogOutput', child: Text('analogOutput')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => entry.pointType = v);
              widget.onProjectUpdated();
            },
          );
          final indexField = TextFormField(
            initialValue: entry.index.toString(),
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: const InputDecoration(isDense: true, labelText: 'Index'),
            onChanged: (v) {
              final parsed = int.tryParse(v.trim());
              if (parsed == null || parsed < 0) return;
              entry.index = parsed;
              widget.onProjectUpdated();
            },
          );
          // Event Class assignment applies to all four DNP3 point types:
          // input changes and output-command changes can both be captured
          // into a Class 1/2/3 event buffer (g2/g32 for inputs, g11/g42 for
          // outputs). Keep this as an explicit flag so a future point type
          // with no event semantics can still be excluded.
          final supportsEvents = entry.pointType == 'binaryInput' ||
              entry.pointType == 'binaryOutput' ||
              entry.pointType == 'analogInput' ||
              entry.pointType == 'analogOutput';
          final Widget eventClassField = supportsEvents
              ? DropdownButtonFormField<int>(
                  key: const Key('dnp_event_class_dropdown'),
                  initialValue: entry.eventClass,
                  decoration: const InputDecoration(isDense: true, labelText: 'Event class'),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  dropdownColor: const Color(0xFF1E293B),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Static')),
                    DropdownMenuItem(value: 1, child: Text('Class 1')),
                    DropdownMenuItem(value: 2, child: Text('Class 2')),
                    DropdownMenuItem(value: 3, child: Text('Class 3')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => entry.eventClass = v);
                    widget.onProjectUpdated();
                  },
                )
              : const Center(child: Text('—', style: TextStyle(color: Colors.grey, fontSize: 12)));
          final deleteButton = IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
            tooltip: 'Delete entry',
            onPressed: () => _deleteDnpEntry(entry),
          );

          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                tagField,
                const SizedBox(height: 4),
                pointTypeDropdown,
                const SizedBox(height: 4),
                indexField,
                const SizedBox(height: 4),
                eventClassField,
                Align(alignment: Alignment.centerRight, child: deleteButton),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: tagField),
              const SizedBox(width: 8),
              SizedBox(width: 190, child: pointTypeDropdown),
              const SizedBox(width: 8),
              SizedBox(width: 100, child: indexField),
              const SizedBox(width: 8),
              SizedBox(width: 140, child: eventClassField),
              SizedBox(width: 40, child: deleteButton),
            ],
          );
        },
      ),
    );
  }

  /// Wraps [child] in `Expanded` for the horizontal (Row) arrangement of a
  /// direction-toggling `Flex`, or returns it as-is for the vertical
  /// (Column) one — `Expanded` inside a `Column` nested in this screen's
  /// `SingleChildScrollView` has no bounded main-axis size to expand into
  /// and throws (an unbounded-height `RenderFlex` exception), whereas a
  /// bare field already fills the available width there without it.
  Widget _mqttFlexField({required bool isCompact, required Widget child}) {
    return isCompact ? child : Expanded(child: child);
  }

  /// The MQTT / Sparkplug B protocol card: header + enable switch,
  /// connection controls (broker host/port/TLS, Connect/Disconnect, status,
  /// endpoint), payload format (with format-conditional identity fields),
  /// QoS/heartbeat/allow-remote-writes controls, optional username, an
  /// in-memory-only password field, and the tag<->metric map editor.
  /// Mirrors `_buildModbusCard`.
  Widget _buildMqttCard(BuildContext context, List<String> tagOptions) {
    final mqtt = widget.currentProject.protocols!.mqtt!;
    final isCompact = context.isCompact;
    final isJson = mqtt.format == 'json';

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'MQTT / Sparkplug B',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                Switch(
                  key: const Key('mqtt_enable_switch'),
                  value: mqtt.enabled,
                  onChanged: _setMqttEnabled,
                ),
              ],
            ),
            if (!mqtt.enabled)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Disabled — no tags are published to this protocol.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              )
            else ...[
              const SizedBox(height: 12),
              // ── Connection controls ─────────────────────────────────
              // Scoped to `widget.mqttHost` alone (WS-perf task 1): the
              // status chip, publish count, and every field/button gated
              // on connected/connecting are the only things here driven by
              // host notifies (the MQTT host fires ~4Hz while publishing).
              // The tag<->metric map editor below is untouched by a host
              // `notifyListeners()` — see `_mqttMapEditorCard`, which
              // scopes its own tiny "tap Rebirth above" hint to a separate,
              // much cheaper `ListenableBuilder` instead.
              ListenableBuilder(
                listenable: widget.mqttHost,
                builder: (context, _) {
                  final status = widget.mqttHost.status;
                  final connected = status == MqttHostStatus.running;
                  final connecting = status == MqttHostStatus.connecting;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration:
                                    BoxDecoration(color: _mqttStatusColor(status), shape: BoxShape.circle),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _mqttStatusLabel(status),
                                style: const TextStyle(
                                    color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          Text(
                            'Mapped tags: ${mqtt.map.entries.length}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                          if (widget.mqttHost.publishCount > 0)
                            Text(
                              'Published: ${widget.mqttHost.publishCount}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // `Expanded` only makes sense in the horizontal (Row)
                          // arrangement — inside the vertical (Column) one used at
                          // compact widths there's no bounded main-axis size for it
                          // to expand into, so the field is a plain (already
                          // full-width) child there instead.
                          _mqttFlexField(
                            isCompact: isCompact,
                            child: TextFormField(
                              initialValue: mqtt.host,
                              enabled: !connected && !connecting,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Broker host',
                                filled: true,
                                fillColor: Color(0xFF0F172A),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _setMqttHost,
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          SizedBox(
                            width: isCompact ? double.infinity : 120,
                            child: TextField(
                              controller: _mqttPortController,
                              enabled: !connected && !connecting,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Port',
                                helperText: 'Default: 1883',
                                filled: true,
                                fillColor: Color(0xFF0F172A),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: _setMqttPort,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('TLS', style: TextStyle(color: Colors.white70, fontSize: 12)),
                          Switch(
                            key: const Key('mqtt_tls_switch'),
                            value: mqtt.tls,
                            onChanged: (connected || connecting) ? null : _setMqttTls,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              key: const Key('mqtt_format_dropdown'),
                              initialValue: mqtt.format,
                              decoration: const InputDecoration(isDense: true, labelText: 'Payload format'),
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              dropdownColor: const Color(0xFF1E293B),
                              items: const [
                                DropdownMenuItem(value: 'json', child: Text('json')),
                                DropdownMenuItem(value: 'sparkplug', child: Text('sparkplug')),
                              ],
                              onChanged: (connected || connecting)
                                  ? null
                                  : (v) {
                                      if (v == null) return;
                                      _setMqttFormat(v);
                                    },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (isJson)
                        TextFormField(
                          initialValue: mqtt.baseTopic,
                          enabled: !connected && !connecting,
                          style: const TextStyle(fontSize: 12, color: Colors.white),
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Base topic',
                            filled: true,
                            fillColor: Color(0xFF0F172A),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: _setMqttBaseTopic,
                        )
                      else
                        Flex(
                          direction: isCompact ? Axis.vertical : Axis.horizontal,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _mqttFlexField(
                              isCompact: isCompact,
                              child: TextFormField(
                                initialValue: mqtt.groupId,
                                enabled: !connected && !connecting,
                                style: const TextStyle(fontSize: 12, color: Colors.white),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  labelText: 'Group ID',
                                  filled: true,
                                  fillColor: Color(0xFF0F172A),
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: _setMqttGroupId,
                              ),
                            ),
                            SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                            _mqttFlexField(
                              isCompact: isCompact,
                              child: TextFormField(
                                initialValue: mqtt.edgeNodeId,
                                enabled: !connected && !connecting,
                                style: const TextStyle(fontSize: 12, color: Colors.white),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  labelText: 'Edge node ID',
                                  helperText: 'Falls back to the project name',
                                  filled: true,
                                  fillColor: Color(0xFF0F172A),
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: _setMqttEdgeNodeId,
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: isCompact ? double.infinity : 120,
                            child: DropdownButtonFormField<int>(
                              key: const Key('mqtt_qos_dropdown'),
                              initialValue: mqtt.qos,
                              decoration: const InputDecoration(isDense: true, labelText: 'QoS'),
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              dropdownColor: const Color(0xFF1E293B),
                              items: const [
                                DropdownMenuItem(value: 0, child: Text('0')),
                                DropdownMenuItem(value: 1, child: Text('1')),
                                DropdownMenuItem(value: 2, child: Text('2')),
                              ],
                              onChanged: (connected || connecting)
                                  ? null
                                  : (v) {
                                      if (v == null) return;
                                      _setMqttQos(v);
                                    },
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          SizedBox(
                            width: isCompact ? double.infinity : 160,
                            child: TextFormField(
                              initialValue: mqtt.heartbeatSeconds.toString(),
                              enabled: !connected && !connecting,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(isDense: true, labelText: 'Heartbeat (s)'),
                              onChanged: _setMqttHeartbeat,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: isCompact ? double.infinity : 160,
                            child: TextFormField(
                              key: const Key('mqtt_publish_interval_field'),
                              initialValue: mqtt.publishIntervalMs.toString(),
                              enabled: !connected && !connecting,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration:
                                  const InputDecoration(isDense: true, labelText: 'Publish interval (ms)'),
                              onChanged: _setMqttPublishInterval,
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          SizedBox(
                            width: isCompact ? double.infinity : 160,
                            child: TextFormField(
                              key: const Key('mqtt_deadband_field'),
                              initialValue: mqtt.deadband.toString(),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              decoration: const InputDecoration(isDense: true, labelText: 'Deadband (analog)'),
                              onChanged: _setMqttDeadband,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Expanded(
                            child: Text('Allow remote writes',
                                style: TextStyle(color: Colors.white70, fontSize: 12)),
                          ),
                          Switch(
                            // Safe to toggle live (unlike format/topic/group/node,
                            // which would break the Sparkplug stream): the host is
                            // always subscribed to the command/NCMD topic and re-reads
                            // this flag on every inbound message, so flipping it while
                            // connected takes effect immediately without a reconnect.
                            key: const Key('mqtt_allow_remote_writes_switch'),
                            value: mqtt.allowRemoteWrites,
                            onChanged: _setMqttAllowRemoteWrites,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: mqtt.username,
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Username (optional)',
                          filled: true,
                          fillColor: Color(0xFF0F172A),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: _setMqttUsername,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('mqtt_password_field'),
                        obscureText: true,
                        style: const TextStyle(fontSize: 12, color: Colors.white),
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Password (session only — never saved)',
                          filled: true,
                          fillColor: Color(0xFF0F172A),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => _mqttPassword = v,
                      ),
                      const SizedBox(height: 12),
                      Flex(
                        direction: isCompact ? Axis.vertical : Axis.horizontal,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: ElevatedButton(
                              onPressed: (connected || connecting || !widget.hostingSupported)
                                  ? null
                                  : _connectMqtt,
                              child: const Text('Connect'),
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: OutlinedButton(
                              onPressed: (connected || connecting) ? _disconnectMqtt : null,
                              child: const Text('Disconnect'),
                            ),
                          ),
                          SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                          SizedBox(
                            width: isCompact ? double.infinity : null,
                            child: Tooltip(
                              message: (connected && !isJson)
                                  ? 'Re-publish NBIRTH with the current tag map — other Sparkplug B '
                                      'subscribers (e.g. Ignition MQTT Engine) will see any tags added '
                                      'or changed while connected.'
                                  : 'Connect with Sparkplug B to re-publish births.',
                              child: OutlinedButton.icon(
                                key: const Key('mqtt_rebirth_button'),
                                icon: const Icon(Icons.campaign_outlined, size: 16),
                                label: const Text('Rebirth'),
                                onPressed: (connected && !isJson) ? _rebirthMqtt : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (!widget.hostingSupported) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Publishing dials the broker over a TCP socket, which web '
                          'browsers do not allow. Run the desktop (Windows/macOS/Linux) '
                          'or mobile (Android/iOS) app to publish — you can still '
                          'design the tag map here.',
                          style: TextStyle(fontSize: 11, color: Colors.amber.shade200),
                        ),
                      ],
                      if ((connected || connecting) && widget.mqttHost.endpointUrl != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          widget.mqttHost.endpointUrl!,
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                        ),
                      ],
                      if (widget.mqttHost.lastError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Last error: ${widget.mqttHost.lastError}',
                          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              _mqttMapEditorCard(context, mqtt.map, tagOptions, isJson: isJson),
            ],
          ],
        ),
      ),
    );
  }

  /// The tag<->metric map editor. Editable (Add entry / edit tag, metric,
  /// writable / delete) at all times, INCLUDING while connected — unlike the
  /// identity fields above (format/base topic/group ID/edge node ID), adding
  /// or removing a mapped tag doesn't itself break the live Sparkplug B
  /// stream; it just means the currently-connected subscriber won't see the
  /// new metric set until a Rebirth is published. The "tap Rebirth above"
  /// hint (shown once connected with Sparkplug format) is the only part of
  /// this card that depends on live host state, so — unlike the rest of the
  /// card — it gets its own tiny `ListenableBuilder` on `widget.mqttHost`
  /// rather than pulling the (virtualized, potentially 100+-row) map list
  /// into the connection-controls listener above.
  Widget _mqttMapEditorCard(
    BuildContext context,
    MqttMap map,
    List<String> tagOptions, {
    required bool isJson,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              const Text(
                'MQTT Tag Map',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 16, color: Colors.cyanAccent),
                    label: const Text('Add entry', style: TextStyle(color: Colors.cyanAccent)),
                    onPressed: () => _addMqttEntry(tagOptions),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.autorenew, size: 16, color: Colors.cyanAccent),
                    label: const Text('Regenerate', style: TextStyle(color: Colors.cyanAccent)),
                    onPressed: _autoGenerateMqttMap,
                  ),
                ],
              ),
            ],
          ),
          ListenableBuilder(
            listenable: widget.mqttHost,
            builder: (context, _) {
              final connected = widget.mqttHost.status == MqttHostStatus.running;
              if (!(connected && !isJson)) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Connected — tap Rebirth above after adding/editing entries so subscribers see them.',
                  style: TextStyle(color: Colors.amber.shade200, fontSize: 11),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          if (map.entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No entries yet. Tap Regenerate to build a default map from the project tags.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            )
          else
            _virtualizedMapList<MqttMapEntry>(
              map.entries,
              (e) => e.tag,
              (e) => _mqttRow(e, tagOptions),
              listKey: const Key('mqtt_map_list'),
            ),
        ],
      ),
    );
  }

  Widget _mqttRow(MqttMapEntry entry, List<String> tagOptions) {
    mqttRowBuildCount++; // test-only hook — see its doc comment above.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = context.isCompact;
          final tagField = TagAutocompleteField(
            options: tagOptions,
            initialValue: entry.tag,
            label: 'Tag',
            onChanged: (v) {
              entry.tag = v;
              widget.onProjectUpdated();
            },
          );
          final metricField = TextFormField(
            initialValue: entry.metric,
            style: const TextStyle(fontSize: 12, color: Colors.white),
            decoration: const InputDecoration(isDense: true, labelText: 'Metric'),
            onChanged: (v) {
              entry.metric = v;
              widget.onProjectUpdated();
            },
          );
          final writableToggle = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Writable', style: TextStyle(color: Colors.white70, fontSize: 11)),
              Switch(
                value: entry.writable,
                onChanged: (v) {
                  setState(() => entry.writable = v);
                  widget.onProjectUpdated();
                },
              ),
            ],
          );
          final deleteButton = IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
            tooltip: 'Delete entry',
            onPressed: () => _deleteMqttEntry(entry),
          );

          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                tagField,
                const SizedBox(height: 4),
                metricField,
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [writableToggle, deleteButton],
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: tagField),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: metricField),
              const SizedBox(width: 8),
              SizedBox(width: 170, child: writableToggle),
              SizedBox(width: 40, child: deleteButton),
            ],
          );
        },
      ),
    );
  }
}

/// Keeps a `TabBarView` page's subtree alive when it scrolls out of view
/// (rather than disposing/rebuilding it on every tab switch), via the
/// standard [AutomaticKeepAliveClientMixin] pattern — `TabBarView`'s
/// underlying `PageView` honors keep-alive requests from its children's
/// slivers, so wrapping each protocol card's tab body in this is enough to
/// preserve its subtree without this screen creating/disposing anything
/// itself. The hosts (`host`/`modbusHost`/`mqttHost`/`dnpHost`) are already
/// owned by the parent regardless — this only protects the tab body's own
/// widget subtree/scroll position from being torn down on every switch.
class _KeepAliveTabBody extends StatefulWidget {
  const _KeepAliveTabBody({required this.child});

  final Widget child;

  @override
  State<_KeepAliveTabBody> createState() => _KeepAliveTabBodyState();
}

class _KeepAliveTabBodyState extends State<_KeepAliveTabBody>
    with AutomaticKeepAliveClientMixin<_KeepAliveTabBody> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    return widget.child;
  }
}
