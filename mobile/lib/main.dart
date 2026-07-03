import 'package:flutter/material.dart';
import 'models/project_model.dart';
import 'screens/st_editor_screen.dart';
import 'screens/project_manager_screen.dart';

void main() {
  runApp(const SoftPlcApp());
}

class SoftPlcApp extends StatelessWidget {
  const SoftPlcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mobile Soft PLC Simulator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Dark slate
        cardColor: const Color(0xFF1E293B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8), // Cyan accent
          secondary: Color(0xFF2DD4BF), // Teal accent
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const MainNavigationShell(),
    );
  }
}

class MainNavigationShell extends StatefulWidget {
  const MainNavigationShell({super.key});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _selectedIndex = 0;

  // Active Project State
  late PlcProject _currentProject;

  // Runtime engine states
  bool isRunning = true;
  int scanCount = 100;
  double lastScanTimeMs = 1.4;

  @override
  void initState() {
    super.initState();
    _initDefaultProject();
  }

  void _initDefaultProject() {
    _currentProject = PlcProject(
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
      programs: [
        PlcProgram(
          name: 'StMotorControl',
          language: 'StructuredText',
          description: 'Motor start/stop with permissives in ST',
          stSource: '// Structured Text Motor Control\nIF (Start_PB OR Motor_Latch) AND NOT Stop_PB AND EStop_OK AND Overload_OK THEN\n    Motor_Latch := TRUE;\nELSE\n    Motor_Latch := FALSE;\nEND_IF;\nMotor_Run := Motor_Latch AND EStop_OK AND Overload_OK;',
        ),
      ],
      tasks: [
        PlcTask(name: 'MainTask', type: 'Continuous', periodMs: 100, programNames: ['StMotorControl']),
      ],
    );
  }

  void _executeScanCycle() {
    if (!isRunning) return;

    setState(() {
      scanCount++;
      // Execute all active programs in project
      for (var prog in _currentProject.programs) {
        if (!prog.enabled) continue;
        if (prog.language == 'StructuredText') {
          _evalSimpleSt(prog.stSource);
        }
      }
    });
  }

  void _evalSimpleSt(String source) {
    // Client-side quick execution model for ST in Flutter web
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
  }

  bool _getTagBool(String name) {
    final t = _currentProject.tags.firstWhere((t) => t.name == name, orElse: () => PlcTag(name: name, path: '', dataType: 'BOOL', value: false, ioType: 'Internal'));
    return t.isForced ? (t.forcedValue as bool) : (t.value == true);
  }

  void _setTagBool(String name, bool val) {
    final idx = _currentProject.tags.indexWhere((t) => t.name == name);
    if (idx != -1) {
      final t = _currentProject.tags[idx];
      if (!t.isForced) {
        t.value = val;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _buildDashboardView(),
      StEditorScreen(
        currentProject: _currentProject,
        onSaveProgram: (prog) {
          setState(() {
            final idx = _currentProject.programs.indexWhere((p) => p.name == prog.name);
            if (idx != -1) {
              _currentProject.programs[idx] = prog;
            } else {
              _currentProject.programs.add(prog);
            }
          });
        },
      ),
      ProjectManagerScreen(
        currentProject: _currentProject,
        onLoadProject: (newProj) {
          setState(() {
            _currentProject = newProj;
          });
        },
      ),
      _buildTagInspectorView(),
    ];

    return Scaffold(
      body: pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'HMI Dashboard'),
          NavigationDestination(icon: Icon(Icons.code), label: 'ST Editor'),
          NavigationDestination(icon: Icon(Icons.folder), label: 'Project & Tasks'),
          NavigationDestination(icon: Icon(Icons.table_rows), label: 'Tag Inspector'),
        ],
      ),
    );
  }

  Widget _buildDashboardView() {
    final motorRun = _getTagBool('Motor_Run');
    final eStopOk = _getTagBool('EStop_OK');
    final overloadOk = _getTagBool('Overload_OK');

    return Scaffold(
      appBar: AppBar(
        title: Text('${_currentProject.name} — HMI Dashboard'),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            icon: Icon(isRunning ? Icons.pause_circle : Icons.play_circle, color: isRunning ? Colors.amber : Colors.greenAccent),
            tooltip: isRunning ? 'Pause PLC Scan' : 'Run PLC Scan',
            onPressed: () => setState(() => isRunning = !isRunning),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isRunning ? Colors.green.withOpacity(0.2) : Colors.amber.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isRunning ? Colors.green : Colors.amber),
            ),
            child: Text(
              isRunning ? 'PLC RUNNING' : 'PLC STOPPED',
              style: TextStyle(color: isRunning ? Colors.green : Colors.amber, fontWeight: FontWeight.bold, fontSize: 11),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Banner
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.shade900.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade700),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'SIMULATOR ONLY: Not safety certified. Do not use for real machine control.',
                      style: TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Performance Cards
            Row(
              children: [
                Expanded(child: _buildMetricCard('Scan Time', '${lastScanTimeMs.toStringAsFixed(1)} ms', Icons.timer_outlined, Colors.cyan)),
                const SizedBox(width: 12),
                Expanded(child: _buildMetricCard('Scan Period', '${_currentProject.scanPeriodMs} ms', Icons.speed, Colors.teal)),
                const SizedBox(width: 12),
                Expanded(child: _buildMetricCard('Scan Count', '$scanCount', Icons.refresh, Colors.indigoAccent)),
              ],
            ),
            const SizedBox(height: 24),

            // Motor Control HMI Panel
            const Text('Motor Control HMI Panel', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 12),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        // Input Controls
                        Column(
                          children: [
                            ElevatedButton(
                              onPressed: () {
                                _setTagBool('Start_PB', true);
                                _executeScanCycle();
                                Future.delayed(const Duration(milliseconds: 300), () {
                                  if (mounted) {
                                    _setTagBool('Start_PB', false);
                                    _executeScanCycle();
                                  }
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                              ),
                              child: const Text('START (NO)'),
                            ),
                            const SizedBox(height: 8),
                            const Text('Start_PB', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),

                        Column(
                          children: [
                            ElevatedButton(
                              onPressed: () {
                                _setTagBool('Stop_PB', true);
                                _executeScanCycle();
                                Future.delayed(const Duration(milliseconds: 300), () {
                                  if (mounted) {
                                    _setTagBool('Stop_PB', false);
                                    _executeScanCycle();
                                  }
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                              ),
                              child: const Text('STOP (NC)'),
                            ),
                            const SizedBox(height: 8),
                            const Text('Stop_PB', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),

                        // Motor Output Indicator
                        Column(
                          children: [
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: motorRun ? Colors.greenAccent : Colors.grey.shade800,
                                boxShadow: motorRun ? [BoxShadow(color: Colors.greenAccent.withOpacity(0.6), blurRadius: 16)] : [],
                                border: Border.all(color: motorRun ? Colors.green : Colors.grey, width: 2),
                              ),
                              child: Icon(Icons.power_settings_new, color: motorRun ? Colors.black : Colors.grey, size: 32),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              motorRun ? 'RUNNING' : 'STOPPED',
                              style: TextStyle(fontWeight: FontWeight.bold, color: motorRun ? Colors.greenAccent : Colors.grey),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Divider(height: 32),

                    // Permissives Switched Controls
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Row(
                          children: [
                            Switch(
                              value: eStopOk,
                              activeColor: Colors.green,
                              onChanged: (val) {
                                _setTagBool('EStop_OK', val);
                                _executeScanCycle();
                              },
                            ),
                            const Text('E-Stop OK'),
                          ],
                        ),
                        Row(
                          children: [
                            Switch(
                              value: overloadOk,
                              activeColor: Colors.green,
                              onChanged: (val) {
                                _setTagBool('Overload_OK', val);
                                _executeScanCycle();
                              },
                            ),
                            const Text('Overload OK'),
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
      ),
    );
  }

  Widget _buildTagInspectorView() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tag Inspector & Manual Forcing Matrix'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _currentProject.tags.length,
        itemBuilder: (context, index) {
          final tag = _currentProject.tags[index];
          return Card(
            child: ListTile(
              title: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${tag.path} [${tag.dataType}] — ${tag.description}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Value Display
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: tag.value == true ? Colors.green.withOpacity(0.2) : Colors.black45,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: tag.value == true ? Colors.green : Colors.grey),
                    ),
                    child: Text(tag.value.toString(), style: TextStyle(fontWeight: FontWeight.bold, color: tag.value == true ? Colors.greenAccent : Colors.white70)),
                  ),
                  const SizedBox(width: 8),

                  // Force Toggle Button
                  IconButton(
                    icon: Icon(tag.isForced ? Icons.lock : Icons.lock_open, color: tag.isForced ? Colors.amber : Colors.grey),
                    tooltip: tag.isForced ? 'Unforce Tag' : 'Force Value',
                    onPressed: () {
                      setState(() {
                        tag.isForced = !tag.isForced;
                        if (tag.isForced) {
                          tag.forcedValue = !(tag.value == true);
                        }
                      });
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMetricCard(String label, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
