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

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/modbus_map.dart';
import '../models/mqtt_map.dart';
import '../models/opcua_map.dart';
import '../models/project_model.dart';
import '../models/protocol_settings.dart';
import '../models/tag_resolver.dart';
import '../services/modbus_host.dart';
import '../services/mqtt_host.dart';
import '../services/opcua_host.dart';
import '../ui/responsive.dart';
import '../widgets/tag_autocomplete_field.dart';

class GatewayScreen extends StatefulWidget {
  final PlcProject currentProject;
  final OpcUaHost host;
  final ModbusHost modbusHost;
  final MqttHost mqttHost;
  final VoidCallback onProjectUpdated;

  /// Whether this platform can host the in-app OPC UA/Modbus TCP servers (or
  /// dial out an MQTT connection). Hosting/dialing uses a real TCP socket,
  /// which web browsers do not allow (a start attempt throws `Unsupported
  /// operation: InternetAddress.anyIPv4` for the listen-only servers, and
  /// `Socket.connect` is similarly unavailable), so it's native-only
  /// (Android/iOS/desktop). Defaults to `!kIsWeb`; overridable for tests.
  final bool hostingSupported;

  const GatewayScreen({
    super.key,
    required this.currentProject,
    required this.host,
    required this.modbusHost,
    required this.mqttHost,
    required this.onProjectUpdated,
    this.hostingSupported = !kIsWeb,
  });

  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  late final TextEditingController _portController;
  late final TextEditingController _modbusPortController;
  late final TextEditingController _mqttPortController;

  /// The MQTT broker password: held ONLY here, in ephemeral widget State —
  /// never written to `currentProject`/`MqttProtocolConfig` (see that
  /// class's doc comment). Reset to empty whenever the project identity
  /// changes so a credential typed for one project can never leak into a
  /// Connect attempt against a different one.
  String _mqttPassword = '';

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
    _mqttPortController = TextEditingController(
      text: widget.currentProject.protocols!.mqtt!.port.toString(),
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
      final newMqttPort = widget.currentProject.protocols!.mqtt!.port.toString();
      if (_mqttPortController.text != newMqttPort) {
        _mqttPortController.value = TextEditingValue(
          text: newMqttPort,
          selection: TextSelection.collapsed(offset: newMqttPort.length),
        );
      }
      _mqttPassword = '';
    }
  }

  @override
  void dispose() {
    _portController.dispose();
    _modbusPortController.dispose();
    _mqttPortController.dispose();
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

  Future<void> _connectMqtt() async {
    await widget.mqttHost.connect(() => widget.currentProject, password: _mqttPassword);
  }

  Future<void> _disconnectMqtt() async {
    await widget.mqttHost.disconnect();
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

  void _setModbusPort(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0 || parsed > 65535) {
      return; // ignore invalid input; keep the last-valid persisted port
    }
    widget.currentProject.protocols!.modbus!.port = parsed;
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

  @override
  Widget build(BuildContext context) {
    _ensureProtocols();
    final tagOptions = leafAndNodePaths(widget.currentProject);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Outbound Protocols'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([widget.host, widget.modbusHost, widget.mqttHost]),
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Protocols',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                _buildOpcUaCard(context, tagOptions),
                const SizedBox(height: 12),
                _buildModbusCard(context, tagOptions),
                const SizedBox(height: 12),
                _buildMqttCard(context, tagOptions),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The OPC UA protocol card: header + enable switch, hosting controls
  /// (Start/Stop, port, status, endpoint), and (when enabled) the namespace
  /// field + node-map editor. Adding a future protocol means adding another
  /// `_buildXCard(...)` alongside this one in `build`'s protocol list.
  Widget _buildOpcUaCard(BuildContext context, List<String> tagOptions) {
    final opcua = widget.currentProject.protocols!.opcua!;
    final status = widget.host.status;
    final running = status == OpcUaHostStatus.running;
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
                        decoration: BoxDecoration(color: _statusColor(status), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _statusLabel(status),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
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
              _mapEditorCard(context, opcua.map, tagOptions),
            ],
          ],
        ),
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
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: map.nodes.length,
              itemBuilder: (context, i) => _nodeRow(map.nodes[i], tagOptions),
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
    final status = widget.modbusHost.status;
    final running = status == ModbusHostStatus.running;
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
                        decoration: BoxDecoration(color: _modbusStatusColor(status), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _modbusStatusLabel(status),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
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
              TextField(
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
              const SizedBox(height: 12),
              Flex(
                direction: isCompact ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: isCompact ? double.infinity : null,
                    child: ElevatedButton(
                      onPressed: (running || !widget.hostingSupported) ? null : _startModbusHosting,
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
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: map.entries.length,
              itemBuilder: (context, i) => _modbusRow(map.entries[i], tagOptions),
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
    final status = widget.mqttHost.status;
    final connected = status == MqttHostStatus.running;
    final connecting = status == MqttHostStatus.connecting;
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
                        decoration: BoxDecoration(color: _mqttStatusColor(status), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _mqttStatusLabel(status),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
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
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                    child: Text('Allow remote writes', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                  Switch(
                    key: const Key('mqtt_allow_remote_writes_switch'),
                    value: mqtt.allowRemoteWrites,
                    onChanged: (connected || connecting) ? null : _setMqttAllowRemoteWrites,
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
                      onPressed:
                          (connected || connecting || !widget.hostingSupported) ? null : _connectMqtt,
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
              const SizedBox(height: 12),
              _mqttMapEditorCard(context, mqtt.map, tagOptions),
            ],
          ],
        ),
      ),
    );
  }

  Widget _mqttMapEditorCard(BuildContext context, MqttMap map, List<String> tagOptions) {
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
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: map.entries.length,
              itemBuilder: (context, i) => _mqttRow(map.entries[i], tagOptions),
            ),
        ],
      ),
    );
  }

  Widget _mqttRow(MqttMapEntry entry, List<String> tagOptions) {
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
