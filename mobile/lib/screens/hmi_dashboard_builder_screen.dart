import 'package:flutter/material.dart';
import '../models/project_model.dart';

class HmiDashboardBuilderScreen extends StatefulWidget {
  final PlcProject currentProject;
  final HmiScreenDef hmiScreen;
  final VoidCallback onScanTriggered;
  final VoidCallback onProjectUpdated;

  const HmiDashboardBuilderScreen({
    super.key,
    required this.currentProject,
    required this.hmiScreen,
    required this.onScanTriggered,
    required this.onProjectUpdated,
  });

  @override
  State<HmiDashboardBuilderScreen> createState() => _HmiDashboardBuilderScreenState();
}

class _HmiDashboardBuilderScreenState extends State<HmiDashboardBuilderScreen> {
  bool isEditMode = false;
  bool isPaletteVisible = true;

  // Component Library Palette Templates
  final List<HmiComponent> _paletteTemplates = [
    HmiComponent(id: 'tmpl_pb', title: 'Pushbutton Switch', type: 'PushbuttonSwitch', tagBinding: '', gridSpanWidth: 1, accentColor: 'green'),
    HmiComponent(id: 'tmpl_toggle', title: 'Toggle Switch', type: 'ToggleSwitch', tagBinding: '', gridSpanWidth: 1, accentColor: 'cyan'),
    HmiComponent(id: 'tmpl_slider', title: 'Numeric Slider Input', type: 'NumericSliderInput', tagBinding: '', gridSpanWidth: 2, accentColor: 'teal'),
    HmiComponent(id: 'tmpl_input', title: 'Text/Numeric Value Input', type: 'TextInputField', tagBinding: '', gridSpanWidth: 2, accentColor: 'blue'),
    HmiComponent(id: 'tmpl_led', title: 'LED Indicator Light', type: 'LedIndicatorLight', tagBinding: '', gridSpanWidth: 1, accentColor: 'green'),
    HmiComponent(id: 'tmpl_gauge', title: 'Digital Gauge Bar', type: 'DigitalGaugeDisplay', tagBinding: '', gridSpanWidth: 2, accentColor: 'cyan'),
    HmiComponent(id: 'tmpl_pill', title: 'Status Value Pill', type: 'StatusPillDisplay', tagBinding: '', gridSpanWidth: 2, accentColor: 'amber'),
    HmiComponent(id: 'tmpl_tank', title: 'Process Vessel Graphic', type: 'TankGraphicDisplay', tagBinding: '', gridSpanWidth: 2, accentColor: 'cyan'),
  ];

  void _showAddComponentDialog([HmiComponent? existingComp]) {
    final titleCtrl = TextEditingController(text: existingComp?.title ?? 'New Component');
    String selectedType = existingComp?.type ?? 'LedIndicatorLight';
    String selectedTag = existingComp?.tagBinding ?? (widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : '');
    int gridSpanWidth = existingComp?.gridSpanWidth ?? 1;
    String accentColor = existingComp?.accentColor ?? 'cyan';

    final availableTypes = [
      {'type': 'PushbuttonSwitch', 'label': 'Pushbutton Switch (BOOL Input)'},
      {'type': 'ToggleSwitch', 'label': 'Toggle Switch (BOOL Input)'},
      {'type': 'NumericSliderInput', 'label': 'Numeric Setpoint Slider (INT/FLOAT Input)'},
      {'type': 'TextInputField', 'label': 'Text / Numeric Value Input (ANY Input)'},
      {'type': 'LedIndicatorLight', 'label': 'LED Indicator Light (BOOL Output)'},
      {'type': 'DigitalGaugeDisplay', 'label': 'Digital Gauge Display (NUMERIC Display)'},
      {'type': 'StatusPillDisplay', 'label': 'Status Value Pill (ANY Display)'},
      {'type': 'TankGraphicDisplay', 'label': 'Process Vessel Graphic (NUMERIC Display)'},
    ];

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: Text(existingComp == null ? 'Add HMI Grid Component' : 'Configure Component: ${existingComp.title}'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Component Title')),
                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    value: selectedType,
                    decoration: const InputDecoration(labelText: 'Component Type'),
                    items: availableTypes.map((t) => DropdownMenuItem(
                      value: t['type'],
                      child: Text('${t['label']}'),
                    )).toList(),
                    onChanged: (val) => setDlgState(() => selectedType = val!),
                  ),
                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    value: selectedTag.isNotEmpty ? selectedTag : null,
                    decoration: const InputDecoration(labelText: 'Link / Bind to PLC Tag'),
                    items: widget.currentProject.tags.map((t) => DropdownMenuItem(
                      value: t.name,
                      child: Text('${t.name} [${t.dataType}] — ${t.path}'),
                    )).toList(),
                    onChanged: (val) => setDlgState(() => selectedTag = val!),
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: gridSpanWidth,
                          decoration: const InputDecoration(labelText: 'Grid Width Span'),
                          items: const [
                            DropdownMenuItem(value: 1, child: Text('1 Column (Small)')),
                            DropdownMenuItem(value: 2, child: Text('2 Columns (Medium)')),
                            DropdownMenuItem(value: 3, child: Text('3 Columns (Large)')),
                            DropdownMenuItem(value: 4, child: Text('4 Columns (Full Width)')),
                          ],
                          onChanged: (val) => setDlgState(() => gridSpanWidth = val!),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: accentColor,
                          decoration: const InputDecoration(labelText: 'Accent Color'),
                          items: const [
                            DropdownMenuItem(value: 'cyan', child: Text('Cyan')),
                            DropdownMenuItem(value: 'green', child: Text('Green')),
                            DropdownMenuItem(value: 'red', child: Text('Red')),
                            DropdownMenuItem(value: 'amber', child: Text('Amber')),
                            DropdownMenuItem(value: 'teal', child: Text('Teal')),
                          ],
                          onChanged: (val) => setDlgState(() => accentColor = val!),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    if (existingComp != null) {
                      existingComp.title = titleCtrl.text;
                      existingComp.type = selectedType;
                      existingComp.tagBinding = selectedTag;
                      existingComp.gridSpanWidth = gridSpanWidth;
                      existingComp.accentColor = accentColor;
                    } else {
                      final comp = HmiComponent(
                        id: 'comp_${DateTime.now().millisecondsSinceEpoch}',
                        title: titleCtrl.text,
                        type: selectedType,
                        tagBinding: selectedTag,
                        gridSpanWidth: gridSpanWidth,
                        accentColor: accentColor,
                      );
                      widget.hmiScreen.components.add(comp);
                    }
                  });
                  widget.onProjectUpdated();
                  Navigator.pop(ctx);
                },
                child: Text(existingComp == null ? 'Add Component' : 'Save Changes'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _addDroppedTemplate(HmiComponent tmpl) {
    final defaultTag = widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : '';
    final newComp = HmiComponent(
      id: 'comp_${DateTime.now().millisecondsSinceEpoch}',
      title: tmpl.title,
      type: tmpl.type,
      tagBinding: defaultTag,
      gridSpanWidth: tmpl.gridSpanWidth,
      accentColor: tmpl.accentColor,
    );

    setState(() {
      widget.hmiScreen.components.add(newComp);
    });
    widget.onProjectUpdated();

    // Automatically open configuration dialog to link tag
    _showAddComponentDialog(newComp);
  }

  PlcTag? _getBoundTag(String tagName) {
    try {
      return widget.currentProject.tags.firstWhere((t) => t.name == tagName);
    } catch (_) {
      return null;
    }
  }

  void _setTagValue(PlcTag tag, dynamic val) {
    setState(() {
      if (tag.isForced) {
        tag.forcedValue = val;
      } else {
        tag.value = val;
      }
    });
    widget.onScanTriggered();
  }

  @override
  Widget build(BuildContext context) {
    final components = widget.hmiScreen.components;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.hmiScreen.title),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        actions: [
          // Mode Switcher: RUN MODE vs EDIT HMI BUILDER MODE
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.cyan),
            ),
            child: Row(
              children: [
                InkWell(
                  onTap: () => setState(() => isEditMode = false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: !isEditMode ? Colors.cyan : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      'RUN MODE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: !isEditMode ? Colors.black : Colors.grey,
                      ),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => isEditMode = true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: isEditMode ? Colors.amber : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      'EDIT BUILDER',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: isEditMode ? Colors.black : Colors.grey,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (isEditMode) ...[
            IconButton(
              icon: Icon(Icons.view_sidebar, color: isPaletteVisible ? Colors.amberAccent : Colors.grey),
              tooltip: 'Toggle Component Palette',
              onPressed: () => setState(() => isPaletteVisible = !isPaletteVisible),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle, color: Colors.greenAccent),
              tooltip: 'Add HMI Component via Dialog',
              onPressed: () => _showAddComponentDialog(),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          // CENTER WORKSPACE: Grid DragTarget Canvas
          Expanded(
            child: DragTarget<HmiComponent>(
              onAcceptWithDetails: (details) {
                _addDroppedTemplate(details.data);
              },
              builder: (context, candidateData, rejectedData) {
                final isDragHover = candidateData.isNotEmpty;

                return Container(
                  color: isDragHover ? Colors.cyan.withValues(alpha: 0.1) : const Color(0xFF0F172A),
                  child: components.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.dashboard_customize, size: 48, color: isDragHover ? Colors.cyanAccent : Colors.grey),
                              const SizedBox(height: 12),
                              Text(
                                isDragHover ? 'Drop Component Here!' : 'No HMI components on this dashboard yet.',
                                style: TextStyle(color: isDragHover ? Colors.cyanAccent : Colors.grey, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 12),
                              if (isEditMode)
                                const Text('Drag components from the Right Palette or click "+ Add Component"', style: TextStyle(color: Colors.amber, fontSize: 12))
                              else
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.edit),
                                  label: const Text('Switch to Edit Builder Mode'),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
                                  onPressed: () => setState(() => isEditMode = true),
                                ),
                            ],
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            children: List.generate(components.length, (index) {
                              final comp = components[index];
                              final boundTag = _getBoundTag(comp.tagBinding);
                              final double cardWidth = (MediaQuery.of(context).size.width - 320 - 48) * (comp.gridSpanWidth / 4.0);

                              return SizedBox(
                                width: cardWidth < 220 ? 220 : cardWidth,
                                child: Card(
                                  color: const Color(0xFF1E293B),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: isEditMode ? Colors.amber : Colors.white12,
                                      width: isEditMode ? 1.5 : 1,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(14.0),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        // Header Bar with Title, Snap Resizer, Gear Config, & Delete Icon in Edit Mode
                                        Row(
                                          children: [
                                            Icon(_getIconForComponent(comp.type), size: 16, color: _getColor(comp.accentColor)),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                comp.title,
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),

                                            if (isEditMode) ...[
                                              // Snap Grid Resizer Controls ([–] 1..4 Col [+])
                                              IconButton(
                                                icon: const Icon(Icons.remove, size: 14, color: Colors.amber),
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(),
                                                tooltip: 'Decrease Grid Width',
                                                onPressed: comp.gridSpanWidth > 1
                                                    ? () {
                                                        setState(() => comp.gridSpanWidth--);
                                                        widget.onProjectUpdated();
                                                      }
                                                    : null,
                                              ),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: Colors.amber.withValues(alpha: 0.2),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text('${comp.gridSpanWidth} Col', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amber)),
                                              ),
                                              IconButton(
                                                icon: const Icon(Icons.add, size: 14, color: Colors.amber),
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(),
                                                tooltip: 'Increase Grid Width',
                                                onPressed: comp.gridSpanWidth < 4
                                                    ? () {
                                                        setState(() => comp.gridSpanWidth++);
                                                        widget.onProjectUpdated();
                                                      }
                                                    : null,
                                              ),

                                              const SizedBox(width: 6),

                                              // Reconfigure Settings (Gear)
                                              IconButton(
                                                icon: const Icon(Icons.settings, size: 16, color: Colors.cyan),
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(),
                                                tooltip: 'Reconfigure Component',
                                                onPressed: () => _showAddComponentDialog(comp),
                                              ),
                                              const SizedBox(width: 6),

                                              // Delete Component
                                              IconButton(
                                                icon: const Icon(Icons.delete, size: 16, color: Colors.redAccent),
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(),
                                                tooltip: 'Delete Component',
                                                onPressed: () {
                                                  setState(() {
                                                    components.removeAt(index);
                                                  });
                                                  widget.onProjectUpdated();
                                                },
                                              ),
                                            ],
                                          ],
                                        ),

                                        if (comp.tagBinding.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 2, bottom: 10),
                                            child: Text(
                                              'Linked Tag: ${comp.tagBinding}',
                                              style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace'),
                                            ),
                                          ),

                                        // Render Component Widget
                                        _renderComponentWidget(comp, boundTag),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),
                );
              },
            ),
          ),

          // RIGHT DOCK: Component Library Palette Panel (Visible in EDIT BUILDER mode)
          if (isEditMode && isPaletteVisible) ...[
            const VerticalDivider(width: 1, color: Colors.white12),
            _buildComponentPaletteDock(),
          ],
        ],
      ),
    );
  }

  Widget _buildComponentPaletteDock() {
    return Container(
      width: 260,
      color: const Color(0xFF0F172A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                const Icon(Icons.widgets, color: Colors.amber, size: 18),
                const SizedBox(width: 8),
                const Text('COMPONENT PALETTE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.amber, letterSpacing: 0.5)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => setState(() => isPaletteVisible = false),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(10.0),
            child: Text('Drag any component onto the grid dashboard canvas:', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              itemCount: _paletteTemplates.length,
              separatorBuilder: (ctx, idx) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final tmpl = _paletteTemplates[index];

                return Draggable<HmiComponent>(
                  data: tmpl,
                  feedback: Material(
                    elevation: 8,
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 220,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber, width: 2),
                      ),
                      child: Row(
                        children: [
                          Icon(_getIconForComponent(tmpl.type), size: 16, color: Colors.amber),
                          const SizedBox(width: 8),
                          Text(tmpl.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.4,
                    child: _buildPaletteCardItem(tmpl),
                  ),
                  child: _buildPaletteCardItem(tmpl),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaletteCardItem(HmiComponent tmpl) {
    return Card(
      margin: EdgeInsets.zero,
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Row(
          children: [
            Icon(_getIconForComponent(tmpl.type), size: 18, color: _getColor(tmpl.accentColor)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tmpl.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  Text('${tmpl.gridSpanWidth} Col Span', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
            ),
            const Icon(Icons.drag_indicator, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _renderComponentWidget(HmiComponent comp, PlcTag? tag) {
    if (tag == null) {
      return const Text('(No tag linked - click ⚙ to bind tag)', style: TextStyle(color: Colors.amber, fontSize: 11, fontStyle: FontStyle.italic));
    }

    final effectiveVal = tag.isForced ? tag.forcedValue : tag.value;

    switch (comp.type) {
      // INPUT 1: Pushbutton Switch (BOOL)
      case 'PushbuttonSwitch':
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () {
              _setTagValue(tag, true);
              Future.delayed(const Duration(milliseconds: 300), () {
                if (mounted) _setTagValue(tag, false);
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _getColor(comp.accentColor),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(comp.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        );

      // INPUT 2: Toggle Switch (BOOL)
      case 'ToggleSwitch':
        final isTrue = effectiveVal == true;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(isTrue ? 'State: ON' : 'State: OFF', style: TextStyle(fontWeight: FontWeight.bold, color: isTrue ? Colors.greenAccent : Colors.grey)),
            Switch(
              value: isTrue,
              activeTrackColor: Colors.green,
              onChanged: (val) => _setTagValue(tag, val),
            ),
          ],
        );

      // INPUT 3: Numeric Setpoint Slider (INT/FLOAT)
      case 'NumericSliderInput':
        final double numVal = (effectiveVal is num) ? effectiveVal.toDouble() : 0.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Value: ${numVal.toStringAsFixed(1)} ${tag.engineeringUnits}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            Slider(
              value: numVal.clamp(0.0, 100.0),
              min: 0.0,
              max: 100.0,
              divisions: 20,
              label: numVal.toStringAsFixed(1),
              activeColor: _getColor(comp.accentColor),
              onChanged: (val) => _setTagValue(tag, val),
            ),
          ],
        );

      // INPUT 4: Text Input Field (STRING/ANY)
      case 'TextInputField':
        return TextField(
          controller: TextEditingController(text: effectiveVal.toString()),
          onSubmitted: (val) {
            if (tag.dataType == 'FLOAT64' || tag.dataType == 'REAL') {
              _setTagValue(tag, double.tryParse(val) ?? 0.0);
            } else if (tag.dataType.startsWith('INT')) {
              _setTagValue(tag, int.tryParse(val) ?? 0);
            } else if (tag.dataType == 'BOOL') {
              _setTagValue(tag, val.toLowerCase() == 'true' || val == '1');
            } else {
              _setTagValue(tag, val);
            }
          },
          decoration: InputDecoration(
            isDense: true,
            suffixIcon: const Icon(Icons.send, size: 16),
            border: const OutlineInputBorder(),
            hintText: 'Enter value for ${tag.name}...',
          ),
        );

      // OUTPUT 1: LED Indicator Light (BOOL)
      case 'LedIndicatorLight':
        final isLit = effectiveVal == true;
        return Center(
          child: Column(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isLit ? _getColor(comp.accentColor) : Colors.grey.shade800,
                  boxShadow: isLit ? [BoxShadow(color: _getColor(comp.accentColor).withValues(alpha: 0.6), blurRadius: 16)] : [],
                  border: Border.all(color: isLit ? Colors.white : Colors.grey, width: 2),
                ),
                child: Icon(Icons.lightbulb, color: isLit ? Colors.black : Colors.grey, size: 28),
              ),
              const SizedBox(height: 6),
              Text(
                isLit ? 'ACTIVE / ON' : 'INACTIVE / OFF',
                style: TextStyle(fontWeight: FontWeight.bold, color: isLit ? _getColor(comp.accentColor) : Colors.grey, fontSize: 11),
              ),
            ],
          ),
        );

      // OUTPUT 2: Digital Gauge Display (NUMERIC)
      case 'DigitalGaugeDisplay':
        final double numVal = (effectiveVal is num) ? effectiveVal.toDouble() : 0.0;
        return Column(
          children: [
            LinearProgressIndicator(
              value: (numVal / 100.0).clamp(0.0, 1.0),
              color: _getColor(comp.accentColor),
              backgroundColor: Colors.black45,
              minHeight: 12,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('0.0', style: TextStyle(fontSize: 10, color: Colors.grey)),
                Text('${numVal.toStringAsFixed(1)} ${tag.engineeringUnits}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
                const Text('100.0', style: TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
          ],
        );

      // OUTPUT 3: Status Pill Display (ANY)
      case 'StatusPillDisplay':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _getColor(comp.accentColor).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _getColor(comp.accentColor)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              Text('$effectiveVal ${tag.engineeringUnits}', style: TextStyle(fontWeight: FontWeight.bold, color: _getColor(comp.accentColor), fontSize: 13)),
            ],
          ),
        );

      // OUTPUT 4: Process Vessel Graphic (NUMERIC)
      case 'TankGraphicDisplay':
        final double level = (effectiveVal is num) ? effectiveVal.toDouble() : 0.0;
        return Center(
          child: Column(
            children: [
              Container(
                width: 100,
                height: 120,
                decoration: BoxDecoration(
                  border: Border.all(color: _getColor(comp.accentColor), width: 2),
                  borderRadius: BorderRadius.circular(6),
                  color: const Color(0xFF0F172A),
                ),
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 100,
                      height: (level / 100.0) * 116.0,
                      color: _getColor(comp.accentColor).withValues(alpha: 0.6),
                    ),
                    Center(
                      child: Text('${level.toStringAsFixed(1)}%', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      default:
        return Text('Value: $effectiveVal');
    }
  }

  IconData _getIconForComponent(String type) {
    switch (type) {
      case 'PushbuttonSwitch': return Icons.smart_button;
      case 'ToggleSwitch': return Icons.toggle_on;
      case 'NumericSliderInput': return Icons.tune;
      case 'TextInputField': return Icons.edit_note;
      case 'LedIndicatorLight': return Icons.lightbulb;
      case 'DigitalGaugeDisplay': return Icons.speed;
      case 'StatusPillDisplay': return Icons.label;
      case 'TankGraphicDisplay': return Icons.water_drop;
      default: return Icons.widgets;
    }
  }

  Color _getColor(String colorName) {
    switch (colorName) {
      case 'green': return Colors.greenAccent;
      case 'red': return Colors.redAccent;
      case 'amber': return Colors.amberAccent;
      case 'teal': return Colors.tealAccent;
      case 'blue': return Colors.blueAccent;
      case 'cyan': default: return Colors.cyanAccent;
    }
  }
}
