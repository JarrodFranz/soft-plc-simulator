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

  // Set of expanded Integer tag names for bit expansion
  final Set<String> _expandedTagBits = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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

  void _showAddStructDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final structNameCtrl = TextEditingController(text: 'Motor_DUT');
        final fields = <StructFieldDef>[
          StructFieldDef(name: 'Run', dataType: 'BOOL', defaultValue: false),
          StructFieldDef(name: 'Fault', dataType: 'BOOL', defaultValue: false),
          StructFieldDef(name: 'Speed', dataType: 'INT32', defaultValue: 0),
          StructFieldDef(name: 'Current_Amps', dataType: 'FLOAT64', defaultValue: 0.0),
        ];

        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('Define New Struct (DUT / User Defined Type)'),
            content: SizedBox(
              width: 450,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: structNameCtrl,
                    decoration: const InputDecoration(labelText: 'Struct Name (e.g. Motor_DUT, Valve_DUT)'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('STRUCT FIELDS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                      IconButton(
                        icon: const Icon(Icons.add_circle, color: Colors.cyan),
                        onPressed: () {
                          setDlgState(() {
                            fields.add(StructFieldDef(name: 'Field_${fields.length + 1}', dataType: 'BOOL', defaultValue: false));
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 180,
                    child: ListView.builder(
                      itemCount: fields.length,
                      itemBuilder: (ctx, idx) {
                        final f = fields[idx];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: TextEditingController(text: f.name),
                                  onChanged: (v) => f.name = v,
                                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                                ),
                              ),
                              const SizedBox(width: 8),
                              DropdownButton<String>(
                                value: f.dataType,
                                isDense: true,
                                items: ['BOOL', 'INT32', 'FLOAT64', 'STRING'].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                                onChanged: (val) => setDlgState(() => f.dataType = val!),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18),
                                onPressed: () => setDlgState(() => fields.removeAt(idx)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  final structDef = PlcStructDef(
                    name: structNameCtrl.text.trim().isEmpty ? 'Custom_DUT' : structNameCtrl.text.trim(),
                    fields: fields,
                  );
                  setState(() {
                    widget.currentProject.structDefs.add(structDef);
                  });
                  widget.onProjectUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Save Struct Definition'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddDataBlockDialog() {
    if (widget.currentProject.structDefs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please define at least one Struct (DUT) before creating a Data Block!')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) {
        final dbNameCtrl = TextEditingController(text: 'DB_Motor1');
        String selectedStruct = widget.currentProject.structDefs.first.name;

        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('Create New Data Block (DB)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: dbNameCtrl, decoration: const InputDecoration(labelText: 'Data Block Name (e.g. DB_Pump1)')),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: selectedStruct,
                  decoration: const InputDecoration(labelText: 'Instantiate Struct Type'),
                  items: widget.currentProject.structDefs.map((s) => DropdownMenuItem(value: s.name, child: Text(s.name))).toList(),
                  onChanged: (val) => setDlgState(() => selectedStruct = val!),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  final structDef = widget.currentProject.structDefs.firstWhere((s) => s.name == selectedStruct);
                  final initialValues = <String, dynamic>{};
                  for (var f in structDef.fields) {
                    initialValues[f.name] = f.defaultValue;
                  }

                  final db = PlcDataBlock(
                    name: dbNameCtrl.text,
                    structTypeName: selectedStruct,
                    fieldValues: initialValues,
                  );

                  for (var f in structDef.fields) {
                    widget.currentProject.tags.add(PlcTag(
                      name: '${db.name}.${f.name}',
                      path: 'DataBlocks/${db.name}.${f.name}',
                      dataType: f.dataType,
                      value: f.defaultValue,
                      ioType: 'Internal',
                      description: 'DataBlock ${db.name} field ${f.name}',
                    ));
                  }

                  setState(() {
                    widget.currentProject.dataBlocks.add(db);
                  });
                  widget.onProjectUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Create Data Block'),
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

        final availableTypes = ['BOOL', 'INT16', 'INT32', 'FLOAT64', 'STRING', ...widget.currentProject.structDefs.map((s) => s.name)];

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
                  value: dataType,
                  decoration: const InputDecoration(labelText: 'Data Type (Standard or Struct)'),
                  items: availableTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (val) => setDlgState(() => dataType = val!),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: ioType,
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
        title: Text('${widget.currentProject.name} — Memory, DUTs & Data Blocks'),
        backgroundColor: const Color(0xFF1E293B),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.cyan,
          tabs: const [
            Tab(icon: Icon(Icons.table_chart), text: 'Global Tags (Sortable Table)'),
            Tab(icon: Icon(Icons.dataset), text: 'Struct Definitions (DUT)'),
            Tab(icon: Icon(Icons.inventory_2), text: 'Data Blocks (DB)'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildGlobalTagsSortableTableTab(),
          _buildStructDefsTab(),
          _buildDataBlocksTab(),
        ],
      ),
    );
  }

  Widget _buildGlobalTagsSortableTableTab() {
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
            const Text('GLOBAL TAG DATABASE & BIT EXPANSION TABLE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.cyanAccent)),
            const SizedBox(height: 4),
            const Text('Click column headers to sort. Expand integer tags (INT16/INT32) to view and force individual bits (myInt.0 to myInt.15).', style: TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 16),

            Card(
              color: const Color(0xFF1E293B),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  sortColumnIndex: _sortColumnIndex,
                  sortAscending: _isAscending,
                  columns: [
                    DataColumn(label: const Text('Tag Name'), onSort: _sortTags),
                    DataColumn(label: const Text('Browse Path'), onSort: _sortTags),
                    DataColumn(label: const Text('Data Type'), onSort: _sortTags),
                    DataColumn(label: const Text('Live Value'), onSort: _sortTags),
                    DataColumn(label: const Text('Quality'), onSort: _sortTags),
                    DataColumn(label: const Text('I/O Classification'), onSort: _sortTags),
                    const DataColumn(label: Text('Bit Expansion / Actions')),
                  ],
                  rows: _buildTableRowsWithBitExpansion(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<DataRow> _buildTableRowsWithBitExpansion() {
    final rows = <DataRow>[];

    for (int i = 0; i < widget.currentProject.tags.length; i++) {
      final tag = widget.currentProject.tags[i];
      final isInt = tag.dataType.startsWith('INT');
      final isExpanded = _expandedTagBits.contains(tag.name);

      // Parent Tag Row
      rows.add(DataRow(
        cells: [
          DataCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isInt)
                IconButton(
                  icon: Icon(isExpanded ? Icons.arrow_drop_down_circle : Icons.play_arrow, size: 16, color: Colors.amberAccent),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Expand 16 Bits (${tag.name}.0 to ${tag.name}.15)',
                  onPressed: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedTagBits.remove(tag.name);
                      } else {
                        _expandedTagBits.add(tag.name);
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
            decoration: BoxDecoration(color: Colors.cyan.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
            child: Text(tag.dataType, style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 11)),
          )),
          DataCell(Text(
            '${tag.value} ${tag.engineeringUnits}',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent, fontFamily: 'monospace'),
          )),
          DataCell(Text(tag.quality, style: const TextStyle(color: Colors.green, fontSize: 11))),
          DataCell(Text(tag.ioType, style: const TextStyle(color: Colors.grey, fontSize: 11))),
          DataCell(IconButton(
            icon: const Icon(Icons.delete, color: Colors.redAccent, size: 16),
            onPressed: () {
              setState(() {
                widget.currentProject.tags.removeAt(i);
              });
              widget.onProjectUpdated();
            },
          )),
        ],
      ));

      // Expanded 16 Bit Sub-Rows for Integers (myInt.0 through myInt.15)
      if (isInt && isExpanded) {
        final int val = (tag.value is int) ? (tag.value as int) : 0;

        for (int bitIndex = 0; bitIndex < 16; bitIndex++) {
          final bool bitVal = (val & (1 << bitIndex)) != 0;
          final String bitTagName = '${tag.name}.$bitIndex';

          rows.add(DataRow(
            color: WidgetStateProperty.all(const Color(0xFF0F172A)),
            cells: [
              DataCell(Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Text(bitTagName, style: const TextStyle(fontFamily: 'monospace', color: Colors.amberAccent, fontSize: 12)),
              )),
              DataCell(Text('${tag.path}.$bitIndex', style: const TextStyle(color: Colors.grey, fontSize: 10))),
              DataCell(const Text('BOOL (Bit)', style: TextStyle(color: Colors.amber, fontSize: 10))),
              DataCell(Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: bitVal ? Colors.greenAccent : Colors.grey),
                  ),
                  const SizedBox(width: 6),
                  Text(bitVal ? 'TRUE (1)' : 'FALSE (0)', style: TextStyle(fontWeight: FontWeight.bold, color: bitVal ? Colors.greenAccent : Colors.grey, fontSize: 11)),
                ],
              )),
              const DataCell(Text('Good', style: TextStyle(color: Colors.green, fontSize: 10))),
              const DataCell(Text('Bit Reference', style: TextStyle(color: Colors.grey, fontSize: 10))),
              DataCell(OutlinedButton(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), side: const BorderSide(color: Colors.amberAccent)),
                onPressed: () => _toggleBitValue(tag, bitIndex),
                child: Text(bitVal ? 'Reset to 0' : 'Set to 1', style: const TextStyle(fontSize: 10, color: Colors.amberAccent)),
              )),
            ],
          ));
        }
      }
    }

    return rows;
  }

  Widget _buildStructDefsTab() {
    final structs = widget.currentProject.structDefs;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New Struct (DUT)'),
        backgroundColor: Colors.teal,
        onPressed: _showAddStructDialog,
      ),
      body: structs.isEmpty
          ? const Center(child: Text('No Struct definitions defined yet. Click "New Struct (DUT)" to define one!'))
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
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18),
                      onPressed: () {
                        setState(() {
                          structs.removeAt(index);
                        });
                        widget.onProjectUpdated();
                      },
                    ),
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
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Create Data Block'),
        backgroundColor: Colors.indigoAccent,
        onPressed: _showAddDataBlockDialog,
      ),
      body: dbs.isEmpty
          ? const Center(child: Text('No Data Blocks created yet. Click "Create Data Block" to instantiate a Struct!'))
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
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.redAccent, size: 18),
                      onPressed: () {
                        setState(() {
                          dbs.removeAt(index);
                          widget.currentProject.tags.removeWhere((t) => t.name.startsWith('${db.name}.'));
                        });
                        widget.onProjectUpdated();
                      },
                    ),
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
