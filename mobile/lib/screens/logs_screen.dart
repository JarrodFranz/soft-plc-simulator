// The in-app Logs / Diagnostics window (Task 5 of the log feature). Replaces
// the Task-4 placeholder in `workspace_shell.dart`'s `_buildCenterWorkspace()`
// LOGS branch.
//
// This is a thin view over `AppLogger` (`mobile/lib/services/app_logger.dart`)
// and the pure filter `filterLogEntries` (`mobile/lib/models/app_log.dart`) —
// all filtering logic lives there, not here, so a filter bug is testable
// without pumping a widget.
//
// ── THE LIVE-TICK REPAINT RULE ──────────────────────────────────────────
// `AppLogger` deliberately never notifies per entry (see its class doc) —
// notifying on every `log()` call would thrash the widget tree exactly the
// way `LiveTick` (`mobile/lib/widgets/live_tick.dart`) was introduced to
// avoid for the per-scan `setState`. So this screen repaints its entry list
// on the shell's existing throttled `LiveTick` pulse instead.
//
// `LiveTickScope.of(context)` is a deliberate NON-dependency lookup (see its
// doc comment) — calling it does not itself make the calling widget rebuild
// on every pulse. What makes the repaint actually happen is handing the
// returned `LiveTick` to a `ListenableBuilder` that wraps ONLY the leaf that
// must repaint: here, `_buildLogList` builds the (possibly large,
// virtualized) entry `ListView` and NOTHING else — the filter bar, the
// per-source verbosity panel, and the screen's own `Scaffold`/`AppBar` are
// built once by `State.build()` and are not inside the `ListenableBuilder`,
// so they never rebuild on a tick. Only that inner call site invokes
// `LiveTickScope.of(context)`, and only while live-tail is ON (while it is
// OFF the builder is handed a never-notifying `Listenable` instead, so
// nothing is subscribed to the tick at all) — this is the "wrap only the
// leaf" pattern the doc comment calls for.
//
// ── LIVE-TAIL ON vs OFF ──────────────────────────────────────────────────
// ON (the default): every tick pulse re-reads `logger.entries`, re-applies
// the current filter, and the list is scrolled to its tail after each
// rebuild — "follow the tail" is intentionally unconditional while live-tail
// is on, matching the brief: reading in place while new entries keep
// arriving is exactly what turning live-tail OFF is for.
// OFF: the raw entry list is snapshotted once (at the moment live-tail is
// turned off) into `_frozenRaw`. The filter can still be changed and re-narrows
// that frozen snapshot, but no entry logged after the snapshot appears, and
// the list is never force-scrolled — so a user reading it keeps their
// scroll position undisturbed by anything happening live.
import 'package:flutter/material.dart';

import '../models/app_log.dart';
import '../services/app_logger.dart';
import '../widgets/live_tick.dart';

// The source multi-select and the per-source verbosity panel are populated
// from `kAllLogSources` (app_log.dart) — the canonical list kept next to the
// source constants themselves, so a newly added protocol's toggle cannot be
// forgotten here (this file used to keep its own copy, and FINS/SLMP were
// invisible until an operator noticed). An operator can dial up DEBUG/TRACE
// for a source that hasn't logged anything yet (e.g. because it's the one
// silently failing).

const Map<LogLevel, Color> _kLevelColors = {
  LogLevel.trace: Colors.grey,
  LogLevel.debug: Colors.lightBlueAccent,
  LogLevel.info: Colors.tealAccent,
  LogLevel.warn: Colors.amber,
  LogLevel.error: Colors.redAccent,
};

Color _levelColor(LogLevel level) => _kLevelColors[level] ?? Colors.white;

String _levelLabel(LogLevel level) => level.name.toUpperCase();

String _formatTime(int tMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(tMs);
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}.${three(dt.millisecond)}';
}

/// A [Listenable] that never notifies. Handed to the log list's
/// `ListenableBuilder` while live-tail is OFF, so the frozen state occupies
/// the same widget slot with the same `runtimeType` as the live state without
/// subscribing to anything — see `_buildLogList` for why that matters.
class _NeverNotifies implements Listenable {
  const _NeverNotifies();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

const Listenable _kFrozenListenable = _NeverNotifies();

class LogsScreen extends StatefulWidget {
  final AppLogger logger;

  const LogsScreen({super.key, required this.logger});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Set<String> _selectedSources = <String>{};
  final Set<int> _expandedSeqs = <int>{};

  String _textFilter = '';
  LogLevel _minLevel = LogLevel.trace;
  bool _liveTail = true;
  bool _verbosityExpanded = false;
  bool _sourcesExpanded = false;

  /// Snapshot of the raw (unfiltered) entries taken the moment live-tail is
  /// turned off. Only read while `_liveTail` is false — see the file header.
  List<LogEntry> _frozenRaw = <LogEntry>[];

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<LogEntry> _applyFilter(List<LogEntry> raw) {
    return filterLogEntries(
      raw,
      minLevel: _minLevel,
      sources: _selectedSources,
      textFilter: _textFilter,
    );
  }

  void _followTail() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Logs'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: Column(
        children: [
          // The filter bar plus the (optionally expanded) sources and
          // verbosity disclosure panels are wrapped in their OWN `Expanded`
          // (a small flex share) containing a `SingleChildScrollView`,
          // rather than laid out as plain, unconstrained `Column` children.
          // With ~11 sources and ~11 verbosity switches, expanding both
          // panels at once easily wants more height than a short/narrow
          // screen has — as plain Column children that would throw a
          // "RenderFlex overflowed" assertion (there is nothing to absorb
          // the excess). Giving this region a bounded flex share and letting
          // it scroll internally instead means it can NEVER overflow,
          // regardless of window size or how many panels are expanded; the
          // log list below keeps the majority share (flex 7 vs 3) so it
          // stays the dominant, usable area in the common case (both panels
          // collapsed).
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildFilterBar(context),
                  _buildSourcesPanel(context),
                  _buildVerbosityPanel(context),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(flex: 7, child: _buildLogList(context)),
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 200,
            child: TextField(
              key: const Key('logs_text_filter'),
              controller: _textController,
              style: const TextStyle(fontSize: 12, color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Filter text',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _textFilter = v),
            ),
          ),
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<LogLevel>(
              key: const Key('logs_min_level_dropdown'),
              initialValue: _minLevel,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(fontSize: 12, color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Min level',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: LogLevel.values
                  .map((l) => DropdownMenuItem(value: l, child: Text(_levelLabel(l))))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() => _minLevel = v);
                }
              },
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Live tail', style: TextStyle(fontSize: 11, color: Colors.white70)),
              Switch(
                key: const Key('logs_live_tail_switch'),
                value: _liveTail,
                onChanged: (v) => setState(() {
                  if (!v) {
                    // Snapshot now — the view must stay exactly here, not
                    // wherever `logger.entries` happens to be by the time
                    // the user next looks, per the freeze contract above.
                    _frozenRaw = widget.logger.entries;
                  }
                  _liveTail = v;
                }),
              ),
            ],
          ),
          TextButton(
            key: const Key('logs_clear_button'),
            onPressed: () => setState(() {
              widget.logger.clear();
              _expandedSeqs.clear();
              if (!_liveTail) {
                _frozenRaw = <LogEntry>[];
              }
            }),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Widget _buildSourcesPanel(BuildContext context) {
    final summary = _selectedSources.isEmpty
        ? 'Sources: all'
        : 'Sources: ${_selectedSources.length} selected';
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('logs_sources_panel'),
        title: Text(summary, style: const TextStyle(fontSize: 13, color: Colors.white70)),
        initiallyExpanded: _sourcesExpanded,
        onExpansionChanged: (expanded) => setState(() => _sourcesExpanded = expanded),
        collapsedBackgroundColor: const Color(0xFF0F172A),
        backgroundColor: const Color(0xFF0F172A),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final source in kAllLogSources)
                  FilterChip(
                    key: Key('logs_source_chip_$source'),
                    label: Text(source, style: const TextStyle(fontSize: 11)),
                    selected: _selectedSources.contains(source),
                    backgroundColor: const Color(0xFF1E293B),
                    selectedColor: Colors.cyan.withValues(alpha: 0.3),
                    checkmarkColor: Colors.cyanAccent,
                    labelStyle: const TextStyle(color: Colors.white),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _selectedSources.add(source);
                      } else {
                        _selectedSources.remove(source);
                      }
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerbosityPanel(BuildContext context) {
    return Theme(
      // Compact the ExpansionTile's default padding so it doesn't dominate
      // the screen — this panel is a secondary, occasionally-used control.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text(
          'Per-source verbosity (DEBUG)',
          style: TextStyle(fontSize: 13, color: Colors.white70),
        ),
        initiallyExpanded: _verbosityExpanded,
        onExpansionChanged: (expanded) => setState(() => _verbosityExpanded = expanded),
        collapsedBackgroundColor: const Color(0xFF0F172A),
        backgroundColor: const Color(0xFF0F172A),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final source in kAllLogSources)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(source, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                      Switch(
                        key: Key('logs_verbosity_switch_$source'),
                        value: widget.logger.sourceLevel(source).index <= LogLevel.debug.index,
                        onChanged: (on) => setState(() {
                          widget.logger.setSourceLevel(
                            source,
                            on ? LogLevel.debug : LogLevel.info,
                          );
                        }),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The one leaf that repaints on `LiveTick` — see the file header. Only
  /// this method ever calls `LiveTickScope.of(context)`, and only while
  /// live-tail is on; while it's off, this builds once from `_frozenRaw` and
  /// is not wired to the tick at all.
  Widget _buildLogList(BuildContext context) {
    // *** WHY BOTH STATES GO THROUGH A ListenableBuilder ***
    // Returning a `ListenableBuilder` in one state and a bare list in the
    // other would put two DIFFERENT `runtimeType`s in the same slot.
    // `Widget.canUpdate` compares `runtimeType`, so toggling live-tail would
    // deactivate this subtree and inflate a fresh one: the `ListView`'s
    // `Scrollable` is disposed, its `ScrollPosition` goes with it, and the
    // replacement gets `createScrollPosition(oldPosition: null)`. A
    // `ScrollController` does NOT carry an offset across that — only
    // `oldPosition` absorption or `PageStorage` (which needs a
    // `PageStorageKey` on the path, and there is none) does — so the list
    // would land at offset 0. That is exactly backwards: an operator flips
    // live-tail OFF to keep reading where they are, and would instead be
    // thrown to the OLDEST entry in a 2000-entry buffer.
    //
    // So the widget TYPE is constant and only the `listenable` changes.
    // `ListenableBuilder.didUpdateWidget` re-subscribes cleanly, the element
    // (and with it the `ScrollPosition`) is preserved, and the good property
    // that nothing is subscribed to the tick while frozen is kept intact:
    // `LiveTickScope.of(context)` is not even called in the frozen state, and
    // `_kFrozenListenable` never notifies anyone.
    final listenable = _liveTail ? LiveTickScope.of(context) : _kFrozenListenable;
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        if (!_liveTail) {
          return _buildListBody(_frozenRaw, _applyFilter(_frozenRaw));
        }
        final raw = widget.logger.entries;
        final filtered = _applyFilter(raw);
        _followTail();
        return _buildListBody(raw, filtered);
      },
    );
  }

  Widget _buildListBody(List<LogEntry> raw, List<LogEntry> filtered) {
    if (raw.isEmpty) {
      return const Center(
        child: Text(
          'No log entries recorded yet.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    if (filtered.isEmpty) {
      return const Center(
        child: Text(
          'No entries match the current filter.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    return ListView.builder(
      key: const Key('logs_list_view'),
      controller: _scrollController,
      itemCount: filtered.length,
      itemBuilder: (context, index) => _buildRow(filtered[index]),
    );
  }

  Widget _buildRow(LogEntry e) {
    final color = _levelColor(e.level);
    final hasDetail = e.detail != null && e.detail!.isNotEmpty;
    final expanded = _expandedSeqs.contains(e.seq);

    final header = ListTile(
      key: ValueKey('logs_row_${e.seq}'),
      dense: true,
      tileColor: color.withValues(alpha: 0.08),
      leading: SizedBox(
        width: 46,
        child: Text(
          _levelLabel(e.level),
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 10),
        ),
      ),
      title: Text(
        e.message,
        style: const TextStyle(fontSize: 12, color: Colors.white),
      ),
      subtitle: Text(
        '${_formatTime(e.tMs)} · ${e.source}',
        style: const TextStyle(fontSize: 10, color: Colors.white54),
      ),
      trailing: hasDetail
          ? Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              color: Colors.white54,
            )
          : null,
      onTap: hasDetail
          ? () => setState(() {
                if (expanded) {
                  _expandedSeqs.remove(e.seq);
                } else {
                  _expandedSeqs.add(e.seq);
                }
              })
          : null,
    );

    if (!hasDetail || !expanded) {
      return header;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Container(
          key: ValueKey('logs_detail_${e.seq}'),
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          color: Colors.black.withValues(alpha: 0.3),
          child: Text(
            e.detail!,
            style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
