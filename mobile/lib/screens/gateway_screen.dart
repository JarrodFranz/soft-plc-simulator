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

import 'package:flutter/material.dart';

import '../models/opcua_map.dart';
import '../models/project_model.dart';
import '../models/protocol_settings.dart';
import '../models/tag_resolver.dart';
import '../services/opcua_host.dart';
import '../ui/responsive.dart';
import '../widgets/tag_autocomplete_field.dart';

class GatewayScreen extends StatefulWidget {
  final PlcProject currentProject;
  final OpcUaHost host;
  final VoidCallback onProjectUpdated;

  const GatewayScreen({
    super.key,
    required this.currentProject,
    required this.host,
    required this.onProjectUpdated,
  });

  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  late final TextEditingController _portController;

  @override
  void initState() {
    super.initState();
    _ensureProtocols();
    _portController = TextEditingController(
      text: widget.currentProject.protocols!.opcua!.port.toString(),
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
    }
  }

  @override
  void dispose() {
    _portController.dispose();
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

  Future<void> _startHosting() async {
    await widget.host.start(() => widget.currentProject);
  }

  Future<void> _stopHosting() async {
    await widget.host.stop();
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
        listenable: widget.host,
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
                      onPressed: running ? null : _startHosting,
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
}
