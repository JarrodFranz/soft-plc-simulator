import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../widgets/tag_inspector_dock.dart';
import 'st_editor_screen.dart';
import 'memory_manager_screen.dart';

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({super.key});

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  // Project Workspace Repository
  late List<PlcProject> _allProjects;
  late PlcProject _activeProject;

  // Active Main Content View
  // 'HMI:<hmi_id>', 'PROGRAM:<prog_name>', 'MEMORY'
  String _activeViewId = 'HMI:hmi_motor';

  // PLC Engine State
  bool isRunning = true;
  int scanCount = 0;
  int scanSpeedMs = 500; // Configurable scan speed (50ms to 2000ms)
  Timer? _scanTimer;

  // Side Dock Inspector State
  bool isTagDockVisible = true;

  @override
  void initState() {
    super.initState();
    _initProjects();
    _startScanLoop();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  void _initProjects() {
    // 1. Basic Motor Start Stop
    final motorProj = PlcProject(
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
      structDefs: [
        PlcStructDef(
          name: 'Motor_DUT',
          fields: [
            StructFieldDef(name: 'Run', dataType: 'BOOL', defaultValue: false),
            StructFieldDef(name: 'Fault', dataType: 'BOOL', defaultValue: false),
            StructFieldDef(name: 'Speed', dataType: 'INT32', defaultValue: 0),
          ],
        ),
      ],
      dataBlocks: [
        PlcDataBlock(name: 'DB_Motor1', structTypeName: 'Motor_DUT', fieldValues: {'Run': false, 'Fault': false, 'Speed': 1450}),
      ],
      programs: [
        PlcProgram(
          name: 'MotorControl_ST',
          language: 'StructuredText',
          description: 'Motor start/stop with permissives in ST',
          stSource: '// Structured Text Motor Control\nIF (Start_PB OR Motor_Latch) AND NOT Stop_PB AND EStop_OK AND Overload_OK THEN\n    Motor_Latch := TRUE;\nELSE\n    Motor_Latch := FALSE;\nEND_IF;\nMotor_Run := Motor_Latch AND EStop_OK AND Overload_OK;',
        ),
      ],
      tasks: [
        PlcTask(name: 'MainContinuousTask', type: 'Continuous', periodMs: 100, programNames: ['MotorControl_ST']),
      ],
      hmis: [
        HmiScreenDef(id: 'hmi_motor', title: 'Motor Control HMI Panel', type: 'MotorControl'),
      ],
    );

    // 2. Tank Level Simulation
    final tankProj = PlcProject(
      id: 'proj_tank',
      name: 'Tank Level Simulation',
      controllerName: 'PLC_02',
      scanPeriodMs: 100,
      tags: [
        PlcTag(name: 'Level_PV', path: 'Inputs/Level_PV', dataType: 'FLOAT64', value: 42.0, ioType: 'SimulatedInput', engineeringUnits: '%', description: 'Tank Level PV'),
        PlcTag(name: 'Level_SP', path: 'Internal/Level_SP', dataType: 'FLOAT64', value: 50.0, ioType: 'Internal', engineeringUnits: '%', description: 'Level Setpoint'),
        PlcTag(name: 'Auto_Mode', path: 'Inputs/Auto_Mode', dataType: 'BOOL', value: true, ioType: 'SimulatedInput', description: 'Auto/Manual Switch'),
        PlcTag(name: 'Fill_Valve', path: 'Outputs/Fill_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Fill Valve Solenoid'),
        PlcTag(name: 'Drain_Valve', path: 'Outputs/Drain_Valve', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'Drain Valve Solenoid'),
        PlcTag(name: 'High_Alarm', path: 'Outputs/High_Alarm', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput', description: 'High Level Alarm Light'),
      ],
      structDefs: [],
      dataBlocks: [],
      programs: [
        PlcProgram(
          name: 'TankLevelControl_ST',
          language: 'StructuredText',
          description: 'On/Off Tank Level Fill/Drain Control',
          stSource: '// Tank Level Fill/Drain Logic\nIF Auto_Mode THEN\n    IF Level_PV < (Level_SP - 5.0) THEN\n        Fill_Valve := TRUE;\n        Drain_Valve := FALSE;\n    ELSIF Level_PV > (Level_SP + 5.0) THEN\n        Fill_Valve := FALSE;\n        Drain_Valve := TRUE;\n    ELSE\n        Fill_Valve := FALSE;\n        Drain_Valve := FALSE;\n    END_IF;\nEND_IF;\nHigh_Alarm := Level_PV > 85.0;',
        ),
      ],
      tasks: [
        PlcTask(name: 'ProcessLoopTask', type: 'Continuous', periodMs: 100, programNames: ['TankLevelControl_ST']),
      ],
      hmis: [
        HmiScreenDef(id: 'hmi_tank', title: 'Tank Level Process HMI', type: 'TankLevel'),
      ],
    );

    _allProjects = [motorProj, tankProj];
    _activeProject = motorProj;
  }

  void _startScanLoop() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(Duration(milliseconds: scanSpeedMs), (timer) {
      if (isRunning) {
        _executeScan();
      }
    });
  }

  void _executeScan() {
    setState(() {
      scanCount++;
      _evaluateActiveLogic();
    });
  }

  void _evaluateActiveLogic() {
    if (_activeProject.id == 'proj_motor') {
      bool start = _getTagBool('Start_PB');
      bool stop = _getTagBool('Stop_PB');
      bool estop = _getTagBool('EStop_OK');
      bool overload = _getTagBool('Overload_OK');
      bool latch = _getTagBool('Motor_Latch');

      if ((start || latch) && !stop && estop && overload) {
        latch = true;
      } else {
        latch = false;
      }

      bool run = latch && estop && overload;

      _setTagBool('Motor_Latch', latch);
      _setTagBool('Motor_Run', run);
    } else if (_activeProject.id == 'proj_tank') {
      double levelPv = _getTagDouble('Level_PV');
      double levelSp = _getTagDouble('Level_SP');
      bool autoMode = _getTagBool('Auto_Mode');
      bool fill = _getTagBool('Fill_Valve');
      bool drain = _getTagBool('Drain_Valve');

      if (autoMode) {
        if (levelPv < (levelSp - 5.0)) {
          fill = true;
          drain = false;
        } else if (levelPv > (levelSp + 5.0)) {
          fill = false;
          drain = true;
        } else {
          fill = false;
          drain = false;
        }
      }

      // Simulate process tank physics
      if (fill && levelPv < 100.0) levelPv += 0.5;
      if (drain && levelPv > 0.0) levelPv -= 0.5;

      _setTagDouble('Level_PV', levelPv);
      _setTagBool('Fill_Valve', fill);
      _setTagBool('Drain_Valve', drain);
      _setTagBool('High_Alarm', levelPv > 85.0);
    }
  }

  bool _getTagBool(String name) {
    final t = _activeProject.tags.firstWhere((t) => t.name == name, orElse: () => PlcTag(name: name, path: '', dataType: 'BOOL', value: false, ioType: 'Internal'));
    return t.isForced ? (t.forcedValue as bool) : (t.value == true);
  }

  double _getTagDouble(String name) {
    final t = _activeProject.tags.firstWhere((t) => t.name == name, orElse: () => PlcTag(name: name, path: '', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
    return t.isForced ? (t.forcedValue as double) : (t.value is double ? t.value : 0.0);
  }

  void _setTagBool(String name, bool val) {
    final idx = _activeProject.tags.indexWhere((t) => t.name == name);
    if (idx != -1) {
      final t = _activeProject.tags[idx];
      if (!t.isForced) {
        t.value = val;
      }
    }
  }

  void _setTagDouble(String name, double val) {
    final idx = _activeProject.tags.indexWhere((t) => t.name == name);
    if (idx != -1) {
      final t = _activeProject.tags[idx];
      if (!t.isForced) {
        t.value = val;
      }
    }
  }

  void _switchActiveProject(PlcProject proj) {
    setState(() {
      _activeProject = proj;
      if (proj.hmis.isNotEmpty) {
        _activeViewId = 'HMI:${proj.hmis.first.id}';
      } else if (proj.programs.isNotEmpty) {
        _activeViewId = 'PROGRAM:${proj.programs.first.name}';
      }
      scanCount = 0;
    });
  }

  void _deleteProgram(String progName) {
    setState(() {
      _activeProject.programs.removeWhere((p) => p.name == progName);
      for (var task in _activeProject.tasks) {
        task.programNames.remove(progName);
      }
      if (_activeViewId == 'PROGRAM:$progName') {
        if (_activeProject.hmis.isNotEmpty) {
          _activeViewId = 'HMI:${_activeProject.hmis.first.id}';
        } else {
          _activeViewId = 'MEMORY';
        }
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Program "$progName" deleted')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.memory, color: Colors.cyan, size: 22),
            const SizedBox(width: 10),
            Text(
              'Soft PLC Simulator — ${_activeProject.name}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        actions: [
          // Run / Pause Toggle
          IconButton(
            icon: Icon(
              isRunning ? Icons.pause_circle_filled : Icons.play_circle_fill,
              color: isRunning ? Colors.amber : Colors.greenAccent,
              size: 26,
            ),
            tooltip: isRunning ? 'Pause Scan Loop' : 'Run Scan Loop',
            onPressed: () {
              setState(() {
                isRunning = !isRunning;
              });
            },
          ),

          // Step Scan Button (for step-by-step debugging)
          IconButton(
            icon: const Icon(Icons.skip_next, color: Colors.cyanAccent, size: 26),
            tooltip: 'Execute Single Scan Step (Step Scan)',
            onPressed: () => _executeScan(),
          ),

          const SizedBox(width: 12),

          // Status Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isRunning ? Colors.green.withValues(alpha: 0.2) : Colors.amber.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isRunning ? Colors.green : Colors.amber),
            ),
            child: Text(
              isRunning ? 'RUNNING' : 'PAUSED',
              style: TextStyle(color: isRunning ? Colors.green : Colors.amber, fontWeight: FontWeight.bold, fontSize: 11),
            ),
          ),

          const SizedBox(width: 16),

          // Toggle Tag Inspector Side Dock
          IconButton(
            icon: Icon(Icons.table_chart, color: isTagDockVisible ? Colors.cyanAccent : Colors.grey, size: 24),
            tooltip: 'Toggle Tag Inspector Side Dock',
            onPressed: () => setState(() => isTagDockVisible = !isTagDockVisible),
          ),

          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          // PLC Execution Controls Toolbar (Scan Speed Slider cleanly placed to avoid clipping)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: const Color(0xFF0F172A),
            child: Row(
              children: [
                const Icon(Icons.speed, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                const Text('SCAN LOOP SPEED:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                const SizedBox(width: 12),
                SizedBox(
                  width: 220,
                  child: Slider(
                    value: scanSpeedMs.toDouble(),
                    min: 50.0,
                    max: 2000.0,
                    divisions: 39,
                    activeColor: scanSpeedMs > 500 ? Colors.amber : Colors.cyan,
                    onChanged: (val) {
                      setState(() {
                        scanSpeedMs = val.round();
                      });
                      _startScanLoop();
                    },
                  ),
                ),
                Text(
                  '${scanSpeedMs}ms ${scanSpeedMs >= 500 ? "(Slow Mo Step)" : ""}',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: scanSpeedMs >= 500 ? Colors.amberAccent : Colors.cyanAccent,
                  ),
                ),
                const Spacer(),
                Text('Scan Count: $scanCount', style: const TextStyle(fontSize: 12, color: Colors.grey, fontFamily: 'monospace')),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),

          // Main Shell Layout
          Expanded(
            child: Row(
              children: [
                // LEFT DOCK: Project Tree & Navigation Explorer
                _buildLeftDockExplorer(),

                const VerticalDivider(width: 1, color: Colors.white12),

                // CENTER WORKSPACE: Active View (HMI, ST Editor, or Memory Manager)
                Expanded(
                  child: _buildCenterWorkspace(),
                ),

                // RIGHT DOCK: Toggleable Tag Inspector & Forcing Matrix
                if (isTagDockVisible) ...[
                  const VerticalDivider(width: 1, color: Colors.white12),
                  TagInspectorDock(
                    tags: _activeProject.tags,
                    onTagStateChanged: () => setState(() {}),
                    onClose: () => setState(() => isTagDockVisible = false),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftDockExplorer() {
    return Container(
      width: 280,
      color: const Color(0xFF0F172A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Projects Switcher Header
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF1E293B),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SELECT PROJECT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey, letterSpacing: 0.5)),
                const SizedBox(height: 6),
                DropdownButton<String>(
                  value: _activeProject.id,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF1E293B),
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                  items: _allProjects.map((p) {
                    final isActive = p.id == _activeProject.id;
                    return DropdownMenuItem(
                      value: p.id,
                      child: Row(
                        children: [
                          Icon(isActive ? Icons.check_circle : Icons.folder, size: 16, color: isActive ? Colors.greenAccent : Colors.grey),
                          const SizedBox(width: 8),
                          Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (id) {
                    if (id != null) {
                      final selected = _allProjects.firstWhere((p) => p.id == id);
                      _switchActiveProject(selected);
                    }
                  },
                ),
              ],
            ),
          ),

          // Active Project Tree Navigation
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                // Project Header Info
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.account_tree, color: Colors.cyan, size: 20),
                  title: Text(_activeProject.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  subtitle: Text('${_activeProject.controllerName} (${_activeProject.scanPeriodMs}ms)', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ),

                const Divider(height: 16, color: Colors.white12),

                // SECTION 1: HMI Dashboards Folder
                _buildTreeFolderHeader('HMI DASHBOARDS', Icons.dashboard_outlined),
                ..._activeProject.hmis.map((hmi) {
                  final isSelected = _activeViewId == 'HMI:${hmi.id}';
                  return Container(
                    margin: const EdgeInsets.only(left: 12, top: 2),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.monitor, size: 16, color: isSelected ? Colors.cyanAccent : Colors.grey),
                      title: Text(hmi.title, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                      onTap: () => setState(() => _activeViewId = 'HMI:${hmi.id}'),
                    ),
                  );
                }),

                const SizedBox(height: 12),

                // SECTION 2: MEMORY (Tags & Data Blocks)
                _buildTreeFolderHeader('MEMORY (TAGS & DATA BLOCKS)', Icons.storage),
                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'MEMORY' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.memory, size: 16, color: _activeViewId == 'MEMORY' ? Colors.cyanAccent : Colors.tealAccent),
                    title: Text(
                      'Tags & Data Blocks (${_activeProject.tags.length} Tags, ${_activeProject.structDefs.length} Structs, ${_activeProject.dataBlocks.length} DBs)',
                      style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'MEMORY' ? FontWeight.bold : FontWeight.normal),
                    ),
                    onTap: () => setState(() => _activeViewId = 'MEMORY'),
                  ),
                ),

                const SizedBox(height: 12),

                // SECTION 3: Tasks & Programs Classified by Task Type
                _buildTreeFolderHeader('TASKS & CONTROL LOGIC', Icons.folder_special_outlined),

                _buildTaskCategoryFolder('Startup Tasks', Icons.play_arrow, 'Startup'),
                _buildTaskCategoryFolder('Continuous Tasks', Icons.loop, 'Continuous'),
                _buildTaskCategoryFolder('Periodic Tasks', Icons.timer, 'Periodic'),
                _buildTaskCategoryFolder('Event Tasks', Icons.bolt, 'Event'),

                const SizedBox(height: 16),

                // Add Program Button
                OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add New Program'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.cyan,
                    side: const BorderSide(color: Colors.cyan),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: _showAddProgramDialog,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeFolderHeader(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey, letterSpacing: 0.5)),
        ],
      ),
    );
  }

  Widget _buildTaskCategoryFolder(String title, IconData icon, String taskType) {
    // Count total programs assigned to tasks of this taskType
    final programsInTaskType = <String>[];
    for (var task in _activeProject.tasks.where((t) => t.type == taskType)) {
      programsInTaskType.addAll(task.programNames);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: Colors.tealAccent),
              const SizedBox(width: 6),
              Text('$title (${programsInTaskType.length})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70)),
            ],
          ),

          if (programsInTaskType.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 20, top: 2, bottom: 4),
              child: Text('(none configured)', style: TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic)),
            )
          else
            ...programsInTaskType.map((progName) {
              final prog = _activeProject.programs.firstWhere((p) => p.name == progName, orElse: () => PlcProgram(name: progName, language: 'StructuredText'));
              final isSelected = _activeViewId == 'PROGRAM:$progName';

              return Container(
                margin: const EdgeInsets.only(left: 20, top: 2),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                  leading: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: prog.language == 'StructuredText' ? Colors.blue.withValues(alpha: 0.3) : Colors.orange.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(prog.language == 'StructuredText' ? 'ST' : 'LD', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                  title: Text(prog.name, style: TextStyle(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Delete Program',
                    onPressed: () => _deleteProgram(prog.name),
                  ),
                  onTap: () => setState(() => _activeViewId = 'PROGRAM:$progName'),
                ),
              );
            }),
        ],
      ),
    );
  }

  void _showAddProgramDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: 'NewProgram');
        String language = 'StructuredText';

        // Ensure at least 1 task exists
        if (_activeProject.tasks.isEmpty) {
          _activeProject.tasks.add(PlcTask(name: 'MainTask', type: 'Continuous', periodMs: 100, programNames: []));
        }
        String taskName = _activeProject.tasks.first.name;

        return AlertDialog(
          title: const Text('Add New Program to Project'),
          content: StatefulBuilder(
            builder: (context, setDlgState) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Program Name')),
                const SizedBox(height: 12),
                DropdownButton<String>(
                  value: language,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'StructuredText', child: Text('Structured Text (ST)')),
                    DropdownMenuItem(value: 'LadderLogic', child: Text('Ladder Logic (LD)')),
                  ],
                  onChanged: (val) => setDlgState(() => language = val!),
                ),
                const SizedBox(height: 12),
                DropdownButton<String>(
                  value: taskName,
                  isExpanded: true,
                  items: _activeProject.tasks.map((t) => DropdownMenuItem(value: t.name, child: Text('${t.name} (${t.type})'))).toList(),
                  onChanged: (val) => setDlgState(() => taskName = val!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final newProg = PlcProgram(
                  name: nameCtrl.text,
                  language: language,
                  stSource: '// Write ST Code for ${nameCtrl.text}\n',
                );
                setState(() {
                  _activeProject.programs.add(newProg);
                  final t = _activeProject.tasks.firstWhere((tk) => tk.name == taskName);
                  if (!t.programNames.contains(newProg.name)) {
                    t.programNames.add(newProg.name);
                  }
                  _activeViewId = 'PROGRAM:${newProg.name}';
                });
                Navigator.pop(ctx);
              },
              child: const Text('Add Program'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCenterWorkspace() {
    if (_activeViewId.startsWith('HMI:')) {
      return _buildHmiView();
    } else if (_activeViewId == 'MEMORY') {
      return MemoryManagerScreen(
        currentProject: _activeProject,
        onProjectUpdated: () => setState(() {}),
      );
    } else if (_activeViewId.startsWith('PROGRAM:')) {
      final progName = _activeViewId.replaceFirst('PROGRAM:', '');
      final prog = _activeProject.programs.firstWhere((p) => p.name == progName, orElse: () => _activeProject.programs.first);
      return StEditorScreen(
        currentProject: _activeProject,
        onSaveProgram: (updated) {
          setState(() {
            final idx = _activeProject.programs.indexWhere((p) => p.name == updated.name);
            if (idx != -1) {
              _activeProject.programs[idx] = updated;
            }
          });
        },
      );
    }
    return const Center(child: Text('Select an HMI, Memory, or Program from the Left Dock'));
  }

  Widget _buildHmiView() {
    if (_activeProject.id == 'proj_motor') {
      return _buildMotorHmi();
    } else if (_activeProject.id == 'proj_tank') {
      return _buildTankHmi();
    }
    return const Center(child: Text('HMI Surface'));
  }

  Widget _buildMotorHmi() {
    final motorRun = _getTagBool('Motor_Run');
    final eStopOk = _getTagBool('EStop_OK');
    final overloadOk = _getTagBool('Overload_OK');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Project: ${_activeProject.name}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.cyan)),
          const SizedBox(height: 4),
          const Text('Interactive HMI Control Surface for Motor Start/Stop Circuit', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 20),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          _setTagBool('Start_PB', true);
                          if (isRunning) _executeScan();
                          Future.delayed(const Duration(milliseconds: 300), () {
                            if (mounted) {
                              _setTagBool('Start_PB', false);
                              if (isRunning) _executeScan();
                            }
                          });
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
                        child: const Text('START (NO)'),
                      ),

                      ElevatedButton(
                        onPressed: () {
                          _setTagBool('Stop_PB', true);
                          if (isRunning) _executeScan();
                          Future.delayed(const Duration(milliseconds: 300), () {
                            if (mounted) {
                              _setTagBool('Stop_PB', false);
                              if (isRunning) _executeScan();
                            }
                          });
                        },
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
                        child: const Text('STOP (NC)'),
                      ),

                      Column(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: motorRun ? Colors.greenAccent : Colors.grey.shade800,
                              boxShadow: motorRun ? [BoxShadow(color: Colors.greenAccent.withValues(alpha: 0.6), blurRadius: 16)] : [],
                              border: Border.all(color: motorRun ? Colors.green : Colors.grey, width: 2),
                            ),
                            child: Icon(Icons.power_settings_new, color: motorRun ? Colors.black : Colors.grey, size: 36),
                          ),
                          const SizedBox(height: 8),
                          Text(motorRun ? 'RUNNING' : 'STOPPED', style: TextStyle(fontWeight: FontWeight.bold, color: motorRun ? Colors.greenAccent : Colors.grey)),
                        ],
                      ),
                    ],
                  ),

                  const Divider(height: 32),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Row(
                        children: [
                          Switch(
                            value: eStopOk,
                            activeTrackColor: Colors.green,
                            onChanged: (val) {
                              _setTagBool('EStop_OK', val);
                              if (isRunning) _executeScan();
                            },
                          ),
                          const Text('E-Stop Healthy'),
                        ],
                      ),
                      Row(
                        children: [
                          Switch(
                            value: overloadOk,
                            activeTrackColor: Colors.green,
                            onChanged: (val) {
                              _setTagBool('Overload_OK', val);
                              if (isRunning) _executeScan();
                            },
                          ),
                          const Text('Overload Healthy'),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTankHmi() {
    final levelPv = _getTagDouble('Level_PV');
    final levelSp = _getTagDouble('Level_SP');
    final fillValve = _getTagBool('Fill_Valve');
    final drainValve = _getTagBool('Drain_Valve');
    final highAlarm = _getTagBool('High_Alarm');
    final autoMode = _getTagBool('Auto_Mode');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Project: ${_activeProject.name}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.tealAccent)),
          const SizedBox(height: 4),
          const Text('Interactive Tank Level Fill & Drain Process Simulation HMI', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 20),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                children: [
                  // Tank Graphics Visualization
                  Column(
                    children: [
                      Container(
                        width: 120,
                        height: 200,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.cyan, width: 3),
                          borderRadius: BorderRadius.circular(8),
                          color: const Color(0xFF0F172A),
                        ),
                        child: Stack(
                          alignment: Alignment.bottomCenter,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 120,
                              height: (levelPv / 100.0) * 194.0,
                              color: highAlarm ? Colors.red.withValues(alpha: 0.7) : Colors.cyan.withValues(alpha: 0.6),
                            ),
                            Center(
                              child: Text(
                                '${levelPv.toStringAsFixed(1)}%',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('Tank PV: ${levelPv.toStringAsFixed(1)}%', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(width: 32),

                  // Process Controls & Valve Indicators
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Switch(
                              value: autoMode,
                              activeTrackColor: Colors.tealAccent,
                              onChanged: (val) {
                                _setTagBool('Auto_Mode', val);
                                if (isRunning) _executeScan();
                              },
                            ),
                            Text('Auto Control Mode (${autoMode ? "ON" : "OFF"})', style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Valve status indicators
                        Row(
                          children: [
                            _buildValvePill('Fill Valve', fillValve, Colors.green),
                            const SizedBox(width: 16),
                            _buildValvePill('Drain Valve', drainValve, Colors.orange),
                            const SizedBox(width: 16),
                            _buildValvePill('High Level Alarm', highAlarm, Colors.red),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // Setpoint Slider
                        Text('Set Level Setpoint (SP): ${levelSp.toStringAsFixed(1)}%', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Slider(
                          value: levelSp,
                          min: 10.0,
                          max: 90.0,
                          divisions: 16,
                          label: '${levelSp.toStringAsFixed(0)}%',
                          activeColor: Colors.teal,
                          onChanged: (val) {
                            _setTagDouble('Level_SP', val);
                            if (isRunning) _executeScan();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildValvePill(String name, bool active, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.2) : Colors.black45,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: active ? color : Colors.grey),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.water_drop, size: 16, color: active ? color : Colors.grey),
          const SizedBox(width: 6),
          Text(name, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: active ? color : Colors.grey)),
        ],
      ),
    );
  }
}
