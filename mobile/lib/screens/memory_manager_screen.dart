import 'package:flutter/material.dart';
import '../models/project_model.dart';

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
    _tabController = TabController(length: 3, vsync: this);
    _ensureTimerParentTags();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _ensureTimerParentTags() {
    // Check if TONTimer parent exists
    if (!widget.currentProject.tags.any((t) => t.name == 'TONTimer')) {
      widget.currentProject.tags.add(PlcTag(
        name: 'TONTimer',
        path: 'Timers/TONTimer',
        dataType: 'TIMER',
        value: 'Struct [PRE: 5000, ACC: 0]',
        ioType: 'Internal',
        description: 'Timer Structure (EN, TT, DN, PRE, ACC)',
      ));
    }
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

  void _toggleBitValue(PlcTag parentTag, int bitIndex) {
    if (parentTag.value is! int) return;
    int currentInt = parentTag.value as int;
    int mask = 1 << bitIndex;
    int newInt = currentInt ^ mask;

    setState(() {
      parentTag.value = newInt;
    });
    widget.onProjectUpdated();
  }

  void _showAddTagDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: 'New_Tag');
        final pathCtrl = TextEditingController(text: 'Inputs/New_Tag');
        String dataType = 'BOOL';
        String ioType = 'SimulatedInput';

        final availableTypes = ['BOOL', 'INT16', 'INT32', 'FLOAT64', 'STRING', 'TIMER', ...widget.currentProject.structDefs.map((s) => s.name)];

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
                  final tag = PlcTag(
                    name: nameCtrl.text,
                    path: pathCtrl.text,
                    dataType: dataType,
                    value: dataType == 'BOOL' ? false : (dataType.startsWith('INT') ? 0 : 0.0),
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
            Tab(icon: Icon(Icons.inventory_2), text: 'Data Blocks (DB)'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildGlobalTagsHierarchicalTab(),
          _buildStructDefsTab(),
          _buildDataBlocksTab(),
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
            const Text('Expand TIMER structures (TONTimer) to see .EN, .TT, .DN, .PRE, .ACC members. Expand integer members to view individual bits (.0 to .15).', style: TextStyle(color: Colors.grey, fontSize: 11)),
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
    // Filter out child tags that belong under parent timer structs (e.g. TONTimer.EN) so they render under parent!
    final topLevelTags = widget.currentProject.tags.where((t) => !t.name.contains('.')).toList();

    for (var tag in topLevelTags) {
      final isTimer = tag.dataType == 'TIMER';
      final isInt = tag.dataType.startsWith('INT');
      final isParentExpanded = _expandedTagKeys.contains(tag.name);

      rows.add(DataRow(
        cells: [
          DataCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isTimer || isInt)
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
            child: Text(tag.dataType, style: TextStyle(color: isTimer ? Colors.purpleAccent : Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 11)),
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

      // Expand TIMER Structure Children (TONTimer.EN, TONTimer.TT, TONTimer.DN, TONTimer.PRE, TONTimer.ACC)
      if (isTimer && isParentExpanded) {
        final childTags = widget.currentProject.tags.where((t) => t.name.startsWith('${tag.name}.')).toList();

        for (var child in childTags) {
          final isChildInt = child.dataType.startsWith('INT');
          final isChildExpanded = _expandedTagKeys.contains(child.name);

          rows.add(DataRow(
            color: WidgetStateProperty.all(const Color(0xFF161E2E)),
            cells: [
              DataCell(Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isChildInt)
                      IconButton(
                        icon: Icon(isChildExpanded ? Icons.arrow_drop_down_circle : Icons.play_arrow, size: 14, color: Colors.amberAccent),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          setState(() {
                            if (isChildExpanded) {
                              _expandedTagKeys.remove(child.name);
                            } else {
                              _expandedTagKeys.add(child.name);
                            }
                          });
                        },
                      ),
                    const SizedBox(width: 4),
                    Text(child.name, style: const TextStyle(fontFamily: 'monospace', color: Colors.purpleAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                  ],
                ),
              )),
              DataCell(Text(child.path, style: const TextStyle(color: Colors.grey, fontSize: 10))),
              DataCell(Text(child.dataType, style: const TextStyle(color: Colors.purple, fontSize: 10))),
              DataCell(Text(child.value.toString(), style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 11))),
              const DataCell(Text('Good', style: TextStyle(color: Colors.green, fontSize: 10))),
              const DataCell(Text('Timer Member', style: TextStyle(color: Colors.grey, fontSize: 10))),
              const DataCell(Text('Member', style: TextStyle(color: Colors.grey, fontSize: 10))),
            ],
          ));

          // Expand Integer Bits under Child (.PRE.0 to .PRE.15)
          if (isChildInt && isChildExpanded) {
            final int val = (child.value is int) ? (child.value as int) : 0;
            for (int b = 0; b < 16; b++) {
              final bool bitVal = (val & (1 << b)) != 0;
              rows.add(DataRow(
                color: WidgetStateProperty.all(const Color(0xFF0F172A)),
                cells: [
                  DataCell(Padding(
                    padding: const EdgeInsets.only(left: 48),
                    child: Text('${child.name}.$b', style: const TextStyle(fontFamily: 'monospace', color: Colors.amberAccent, fontSize: 11)),
                  )),
                  DataCell(Text('${child.path}.$b', style: const TextStyle(color: Colors.grey, fontSize: 9))),
                  const DataCell(Text('BOOL (Bit)', style: TextStyle(color: Colors.amber, fontSize: 9))),
                  DataCell(Text(bitVal ? 'TRUE (1)' : 'FALSE (0)', style: TextStyle(fontWeight: FontWeight.bold, color: bitVal ? Colors.greenAccent : Colors.grey, fontSize: 10))),
                  const DataCell(Text('Good', style: TextStyle(color: Colors.green, fontSize: 9))),
                  const DataCell(Text('Bit Reference', style: TextStyle(color: Colors.grey, fontSize: 9))),
                  DataCell(OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0)),
                    onPressed: () => _toggleBitValue(child, b),
                    child: Text(bitVal ? 'Reset 0' : 'Set 1', style: const TextStyle(fontSize: 9, color: Colors.amberAccent)),
                  )),
                ],
              ));
            }
          }
        }
      }
    }

    return rows;
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

  Widget _buildDataBlocksTab() {
    final dbs = widget.currentProject.dataBlocks;
    return Scaffold(
      body: dbs.isEmpty
          ? const Center(child: Text('No Data Blocks created yet.'))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: dbs.length,
              itemBuilder: (context, index) {
                final db = dbs[index];
                return Card(
                  color: const Color(0xFF1E293B),
                  child: ExpansionTile(
                    leading: const Icon(Icons.inventory_2, color: Colors.indigoAccent),
                    title: Text(db.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Type: ${db.structTypeName}'),
                    children: db.fieldValues.entries.map((entry) => ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 32, right: 16),
                      title: Text('${db.name}.${entry.key}', style: const TextStyle(fontFamily: 'monospace')),
                      trailing: Text(entry.value.toString(), style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                    )).toList(),
                  ),
                );
              },
            ),
    );
  }
}
