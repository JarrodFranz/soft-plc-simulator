import 'package:flutter/material.dart';

import '../models/interaction_analysis.dart';
import '../models/project_model.dart';
import '../ui/responsive.dart';

/// Interaction Analysis panel: pick the two MVs and two PVs of a 2x2 process,
/// run open-loop step tests on deep copies of the simulated plant to identify
/// the steady-state gain matrix, then view the Relative Gain Array (RGA), the
/// recommended loop pairing and the suggested static-decoupler gains.
///
/// Mirrors [PidAutoTuneScreen]'s structure: selectors → params → Run →
/// results, all rendered synchronously against a fresh deep copy so the source
/// project is never mutated.
class InteractionAnalysisScreen extends StatefulWidget {
  final PlcProject currentProject;
  final VoidCallback onProjectUpdated;

  const InteractionAnalysisScreen({
    super.key,
    required this.currentProject,
    required this.onProjectUpdated,
  });

  @override
  State<InteractionAnalysisScreen> createState() =>
      _InteractionAnalysisScreenState();
}

class _InteractionAnalysisScreenState extends State<InteractionAnalysisScreen> {
  final _mv1Ctrl = TextEditingController();
  final _mv2Ctrl = TextEditingController();
  final _pv1Ctrl = TextEditingController();
  final _pv2Ctrl = TextEditingController();
  final _baseMvCtrl = TextEditingController(text: '30');
  final _stepDeltaCtrl = TextEditingController(text: '20');
  final _maxScansCtrl = TextEditingController(text: '20000');

  GainMatrix? _gain;
  RgaResult? _rga;

  @override
  void initState() {
    super.initState();
    final tags = widget.currentProject.tags;
    _mv1Ctrl.text = _defaultTag('Heater_A', tags, 0);
    _mv2Ctrl.text = _defaultTag('Heater_B', tags, 1);
    _pv1Ctrl.text = _defaultTag('Temp_A', tags, 2);
    _pv2Ctrl.text = _defaultTag('Temp_B', tags, 3);
  }

  /// Uses [preferred] when a tag of that name exists in [tags]; otherwise the
  /// [fallbackIndex]-th tag's name (empty when there aren't that many tags).
  String _defaultTag(String preferred, List<PlcTag> tags, int fallbackIndex) {
    for (final t in tags) {
      if (t.name == preferred) {
        return preferred;
      }
    }
    if (fallbackIndex < tags.length) {
      return tags[fallbackIndex].name;
    }
    return tags.isNotEmpty ? tags.first.name : '';
  }

  @override
  void dispose() {
    _mv1Ctrl.dispose();
    _mv2Ctrl.dispose();
    _pv1Ctrl.dispose();
    _pv2Ctrl.dispose();
    _baseMvCtrl.dispose();
    _stepDeltaCtrl.dispose();
    _maxScansCtrl.dispose();
    super.dispose();
  }

  void _run() {
    final params = StepTestParams(
      baseMv: double.tryParse(_baseMvCtrl.text) ?? 30,
      stepDelta: double.tryParse(_stepDeltaCtrl.text) ?? 20,
      dtMs: widget.currentProject.scanPeriodMs,
      maxScans: int.tryParse(_maxScansCtrl.text) ?? 20000,
      settleEps: 1e-3,
      settleWindow: 10,
    );
    final gain = identifyGainMatrix(
      widget.currentProject,
      mv1Path: _mv1Ctrl.text.trim(),
      mv2Path: _mv2Ctrl.text.trim(),
      pv1Path: _pv1Ctrl.text.trim(),
      pv2Path: _pv2Ctrl.text.trim(),
      params: params,
    );
    final rga = gain.converged ? computeRga(gain) : null;
    setState(() {
      _gain = gain;
      _rga = rga;
    });
  }

  /// Compact numeric string: up to 3 dp with trailing zeros trimmed; NaN /
  /// infinities render as an em dash.
  static String _fmt(double v) {
    if (v.isNaN || v.isInfinite) {
      return '—';
    }
    var s = v.toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '');
      s = s.replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Interaction Analysis — Gain Matrix & RGA'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _tagsCard(context),
            const SizedBox(height: 12),
            _paramsCard(context),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton.icon(
                key: const Key('interaction-run-button'),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Run Analysis'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.tealAccent.shade700,
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onPressed: _run,
              ),
            ),
            const SizedBox(height: 12),
            if (_gain != null) _resultSection(_gain!, _rga),
          ],
        ),
      ),
    );
  }

  Widget _tagsCard(BuildContext context) {
    final compact = context.isCompact;
    final mv1 = _labeledField('Manipulated var 1 (MV1) tag', _mv1Ctrl,
        key: const Key('interaction-mv1-field'));
    final mv2 = _labeledField('Manipulated var 2 (MV2) tag', _mv2Ctrl,
        key: const Key('interaction-mv2-field'));
    final pv1 = _labeledField('Process var 1 (PV1) tag', _pv1Ctrl,
        key: const Key('interaction-pv1-field'));
    final pv2 = _labeledField('Process var 2 (PV2) tag', _pv2Ctrl,
        key: const Key('interaction-pv2-field'));

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Loop Variables',
                style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _pair(compact, mv1, mv2),
            const SizedBox(height: 8),
            _pair(compact, pv1, pv2),
          ],
        ),
      ),
    );
  }

  Widget _paramsCard(BuildContext context) {
    final compact = context.isCompact;
    final base = _labeledField('Base MV', _baseMvCtrl, numeric: true);
    final step = _labeledField('Step delta', _stepDeltaCtrl, numeric: true);
    final ms =
        _labeledField('Max duration (scans)', _maxScansCtrl, numeric: true);

    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Step Test',
                style: TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _pair(compact, base, step),
            const SizedBox(height: 8),
            _pair(compact, ms, const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }

  Widget _pair(bool compact, Widget a, Widget b) {
    if (compact) {
      return Column(children: [a, const SizedBox(height: 8), b]);
    }
    return Row(children: [
      Expanded(child: a),
      const SizedBox(width: 12),
      Expanded(child: b),
    ]);
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

  Widget _resultSection(GainMatrix g, RgaResult? rga) {
    final warning = !g.converged ? g.warning : rga?.warning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (warning != null) ...[
          _warningCard(warning),
          const SizedBox(height: 12),
        ],
        // A non-converged gain matrix is not trustworthy — show only the
        // warning above (mirrors the engine's contract) and stop.
        if (g.converged) ...[
          _gainCard(g),
          const SizedBox(height: 12),
          if (rga != null) ...[
            _rgaCard(rga),
            const SizedBox(height: 12),
            _pairingCard(rga),
            const SizedBox(height: 12),
            _decouplerCard(g),
          ],
        ],
      ],
    );
  }

  Widget _warningCard(String text) {
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
                text,
                style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({required String title, required Widget child}) {
    return Card(
      color: const Color(0xFF1E293B),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _gainCard(GainMatrix g) {
    return _sectionCard(
      title: 'Gain Matrix K (ΔPV / ΔMV)',
      child: Align(
        alignment: Alignment.centerLeft,
        child: _matrix2x2(
          rowHeaders: const ['PV1', 'PV2'],
          colHeaders: const ['MV1', 'MV2'],
          cells: [
            ['K11', g.k11],
            ['K12', g.k12],
            ['K21', g.k21],
            ['K22', g.k22],
          ],
          accent: Colors.cyanAccent,
        ),
      ),
    );
  }

  Widget _rgaCard(RgaResult rga) {
    final l = rga.lambda11;
    return _sectionCard(
      title: 'Relative Gain Array (RGA)',
      child: Align(
        alignment: Alignment.centerLeft,
        child: _matrix2x2(
          rowHeaders: const ['PV1', 'PV2'],
          colHeaders: const ['MV1', 'MV2'],
          cells: [
            ['λ11', l],
            ['λ12', 1 - l],
            ['λ21', 1 - l],
            ['λ22', l],
          ],
          accent: Colors.tealAccent,
        ),
      ),
    );
  }

  Widget _pairingCard(RgaResult rga) {
    return _sectionCard(
      title: 'Recommended Pairing',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.link, color: Colors.greenAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              rga.pairing,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _decouplerCard(GainMatrix g) {
    final d12 = g.k11.abs() < 1e-12 ? double.nan : g.k12 / g.k11;
    final d21 = g.k22.abs() < 1e-12 ? double.nan : g.k21 / g.k22;
    return _sectionCard(
      title: 'Suggested Static Decoupler Gains',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metricRow('d12 = K12 / K11', _fmt(d12)),
          const SizedBox(height: 6),
          _metricRow('d21 = K21 / K22', _fmt(d21)),
        ],
      ),
    );
  }

  Widget _metricRow(String label, String value) {
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

  /// A fixed-size 2x2 grid with MV column headers and PV row headers. [cells]
  /// is four `[label, value]` pairs in row-major order (11, 12, 21, 22).
  Widget _matrix2x2({
    required List<String> rowHeaders,
    required List<String> colHeaders,
    required List<List<Object>> cells,
    required Color accent,
  }) {
    const cellW = 96.0;
    const cellH = 52.0;
    const headW = 40.0;

    Widget headCell(String text, double w) => SizedBox(
          width: w,
          height: 24,
          child: Center(
            child: Text(text,
                style: TextStyle(
                    color: accent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
        );

    Widget valueCell(String label, double value) => Container(
          width: cellW,
          height: cellH,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.08),
            border: Border.all(color: accent.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.grey, fontSize: 10)),
              const SizedBox(height: 2),
              Text(_fmt(value),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Column-header row.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: headW),
            headCell(colHeaders[0], cellW + 4),
            headCell(colHeaders[1], cellW + 4),
          ],
        ),
        // Data rows, each led by a PV row header.
        for (var r = 0; r < 2; r++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: headW,
                height: cellH,
                child: Center(
                  child: Text(rowHeaders[r],
                      style: TextStyle(
                          color: accent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              valueCell(
                cells[r * 2][0] as String,
                (cells[r * 2][1] as num).toDouble(),
              ),
              valueCell(
                cells[r * 2 + 1][0] as String,
                (cells[r * 2 + 1][1] as num).toDouble(),
              ),
            ],
          ),
      ],
    );
  }
}
