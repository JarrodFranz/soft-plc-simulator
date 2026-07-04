import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/tag_resolver.dart';

class MemoryManagerScreen extends StatefulWidget {
  final PlcProject currentProject;
  final VoidCallback onProjectUpdated;

  const MemoryManagerScreen({
    super.key,
    required this.currentProject,
    required this.onProjectUpdated,
  });

  @override
  State<MemoryManagerScreen> createState() => _MemoryManagerScreenState();
}

class _MemoryManagerScreenState extends State<MemoryManagerScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Sorting State for Global Tags Table
  int _sortColumnIndex = 0;
  bool _isAscending = true;

  // Set of expanded parent tags (e.g. 'TONTimer', 'TONTimer.PRE')
  final Set<String> _expandedTagKeys = {};

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

  void _showAddTagDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: 'New_Tag');
        final pathCtrl = TextEditingController(text: 'Inputs/New_Tag');
        String dataType = 'BOOL';
        String ioType = 'SimulatedInput';
        final arrayLenCtrl = TextEditingController(text: '0');

        final availableTypes = ['BOOL', 'INT16', 'INT32', 'INT64', 'FLOAT64', 'STRING',
            ...builtinCompositeNames(), ...widget.currentProject.structDefs.map((s) => s.name)];

        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('Add Global Tag / Variable'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Tag Name')),
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
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add Tag'),
        backgroundColor: Colors.cyan,
        onPressed: _showAddTagDialog,
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

            Card(
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
                  rows: _buildHierarchicalRows(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<DataRow> _buildHierarchicalRows() {
    final rows = <DataRow>[];
    // Filter out child tags that belong under parent structs (e.g. TONTimer.EN) so they render under parent!
    final topLevelTags = widget.currentProject.tags.where((t) => !t.name.contains('.')).toList();

    for (var tag in topLevelTags) {
      final isTimer = tag.dataType == 'TIMER';
      final expandable = childrenOf(widget.currentProject, tag.name).isNotEmpty;
      final isParentExpanded = _expandedTagKeys.contains(tag.name);

      rows.add(DataRow(
        cells: [
          DataCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (expandable)
                IconButton(
                  icon: Icon(isParentExpanded ? Icons.arrow_drop_down_circle : Icons.play_arrow, size: 16, color: isTimer ? Colors.purpleAccent : Colors.amberAccent),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Expand Structure Members',
                  onPressed: () {
                    setState(() {
                      if (isParentExpanded) {
                        _expandedTagKeys.remove(tag.name);
                      } else {
                        _expandedTagKeys.add(tag.name);
                      }
                    });
                  },
                ),
              const SizedBox(width: 6),
              Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace')),
            ],
          )),
          DataCell(Text(tag.path, style: const TextStyle(color: Colors.grey, fontSize: 11))),
          DataCell(Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: (isTimer ? Colors.purple : Colors.cyan).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
            child: Text('${tag.dataType}${tag.arrayLength > 0 ? '[${tag.arrayLength}]' : ''}', style: TextStyle(color: isTimer ? Colors.purpleAccent : Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 11)),
          )),
          DataCell(Text(tag.value.toString(), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent, fontFamily: 'monospace'))),
          DataCell(Text(tag.quality, style: const TextStyle(color: Colors.green, fontSize: 11))),
          DataCell(Text(tag.ioType, style: const TextStyle(color: Colors.grey, fontSize: 11))),
          DataCell(IconButton(
            icon: const Icon(Icons.delete, color: Colors.redAccent, size: 16),
            onPressed: () {
              setState(() {
                widget.currentProject.tags.removeWhere((t) => t.name == tag.name || t.name.startsWith('${tag.name}.'));
              });
              widget.onProjectUpdated();
            },
          )),
        ],
      ));

      rows.addAll(_childRows(tag.name, 1));
    }

    return rows;
  }

  // Emits DataRows for the children of [path] when it is expanded, recursing
  // into any expanded descendant. `depth` drives the indent.
  List<DataRow> _childRows(String path, int depth) {
    final rows = <DataRow>[];
    if (!_expandedTagKeys.contains(path)) {
      return rows;
    }
    for (final child in childrenOf(widget.currentProject, path)) {
      final expandable = child.hasChildren;
      final isExpanded = _expandedTagKeys.contains(child.path);
      rows.add(DataRow(cells: [
        DataCell(Padding(
          padding: EdgeInsets.only(left: 16.0 * depth),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (expandable)
              IconButton(
                icon: Icon(isExpanded ? Icons.arrow_drop_down_circle : Icons.play_arrow,
                    size: 14, color: Colors.amberAccent),
                onPressed: () => setState(() {
                  if (isExpanded) {
                    _expandedTagKeys.remove(child.path);
                  } else {
                    _expandedTagKeys.add(child.path);
                  }
                }),
              )
            else
              const SizedBox(width: 14),
            Text(child.label,
                style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 12)),
          ]),
        )),
        DataCell(Text(child.path, style: const TextStyle(fontSize: 10, color: Colors.grey))),
        DataCell(Text('${child.dataType}${child.arrayLength > 0 ? '[${child.arrayLength}]' : ''}',
            style: const TextStyle(fontSize: 10, color: Colors.cyanAccent))),
        DataCell(_leafValueCell(child)),
        const DataCell(Text('Good', style: TextStyle(color: Colors.greenAccent, fontSize: 10))),
        const DataCell(Text('Derived', style: TextStyle(fontSize: 10, color: Colors.grey))),
        const DataCell(SizedBox()),
      ]));
      rows.addAll(_childRows(child.path, depth + 1));
    }
    return rows;
  }

  // A value cell for a leaf child: BOOL toggles, integers/others show value.
  Widget _leafValueCell(TagChild child) {
    if (child.hasChildren) {
      return Text(child.value is Map ? '{...}' : (child.value is List ? '[${(child.value as List).length}]' : '${child.value}'),
          style: const TextStyle(fontSize: 10, color: Colors.grey));
    }
    if (child.dataType == 'BOOL') {
      final on = child.value == true;
      return TextButton(
        onPressed: () {
          writePath(widget.currentProject, child.path, !on);
          setState(() {});
          widget.onProjectUpdated();
        },
        child: Text(on ? 'TRUE (1)' : 'FALSE (0)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: on ? Colors.greenAccent : Colors.grey)),
      );
    }
    return Text('${child.value}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white));
  }

  Widget _buildStructDefsTab() {
    final structs = widget.currentProject.structDefs;
    return Scaffold(
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
                    children: s.fields.map((f) => ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 32, right: 16),
                      title: Text(f.name, style: const TextStyle(fontFamily: 'monospace')),
                      trailing: Text(f.dataType, style: const TextStyle(color: Colors.cyan)),
                    )).toList(),
                  ),
                );
              },
            ),
    );
  }
}
