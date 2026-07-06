// Gateway panel: connect the app to a companion OPC UA gateway over
// WebSocket, and edit the OPC UA node<->tag map that decides which tags are
// exposed (see docs/superpowers/specs/2026-07-06-opcua-gateway-bridge-design.md,
// "App side"). Purely an opt-in observer — the rest of the app runs exactly
// as it does today whether or not this panel is ever opened.

import 'package:flutter/material.dart';

import '../models/opcua_map.dart';
import '../models/project_model.dart';
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
    _urlController = TextEditingController(text: kDefaultGatewayUrl);
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
    await widget.client.connect(_urlController.text.trim(), widget.currentProject);
  }

  Future<void> _disconnect() async {
    await widget.client.disconnect();
  }

  void _autoGenerateMap() {
    setState(() {
      widget.currentProject.opcuaMap = OpcuaMap.autoGenerate(widget.currentProject);
    });
    widget.onProjectUpdated();
  }

  void _ensureMap() {
    widget.currentProject.opcuaMap ??= OpcuaMap.autoGenerate(widget.currentProject);
  }

  /// The exposed-tag count to show: the client's live count once connected
  /// (reflecting what was actually sent), otherwise the current map's node
  /// count (what *would* be exposed on connect) so the figure is meaningful
  /// even when disconnected.
  int get _displayedExposedCount {
    if (widget.client.status == GatewayStatus.connected) {
      return widget.client.exposedTagCount;
    }
    return widget.currentProject.opcuaMap?.nodes.length ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    _ensureMap();
    final map = widget.currentProject.opcuaMap!;
    final tagOptions = leafAndNodePaths(widget.currentProject);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Gateway — OPC UA Bridge'),
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
                _mapEditorCard(context, map, tagOptions),
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

  Widget _mapEditorCard(BuildContext context, OpcuaMap map, List<String> tagOptions) {
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
