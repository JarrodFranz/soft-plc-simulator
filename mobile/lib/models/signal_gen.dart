/// One always-on simulated signal driving a single tag. The engine
/// (`signal_engine.dart`) writes [targetPath] every scan; the tag is grouped
/// in the UI by its `PlcTag.folder`. Pure data.
class SignalGen {
  String id;
  String targetPath;
  String type; // ramp | sine | square | triangle | random | counter | toggle
  double minValue;
  double maxValue;
  int periodMs;
  double phase; // 0..1 fraction of the period
  bool enabled;

  SignalGen({
    required this.id,
    required this.targetPath,
    required this.type,
    required this.minValue,
    required this.maxValue,
    required this.periodMs,
    this.phase = 0,
    this.enabled = true,
  });

  factory SignalGen.fromJson(Map<String, dynamic> j) => SignalGen(
        id: j['id'] ?? '',
        targetPath: j['target_path'] ?? '',
        type: j['type'] ?? 'ramp',
        minValue: (j['min_value'] as num?)?.toDouble() ?? 0,
        maxValue: (j['max_value'] as num?)?.toDouble() ?? 0,
        periodMs: (j['period_ms'] as num?)?.toInt() ?? 1000,
        phase: (j['phase'] as num?)?.toDouble() ?? 0,
        enabled: j['enabled'] ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'target_path': targetPath,
        'type': type,
        'min_value': minValue,
        'max_value': maxValue,
        'period_ms': periodMs,
        'phase': phase,
        'enabled': enabled,
      };
}
