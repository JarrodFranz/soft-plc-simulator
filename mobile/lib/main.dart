import 'package:flutter/material.dart';
import 'screens/workspace_shell.dart';

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
      home: const WorkspaceShell(),
    );
  }
}
