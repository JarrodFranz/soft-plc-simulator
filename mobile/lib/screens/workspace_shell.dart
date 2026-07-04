import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import '../data/default_projects.dart';
import '../widgets/tag_inspector_dock.dart';
import 'st_editor_screen.dart';
import 'ld_editor_screen.dart';
import 'fbd_editor_screen.dart';
import 'sfc_editor_screen.dart';
import 'memory_manager_screen.dart';
import 'hmi_dashboard_builder_screen.dart';
import 'simulated_io_screen.dart';

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
    _allProjects = DefaultProjects.all();
    _activeProject = _allProjects.first;
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
    final id = _activeProject.id;

    // ── 1. Basic Motor Start/Stop ─────────────────────────────────────────
    if (id == 'proj_motor') {
      bool start = _getTagBool('Start_PB');
      bool stop = _getTagBool('Stop_PB');
      bool estop = _getTagBool('EStop_OK');
      bool overload = _getTagBool('Overload_OK');
      bool latch = _getTagBool('Motor_Latch');
      latch = (start || latch) && !stop && estop && overload;
      _setTagBool('Motor_Latch', latch);
      _setTagBool('Motor_Run', latch && estop && overload);

    // ── 2. Tank Level Simulation ──────────────────────────────────────────
    } else if (id == 'proj_tank') {
      double pv = _getTagDouble('Level_PV');
      double sp = _getTagDouble('Level_SP');
      bool auto = _getTagBool('Auto_Mode');
      bool fill = false, drain = false;
      if (auto) {
        if (pv < sp - 5.0) { fill = true; }
        else if (pv > sp + 5.0) { drain = true; }
      }
      if (fill && pv < 100.0) pv += 0.5;
      if (drain && pv > 0.0) pv -= 0.5;
      _setTagDouble('Level_PV', pv);
      _setTagBool('Fill_Valve', fill);
      _setTagBool('Drain_Valve', drain);
      _setTagBool('High_Alarm', pv > 85.0);

    // ── 3. ST Reactor Temperature Controller ─────────────────────────────
    } else if (id == 'proj_st_reactor') {
      double temp = _getTagDouble('Temp_PV');
      double sp = _getTagDouble('Temp_SP');
      bool auto = _getTagBool('Auto_Mode');
      bool heat = false, cool = false;
      if (auto) {
        if (temp < sp - 2.0) { heat = true; }
        else if (temp > sp + 2.0) { cool = true; }
      }
      if (heat && temp < 100.0) temp += 0.3;
      if (cool && temp > 0.0) temp -= 0.2;
      if (!heat && !cool && temp > 20.0) temp -= 0.02; // ambient loss
      _setTagDouble('Temp_PV', double.parse(temp.clamp(0.0, 105.0).toStringAsFixed(1)));
      _setTagBool('Heat_Cmd', heat);
      _setTagBool('Cool_Cmd', cool);
      _setTagBool('Alarm_High', temp > 95.0);
      _setTagBool('Alarm_Low', temp < 5.0);
      _setTagBool('Reactor_Ready', !heat && !cool && temp >= sp - 2.0 && temp <= sp + 2.0);

    // ── 4. LD Conveyor Belt Control ───────────────────────────────────────
    } else if (id == 'proj_ld_conveyor') {
      bool start = _getTagBool('Start_PB');
      bool stop = _getTagBool('Stop_PB');
      bool estop = _getTagBool('EStop');
      bool jog = _getTagBool('Manual_Jog');
      bool latch = _getTagBool('Belt_Latch');
      bool jammed = _getTagBool('Belt_Jammed');

      bool run = (start || latch || jog) && !stop && estop && !jammed;
      _setTagBool('Belt_Motor', run);
      _setTagBool('Belt_Latch', run);

      // Simulate parts arriving every ~2s when belt running
      bool eye = false;
      if (run) {
        eye = (scanCount % 22) < 4; // part present for 4/22 scans (~400ms pulse)
        if (eye) _setTagBool('Belt_Jammed', false); // part clears jam
      }
      _setTagBool('Photo_Eye', eye);
      _setTagBool('Part_Present', eye);

    // ── 5. FBD HVAC Zone Controller ───────────────────────────────────────
    } else if (id == 'proj_fbd_hvac') {
      double temp = _getTagDouble('Room_Temp');
      double sp = _getTagDouble('Setpoint');
      bool occupied = _getTagBool('Occupied');
      bool windowOpen = _getTagBool('Window_Open');

      bool hvacEnable = occupied && !windowOpen;
      bool heat = hvacEnable && temp < (sp - 1.0);
      bool cool = hvacEnable && temp > (sp + 1.0);

      if (heat && temp < 35.0) temp += 0.08;
      if (cool && temp > 10.0) temp -= 0.08;
      if (!heat && !cool && temp > 15.0) temp -= 0.01; // ambient drift

      _setTagDouble('Room_Temp', double.parse(temp.clamp(0.0, 45.0).toStringAsFixed(1)));
      _setTagBool('Hvac_Active', hvacEnable);
      _setTagBool('Fan_Cmd', hvacEnable);
      _setTagBool('Heat_Cmd', heat);
      _setTagBool('Cool_Cmd', cool);

    // ── 6. SFC Bottle Filling Sequence ────────────────────────────────────
    } else if (id == 'proj_sfc_filling') {
      int step = _getTagInt('Sfc_Step');
      int delay = _getTagInt('Step_Delay');
      bool startCmd = _getTagBool('Start_Cmd');
      bool bottlePresent = _getTagBool('Bottle_Present');
      double fillLevel = _getTagDouble('Fill_Level');

      switch (step) {
        case 0: // IDLE
          _setTagBool('Fill_Valve', false);
          _setTagBool('Cap_Solenoid', false);
          _setTagBool('Eject_Cyl', false);
          _setTagBool('Sequence_Running', false);
          if (startCmd) { step = 1; delay = 0; }
          break;
        case 1: // WAIT_BOTTLE
          _setTagBool('Sequence_Running', true);
          _setTagBool('Eject_Cyl', false);
          if (bottlePresent) { step = 2; fillLevel = 0.0; delay = 0; }
          break;
        case 2: // FILLING
          _setTagBool('Fill_Valve', true);
          fillLevel = (fillLevel + 4.0).clamp(0.0, 100.0);
          _setTagDouble('Fill_Level', fillLevel);
          if (fillLevel >= 95.0) { step = 3; delay = 0; }
          break;
        case 3: // CAPPING — hold 6 scans (~1.2s)
          _setTagBool('Fill_Valve', false);
          _setTagBool('Cap_Solenoid', true);
          delay++;
          if (delay >= 6) { step = 4; delay = 0; }
          break;
        case 4: // EJECTING — hold 4 scans (~800ms)
          _setTagBool('Cap_Solenoid', false);
          _setTagBool('Eject_Cyl', true);
          delay++;
          if (delay >= 4) {
            _setTagInt('Filled_Count', _getTagInt('Filled_Count') + 1);
            step = 1;
            delay = 0;
          }
          break;
      }
      _setTagInt('Sfc_Step', step);
      _setTagInt('Step_Delay', delay);

    // ── 7. All Languages — Water Treatment Plant ──────────────────────────
    } else if (id == 'proj_all_water') {
      // LD: Pump start/stop seal-in
      bool start = _getTagBool('Start_PB');
      bool stop = _getTagBool('Stop_PB');
      bool estop = _getTagBool('EStop');
      bool latch = _getTagBool('Pump_Latch');
      bool pumpRun = (start || latch) && !stop && estop && !_getTagBool('Alarm_Active');
      _setTagBool('Pump_Latch', pumpRun);
      _setTagBool('Pump_Motor', pumpRun);

      // FBD: Quality gate logic
      double turbidity = _getTagDouble('Turbidity_PV');
      double turbSP = _getTagDouble('Turbidity_SP');
      double level = _getTagDouble('Level_PV');
      bool qualityOk = turbidity < turbSP && level > 10.0;
      _setTagBool('Quality_OK', qualityOk);

      // Simulate flow rate
      _setTagDouble('Flow_PV', pumpRun ? (42.0 + (scanCount % 7 - 3).toDouble()) : 0.0);

      // ST: Dosing pump — dose when running with bad water
      bool dosing = pumpRun && !qualityOk;
      _setTagBool('Treat_Dosing', dosing);

      // Process physics — turbidity clears with dosing, rises slowly otherwise
      if (dosing && turbidity > 0.5) { turbidity -= 0.12; }
      else if (pumpRun && !dosing && turbidity < turbSP * 1.5) { turbidity += 0.04; }
      _setTagDouble('Turbidity_PV', double.parse(turbidity.clamp(0.0, 20.0).toStringAsFixed(1)));

      // Reservoir level — drops while pumping, refills slowly
      if (pumpRun && level > 0.0) level -= 0.15;
      if (!pumpRun && level < 100.0) level += 0.08;
      _setTagDouble('Level_PV', double.parse(level.clamp(0.0, 100.0).toStringAsFixed(1)));

      // SFC: Backwash triggers when turbidity exceeds SP
      bool backwash = !qualityOk && pumpRun;
      _setTagBool('Backwash_Active', backwash);
      _setTagBool('Backwash_Valve', backwash);
      _setTagBool('Backwash_Pump', backwash && turbidity > turbSP + 1.0);

      // ST: Safety supervisor alarm
      bool alarm = !estop || level < 5.0 || turbidity > turbSP + 8.0;
      _setTagBool('Alarm_Active', alarm);
      _setTagBool('System_Ready', pumpRun && qualityOk && !alarm);
    }
  }

  PlcTag? _rootOf(String path) {
    final rootName = path.split('.').first.split('[').first;
    for (final t in _activeProject.tags) {
      if (t.name == rootName) {
        return t;
      }
    }
    return null;
  }

  bool _getTagBool(String path) {
    final root = _rootOf(path);
    if (root != null && root.isForced && root.name == path) {
      return root.forcedValue == true;
    }
    return readPath(_activeProject, path) == true;
  }

  double _getTagDouble(String path) {
    final root = _rootOf(path);
    if (root != null && root.isForced && root.name == path) {
      return (root.forcedValue as num?)?.toDouble() ?? 0.0;
    }
    final v = readPath(_activeProject, path);
    return v is num ? v.toDouble() : 0.0;
  }

  int _getTagInt(String path) {
    final root = _rootOf(path);
    if (root != null && root.isForced && root.name == path) {
      return (root.forcedValue as num?)?.toInt() ?? 0;
    }
    final v = readPath(_activeProject, path);
    return v is num ? v.toInt() : 0;
  }

  void _setTagBool(String path, bool val) => _writeIfNotForced(path, val);
  void _setTagDouble(String path, double val) => _writeIfNotForced(path, val);
  void _setTagInt(String path, int val) => _writeIfNotForced(path, val);

  void _writeIfNotForced(String path, dynamic val) {
    final root = _rootOf(path);
    if (root != null && root.isForced && root.name == path) {
      return; // forced root value is not overwritten by logic
    }
    writePath(_activeProject, path, val);
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

                // SECTION 2: MEMORY (Tags & Structs)
                _buildTreeFolderHeader('MEMORY (TAGS & STRUCTS)', Icons.storage),
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
                        'Tags & Structs (${_activeProject.tags.length} Tags, ${_activeProject.structDefs.length} Structs)',
                        style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'MEMORY' ? FontWeight.bold : FontWeight.normal),
                      ),
                      onTap: () => setState(() => _activeViewId = 'MEMORY'),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'SIMIO:rules' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.sensors, size: 16, color: _activeViewId == 'SIMIO:rules' ? Colors.cyanAccent : Colors.tealAccent),
                      title: Text(
                        'SIMULATED I/O (${_activeProject.simRules.length})',
                        style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'SIMIO:rules' ? FontWeight.bold : FontWeight.normal),
                      ),
                      onTap: () => setState(() => _activeViewId = 'SIMIO:rules'),
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
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey, letterSpacing: 0.5)),
          ),
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
    } else if (_activeViewId == 'SIMIO:rules') {
      return SimulatedIoScreen(
        currentProject: _activeProject,
        onProjectUpdated: () => setState(() {}),
      );
    }
    return const Center(child: Text('Select an HMI, Memory, or Program from the Left Dock'));
  }
}
