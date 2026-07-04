import 'package:flutter/material.dart';
import '../models/project_model.dart';

class TagInspectorDock extends StatefulWidget {
  final List<PlcTag> tags;
  final VoidCallback onTagStateChanged;
  final VoidCallback onClose;

  const TagInspectorDock({
    super.key,
    required this.tags,
    required this.onTagStateChanged,
    required this.onClose,
  });

  @override
  State<TagInspectorDock> createState() => _TagInspectorDockState();
}

class _TagInspectorDockState extends State<TagInspectorDock> {
  String _searchQuery = '';
  String _filterIoType = 'ALL';

  @override
  Widget build(BuildContext context) {
    final filteredTags = widget.tags.where((tag) {
      final matchesSearch = tag.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          tag.path.toLowerCase().contains(_searchQuery.toLowerCase());
      final matchesIo = _filterIoType == 'ALL' || tag.ioType == _filterIoType;
      return matchesSearch && matchesIo;
    }).toList();

    return Container(
      width: 340,
      color: const Color(0xFF0F172A),
      child: Column(
        children: [
          // Header Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                const Icon(Icons.table_rows, color: Colors.cyan, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'TAG INSPECTOR & FORCING',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),

          // Search & Filter Row
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                TextField(
                  onChanged: (val) => setState(() => _searchQuery = val),
                  decoration: InputDecoration(
                    hintText: 'Search tags...',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    isDense: true,
                    contentPadding: const EdgeInsets.all(8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _buildFilterChip('ALL', 'All Tags'),
                    const SizedBox(width: 4),
                    _buildFilterChip('SimulatedInput', 'Inputs'),
                    const SizedBox(width: 4),
                    _buildFilterChip('SimulatedOutput', 'Outputs'),
                    const SizedBox(width: 4),
                    _buildFilterChip('Internal', 'Internal'),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: Colors.white12),

          // Tag List Matrix
          Expanded(
            child: filteredTags.isEmpty
                ? const Center(child: Text('No matching tags', style: TextStyle(color: Colors.grey, fontSize: 12)))
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: filteredTags.length,
                    separatorBuilder: (ctx, idx) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final tag = filteredTags[index];
                      final isBool = tag.dataType == 'BOOL';
                      final effectiveVal = tag.isForced ? tag.forcedValue : tag.value;

                      return Card(
                        margin: EdgeInsets.zero,
                        color: tag.isForced ? Colors.amber.shade900.withValues(alpha: 0.2) : const Color(0xFF1E293B),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: BorderSide(
                            color: tag.isForced ? Colors.amber : Colors.white12,
                            width: tag.isForced ? 1.5 : 1,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(10.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Tag Name & Path
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                        Text('${tag.path} [${tag.dataType}]', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                                      ],
                                    ),
                                  ),

                                  // Forced Badge
                                  if (tag.isForced)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.amber,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text('FORCED', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 9)),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),

                              // Value Display & Controls
                              Row(
                                children: [
                                  // Live Value Pill
                                  InkWell(
                                    onTap: () {
                                      if (isBool) {
                                        setState(() {
                                          if (tag.isForced) {
                                            tag.forcedValue = !(tag.forcedValue == true);
                                          } else {
                                            tag.value = !(tag.value == true);
                                          }
                                        });
                                        widget.onTagStateChanged();
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: effectiveVal == true
                                            ? Colors.green.withValues(alpha: 0.2)
                                            : (effectiveVal == false ? Colors.red.withValues(alpha: 0.1) : Colors.cyan.withValues(alpha: 0.1)),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: effectiveVal == true ? Colors.green : (effectiveVal == false ? Colors.red.shade700 : Colors.cyan),
                                        ),
                                      ),
                                      child: Text(
                                        '$effectiveVal ${tag.engineeringUnits}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          color: effectiveVal == true ? Colors.greenAccent : (effectiveVal == false ? Colors.redAccent : Colors.cyanAccent),
                                        ),
                                      ),
                                    ),
                                  ),

                                  const Spacer(),

                                  // Force Toggle Lock
                                  ElevatedButton.icon(
                                    icon: Icon(tag.isForced ? Icons.lock : Icons.lock_open, size: 14),
                                    label: Text(tag.isForced ? 'Unforce' : 'Force', style: const TextStyle(fontSize: 11)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: tag.isForced ? Colors.amber.shade800 : const Color(0xFF334155),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        tag.isForced = !tag.isForced;
                                        if (tag.isForced) {
                                          tag.forcedValue = isBool ? !(tag.value == true) : tag.value;
                                        }
                                      });
                                      widget.onTagStateChanged();
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    final isSelected = _filterIoType == value;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _filterIoType = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: isSelected ? Colors.cyan : Colors.white12),
          ),
          child: Text(label, style: TextStyle(fontSize: 10, color: isSelected ? Colors.cyanAccent : Colors.grey)),
        ),
      ),
    );
  }
}
