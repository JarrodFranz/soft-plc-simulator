import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../ui/responsive.dart';

class ProjectManagerScreen extends StatefulWidget {
  final PlcProject currentProject;
  final Function(PlcProject newProject) onLoadProject;

  const ProjectManagerScreen({
    super.key,
    required this.currentProject,
    required this.onLoadProject,
  });

  @override
  State<ProjectManagerScreen> createState() => _ProjectManagerScreenState();
}

class _ProjectManagerScreenState extends State<ProjectManagerScreen> {
  late TextEditingController _nameController;
  late TextEditingController _controllerNameController;
  late TextEditingController _scanPeriodController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentProject.name);
    _controllerNameController = TextEditingController(text: widget.currentProject.controllerName);
    _scanPeriodController = TextEditingController(text: widget.currentProject.scanPeriodMs.toString());
  }

  void _loadPresetProject(String preset) {
    if (preset == 'MotorControl') {
      final proj = PlcProject(
        id: 'proj_motor',
        name: 'Basic Motor Start Stop',
        controllerName: 'PLC_01',
        scanPeriodMs: 100,
        tags: [
          PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Start pushbutton'),
          PlcTag(name: 'Stop_PB', path: 'Inputs/Stop_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput', description: 'Stop pushbutton'),
          PlcTag(name: 'EStop_OK', path: 'Inputs/EStop_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Emergency Stop Healthy'),
          PlcTag(name: 'Overload_OK', path: 'Inputs/Overload_OK', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Thermal Overload Healthy'),
          PlcTag(name: 'Motor_Latch', path: 'Internal/Motor_Latch', dataType: 'BOOL', value: false, ioType: 'Internal', description: 'Internal seal-in latch'),
          PlcTag(name: 'Motor_Run', path: 'Outputs/Motor_Run', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Motor contactor output'),
        ],
        structDefs: [],
        programs: [
          PlcProgram(
            name: 'StMotorControl',
            language: 'StructuredText',
            description: 'Motor start/stop with permissives in ST',
            stSource: 'IF (Start_PB OR Motor_Latch) AND NOT Stop_PB AND EStop_OK AND Overload_OK THEN\n    Motor_Latch := TRUE;\nELSE\n    Motor_Latch := FALSE;\nEND_IF;\nMotor_Run := Motor_Latch AND EStop_OK AND Overload_OK;',
          ),
        ],
        tasks: [
          PlcTask(name: 'MainTask', type: 'Continuous', periodMs: 100, programNames: ['StMotorControl']),
        ],
        hmis: [
          HmiScreenDef(id: 'hmi_motor', title: 'Motor Control HMI', layoutType: 'GridDashboard', components: []),
        ],
      );
      widget.onLoadProject(proj);
    } else if (preset == 'TankLevel') {
      final proj = PlcProject(
        id: 'proj_tank',
        name: 'Tank Level Simulation',
        controllerName: 'PLC_02',
        scanPeriodMs: 100,
        tags: [
          PlcTag(name: 'Level_PV', path: 'Inputs/Level_PV', dataType: 'FLOAT64', value: 45.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Tank level sensor'),
          PlcTag(name: 'Level_SP', path: 'Internal/Level_SP', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal', engineeringUnits: '%', description: 'Level setpoint'),
          PlcTag(name: 'Start_PB', path: 'Inputs/Start_PB', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Pump start enable'),
          PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Fill valve solenoid'),
          PlcTag(name: 'Drain_Valve', path: 'Outputs/Drain_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Drain valve solenoid'),
        ],
        structDefs: [],
        programs: [
          PlcProgram(
            name: 'StTankControl',
            language: 'StructuredText',
            description: 'Tank fill/drain on/off control',
            stSource: 'IF Level_PV < (Level_SP - 5.0) AND Start_PB THEN\n    Fill_Valve := TRUE;\n    Drain_Valve := FALSE;\nELSIF Level_PV > (Level_SP + 5.0) THEN\n    Fill_Valve := FALSE;\n    Drain_Valve := TRUE;\nELSE\n    Fill_Valve := FALSE;\n    Drain_Valve := FALSE;\nEND_IF;',
          ),
        ],
        tasks: [
          PlcTask(name: 'MainTask', type: 'Continuous', periodMs: 100, programNames: ['StTankControl']),
        ],
        hmis: [
          HmiScreenDef(id: 'hmi_tank', title: 'Tank Level HMI', layoutType: 'GridDashboard', components: []),
        ],
      );
      widget.onLoadProject(proj);
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Loaded preset project: $preset')));
  }

  void _addNewTag() {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: 'New_Tag');
        final pathCtrl = TextEditingController(text: 'Inputs/New_Tag');
        String dataType = 'BOOL';
        String ioType = 'SimulatedInput';

        return AlertDialog(
          title: const Text('Add New Tag'),
          content: StatefulBuilder(
            builder: (context, setDlgState) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Tag Name')),
                TextField(controller: pathCtrl, decoration: const InputDecoration(labelText: 'Browse Path')),
                DropdownButton<String>(
                  value: dataType,
                  isExpanded: true,
                  items: ['BOOL', 'INT16', 'INT32', 'FLOAT64', 'STRING'].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (val) => setDlgState(() => dataType = val!),
                ),
                DropdownButton<String>(
                  value: ioType,
                  isExpanded: true,
                  items: ['SimulatedInput', 'SimulatedOutput', 'Internal'].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (val) => setDlgState(() => ioType = val!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final tag = PlcTag(
                  name: nameCtrl.text,
                  path: pathCtrl.text,
                  dataType: dataType,
                  value: dataType == 'BOOL' ? false : (dataType == 'FLOAT64' ? 0.0 : 0),
                  ioType: ioType,
                );
                setState(() => widget.currentProject.tags.add(tag));
                Navigator.pop(ctx);
              },
              child: const Text('Add Tag'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.currentProject;
    final compact = context.isCompact;

    final presetButtons = [
      ElevatedButton.icon(
        icon: const Icon(Icons.build),
        label: const Text('Basic Motor Start/Stop'),
        style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan.shade700, foregroundColor: Colors.white),
        onPressed: () => _loadPresetProject('MotorControl'),
      ),
      ElevatedButton.icon(
        icon: const Icon(Icons.water_drop),
        label: const Text('Tank Level Simulation'),
        style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade700, foregroundColor: Colors.white),
        onPressed: () => _loadPresetProject('TankLevel'),
      ),
    ];

    final propertyFields = [
      TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Project Name')),
      TextField(controller: _controllerNameController, decoration: const InputDecoration(labelText: 'Controller Name')),
      TextField(controller: _scanPeriodController, decoration: const InputDecoration(labelText: 'Scan Period (ms)')),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('PLC Project & Task Manager'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preset Projects Loader
            const Text('PRESET PROJECTS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 8),
            compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final b in presetButtons) ...[
                        b,
                        if (b != presetButtons.last) const SizedBox(height: 12),
                      ],
                    ],
                  )
                : Row(
                    children: [
                      for (final b in presetButtons) ...[
                        b,
                        if (b != presetButtons.last) const SizedBox(width: 12),
                      ],
                    ],
                  ),
            const SizedBox(height: 24),

            // Active Project Properties
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Active Project: ${project.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.cyan)),
                    const SizedBox(height: 12),
                    compact
                        ? Column(
                            children: [
                              for (final f in propertyFields) ...[
                                f,
                                if (f != propertyFields.last) const SizedBox(height: 12),
                              ],
                            ],
                          )
                        : Row(
                            children: [
                              for (final f in propertyFields) ...[
                                Expanded(child: f),
                                if (f != propertyFields.last) const SizedBox(width: 12),
                              ],
                            ],
                          ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Programs in Project
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Flexible(
                  child: Text('PROGRAMS IN PROJECT',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                ),
                Text('${project.programs.length} Programs', style: const TextStyle(color: Colors.cyan)),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: project.programs.length,
                itemBuilder: (context, index) {
                  final prog = project.programs[index];
                  return ListTile(
                    leading: Icon(
                      prog.language == 'StructuredText' ? Icons.code : Icons.linear_scale,
                      color: Colors.cyan,
                    ),
                    title: Text(prog.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${prog.language} — ${prog.description}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Switch(
                      value: prog.enabled,
                      onChanged: (val) => setState(() => prog.enabled = val),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),

            // Tasks & Scheduling
            const Text('TASKS & SCHEDULING', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 8),
            Card(
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: project.tasks.length,
                itemBuilder: (context, index) {
                  final task = project.tasks[index];
                  return ListTile(
                    leading: const Icon(Icons.schedule, color: Colors.teal),
                    title: Text('${task.name} (${task.type})', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Programs assigned: ${task.programNames.join(', ')}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text('${task.periodMs} ms', style: const TextStyle(fontFamily: 'monospace')),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),

            // Tag Database Summary
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Flexible(
                  child: Text('TAG DATABASE REGISTRY',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Tag'),
                  onPressed: _addNewTag,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: project.tags.length,
                itemBuilder: (context, index) {
                  final tag = project.tags[index];
                  return ListTile(
                    dense: true,
                    title: Text(tag.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${tag.path} [${tag.dataType}]', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(tag.ioType, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
