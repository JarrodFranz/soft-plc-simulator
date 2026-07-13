import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/system_tags.dart';
import '../models/tag_resolver.dart';
import '../models/test_tag_set.dart';
import '../ui/responsive.dart';

/// Resolved, display-ready data for one row of the hierarchical tag tree —
/// shared by both the desktop [DataTable] and the compact card list so the
/// two layouts always render identical values from a single source.
class _TagRowData {
  final String name; // display name/label (root name or '.field'/'[i]'/'.bit')
  final String path; // full dotted/bracketed path from the root tag
  final String displayType; // 'INT32[8]' etc.
  final String quality;
  final String ioClass;
  final bool isTimer;
  final bool expandable;
  final bool isExpanded;
  final bool isDeletable; // only root-level tags can be deleted
  final int depth; // 0 = root tag, 1+ = nested child
  final dynamic rawValue;
  final bool isBoolLeaf;
  final bool hasChildren; // used to pick the value renderer (leaf vs subtree)

  _TagRowData({
    required this.name,
    required this.path,
    required this.displayType,
    required this.quality,
    required this.ioClass,
    required this.isTimer,
    required this.expandable,
    required this.isExpanded,
    required this.isDeletable,
    required this.depth,
    required this.rawValue,
    required this.isBoolLeaf,
    required this.hasChildren,
  });

  String get valueText {
    if (hasChildren) {
      return rawValue is Map
          ? '{...}'
          : (rawValue is List ? '[${(rawValue as List).length}]' : '$rawValue');
    }
    if (isBoolLeaf) {
      return (rawValue == true) ? 'TRUE (1)' : 'FALSE (0)';
    }
    return '$rawValue';
  }
}

class MemoryManagerScreen extends StatefulWidget {
  final PlcProject currentProject;
  final VoidCallback onProjectUpdated;

  const MemoryManagerScreen({
    super.key,
    required this.currentProject,
    required this.onProjectUpdated,
  });

  @override
  State<MemoryManagerScreen> createState() => MemoryManagerScreenState();
}

class MemoryManagerScreenState extends State<MemoryManagerScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Sorting State for Global Tags Table
  int _sortColumnIndex = 0;
  bool _isAscending = true;

  // Set of expanded parent tags (e.g. 'TONTimer', 'TONTimer.PRE')
  final Set<String> _expandedTagKeys = {};

  // Set of folder names collapsed in the folder-grouped tag list (root '' is
  // never collapsible — it always renders its tags directly).
  final Set<String> _collapsedFolders = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _sortTags(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _isAscending = ascending;

      widget.currentProject.tags.sort((a, b) {
        dynamic aValue;
        dynamic bValue;

        switch (columnIndex) {
          case 0: aValue = a.name; bValue = b.name; break;
          case 1: aValue = a.path; bValue = b.path; break;
          case 2: aValue = a.dataType; bValue = b.dataType; break;
          case 3: aValue = a.value.toString(); bValue = b.value.toString(); break;
          case 4: aValue = a.quality; bValue = b.quality; break;
          case 5: aValue = a.ioType; bValue = b.ioType; break;
          default: aValue = a.name; bValue = b.name;
        }

        int cmp = Comparable.compare(aValue, bValue);
        return ascending ? cmp : -cmp;
      });
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Validates and generates a `TestSetSpec`'s bulk test tags, mirroring the
  /// Generate Test Set dialog's save action. Shared by the dialog and tests
  /// so both go through the exact same validation + mutation path.
  ///
  /// Rejects (with a SnackBar) if: the folder name is empty; `minValue` is
  /// not strictly less than `maxValue` (this also guards a downstream
  /// `counter` clamp crash in the signal engine); or any generated tag name
  /// collides with an existing project tag. Otherwise builds the set, adds
  /// the tags + signal generators to the project, appends the tags to each
  /// ticked protocol's map (skipping any protocol that isn't configured on
  /// the project), and notifies [PlcProject] listeners via
  /// `widget.onProjectUpdated`.
  @visibleForTesting
  bool debugGenerateTestSet(
    TestSetSpec spec, {
    required bool opcua,
    required bool modbus,
    required bool dnp3,
    required bool mqtt,
  }) {
    final folder = spec.folder.trim();
    if (folder.isEmpty) {
      _showSnack('Folder name cannot be empty');
      return false;
    }
    if (!(spec.minValue < spec.maxValue)) {
      _showSnack('Min value must be less than max value');
      return false;
    }
    spec.folder = folder;
    final built = buildTestSet(spec);
    final existingNames = widget.currentProject.tags.map((t) => t.name).toSet();
    if (built.tags.any((t) => existingNames.contains(t.name))) {
      _showSnack('A tag with one of these names already exists — choose a different base name');
      return false;
    }

    setState(() {
      widget.currentProject.tags.addAll(built.tags);
      widget.currentProject.signalGens.addAll(built.gens);

      final protocols = widget.currentProject.protocols;
      if (opcua && protocols?.opcua != null) {
        appendToOpcuaMap(protocols!.opcua!.map, built.tags);
      }
      if (modbus && protocols?.modbus != null) {
        appendToModbusMap(protocols!.modbus!.map, built.tags);
      }
      if (dnp3 && protocols?.dnp3 != null) {
        appendToDnpMap(protocols!.dnp3!.map, built.tags);
      }
      if (mqtt && protocols?.mqtt != null) {
        appendToMqttMap(protocols!.mqtt!.map, built.tags);
      }
    });
    widget.onProjectUpdated();
    return true;
  }

  /// Deletes every tag whose `folder` is [folder], along with their
  /// `SignalGen`s (matched by `targetPath`, which is the bare tag name — see
  /// `test_tag_set.dart`) and their entries in all four protocol maps.
  /// Shared by the folder-row delete affordance and tests.
  @visibleForTesting
  void debugDeleteFolder(String folder) {
    final removedNames = widget.currentProject.tags
        .where((t) => t.folder == folder)
        .map((t) => t.name)
        .toSet();
    if (removedNames.isEmpty) {
      return;
    }
    setState(() {
      widget.currentProject.tags.removeWhere((t) => t.folder == folder);
      widget.currentProject.signalGens.removeWhere((g) => removedNames.contains(g.targetPath));

      final protocols = widget.currentProject.protocols;
      protocols?.opcua?.map.nodes.removeWhere((n) => removedNames.contains(n.tag));
      protocols?.modbus?.map.entries.removeWhere((e) => removedNames.contains(e.tag));
      protocols?.dnp3?.map.entries.removeWhere((e) => removedNames.contains(e.tag));
      protocols?.mqtt?.map.entries.removeWhere((e) => removedNames.contains(e.tag));

      _collapsedFolders.remove(folder);
    });
    widget.onProjectUpdated();
  }

  void _confirmDeleteFolder(String folder) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Folder'),
        content: Text(
          'Delete folder "$folder" and all its tags? This removes their signal generators '
          'and any protocol-map entries too. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              debugDeleteFolder(folder);
              Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showGenerateTestSetDialog() {
    final protocols = widget.currentProject.protocols;
    final opcuaAvailable = protocols?.opcua?.enabled == true;
    final modbusAvailable = protocols?.modbus?.enabled == true;
    final dnp3Available = protocols?.dnp3?.enabled == true;
    final mqttAvailable = protocols?.mqtt?.enabled == true;

    showDialog(
      context: context,
      builder: (ctx) {
        final folderCtrl = TextEditingController(text: '');
        final baseNameCtrl = TextEditingController(text: 'Tag');
        final countCtrl = TextEditingController(text: '10');
        final minCtrl = TextEditingController(text: '0');
        final maxCtrl = TextEditingController(text: '100');
        final periodCtrl = TextEditingController(text: '1000');
        String type = 'ramp';
        bool opcua = false;
        bool modbus = false;
        bool dnp3 = false;
        bool mqtt = false;

        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('Generate Test Set'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: folderCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Folder Name'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: baseNameCtrl,
                    decoration: const InputDecoration(labelText: 'Base Tag Name'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: countCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Count'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: 'Signal Type'),
                    items: const ['ramp', 'sine', 'square', 'triangle', 'random', 'counter', 'toggle']
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (val) => setDlgState(() => type = val!),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: minCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Min Value'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: maxCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Max Value'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: periodCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Period (ms)'),
                  ),
                  if (opcuaAvailable || modbusAvailable || dnp3Available || mqttAvailable) ...[
                    const SizedBox(height: 12),
                    const Text('Add to protocol map(s):', style: TextStyle(fontWeight: FontWeight.bold)),
                    if (opcuaAvailable)
                      CheckboxListTile(
                        value: opcua,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('OPC UA'),
                        onChanged: (v) => setDlgState(() => opcua = v ?? false),
                      ),
                    if (modbusAvailable)
                      CheckboxListTile(
                        value: modbus,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('Modbus TCP'),
                        onChanged: (v) => setDlgState(() => modbus = v ?? false),
                      ),
                    if (dnp3Available)
                      CheckboxListTile(
                        value: dnp3,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('DNP3'),
                        onChanged: (v) => setDlgState(() => dnp3 = v ?? false),
                      ),
                    if (mqttAvailable)
                      CheckboxListTile(
                        value: mqtt,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('MQTT'),
                        onChanged: (v) => setDlgState(() => mqtt = v ?? false),
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  final spec = TestSetSpec(
                    folder: folderCtrl.text.trim(),
                    baseName: baseNameCtrl.text.trim().isEmpty ? 'Tag' : baseNameCtrl.text.trim(),
                    count: int.tryParse(countCtrl.text) ?? 0,
                    type: type,
                    minValue: double.tryParse(minCtrl.text) ?? 0,
                    maxValue: double.tryParse(maxCtrl.text) ?? 0,
                    periodMs: int.tryParse(periodCtrl.text) ?? 1000,
                  );
                  final ok = debugGenerateTestSet(spec, opcua: opcua, modbus: modbus, dnp3: dnp3, mqtt: mqtt);
                  if (ok) {
                    Navigator.pop(ctx);
                  }
                },
                child: const Text('Generate'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddTagDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: 'New_Tag');
        final pathCtrl = TextEditingController(text: 'Inputs/New_Tag');
        String dataType = 'BOOL';
        String ioType = 'SimulatedInput';
        final arrayLenCtrl = TextEditingController(text: '0');
        String? errorText;

        final availableTypes = ['BOOL', 'INT16', 'INT32', 'INT64', 'FLOAT64', 'STRING',
            ...builtinCompositeNames(), ...widget.currentProject.structDefs.map((s) => s.name)];

        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('Add Global Tag / Variable'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(labelText: 'Tag Name', errorText: errorText),
                ),
                TextField(controller: pathCtrl, decoration: const InputDecoration(labelText: 'Browse Path')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: dataType,
                  decoration: const InputDecoration(labelText: 'Data Type'),
                  items: availableTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (val) => setDlgState(() => dataType = val!),
                ),
                TextField(
                  controller: arrayLenCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Array Length (0 = scalar)'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: ioType,
                  decoration: const InputDecoration(labelText: 'I/O Classification'),
                  items: ['SimulatedInput', 'SimulatedOutput', 'Internal'].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (val) => setDlgState(() => ioType = val!),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  // `System` is reserved: block creating a same-named tag so
                  // a user can't shadow/effectively rename the built-in one.
                  if (nameCtrl.text.trim() == kSystemTagName) {
                    setDlgState(() => errorText = '"$kSystemTagName" is reserved and cannot be reused');
                    return;
                  }
                  final arrLen = int.tryParse(arrayLenCtrl.text) ?? 0;
                  final tag = PlcTag(
                    name: nameCtrl.text,
                    path: pathCtrl.text,
                    dataType: dataType,
                    arrayLength: arrLen,
                    value: defaultValueFor(widget.currentProject, dataType, arrLen),
                    ioType: ioType,
                  );
                  setState(() {
                    widget.currentProject.tags.add(tag);
                  });
                  widget.onProjectUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Add Tag'),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.currentProject.name} — Memory & Struct Hierarchy'),
        backgroundColor: const Color(0xFF1E293B),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.cyan,
          tabs: const [
            Tab(icon: Icon(Icons.account_tree), text: 'Global Tags & Struct Hierarchy'),
            Tab(icon: Icon(Icons.dataset), text: 'Struct Definitions (DUT)'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildGlobalTagsHierarchicalTab(),
          _buildStructDefsTab(),
        ],
      ),
    );
  }

  Widget _buildGlobalTagsHierarchicalTab() {
    return Scaffold(
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'generateTestSet',
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Generate Test Set'),
            backgroundColor: Colors.deepPurple,
            onPressed: _showGenerateTestSetDialog,
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'addTag',
            icon: const Icon(Icons.add),
            label: const Text('Add Tag'),
            backgroundColor: Colors.cyan,
            onPressed: _showAddTagDialog,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('HIERARCHICAL TAG DATABASE (TIMERS, STRUCTS & BITS)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.cyanAccent)),
            const SizedBox(height: 4),
            const Text('Expand structured tags (timers, DUTs, arrays) to see their members. Expand integer tags to view individual bits.', style: TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 16),

            ..._buildFolderSections(),
          ],
        ),
      ),
    );
  }

  // Top-level tags (no dot in name) bucketed by `folder`, in display order:
  // root ('') first, then every other folder alphabetically.
  Map<String, List<PlcTag>> _tagsByFolder() {
    final grouped = <String, List<PlcTag>>{};
    for (final tag in widget.currentProject.tags.where((t) => !t.name.contains('.'))) {
      grouped.putIfAbsent(tag.folder, () => []).add(tag);
    }
    return grouped;
  }

  List<String> _orderedFolderKeys(Map<String, List<PlcTag>> grouped) {
    final keys = grouped.keys.toList();
    keys.sort((a, b) {
      if (a.isEmpty && b.isEmpty) {
        return 0;
      }
      if (a.isEmpty) {
        return -1;
      }
      if (b.isEmpty) {
        return 1;
      }
      return a.compareTo(b);
    });
    return keys;
  }

  // Root tags (folder == '') render directly with no header (there is
  // nothing to collapse/delete). Every other folder gets a collapsible
  // header showing its tag count and a delete affordance.
  List<Widget> _buildFolderSections() {
    final grouped = _tagsByFolder();
    final sections = <Widget>[];
    for (final key in _orderedFolderKeys(grouped)) {
      final folderTags = grouped[key]!;
      if (key.isEmpty) {
        sections.add(_buildGroupBody(folderTags));
        continue;
      }
      final collapsed = _collapsedFolders.contains(key);
      sections.add(_folderHeader(key, folderTags.length, collapsed));
      if (!collapsed) {
        sections.add(_buildGroupBody(folderTags));
      }
      sections.add(const SizedBox(height: 12));
    }
    return sections;
  }

  Widget _folderHeader(String folder, int count, bool collapsed) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() {
            if (collapsed) {
              _collapsedFolders.remove(folder);
            } else {
              _collapsedFolders.add(folder);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Icon(collapsed ? Icons.folder : Icons.folder_open, color: Colors.amberAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(folder,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Text('$count', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(width: 8),
                touchable(
                  const Icon(Icons.delete_forever, color: Colors.redAccent, size: 18),
                  onTap: () => _confirmDeleteFolder(folder),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Renders one folder-group's rows as a DataTable (wide layouts) or a
  // vertical card list (narrow layouts) — same row-data source either way.
  Widget _buildGroupBody(List<PlcTag> folderTopLevelTags) {
    final data = _buildRowData(topLevelTags: folderTopLevelTags);
    if (context.isExpanded) {
      return Card(
        color: const Color(0xFF1E293B),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            sortColumnIndex: _sortColumnIndex,
            sortAscending: _isAscending,
            columns: [
              DataColumn(label: const Text('Tag / Member Name'), onSort: _sortTags),
              DataColumn(label: const Text('Browse Path'), onSort: _sortTags),
              DataColumn(label: const Text('Data Type'), onSort: _sortTags),
              DataColumn(label: const Text('Live Value'), onSort: _sortTags),
              DataColumn(label: const Text('Quality'), onSort: _sortTags),
              DataColumn(label: const Text('I/O Classification'), onSort: _sortTags),
              const DataColumn(label: Text('Actions / Expand')),
            ],
            rows: _buildHierarchicalRows(data),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _buildRowCards(data),
    );
  }

  // Renders the same row data as a vertical list of Cards for compact widths.
  List<Widget> _buildRowCards(List<_TagRowData> data) {
    return data.map((row) => _tagCard(row)).toList();
  }

  Widget _tagCard(_TagRowData row) {
    final accent = row.isTimer ? Colors.purpleAccent : Colors.amberAccent;
    return Padding(
      padding: EdgeInsets.only(left: 16.0 * row.depth, bottom: 8),
      child: Card(
        color: const Color(0xFF1E293B),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (row.expandable)
                    touchable(
                      Icon(row.isExpanded ? Icons.arrow_drop_down_circle : Icons.play_arrow, size: 18, color: accent),
                      onTap: () => _toggleExpand(row.path),
                    )
                  else
                    const SizedBox(width: kMinTouch, height: kMinTouch),
                  Expanded(
                    child: Text(row.name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace', fontSize: 14),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (row.isDeletable)
                    touchable(
                      const Icon(Icons.delete, color: Colors.redAccent, size: 18),
                      onTap: () => _deleteTag(row.name),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              _cardField('Path', row.path),
              _cardField('Data Type', row.displayType),
              _cardValueField(row),
              _cardField('Quality', row.quality),
              _cardField('I/O Class', row.ioClass),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _cardValueField(_TagRowData row) {
    if (!row.hasChildren && row.isBoolLeaf) {
      final on = row.rawValue == true;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            const SizedBox(
              width: 90,
              child: Text('Live Value', style: TextStyle(color: Colors.grey, fontSize: 11)),
            ),
            touchable(
              Text(row.valueText,
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12, color: on ? Colors.greenAccent : Colors.grey)),
              onTap: () => _toggleBoolValue(row),
            ),
          ],
        ),
      );
    }
    return _cardField('Live Value', row.valueText);
  }

  // Builds the flat, depth-annotated list of resolved row data for the whole
  // tag tree (root tags + expanded descendants). This is the single source
  // of truth consumed by both the DataTable and the compact card list.
  List<_TagRowData> _buildRowData({List<PlcTag>? topLevelTags}) {
    final out = <_TagRowData>[];
    // Filter out child tags that belong under parent structs (e.g. TONTimer.EN) so they render under parent!
    // When [topLevelTags] isn't given (scoping to one folder's group), fall
    // back to every top-level tag in the project.
    final tagsToRender =
        topLevelTags ?? widget.currentProject.tags.where((t) => !t.name.contains('.')).toList();

    for (final tag in tagsToRender) {
      final isTimer = tag.dataType == 'TIMER';
      final expandable = childrenOf(widget.currentProject, tag.name).isNotEmpty;
      final isExpanded = _expandedTagKeys.contains(tag.name);

      out.add(_TagRowData(
        name: tag.name,
        path: tag.name,
        displayType: '${tag.dataType}${tag.arrayLength > 0 ? '[${tag.arrayLength}]' : ''}',
        quality: tag.quality,
        ioClass: tag.ioType,
        isTimer: isTimer,
        expandable: expandable,
        isExpanded: isExpanded,
        // The reserved `System` tag cannot be deleted (see `_deleteTag`); hide
        // the affordance entirely rather than offering a no-op control.
        isDeletable: tag.name != kSystemTagName,
        depth: 0,
        rawValue: tag.value,
        // Root rows render their value as static text (matching the pre-WS5
        // desktop table); only child BOOL leaves toggle. Live BOOL toggling for
        // root tags remains available in the Tag Inspector.
        isBoolLeaf: false,
        hasChildren: expandable,
      ));

      out.addAll(_childRowData(tag.name, 1));
    }

    return out;
  }

  // Resolves the rows for the children of [path] when it is expanded,
  // recursing into any expanded descendant. `depth` drives the indent.
  List<_TagRowData> _childRowData(String path, int depth) {
    final out = <_TagRowData>[];
    if (!_expandedTagKeys.contains(path)) {
      return out;
    }
    for (final child in childrenOf(widget.currentProject, path)) {
      final isExpanded = _expandedTagKeys.contains(child.path);
      // Every field under the reserved System tag is a read-only status
      // readout except `System.AlarmReset`; PlcTag.access isn't enforced at
      // the model layer, so this name-based check is what actually keeps the
      // rest of System un-editable here.
      final isReservedSystemChild = child.path.startsWith('$kSystemTagName.');
      final isWritableSystemChild = child.path == '$kSystemTagName.AlarmReset';
      out.add(_TagRowData(
        name: child.label,
        path: child.path,
        displayType: '${child.dataType}${child.arrayLength > 0 ? '[${child.arrayLength}]' : ''}',
        quality: 'Good',
        ioClass: 'Derived',
        isTimer: false,
        expandable: child.hasChildren,
        isExpanded: isExpanded,
        isDeletable: false,
        depth: depth,
        rawValue: child.value,
        isBoolLeaf: !child.hasChildren &&
            child.dataType == 'BOOL' &&
            (!isReservedSystemChild || isWritableSystemChild),
        hasChildren: child.hasChildren,
      ));
      out.addAll(_childRowData(child.path, depth + 1));
    }
    return out;
  }

  void _toggleExpand(String path) {
    setState(() {
      if (_expandedTagKeys.contains(path)) {
        _expandedTagKeys.remove(path);
      } else {
        _expandedTagKeys.add(path);
      }
    });
  }

  void _deleteTag(String name) {
    // The reserved `System` tag is never deletable: the scheduler and
    // AlarmReset flow depend on it always existing.
    if (name == kSystemTagName) {
      return;
    }
    setState(() {
      widget.currentProject.tags.removeWhere((t) => t.name == name || t.name.startsWith('$name.'));
    });
    widget.onProjectUpdated();
  }

  void _toggleBoolValue(_TagRowData row) {
    writePath(widget.currentProject, row.path, !(row.rawValue == true));
    setState(() {});
    widget.onProjectUpdated();
  }

  List<DataRow> _buildHierarchicalRows(List<_TagRowData> data) {
    return data.map((row) {
      final expandIconColor = row.isTimer ? Colors.purpleAccent : Colors.amberAccent;
      return DataRow(cells: [
        DataCell(Padding(
          padding: EdgeInsets.only(left: row.depth == 0 ? 0 : 16.0 * row.depth),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (row.expandable)
              IconButton(
                icon: Icon(row.isExpanded ? Icons.arrow_drop_down_circle : Icons.play_arrow,
                    size: row.depth == 0 ? 16 : 14, color: expandIconColor),
                padding: EdgeInsets.zero,
                constraints: row.depth == 0 ? const BoxConstraints() : null,
                tooltip: 'Expand Structure Members',
                onPressed: () => _toggleExpand(row.path),
              )
            else if (row.depth > 0)
              const SizedBox(width: 14),
            if (row.depth == 0) const SizedBox(width: 6),
            Text(row.name,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    fontSize: row.depth == 0 ? 14 : 12)),
          ]),
        )),
        DataCell(Text(row.path, style: TextStyle(color: Colors.grey, fontSize: row.depth == 0 ? 11 : 10))),
        DataCell(Container(
          padding: row.depth == 0 ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2) : EdgeInsets.zero,
          decoration: row.depth == 0
              ? BoxDecoration(color: (row.isTimer ? Colors.purple : Colors.cyan).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4))
              : null,
          child: Text(row.displayType,
              style: TextStyle(
                  color: row.depth == 0 ? (row.isTimer ? Colors.purpleAccent : Colors.cyanAccent) : Colors.cyanAccent,
                  fontWeight: row.depth == 0 ? FontWeight.bold : FontWeight.normal,
                  fontSize: row.depth == 0 ? 11 : 10)),
        )),
        DataCell(_valueCellForTable(row)),
        DataCell(Text(row.quality, style: TextStyle(color: row.depth == 0 ? Colors.green : Colors.greenAccent, fontSize: row.depth == 0 ? 11 : 10))),
        DataCell(Text(row.ioClass, style: TextStyle(color: Colors.grey, fontSize: row.depth == 0 ? 11 : 10))),
        DataCell(row.isDeletable
            ? IconButton(
                icon: const Icon(Icons.delete, color: Colors.redAccent, size: 16),
                onPressed: () => _deleteTag(row.name),
              )
            : const SizedBox()),
      ]);
    }).toList();
  }

  // The Live Value cell for the DataTable: BOOL leaves toggle, others display text.
  Widget _valueCellForTable(_TagRowData row) {
    if (!row.hasChildren && row.isBoolLeaf) {
      final on = row.rawValue == true;
      return TextButton(
        onPressed: () => _toggleBoolValue(row),
        child: Text(row.valueText,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: row.depth == 0 ? 12 : 10,
                color: on ? Colors.greenAccent : Colors.grey)),
      );
    }
    return Text(row.valueText,
        style: TextStyle(
            fontWeight: FontWeight.bold,
            color: row.hasChildren ? Colors.grey : (row.depth == 0 ? Colors.greenAccent : Colors.white),
            fontFamily: row.depth == 0 ? 'monospace' : null,
            fontSize: row.depth == 0 ? 13 : 11));
  }

  Widget _buildStructDefsTab() {
    final structs = widget.currentProject.structDefs;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add DUT'),
        backgroundColor: Colors.cyan,
        onPressed: _showAddStructDialog,
      ),
      body: structs.isEmpty
          ? const Center(child: Text('No Struct definitions defined yet.'))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: structs.length,
              itemBuilder: (context, index) {
                final s = structs[index];
                return Card(
                  color: const Color(0xFF1E293B),
                  child: ExpansionTile(
                    leading: const Icon(Icons.dataset, color: Colors.tealAccent),
                    title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${s.fields.length} Fields'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.cyanAccent, size: 20),
                          tooltip: 'Edit DUT',
                          onPressed: () => _showEditStructDialog(s),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                          tooltip: 'Delete DUT',
                          onPressed: () => _confirmDeleteStruct(s),
                        ),
                      ],
                    ),
                    children: s.fields.map((f) => ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 32, right: 16),
                      title: Text(f.name, style: const TextStyle(fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
                      trailing: Text(f.dataType, style: const TextStyle(color: Colors.cyan), overflow: TextOverflow.ellipsis),
                    )).toList(),
                  ),
                );
              },
            ),
    );
  }

  bool _isStructNameTaken(String name) {
    return widget.currentProject.structDefs.any((s) => s.name == name) ||
        builtinCompositeNames().contains(name);
  }

  void _showAddStructDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: '');
        String? errorText;

        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('Add Struct Definition (DUT)'),
            content: TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: InputDecoration(labelText: 'DUT Name', errorText: errorText),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) {
                    setDlgState(() => errorText = 'Name cannot be empty');
                    return;
                  }
                  if (_isStructNameTaken(name)) {
                    setDlgState(() => errorText = 'A type named "$name" already exists');
                    return;
                  }
                  setState(() {
                    widget.currentProject.structDefs.add(PlcStructDef(name: name, fields: []));
                  });
                  widget.onProjectUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Add'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDeleteStruct(PlcStructDef s) {
    if (structDefInUse(widget.currentProject, s.name)) {
      final referencedByTags = widget.currentProject.tags
          .where((t) => t.dataType == s.name)
          .map((t) => t.name)
          .toList();
      final referencedByStructs = widget.currentProject.structDefs
          .where((other) => other.fields.any((f) => f.dataType == s.name))
          .map((other) => other.name)
          .toList();
      final refs = [...referencedByTags, ...referencedByStructs].join(', ');
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cannot Delete DUT'),
          content: Text(
            '"${s.name}" is still in use by: $refs. '
            'Remove or retype those references before deleting this DUT.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete DUT'),
        content: Text('Delete struct definition "${s.name}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                widget.currentProject.structDefs.remove(s);
              });
              widget.onProjectUpdated();
              Navigator.pop(ctx);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showEditStructDialog(PlcStructDef s) {
    final nameCtrl = TextEditingController(text: s.name);
    final fields = s.fields
        .map((f) => StructFieldDef(
              name: f.name,
              dataType: f.dataType,
              arrayLength: f.arrayLength,
              defaultValue: f.defaultValue,
            ))
        .toList();
    String? errorText;

    // A field cannot reference its own containing struct directly (that would
    // create a self-referencing DUT and infinitely recurse when resolving
    // default values), so exclude it from the offered field types here.
    final availableTypes = [
      'BOOL', 'INT16', 'INT32', 'INT64', 'FLOAT64', 'STRING',
      ...builtinCompositeNames(),
      ...widget.currentProject.structDefs.map((d) => d.name).where((n) => n != s.name),
    ];

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('Edit Struct Definition (DUT)'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(labelText: 'DUT Name', errorText: errorText),
                    ),
                    const SizedBox(height: 12),
                    const Text('Fields', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    ...fields.asMap().entries.map((entry) {
                      final i = entry.key;
                      final f = entry.value;
                      final fieldNameCtrl = TextEditingController(text: f.name);
                      final arrayLenCtrl = TextEditingController(text: f.arrayLength.toString());
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: fieldNameCtrl,
                                decoration: const InputDecoration(labelText: 'Field Name', isDense: true),
                                onChanged: (val) => f.name = val,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 3,
                              child: DropdownButton<String>(
                                value: availableTypes.contains(f.dataType) ? f.dataType : availableTypes.first,
                                isExpanded: true,
                                items: availableTypes
                                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                                    .toList(),
                                onChanged: (val) => setDlgState(() {
                                  f.dataType = val!;
                                  // Reset the stale default so it is
                                  // recomputed for the new type (e.g. a BOOL
                                  // `false` must not survive a retype to
                                  // INT32).
                                  f.defaultValue = null;
                                }),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: arrayLenCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'Array Len', isDense: true),
                                onChanged: (val) => f.arrayLength = int.tryParse(val) ?? 0,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.remove_circle, color: Colors.redAccent, size: 20),
                              tooltip: 'Remove Field',
                              onPressed: () => setDlgState(() => fields.removeAt(i)),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add Field'),
                      onPressed: () => setDlgState(() {
                        fields.add(StructFieldDef(
                          name: 'Field${fields.length + 1}',
                          dataType: 'BOOL',
                          defaultValue: false,
                        ));
                      }),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  final newName = nameCtrl.text.trim();
                  if (newName.isEmpty) {
                    setDlgState(() => errorText = 'Name cannot be empty');
                    return;
                  }
                  if (newName != s.name && _isStructNameTaken(newName)) {
                    setDlgState(() => errorText = 'A type named "$newName" already exists');
                    return;
                  }
                  setState(() {
                    if (newName != s.name) {
                      renameStructDef(widget.currentProject, s.name, newName);
                    }
                    s.fields
                      ..clear()
                      ..addAll(fields);
                  });
                  widget.onProjectUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }
}
