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
// must repaint: here, `_buildLogSlivers` builds the pagination bar plus the
// current page's (virtualized) `SliverList` and NOTHING else — the filter
// bar, the per-source verbosity panel, and the screen's own
// `Scaffold`/`AppBar` are built once by `State.build()` and are not inside
// the `ListenableBuilder`, so they never rebuild on a tick. Only that inner call site invokes
// `LiveTickScope.of(context)`, and only while live-tail is ON (while it is
// OFF the builder is handed a never-notifying `Listenable` instead, so
// nothing is subscribed to the tick at all) — this is the "wrap only the
// leaf" pattern the doc comment calls for.
//
// ── DISPLAY ORDER + PAGINATION ───────────────────────────────────────────
// Entries display NEWEST FIRST (the ring buffer stores oldest→newest; the
// filtered list is reversed for display), paginated with a per-page size
// dropdown (25/50/100/200) and prev/next controls. Newer entries live on
// LOWER page numbers, so page 1 is always "now".
//
// ── ONE UNIFIED SCROLL VIEW ──────────────────────────────────────────────
// The body is a single `CustomScrollView`: the filter bar and the two
// disclosure panels are box slivers that PUSH the log list down when
// expanded, rather than living in their own small internally-scrolling
// region (the previous design, explicitly rejected by the user). Because
// the whole body is one scroll surface, an expanded panel can never cause
// a RenderFlex overflow even on a 320-wide phone — the page just scrolls.
//
// ── LIVE-TAIL ON vs OFF ──────────────────────────────────────────────────
// ON (the default): every tick pulse re-reads `logger.entries`, re-applies
// the filter, PINS the view to page 1 (the newest entries) and jumps the
// scroll position back to the top after each rebuild — "follow the head" is
// intentionally unconditional while live-tail is on: reading in place while
// new entries keep arriving is exactly what turning live-tail OFF is for
// (the prev/next page controls are disabled while ON for the same reason).
// OFF: the raw entry list is snapshotted once (at the moment live-tail is
// turned off) into `_frozenRaw`. The filter and the page controls still
// work — they re-narrow/re-slice that frozen snapshot — but no entry logged
// after the snapshot appears, and the view is never force-scrolled or
// force-paged, so a user reading keeps their place undisturbed.
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

/// Page-size choices for the pagination bar's "Per page" dropdown.
const List<int> _kPageSizes = [25, 50, 100, 200];

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

  /// Entries shown per page. One of [_kPageSizes].
  int _pageSize = 50;

  /// Current 0-based page over the newest-first display list. Only honored
  /// while live-tail is OFF — while ON the view is pinned to page 0 (the
  /// newest entries); see the file header.
  int _pageIndex = 0;

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

  /// Newest-first "follow the head": while live-tail is ON, every rebuild
  /// jumps back to the top of the page, where the newest entries are.
  void _followHead() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Logs'),
        backgroundColor: const Color(0xFF1E293B),
        // Live tail + Clear live HERE — pinned, never scrolled away — because
        // the primary interaction is "flip live-tail OFF to read the entry
        // that just went past": the operator must be able to reach the
        // toggle without scrolling (which would lose the very place they are
        // trying to keep). Everything else scrolls with the page.
        actions: [
          const Center(
            child: Text('Live tail',
                style: TextStyle(fontSize: 11, color: Colors.white70)),
          ),
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
          TextButton(
            key: const Key('logs_clear_button'),
            onPressed: () => setState(() {
              widget.logger.clear();
              _expandedSeqs.clear();
              _pageIndex = 0;
              if (!_liveTail) {
                _frozenRaw = <LogEntry>[];
              }
            }),
            child: const Text('Clear'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      // One unified scroll surface — see "ONE UNIFIED SCROLL VIEW" in the
      // file header. The panels are plain box slivers, so expanding one
      // pushes everything below it down; there is no inner scroll region and
      // no possible RenderFlex overflow at any window size.
      body: CustomScrollView(
        key: const Key('logs_list_view'),
        controller: _scrollController,
        slivers: [
          SliverToBoxAdapter(child: _buildFilterBar(context)),
          SliverToBoxAdapter(child: _buildSourcesPanel(context)),
          SliverToBoxAdapter(child: _buildVerbosityPanel(context)),
          const SliverToBoxAdapter(
            child: Divider(height: 1, color: Colors.white12),
          ),
          _buildLogSlivers(context),
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
          // Live tail + Clear are NOT here — they are pinned in the AppBar
          // (see `build`), so they stay reachable while scrolled.
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
  /// is not wired to the tick at all. Returns a SLIVER (the pagination bar
  /// plus the current page's rows) for the body's `CustomScrollView`.
  Widget _buildLogSlivers(BuildContext context) {
    // *** WHY BOTH STATES GO THROUGH A ListenableBuilder ***
    // Returning a `ListenableBuilder` in one state and a bare sliver in the
    // other would put two DIFFERENT `runtimeType`s in the same slot.
    // `Widget.canUpdate` compares `runtimeType`, so toggling live-tail would
    // deactivate this subtree — and were that ever to take the enclosing
    // `Scrollable`'s `ScrollPosition` with it, the view would land back at
    // offset 0. That is exactly backwards: an operator flips live-tail OFF
    // to keep reading where they are, and would instead be thrown back to
    // the top of the page, losing their place.
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
        _followHead();
        return _buildListBody(raw, filtered);
      },
    );
  }

  Widget _buildListBody(List<LogEntry> raw, List<LogEntry> filtered) {
    if (raw.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(
            'No log entries recorded yet.',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    if (filtered.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(
            'No entries match the current filter.',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    // Newest first: the ring buffer stores oldest→newest, so reverse for
    // display, then slice out the current page. While live-tail is ON the
    // page is pinned to 0 (the newest entries) — see the file header.
    final display = filtered.reversed.toList();
    final pageCount = (display.length + _pageSize - 1) ~/ _pageSize;
    final page = _liveTail ? 0 : _pageIndex.clamp(0, pageCount - 1);
    final start = page * _pageSize;
    final end =
        start + _pageSize > display.length ? display.length : start + _pageSize;
    final pageItems = display.sublist(start, end);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: _buildPaginationBar(page, pageCount)),
        SliverList.builder(
          itemCount: pageItems.length,
          itemBuilder: (context, index) => _buildRow(pageItems[index]),
        ),
      ],
    );
  }

  Widget _buildPaginationBar(int page, int pageCount) {
    // Newer entries live on LOWER page numbers (page 1 = "now"). While
    // live-tail is ON the view is pinned to page 1, so prev/next are
    // disabled — flip live-tail OFF to page back through history.
    final canPage = !_liveTail;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Per page',
              style: TextStyle(fontSize: 11, color: Colors.white70)),
          DropdownButton<int>(
            key: const Key('logs_page_size_dropdown'),
            value: _pageSize,
            dropdownColor: const Color(0xFF1E293B),
            style: const TextStyle(fontSize: 12, color: Colors.white),
            underline: const SizedBox.shrink(),
            items: _kPageSizes
                .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _pageSize = v;
                  _pageIndex = 0;
                });
              }
            },
          ),
          IconButton(
            key: const Key('logs_page_prev'),
            icon: const Icon(Icons.chevron_left, color: Colors.white70),
            visualDensity: VisualDensity.compact,
            tooltip: 'Newer',
            onPressed: canPage && page > 0
                ? () => setState(() => _pageIndex = page - 1)
                : null,
          ),
          Text(
            'Page ${page + 1} of $pageCount',
            key: const Key('logs_page_label'),
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
          IconButton(
            key: const Key('logs_page_next'),
            icon: const Icon(Icons.chevron_right, color: Colors.white70),
            visualDensity: VisualDensity.compact,
            tooltip: 'Older',
            onPressed: canPage && page < pageCount - 1
                ? () => setState(() => _pageIndex = page + 1)
                : null,
          ),
          if (_liveTail)
            const Text(
              'live — newest first',
              style: TextStyle(fontSize: 10, color: Colors.white38),
            ),
        ],
      ),
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
