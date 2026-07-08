import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import '../ui/responsive.dart';

class TagInspectorDock extends StatefulWidget {
  final PlcProject project;
  final List<PlcTag> tags;
  final VoidCallback onTagStateChanged;
  final VoidCallback onClose;

  const TagInspectorDock({
    super.key,
    required this.project,
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
  final Set<String> _expandedTags = {};

  @override
  Widget build(BuildContext context) {
    final filteredTags = widget.tags.where((tag) {
      final matchesSearch = tag.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          tag.path.toLowerCase().contains(_searchQuery.toLowerCase());
      final matchesIo = _filterIoType == 'ALL' || tag.ioType == _filterIoType;
      return matchesSearch && matchesIo;
    }).toList();

    // 340 wide when the parent gives unbounded width (inline dock in the
    // desktop Row); when the parent constrains the width (e.g. inside the
    // compact end-drawer, which is min(340, screenWidth*0.9)), shrink to fit so
    // the dock's content never overflows a narrow screen.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? math.min(340.0, constraints.maxWidth)
            : 340.0;
        return Container(
          width: width,
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
                const Flexible(
                  child: Text(
                    'TAG INSPECTOR & FORCING',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5),
                  ),
                ),
                const Spacer(),
                touchable(
                  const Icon(Icons.close, size: 18),
                  onTap: widget.onClose,
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
                      final kids = childrenOf(widget.project, tag.name);
                      final isExpanded = _expandedTags.contains(tag.name);

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
                                  if (kids.isNotEmpty)
                                    IconButton(
                                      key: ValueKey('inspector-expand-${tag.name}'),
                                      icon: Icon(
                                        isExpanded ? Icons.expand_more : Icons.chevron_right,
                                        size: 18,
                                        color: Colors.cyan,
                                      ),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                      tooltip: isExpanded ? 'Collapse members' : 'Expand members',
                                      onPressed: () {
                                        setState(() {
                                          if (isExpanded) {
                                            _expandedTags.remove(tag.name);
                                          } else {
                                            _expandedTags.add(tag.name);
                                          }
                                        });
                                      },
                                    ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          tag.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                        Text(
                                          '${tag.path} [${tag.dataType}]',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                                        ),
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
                                  Flexible(
                                    child: InkWell(
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
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                            color: effectiveVal == true ? Colors.greenAccent : (effectiveVal == false ? Colors.redAccent : Colors.cyanAccent),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  const SizedBox(width: 8),

                                  // Force Toggle Lock. Forcing is scalar-only:
                                  // a composite (struct/array) tag's value is
                                  // ill-defined to force (readPath's force
                                  // overlay only ever applies to scalars), so
                                  // the control is not offered for those rows.
                                  if (tag.value is! Map && tag.value is! List)
                                    touchable(
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
                                    ),
                                ],
                              ),

                              // Expanded child members (read-only; live values).
                              if (isExpanded && kids.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                const Divider(height: 1, color: Colors.white12),
                                const SizedBox(height: 4),
                                ...kids.map((child) => _buildChildRow(child, 1)),
                              ],
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
      },
    );
  }

  // Read-only row for a composite/array/integer-bit child, recursing into
  // its own children when expanded. Mirrors memory_manager_screen's
  // _childRowData pattern but rendered as an indented row (not a table).
  Widget _buildChildRow(TagChild child, int depth) {
    final isExpanded = _expandedTags.contains(child.path);
    final value = readPath(widget.project, child.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 16.0 * depth, top: 2, bottom: 2),
          child: Row(
            children: [
              if (child.hasChildren)
                IconButton(
                  key: ValueKey('inspector-expand-${child.path}'),
                  icon: Icon(
                    isExpanded ? Icons.expand_more : Icons.chevron_right,
                    size: 14,
                    color: Colors.grey,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  tooltip: isExpanded ? 'Collapse members' : 'Expand members',
                  onPressed: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedTags.remove(child.path);
                      } else {
                        _expandedTags.add(child.path);
                      }
                    });
                  },
                )
              else
                const SizedBox(width: 20),
              Expanded(
                child: Text(
                  child.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '$value',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.cyanAccent),
                ),
              ),
            ],
          ),
        ),
        if (isExpanded)
          ...childrenOf(widget.project, child.path).map((c) => _buildChildRow(c, depth + 1)),
      ],
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
