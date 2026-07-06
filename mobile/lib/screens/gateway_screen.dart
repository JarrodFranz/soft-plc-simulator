// Outbound Protocols section: a per-project connection card (gateway
// WebSocket endpoint + Connect/Disconnect + live status) plus one card per
// outbound industrial protocol (currently OPC UA) with an enable/disable
// toggle and, when enabled, its config (namespace + node<->tag map editor).
// See docs/superpowers/specs/2026-07-06-outbound-protocols-config-design.md,
// "The 'Outbound Protocols' section" and "Client wiring". Purely an opt-in
// observer — the rest of the app runs exactly as it does today whether or
// not this section is ever opened, and whether or not any protocol is
// enabled.

import 'package:flutter/material.dart';

import '../models/opcua_map.dart';
import '../models/project_model.dart';
import '../models/protocol_settings.dart';
import '../models/tag_resolver.dart';
import '../services/gateway_client.dart';
import '../ui/responsive.dart';
import '../widgets/tag_autocomplete_field.dart';

class GatewayScreen extends StatefulWidget {
  final PlcProject currentProject;
  final GatewayClient client;
  final VoidCallback onProjectUpdated;

  const GatewayScreen({
    super.key,
    required this.currentProject,
    required this.client,
    required this.onProjectUpdated,
  });

  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _ensureProtocols();
    _urlController = TextEditingController(text: widget.currentProject.protocols!.gatewayUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String _statusLabel(GatewayStatus s) {
    switch (s) {
      case GatewayStatus.disconnected:
        return 'Disconnected';
      case GatewayStatus.connecting:
        return 'Connecting…';
      case GatewayStatus.connected:
        return 'Connected';
      case GatewayStatus.error:
        return 'Error';
    }
  }

  Color _statusColor(GatewayStatus s) {
    switch (s) {
      case GatewayStatus.disconnected:
        return Colors.grey;
      case GatewayStatus.connecting:
        return Colors.amberAccent;
      case GatewayStatus.connected:
        return Colors.greenAccent;
      case GatewayStatus.error:
        return Colors.redAccent;
    }
  }

  Future<void> _connect() async {
    await widget.client.connect(widget.currentProject.protocols!.gatewayUrl, widget.currentProject);
  }

  Future<void> _disconnect() async {
    await widget.client.disconnect();
  }

  void _autoGenerateMap() {
    setState(() {
      _ensureProtocols();
      widget.currentProject.protocols!.opcua!.map = OpcuaMap.autoGenerate(widget.currentProject);
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
  }

  void _setGatewayUrl(String value) {
    widget.currentProject.protocols!.gatewayUrl = value;
    widget.onProjectUpdated();
  }

  void _setOpcuaEnabled(bool enabled) {
    setState(() {
      _ensureProtocols();
      widget.currentProject.protocols!.opcua!.enabled = enabled;
    });
    widget.onProjectUpdated();
  }

  void _setOpcuaNamespace(String value) {
    widget.currentProject.protocols!.opcua!.namespaceUri = value;
    widget.onProjectUpdated();
  }

  /// The exposed-tag count to show: the client's live count once connected
  /// (reflecting what was actually sent), otherwise the current map's node
  /// count when OPC UA is enabled (what *would* be exposed on connect) or 0
  /// when disabled, so the figure is meaningful even when disconnected.
  int get _displayedExposedCount {
    if (widget.client.status == GatewayStatus.connected) {
      return widget.client.exposedTagCount;
    }
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
        listenable: widget.client,
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _connectionCard(context),
                const SizedBox(height: 12),
                const Text(
                  'Protocols',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                _buildOpcUaCard(context, tagOptions),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _connectionCard(BuildContext context) {
    final status = widget.client.status;
    final connected = status == GatewayStatus.connected || status == GatewayStatus.connecting;
    final isCompact = context.isCompact;

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
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
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              enabled: !connected,
              style: const TextStyle(fontSize: 12, color: Colors.white),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Gateway URL',
                helperText: 'Default: $kDefaultGatewayUrl',
                filled: true,
                fillColor: Color(0xFF0F172A),
                border: OutlineInputBorder(),
              ),
              onChanged: _setGatewayUrl,
            ),
            const SizedBox(height: 12),
            Flex(
              direction: isCompact ? Axis.vertical : Axis.horizontal,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: isCompact ? double.infinity : null,
                  child: ElevatedButton(
                    onPressed: connected ? null : _connect,
                    child: const Text('Connect'),
                  ),
                ),
                SizedBox(width: isCompact ? 0 : 12, height: isCompact ? 8 : 0),
                SizedBox(
                  width: isCompact ? double.infinity : null,
                  child: OutlinedButton(
                    onPressed: connected ? _disconnect : null,
                    child: const Text('Disconnect'),
                  ),
                ),
              ],
            ),
            if (widget.client.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                'Last error: ${widget.client.lastError}',
                style: const TextStyle(color: Colors.redAccent, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The OPC UA protocol card: header + enable switch, and (when enabled)
  /// the namespace field + node-map editor. Adding a future protocol means
  /// adding another `_buildXCard(...)` alongside this one in `build`'s
  /// protocol list.
  Widget _buildOpcUaCard(BuildContext context, List<String> tagOptions) {
    final opcua = widget.currentProject.protocols!.opcua!;
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
              const SizedBox(height: 8),
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
}
