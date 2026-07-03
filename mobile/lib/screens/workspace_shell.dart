import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../widgets/tag_inspector_dock.dart';
import 'st_editor_screen.dart';
import 'ld_editor_screen.dart';
import 'fbd_editor_screen.dart';
import 'sfc_editor_screen.dart';
import 'memory_manager_screen.dart';
import 'hmi_dashboard_builder_screen.dart';

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
    // 1. Basic Motor Start Stop Project
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
        PlcProgram(
          name: 'MotorControl_LD',
          language: 'LadderLogic',
          description: 'Motor start/stop Rungs in Ladder Logic (LD)',
        ),
      ],
      tasks: [
        PlcTask(name: 'MainContinuousTask', type: 'Continuous', periodMs: 100, programNames: ['MotorControl_ST', 'MotorControl_LD']),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_motor',
          title: 'Motor Control HMI Dashboard',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 'c1', title: 'START Motor (NO)', type: 'PushbuttonSwitch', tagBinding: 'Start_PB', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'c2', title: 'STOP Motor (NC)', type: 'PushbuttonSwitch', tagBinding: 'Stop_PB', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 'c3', title: 'Motor Running LED', type: 'LedIndicatorLight', tagBinding: 'Motor_Run', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 'c4', title: 'E-Stop Healthy Switch', type: 'ToggleSwitch', tagBinding: 'EStop_OK', gridSpanWidth: 1, accentColor: 'cyan'),
            HmiComponent(id: 'c5', title: 'Overload Healthy Switch', type: 'ToggleSwitch', tagBinding: 'Overload_OK', gridSpanWidth: 1, accentColor: 'amber'),
            HmiComponent(id: 'c6', title: 'Motor Status Pill', type: 'StatusPillDisplay', tagBinding: 'Motor_Run', gridSpanWidth: 2, accentColor: 'teal'),
          ],
        ),
      ],
    );

    // 2. Tank Level Simulation Project
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
        PlcProgram(
          name: 'TankLevel_FBD',
          language: 'FunctionBlockDiagram',
          description: 'Tank Level Signal Flow Gate Diagram',
        ),
        PlcProgram(
          name: 'TankSequence_SFC',
          language: 'SequentialFunctionChart',
          description: 'Tank Fill/Drain Sequence State Machine',
        ),
      ],
      tasks: [
        PlcTask(name: 'ProcessLoopTask', type: 'Continuous', periodMs: 100, programNames: ['TankLevelControl_ST', 'TankLevel_FBD', 'TankSequence_SFC']),
      ],
      hmis: [
        HmiScreenDef(
          id: 'hmi_tank',
          title: 'Tank Level Process Dashboard',
          layoutType: 'GridDashboard',
          components: [
            HmiComponent(id: 't1', title: 'Tank Process Graphic', type: 'TankGraphicDisplay', tagBinding: 'Level_PV', gridSpanWidth: 2, accentColor: 'cyan'),
            HmiComponent(id: 't2', title: 'Level Setpoint Slider', type: 'NumericSliderInput', tagBinding: 'Level_SP', gridSpanWidth: 2, accentColor: 'teal'),
            HmiComponent(id: 't3', title: 'Auto Mode Toggle', type: 'ToggleSwitch', tagBinding: 'Auto_Mode', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 't4', title: 'Fill Valve Solenoid LED', type: 'LedIndicatorLight', tagBinding: 'Fill_Valve', gridSpanWidth: 1, accentColor: 'green'),
            HmiComponent(id: 't5', title: 'Drain Valve Solenoid LED', type: 'LedIndicatorLight', tagBinding: 'Drain_Valve', gridSpanWidth: 1, accentColor: 'amber'),
            HmiComponent(id: 't6', title: 'High Level Alarm LED', type: 'LedIndicatorLight', tagBinding: 'High_Alarm', gridSpanWidth: 1, accentColor: 'red'),
            HmiComponent(id: 't7', title: 'Level Gauge Bar', type: 'DigitalGaugeDisplay', tagBinding: 'Level_PV', gridSpanWidth: 4, accentColor: 'cyan'),
          ],
        ),
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

  void _addNewHmiDashboard() {
    showDialog(
      context: context,
      builder: (ctx) {
        final titleCtrl = TextEditingController(text: 'Custom HMI Dashboard');
        return AlertDialog(
          title: const Text('Add New HMI Dashboard'),
          content: TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Dashboard Title')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final newHmi = HmiScreenDef(
                  id: 'hmi_${DateTime.now().millisecondsSinceEpoch}',
                  title: titleCtrl.text,
                  layoutType: 'GridDashboard',
                  components: [],
                );
                setState(() {
                  _activeProject.hmis.add(newHmi);
                  _activeViewId = 'HMI:${newHmi.id}';
                });
                Navigator.pop(ctx);
              },
              child: const Text('Create HMI Dashboard'),
            ),
          ],
        );
      },
    );
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

                // CENTER WORKSPACE: Active View (HMI, Language Editors, or Memory Manager)
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
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.account_tree, color: Colors.cyan, size: 20),
                    title: Text(_activeProject.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Text('${_activeProject.controllerName} (${_activeProject.scanPeriodMs}ms)', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ),
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
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.monitor, size: 16, color: isSelected ? Colors.cyanAccent : Colors.grey),
                        title: Text(hmi.title, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                        onTap: () => setState(() => _activeViewId = 'HMI:${hmi.id}'),
                      ),
                    ),
                  );
                }),

                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 4, bottom: 8),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text('Add HMI Dashboard', style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.tealAccent,
                      side: const BorderSide(color: Colors.tealAccent),
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    ),
                    onPressed: _addNewHmiDashboard,
                  ),
                ),

                const SizedBox(height: 8),

                // SECTION 2: MEMORY (Tags & Data Blocks)
                _buildTreeFolderHeader('MEMORY (TAGS & DATA BLOCKS)', Icons.storage),
                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'MEMORY' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Material(
                    color: Colors.transparent,
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
                ),

                const SizedBox(height: 12),

                // SECTION 3: Tasks & Programs Classified by Task Type & Language
                _buildTreeFolderHeader('TASKS & IEC 61131-3 LOGIC', Icons.folder_special_outlined),

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

              String badgeText = 'ST';
              Color badgeColor = Colors.blue;
              if (prog.language == 'LadderLogic') { badgeText = 'LD'; badgeColor = Colors.orange; }
              if (prog.language == 'FunctionBlockDiagram') { badgeText = 'FBD'; badgeColor = Colors.teal; }
              if (prog.language == 'SequentialFunctionChart') { badgeText = 'SFC'; badgeColor = Colors.purple; }

              return Container(
                margin: const EdgeInsets.only(left: 20, top: 2),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    leading: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(badgeText, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
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
                    DropdownMenuItem(value: 'FunctionBlockDiagram', child: Text('Function Block Diagram (FBD)')),
                    DropdownMenuItem(value: 'SequentialFunctionChart', child: Text('Sequential Function Chart (SFC)')),
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
      final hmiId = _activeViewId.replaceFirst('HMI:', '');
      final hmi = _activeProject.hmis.firstWhere((h) => h.id == hmiId, orElse: () => _activeProject.hmis.first);
      return HmiDashboardBuilderScreen(
        currentProject: _activeProject,
        hmiScreen: hmi,
        onScanTriggered: () => setState(() => _executeScan()),
        onProjectUpdated: () => setState(() {}),
      );
    } else if (_activeViewId == 'MEMORY') {
      return MemoryManagerScreen(
        currentProject: _activeProject,
        onProjectUpdated: () => setState(() {}),
      );
    } else if (_activeViewId.startsWith('PROGRAM:')) {
      final progName = _activeViewId.replaceFirst('PROGRAM:', '');
      final prog = _activeProject.programs.firstWhere((p) => p.name == progName, orElse: () => _activeProject.programs.first);

      // Render Editor according to IEC Language
      if (prog.language == 'LadderLogic') {
        return LdEditorScreen(
          currentProject: _activeProject,
          program: prog,
          onProgramUpdated: () => setState(() {}),
        );
      } else if (prog.language == 'FunctionBlockDiagram') {
        return FbdEditorScreen(
          currentProject: _activeProject,
          program: prog,
          onProgramUpdated: () => setState(() {}),
        );
      } else if (prog.language == 'SequentialFunctionChart') {
        return SfcEditorScreen(
          currentProject: _activeProject,
          program: prog,
          onProgramUpdated: () => setState(() {}),
        );
      } else {
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
    }
    return const Center(child: Text('Select an HMI, Memory, or Program from the Left Dock'));
  }
}
