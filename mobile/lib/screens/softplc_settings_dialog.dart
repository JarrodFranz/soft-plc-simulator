import 'package:flutter/material.dart';

/// Global "SoftPLC Settings" dialog. Currently exposes a single knob — the
/// UI refresh rate (Hz) that re-tunes the shell's repaint throttle — but is
/// its own file/widget so future global (non-per-project) settings have an
/// obvious home.
///
/// Purely presentational: it owns the text field and validates the input,
/// but has no knowledge of `NotifyThrottle`/`SharedPreferences`. `Save` pops
/// the dialog with the parsed, still-unclamped int; the caller (the shell)
/// is responsible for clamping (via `clampRefreshHz`) and applying it.
class SoftPlcSettingsDialog extends StatefulWidget {
  /// The refresh rate (Hz) to prefill the field with — the shell's current
  /// `_refreshHz` at the time the dialog was opened.
  final int initialRefreshHz;

  const SoftPlcSettingsDialog({super.key, required this.initialRefreshHz});

  @override
  State<SoftPlcSettingsDialog> createState() => _SoftPlcSettingsDialogState();
}

class _SoftPlcSettingsDialogState extends State<SoftPlcSettingsDialog> {
  late final TextEditingController _hzController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _hzController = TextEditingController(text: '${widget.initialRefreshHz}');
  }

  @override
  void dispose() {
    _hzController.dispose();
    super.dispose();
  }

  void _save() {
    final parsed = int.tryParse(_hzController.text.trim());
    if (parsed == null) {
      setState(() => _errorText = 'Enter a whole number 1-30');
      return;
    }
    Navigator.pop(context, parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('SoftPLC Settings'),
      // Single-column, vertical layout — no Row of fields, so it never
      // overflows horizontally at narrow phone widths (320/360).
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _hzController,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'UI refresh rate (Hz)',
                helperText: 'Range: 1-30 Hz (default 10 Hz)',
                errorText: _errorText,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
