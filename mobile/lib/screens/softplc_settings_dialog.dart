import 'package:flutter/material.dart';

/// The values the [SoftPlcSettingsDialog] returns on Save. The dialog is purely
/// presentational — the caller (the shell) clamps/persists/applies each field.
class SoftPlcSettingsResult {
  /// The (still-unclamped) UI refresh rate in Hz entered in the field.
  final int refreshHz;

  /// Whether HMI haptic feedback (pushbuttons + toggles) is enabled.
  final bool hapticsEnabled;

  const SoftPlcSettingsResult({
    required this.refreshHz,
    required this.hapticsEnabled,
  });
}

/// Global "SoftPLC Settings" dialog. Exposes device-level (non-per-project)
/// knobs: the UI refresh rate (Hz) that re-tunes the shell's repaint throttle,
/// and a Haptic feedback toggle for HMI pushbuttons/toggles. Its own
/// file/widget so future global settings have an obvious home.
///
/// Purely presentational: it owns the field/switch and validates the input,
/// but has no knowledge of `NotifyThrottle`/`SharedPreferences`. `Save` pops
/// the dialog with a [SoftPlcSettingsResult] (refresh rate still unclamped);
/// the caller (the shell) clamps, applies, and persists.
class SoftPlcSettingsDialog extends StatefulWidget {
  /// The refresh rate (Hz) to prefill the field with — the shell's current
  /// `_refreshHz` at the time the dialog was opened.
  final int initialRefreshHz;

  /// Whether haptics are currently enabled — prefills the toggle.
  final bool initialHapticsEnabled;

  const SoftPlcSettingsDialog({
    super.key,
    required this.initialRefreshHz,
    required this.initialHapticsEnabled,
  });

  @override
  State<SoftPlcSettingsDialog> createState() => _SoftPlcSettingsDialogState();
}

class _SoftPlcSettingsDialogState extends State<SoftPlcSettingsDialog> {
  late final TextEditingController _hzController;
  late bool _hapticsEnabled;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _hzController = TextEditingController(text: '${widget.initialRefreshHz}');
    _hapticsEnabled = widget.initialHapticsEnabled;
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
    Navigator.pop(
      context,
      SoftPlcSettingsResult(refreshHz: parsed, hapticsEnabled: _hapticsEnabled),
    );
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
              // No autofocus: on a short (landscape-phone) viewport the
              // auto-opened keyboard shrinks the dialog and pushes the Haptic
              // feedback toggle below the fold. The user taps the field to edit.
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'UI refresh rate (Hz)',
                helperText: 'Range: 1-30 Hz (default 10 Hz)',
                errorText: _errorText,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Haptic feedback'),
              subtitle: const Text('Vibrate on HMI pushbutton/toggle presses (mobile)'),
              value: _hapticsEnabled,
              onChanged: (v) => setState(() => _hapticsEnabled = v),
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
