import 'package:flutter/material.dart';

import '../models/pid_autotune.dart';
import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import '../ui/responsive.dart';

/// One selectable PID loop: the FBD block plus the program that owns it.
class _PidLoopOption {
  final PlcProgram program;
  final FbdBlock block;
  const _PidLoopOption({required this.program, required this.block});

  String get key => '${program.name}::${block.id}';
  String get label {
    final title = block.title.trim().isNotEmpty ? block.title.trim() : block.id;
    return '$title (${block.id}) — ${program.name}';
  }
}

/// PID Auto-Tune panel: pick a PID loop, run a relay-feedback experiment on a
/// deep copy of the simulated process, view the resulting PV/CV limit cycle and
/// the classic tuning-rule suggestions, then apply a chosen rule's gains back
/// onto the loop's gain-source blocks.
class PidAutoTuneScreen extends StatefulWidget {
  final PlcProject currentProject;
  final VoidCallback onProjectUpdated;

  const PidAutoTuneScreen({
    super.key,
    required this.currentProject,
    required this.onProjectUpdated,
  });

  @override
  State<PidAutoTuneScreen> createState() => _PidAutoTuneScreenState();
}

class _PidAutoTuneScreenState extends State<PidAutoTuneScreen> {
  final _pvCtrl = TextEditingController();
  final _cvCtrl = TextEditingController();
  final _spCtrl = TextEditingController();
  final _relayHighCtrl = TextEditingController(text: '100');
  final _relayLowCtrl = TextEditingController(text: '0');
  final _hystCtrl = TextEditingController(text: '0.5');
  final _dtMsCtrl = TextEditingController();
  final _maxScansCtrl = TextEditingController(text: '4000');

  String? _selectedKey;
  PidLoopBinding? _binding;
  RelayTuneResult? _result;

  @override
  void initState() {
    super.initState();
    final opts = _loopOptions();
    if (opts.isNotEmpty) {
      _selectLoop(opts.first, notify: false);
    }
    if (_dtMsCtrl.text.isEmpty) {
      _dtMsCtrl.text = widget.currentProject.scanPeriodMs.toString();
    }
  }

  @override
  void dispose() {
    _pvCtrl.dispose();
    _cvCtrl.dispose();
    _spCtrl.dispose();
    _relayHighCtrl.dispose();
    _relayLowCtrl.dispose();
    _hystCtrl.dispose();
    _dtMsCtrl.dispose();
    _maxScansCtrl.dispose();
    super.dispose();
  }

  List<_PidLoopOption> _loopOptions() {
    final out = <_PidLoopOption>[];
    for (final prog in widget.currentProject.programs) {
      if (prog.language != 'FunctionBlockDiagram') {
        continue;
      }
      for (final block in prog.fbdBlocks) {
        if (block.type == 'PID') {
          out.add(_PidLoopOption(program: prog, block: block));
        }
      }
    }
    return out;
  }

  _PidLoopOption? get _selectedOption {
    final key = _selectedKey;
    if (key == null) {
      return null;
    }
    for (final o in _loopOptions()) {
      if (o.key == key) {
        return o;
      }
    }
    return null;
  }

  void _selectLoop(_PidLoopOption opt, {bool notify = true}) {
    final binding =
        resolvePidLoop(opt.program, widget.currentProject, opt.block.id);
    void apply() {
      _selectedKey = opt.key;
      _binding = binding;
      _result = null;
      _pvCtrl.text = binding.pvPath ?? '';
      _cvCtrl.text = binding.cvPath ?? '';
      if (binding.setpoint != null) {
        _spCtrl.text = _fmt(binding.setpoint!);
      }
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  void _run() {
    final params = RelayTuneParams(
      relayHigh: double.tryParse(_relayHighCtrl.text) ?? 100,
      relayLow: double.tryParse(_relayLowCtrl.text) ?? 0,
      hysteresis: double.tryParse(_hystCtrl.text) ?? 0.5,
      setpoint: double.tryParse(_spCtrl.text) ?? 0,
      dtMs: int.tryParse(_dtMsCtrl.text) ?? widget.currentProject.scanPeriodMs,
      maxScans: int.tryParse(_maxScansCtrl.text) ?? 4000,
      settleCycles: 3,
    );
    final result = relayAutoTune(
      widget.currentProject,
      pvPath: _pvCtrl.text.trim(),
      cvPath: _cvCtrl.text.trim(),
      params: params,
    );
    setState(() => _result = result);
  }

  void _apply(TuningSuggestion s) {
    final binding = _binding;
    final opt = _selectedOption;
    if (binding == null || opt == null) {
      return;
    }
    final applied = <String>[];
    final skipped = <String>[];

    void writeGain(String label, String? sourceBlockId, double value) {
      if (sourceBlockId == null) {
        skipped.add(label);
        return;
      }
      final block = _blockById(opt.program, sourceBlockId);
      if (block == null) {
        skipped.add(label);
        return;
      }
      if (block.type == 'CONST') {
        block.tagBinding = _fmt(value);
        applied.add('$label=${_fmt(value)}');
      } else if (block.type == 'TAG_INPUT') {
        writePath(widget.currentProject, block.tagBinding, value);
        applied.add('$label=${_fmt(value)}');
      } else {
        skipped.add(label);
      }
    }

    writeGain('Kp', binding.kpSourceBlockId, s.kp);
    writeGain('Ki', binding.kiSourceBlockId, s.ki);
    // PI rules leave Kd at 0 and typically have no wired Kd source; only write
    // Kd for PID-form rules so a PI apply never zeroes an existing Kd gain.
    if (s.form == 'PID') {
      writeGain('Kd', binding.kdSourceBlockId, s.kd);
    }

    widget.onProjectUpdated();
    setState(() {});

    final parts = <String>[];
    if (applied.isNotEmpty) {
      parts.add('Applied ${applied.join(', ')}');
    }
    if (skipped.isNotEmpty) {
      parts.add('skipped ${skipped.join(', ')} (no writable source)');
    }
    final msg = parts.isEmpty ? 'No gains applied' : parts.join(' · ');
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text('${s.name} ${s.form}: $msg'),
        backgroundColor: const Color(0xFF1E293B),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  FbdBlock? _blockById(PlcProgram prog, String id) {
    for (final b in prog.fbdBlocks) {
      if (b.id == id) {
        return b;
      }
    }
    return null;
  }

  /// Compact numeric string: integers lose the decimal, everything else keeps
  /// up to 4 dp with trailing zeros trimmed.
  static String _fmt(double v) {
    if (v.isNaN || v.isInfinite) {
      return '0';
    }
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    var s = v.toStringAsFixed(4);
    s = s.replaceAll(RegExp(r'0+$'), '');
    s = s.replaceAll(RegExp(r'\.$'), '');
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final options = _loopOptions();
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('PID Auto-Tune — Relay Feedback'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: options.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No PID blocks found. Add a PID function block to a '
                  'Function Block Diagram program to auto-tune it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _loopSelector(options),
                  const SizedBox(height: 12),
                  _paramsCard(context),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('Run Auto-Tune'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.tealAccent.shade700,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                      onPressed: _run,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_result != null) _resultSection(_result!),
                ],
              ),
            ),
    );
  }

  Widget _loopSelector(List<_PidLoopOption> options) {
    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('PID Loop',
                style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _selectedKey,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: options
                  .map((o) => DropdownMenuItem(
                        value: o.key,
                        child: Text(o.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                      ))
                  .toList(),
              onChanged: (key) {
                if (key == null) {
                  return;
                }
                for (final o in options) {
                  if (o.key == key) {
                    _selectLoop(o);
                    break;
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _paramsCard(BuildContext context) {
    final compact = context.isCompact;
    final pv = _labeledField('Process value (PV) tag', _pvCtrl,
        key: const Key('pidtune-pv-field'));
    final cv = _labeledField('Control value (CV) tag', _cvCtrl,
        key: const Key('pidtune-cv-field'));
    final sp = _labeledField('Setpoint', _spCtrl, numeric: true);
    final rh = _labeledField('Relay high', _relayHighCtrl, numeric: true);
    final rl = _labeledField('Relay low', _relayLowCtrl, numeric: true);
    final hy = _labeledField('Hysteresis', _hystCtrl, numeric: true);
    final dt = _labeledField('Step dt (ms)', _dtMsCtrl, numeric: true);
    final ms = _labeledField('Max duration (scans)', _maxScansCtrl, numeric: true);

    Widget pair(Widget a, Widget b) {
      if (compact) {
        return Column(children: [a, const SizedBox(height: 8), b]);
      }
      return Row(children: [
        Expanded(child: a),
        const SizedBox(width: 12),
        Expanded(child: b),
      ]);
    }

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Relay Experiment',
                style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            pair(pv, cv),
            const SizedBox(height: 8),
            pair(sp, hy),
            const SizedBox(height: 8),
            pair(rh, rl),
            const SizedBox(height: 8),
            pair(dt, ms),
          ],
        ),
      ),
    );
  }

  Widget _labeledField(String label, TextEditingController ctrl,
      {Key? key, bool numeric = false}) {
    return TextField(
      key: key,
      controller: ctrl,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _resultSection(RelayTuneResult r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: const Color(0xFF1E293B),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Limit Cycle (PV / CV vs time)',
                    style: TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 180,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _TracePainter(r.trace),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (r.converged) _kuPuCard(r) else _warningCard(r),
        if (r.converged) ...[
          const SizedBox(height: 12),
          _suggestionsCard(tuningRules(r.ku, r.pu)),
        ],
      ],
    );
  }

  Widget _kuPuCard(RelayTuneResult r) {
    return Card(
      color: const Color(0xFF14261F),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 18,
                runSpacing: 4,
                children: [
                  _metric('Ku', r.ku.toStringAsFixed(3)),
                  _metric('Pu', '${(r.pu / 1000).toStringAsFixed(3)} s'),
                  _metric('Amplitude', r.amplitude.toStringAsFixed(3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Text.rich(
      TextSpan(
        style: const TextStyle(fontSize: 13),
        children: [
          TextSpan(
              text: '$label = ',
              style: const TextStyle(color: Colors.grey)),
          TextSpan(
              text: value,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _warningCard(RelayTuneResult r) {
    return Card(
      color: const Color(0xFF2A210F),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber, color: Colors.amberAccent, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                r.warning ?? 'Auto-tune did not converge.',
                style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionsCard(List<TuningSuggestion> rules) {
    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Suggested Gains',
                style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 34,
                dataRowMinHeight: 40,
                dataRowMaxHeight: 48,
                columnSpacing: 20,
                columns: const [
                  DataColumn(label: Text('Rule', style: _kHead)),
                  DataColumn(label: Text('Form', style: _kHead)),
                  DataColumn(label: Text('Kp', style: _kHead), numeric: true),
                  DataColumn(label: Text('Ki', style: _kHead), numeric: true),
                  DataColumn(label: Text('Kd', style: _kHead), numeric: true),
                  DataColumn(label: Text('', style: _kHead)),
                ],
                rows: rules
                    .map((s) => DataRow(cells: [
                          DataCell(Text(s.name, style: _kCell)),
                          DataCell(Text(s.form, style: _kCell)),
                          DataCell(Text(_fmt(s.kp), style: _kCell)),
                          DataCell(Text(_fmt(s.ki), style: _kCell)),
                          DataCell(Text(_fmt(s.kd), style: _kCell)),
                          DataCell(ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.cyan.withValues(alpha: 0.2),
                              foregroundColor: Colors.cyanAccent,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            onPressed: () => _apply(s),
                            child: const Text('Apply'),
                          )),
                        ]))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const TextStyle _kHead = TextStyle(
    color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold);
const TextStyle _kCell = TextStyle(color: Colors.white, fontSize: 12);

/// Hand-painted PV (cyan) + CV (amber) polylines over a shared time/value
/// scale — a compact static view of the recorded relay experiment trace.
class _TracePainter extends CustomPainter {
  final List<TunePoint> trace;
  const _TracePainter(this.trace);

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 34.0;
    const rightPad = 8.0;
    const topPad = 8.0;
    const bottomPad = 16.0;
    const plotLeft = leftPad;
    final plotRight = size.width - rightPad;
    const plotTop = topPad;
    final plotBottom = size.height - bottomPad;
    final plotW = (plotRight - plotLeft).clamp(1.0, double.infinity);
    final plotH = (plotBottom - plotTop).clamp(1.0, double.infinity);

    final frame = Paint()
      ..color = Colors.grey.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(
        Rect.fromLTRB(plotLeft, plotTop, plotRight, plotBottom), frame);

    if (trace.isEmpty) {
      return;
    }

    var minV = double.infinity;
    var maxV = -double.infinity;
    final tMin = trace.first.tMs;
    final tMax = trace.last.tMs;
    for (final p in trace) {
      minV = p.pv < minV ? p.pv : minV;
      minV = p.cv < minV ? p.cv : minV;
      maxV = p.pv > maxV ? p.pv : maxV;
      maxV = p.cv > maxV ? p.cv : maxV;
    }
    if ((maxV - minV).abs() < 1e-9) {
      minV -= 1;
      maxV += 1;
    }
    final span = maxV - minV;
    final lo = minV - span * 0.06;
    final hi = maxV + span * 0.06;
    final tSpan = (tMax - tMin).abs() < 1e-9 ? 1.0 : (tMax - tMin);

    double xOf(double t) => plotLeft + plotW * ((t - tMin) / tSpan);
    double yOf(double v) => plotTop + plotH * (1 - (v - lo) / (hi - lo));

    // Value-axis labels.
    void tp(double v, double y) {
      final t = TextPainter(
        text: TextSpan(
            text: v.toStringAsFixed(0),
            style: TextStyle(color: Colors.grey.shade400, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(canvas, Offset(2, y - t.height / 2));
    }

    tp(hi, plotTop);
    tp((hi + lo) / 2, plotTop + plotH / 2);
    tp(lo, plotBottom);

    void drawSeries(double Function(TunePoint) sel, Color color) {
      final path = Path();
      for (var i = 0; i < trace.length; i++) {
        final x = xOf(trace[i].tMs);
        final y = yOf(sel(trace[i]));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }

    drawSeries((p) => p.cv, Colors.amberAccent);
    drawSeries((p) => p.pv, Colors.cyanAccent);

    // Legend.
    void legend(double x, String label, Color color) {
      canvas.drawRect(
          Rect.fromLTWH(x, plotTop + 1, 8, 8), Paint()..color = color);
      final t = TextPainter(
        text: TextSpan(text: label, style: TextStyle(color: color, fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(canvas, Offset(x + 11, plotTop));
    }

    legend(plotLeft + 6, 'PV', Colors.cyanAccent);
    legend(plotLeft + 44, 'CV', Colors.amberAccent);
  }

  @override
  bool shouldRepaint(covariant _TracePainter old) => old.trace != trace;
}
