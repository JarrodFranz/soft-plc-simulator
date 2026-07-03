import 'package:flutter/material.dart';

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
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Simulated controller state
  bool isRunning = true;
  int scanCount = 1420;
  double lastScanTimeMs = 1.8;
  int scanPeriodMs = 100;

  // I/O Tag state
  bool startPb = false;
  bool stopPb = false;
  bool eStopOk = true;
  bool overloadOk = true;
  bool motorLatch = false;
  bool motorRun = false;

  void _executeScan() {
    setState(() {
      scanCount++;
      // Motor start/stop logic execution simulation
      bool startPressed = startPb;
      bool stopPressed = stopPb;

      if ((startPressed || motorLatch) && !stopPressed && eStopOk && overloadOk) {
        motorLatch = true;
      } else {
        motorLatch = false;
      }
      motorRun = motorLatch && eStopOk && overloadOk;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Mobile Soft PLC Simulator',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
        ),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: isRunning
                  ? Colors.green.withOpacity(0.2)
                  : Colors.amber.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isRunning ? Colors.green : Colors.amber,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: isRunning ? Colors.green : Colors.amber,
                ),
                const SizedBox(width: 6),
                Text(
                  isRunning ? 'RUNNING' : 'STOPPED',
                  style: TextStyle(
                    color: isRunning ? Colors.green : Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Warning Banner
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
                Expanded(
                  child: _buildMetricCard('Scan Time', '${lastScanTimeMs.toStringAsFixed(1)} ms', Icons.timer_outlined, Colors.cyan),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMetricCard('Scan Period', '$scanPeriodMs ms', Icons.speed, Colors.teal),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMetricCard('Scan Count', '$scanCount', Icons.refresh, Colors.indigoAccent),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Motor Control HMI Panel
            const Text(
              'Motor Control Simulation (Basic Motor Start/Stop)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
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
                                setState(() => startPb = true);
                                _executeScan();
                                Future.delayed(const Duration(milliseconds: 300), () {
                                  if (mounted) {
                                    setState(() => startPb = false);
                                    _executeScan();
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
                                setState(() => stopPb = true);
                                _executeScan();
                                Future.delayed(const Duration(milliseconds: 300), () {
                                  if (mounted) {
                                    setState(() => stopPb = false);
                                    _executeScan();
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
                                boxShadow: motorRun
                                    ? [BoxShadow(color: Colors.greenAccent.withOpacity(0.6), blurRadius: 16)]
                                    : [],
                                border: Border.all(color: motorRun ? Colors.green : Colors.grey, width: 2),
                              ),
                              child: Icon(
                                Icons.power_settings_new,
                                color: motorRun ? Colors.black : Colors.grey,
                                size: 32,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              motorRun ? 'RUNNING' : 'STOPPED',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: motorRun ? Colors.greenAccent : Colors.grey,
                              ),
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
                                setState(() => eStopOk = val);
                                _executeScan();
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
                                setState(() => overloadOk = val);
                                _executeScan();
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
            const SizedBox(height: 24),

            // Tag Table
            const Text(
              'Tag Database Inspector',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 12),

            Card(
              child: ListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildTagRow('Start_PB', 'Inputs/Start_PB', 'BOOL', startPb.toString(), 'Good'),
                  _buildTagRow('Stop_PB', 'Inputs/Stop_PB', 'BOOL', stopPb.toString(), 'Good'),
                  _buildTagRow('EStop_OK', 'Inputs/EStop_OK', 'BOOL', eStopOk.toString(), 'Good'),
                  _buildTagRow('Overload_OK', 'Inputs/Overload_OK', 'BOOL', overloadOk.toString(), 'Good'),
                  _buildTagRow('Motor_Latch', 'Internal/Motor_Latch', 'BOOL', motorLatch.toString(), 'Good'),
                  _buildTagRow('Motor_Run', 'Outputs/Motor_Run', 'BOOL', motorRun.toString(), 'Good'),
                ],
              ),
            ),
          ],
        ),
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

  Widget _buildTagRow(String name, String path, String type, String value, String quality) {
    return ListTile(
      dense: true,
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(path, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.blue.withAlpha(50),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(type, style: TextStyle(fontSize: 11, color: Colors.blue.shade200)),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: value == 'true' ? Colors.greenAccent : Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}
