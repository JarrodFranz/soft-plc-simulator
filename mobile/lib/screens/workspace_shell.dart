import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_log.dart';
import '../models/project_model.dart';
import '../models/project_history.dart';
import '../models/system_tags.dart';
import '../models/tag_resolver.dart';
import '../data/default_projects.dart';
import '../data/project_repository.dart';
import '../data/project_transfer.dart';
import '../services/app_logger.dart';
import '../services/dnp3_host.dart';
import '../services/enip_host.dart';
import '../services/fins_host.dart';
import '../services/s7_host.dart';
import '../services/modbus_host.dart';
import '../services/mqtt_host.dart';
import '../services/opcua_host.dart';
import '../services/slmp_host.dart';
import '../services/notify_throttle.dart';
import '../services/tag_historian.dart';
import '../ui/responsive.dart';
import '../widgets/live_tick.dart';
import '../widgets/tag_autocomplete_field.dart';
import '../widgets/tag_inspector_dock.dart';
import 'scan_tick.dart';
import 'st_editor_screen.dart';
import 'ld_editor_screen.dart';
import 'fbd_editor_screen.dart';
import 'sfc_editor_screen.dart';
import 'memory_manager_screen.dart';
import 'hmi_dashboard_builder_screen.dart';
import 'simulated_io_screen.dart';
import 'logs_screen.dart';
import 'pid_autotune_screen.dart';
import 'interaction_analysis_screen.dart';
import 'gateway_screen.dart';
import 'softplc_settings_dialog.dart';

/// Debounce window between the last project mutation and the autosave write.
const Duration _autosaveDebounce = Duration(milliseconds: 800);

/// Sentinel item appended to the Add-Program dialog's task dropdown; picking
/// it reveals inline task-creation fields instead of an existing task.
const String _kNewTaskSentinel = '＋ New task…';

/// Global (not per-project) SharedPreferences key for the UI refresh rate,
/// in Hz, that tunes `_repaintThrottle`'s coalescing window.
const String _kUiRefreshHzKey = 'ui_refresh_hz';

/// Default UI refresh rate, in Hz, used when `ui_refresh_hz` has never been
/// persisted (fresh install) or when reading it fails.
const int kDefaultRefreshHz = 10;

/// Global (not per-project) SharedPreferences key for whether HMI haptic
/// feedback (pushbuttons + toggles) is enabled.
const String _kHapticsEnabledKey = 'haptics_enabled';

/// Default for HMI haptic feedback when `haptics_enabled` has never been
/// persisted or reading it fails — on (a no-op on desktop/web regardless).
const bool kDefaultHapticsEnabled = true;

/// Clamps a requested UI refresh rate to the supported 1-30 Hz range. Pure
/// and `@visibleForTesting` so the clamp logic is testable without pumping
/// the shell or its settings dialog.
@visibleForTesting
int clampRefreshHz(int hz) => hz.clamp(1, 30);

/// Maps a (clamped) refresh rate in Hz to the `NotifyThrottle` coalescing
/// window that achieves it. Pure and `@visibleForTesting` alongside
/// [clampRefreshHz].
@visibleForTesting
Duration refreshWindow(int hz) => Duration(milliseconds: (1000 / clampRefreshHz(hz)).round());

class WorkspaceShell extends StatefulWidget {
  /// Optional injection seam so tests (and callers that already own a
  /// [ProjectRepository]) can share one backing store with the shell instead
  /// of it always minting its own via [SharedPreferences.getInstance].
  final ProjectRepository? repository;

  const WorkspaceShell({super.key, this.repository});

  @override
  State<WorkspaceShell> createState() => WorkspaceShellState();
}

class WorkspaceShellState extends State<WorkspaceShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Project Workspace Repository
  ProjectRepository? _repo;
  bool _booting = true;
  List<PlcProject> _allProjects = [];
  late PlcProject _activeProject;

  // Active Main Content View
  // 'HMI:<hmi_id>', 'PROGRAM:<prog_name>', 'MEMORY'
  String _activeViewId = 'HMI:hmi_motor';

  // PLC Engine State
  bool isRunning = true;
  int scanCount = 0;
  int scanSpeedMs = 500; // Configurable scan speed (50ms to 2000ms)
  Timer? _scanTimer;
  Timer? _supervisorTimer;
  final ScanTickRuntime _scan = ScanTickRuntime();

  /// The app-wide logger (see `services/app_logger.dart`) — owned here,
  /// beside the hosts, and threaded into each of them below so every
  /// protocol host's instrumentation (Task 3) actually reaches one shared
  /// buffer instead of six independent, unobserved loggers. NOT cleared on
  /// project switch (a project switch is itself logged, under
  /// `kLogSourceProject`) — see `AppLogger`'s class doc for why that's a
  /// deliberate divergence from `TagHistorian`, which does clear.
  final AppLogger _logger = AppLogger();

  // `late final` (not a plain field initializer) because each constructor
  // below reads the sibling `_logger` field — a plain initializer cannot
  // reference another instance member, only a `late` one (evaluated lazily,
  // on first access, by which time `_logger` is already set).
  late final OpcUaHost _opcuaHost = OpcUaHost(logger: _logger);
  late final ModbusHost _modbusHost = ModbusHost(logger: _logger);
  late final MqttHost _mqttHost = MqttHost(logger: _logger);
  late final DnpHost _dnpHost = DnpHost(logger: _logger);
  late final EnipHost _enipHost = EnipHost(logger: _logger);
  late final S7Host _s7Host = S7Host(logger: _logger);
  late final FinsHost _finsHost = FinsHost(logger: _logger);
  late final SlmpHost _slmpHost = SlmpHost(logger: _logger);

  // Repaint-pulse infrastructure (see live_tick.dart). `_executeScan` no
  // longer setStates the whole shell each tick — it writes the model
  // directly and calls `_repaintThrottle.request()`, which pulses `_liveTick`
  // (throttled to `_refreshHz`) so only the LiveTick-driven value leaves
  // repaint. A targeted `setState` remains for the rare structural
  // transitions (a fault first tripping, an AlarmReset-driven clear).
  final LiveTick _liveTick = LiveTick();
  int _refreshHz = kDefaultRefreshHz;
  bool _hapticsEnabled = kDefaultHapticsEnabled;
  late NotifyThrottle _repaintThrottle;

  /// Memory-only trend historian, sampled once per scan tick in
  /// `_executeScan` and re-synced/cleared on every project switch (see
  /// `_switchActiveProject` and the other project-CRUD paths below) — its
  /// buffers must never straddle two different projects.
  final TagHistorian _historian = TagHistorian();

  /// Counts this State's `build()` invocations — test-only instrumentation
  /// (see [debugBuildCount]) so a widget test can assert the per-scan
  /// repaint path never rebuilds the whole shell.
  int _buildCount = 0;

  // Scheduler-driven scan-tick status (fault latch + scan-time stats),
  // surfaced via the reserved `System` tag each scan (see `system_tags.dart`).
  bool _freeRun = false;
  bool _faulted = false;
  String _faultTaskName = '';
  int _faultCode = 0;
  double _lastScanMs = 0, _maxScanMs = 0, _minScanMs = 0;
  int _sessionScans = 0;
  final Stopwatch _uptime = Stopwatch();
  final Stopwatch _sinceLast = Stopwatch();

  // Side Dock Inspector State
  bool isTagDockVisible = true;
  // In a short (landscape-phone) viewport the Scan Loop Speed bar is collapsed
  // by default to reclaim vertical space; the app-bar speed toggle shows it.
  // Ignored on taller viewports (the bar always shows there).
  bool _scanBarVisibleInShort = false;

  // Autosave status. `_saveFailed` is a third state (alongside
  // saving/saved) surfaced when a save actually throws, so a failure is
  // visible instead of silently swallowed.
  Timer? _autosaveTimer;
  bool _saveInFlight = false;
  bool _savedIndicatorVisible = false;
  bool _saveFailed = false;

  // Undo/Redo history. `_history` snapshots the active project's serialized
  // JSON; `_editorRevision` bumps whenever the active project is replaced
  // wholesale (switch/CRUD/undo/redo) so the center editor widget is keyed
  // fresh instead of trying to diff its old state against the new project.
  final ProjectHistory _history = ProjectHistory();
  int _editorRevision = 0;

  /// Serializes the active project for undo/redo + autosave-dirty
  /// comparison. The reserved `System` tag's value is neutralized to a fixed
  /// placeholder first: it carries continuously-changing per-scan telemetry
  /// (scan count, scan timers, wall clock) written every tick by
  /// `_executeScan`, which would otherwise make every snapshot compare as
  /// "changed" even with no user edit — corrupting dirty-detection and the
  /// undo/redo stacks whenever the scan loop is running. This does not
  /// affect what's actually persisted to disk (`_runAutosave` saves
  /// `_activeProject` directly, live values intact); `_applySnapshot` calls
  /// `ensureSystemTag` right after restoring to backfill sane defaults.
  String _snapshot() {
    final json = _activeProject.toJson();
    final tagsJson = (json['project'] as Map)['tags'] as List;
    for (final t in tagsJson) {
      if (t is Map && t['name'] == kSystemTagName) {
        t['initial_value'] = <String, dynamic>{};
      }
    }
    return jsonEncode(json);
  }

  @override
  void initState() {
    super.initState();
    _repaintThrottle = NotifyThrottle(_liveTick.pulse, window: refreshWindow(_refreshHz));
    _boot();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _supervisorTimer?.cancel();
    _autosaveTimer?.cancel();
    _opcuaHost.dispose();
    _modbusHost.dispose();
    _mqttHost.dispose();
    _dnpHost.dispose();
    _enipHost.dispose();
    _s7Host.dispose();
    _finsHost.dispose();
    _slmpHost.dispose();
    _repaintThrottle.dispose();
    _liveTick.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    ProjectRepository? repo;
    List<PlcProject> loadedProjects = [];
    PlcProject? active;
    SharedPreferences? prefs;

    if (widget.repository != null) {
      // Test/caller-supplied seam: use it directly, never touch
      // SharedPreferences.getInstance().
      repo = widget.repository;
    } else {
      // Plain await + catch, no timeout race. A genuinely-missing platform
      // channel (e.g. an unmocked widget test) throws promptly (typically
      // MissingPluginException) so this resolves to null quickly and falls
      // back to the in-memory defaults below. A slow-but-working device
      // just awaits longer and ALWAYS gets a real, persistent repository —
      // there is no arbitrary timeout that can cause a false fallback.
      try {
        prefs = await SharedPreferences.getInstance();
      } catch (_) {
        prefs = null;
      }
      repo = prefs != null ? ProjectRepository(prefs, logger: _logger) : null;
    }

    // The UI refresh rate is a GLOBAL setting (not per-project), so it lives
    // under its own top-level key rather than inside `repo`/`ProjectRepository`
    // (which only knows about per-project catalog/project/active-id blobs).
    // Reuse `prefs` when the non-injected path above already fetched it;
    // otherwise (an injected `widget.repository`, e.g. in tests) fall back to
    // a fresh `SharedPreferences.getInstance()` call of our own. Either way
    // this is best-effort: any failure just keeps the compile-time default.
    int loadedRefreshHz = kDefaultRefreshHz;
    bool loadedHaptics = kDefaultHapticsEnabled;
    try {
      final settingsPrefs = prefs ?? await SharedPreferences.getInstance();
      loadedRefreshHz = clampRefreshHz(settingsPrefs.getInt(_kUiRefreshHzKey) ?? kDefaultRefreshHz);
      loadedHaptics = settingsPrefs.getBool(_kHapticsEnabledKey) ?? kDefaultHapticsEnabled;
    } catch (_) {
      loadedRefreshHz = kDefaultRefreshHz;
      loadedHaptics = kDefaultHapticsEnabled;
    }

    if (repo != null) {
      // Prefs (or an injected repository) are available. Keep `repo`
      // non-null even if seeding/loading below throws, so the key
      // invariant holds: prefs available => _repo stays non-null => edits
      // persist. A failure here only affects what's shown THIS session,
      // never whether autosave has somewhere to write.
      try {
        await repo.backfillNewDefaults();

        final catalog = await repo.listProjects();
        final activeId = await repo.getActiveProjectId();

        if (activeId != null) {
          active = await repo.loadProject(activeId);
        }
        active ??= catalog.isNotEmpty ? await repo.loadProject(catalog.first.id) : null;

        for (final summary in catalog) {
          if (active != null && summary.id == active.id) {
            loadedProjects.add(active);
            continue;
          }
          final p = await repo.loadProject(summary.id);
          if (p != null) loadedProjects.add(p);
        }
      } catch (e) {
        // A later boot step (seed/list/load) threw despite prefs being
        // available. Don't revert to a null repo — that would silently
        // disable persistence for the whole session. Just fall back to
        // in-memory defaults for THIS session's initial view; `_repo`
        // stays non-null so autosave still writes through.
        _logger.log(
          kLogSourceProject,
          LogLevel.error,
          'Boot: project catalog/list/load failed; falling back to in-memory defaults',
          detail: e.toString(),
        );
        loadedProjects = [];
        active = null;
      }
    }

    if (loadedProjects.isEmpty) {
      loadedProjects = DefaultProjects.all();
      active = loadedProjects.first;
    }

    for (final pr in loadedProjects) {
      ensureSystemTag(pr);
    }

    if (!mounted) return;
    setState(() {
      _repo = repo;
      _allProjects = loadedProjects;
      _activeProject = active ?? loadedProjects.first;
      _historian.syncPens(_activeProject.trends);
      if (_activeProject.hmis.isNotEmpty) {
        _activeViewId = 'HMI:${_activeProject.hmis.first.id}';
      } else if (_activeProject.programs.isNotEmpty) {
        _activeViewId = 'PROGRAM:${_activeProject.programs.first.name}';
      } else {
        _activeViewId = 'MEMORY';
      }
      _booting = false;
      _history.reset(_snapshot());
      if (loadedRefreshHz != _refreshHz) {
        _refreshHz = loadedRefreshHz;
        _repaintThrottle.dispose();
        _repaintThrottle = NotifyThrottle(_liveTick.pulse, window: refreshWindow(_refreshHz));
      }
      _hapticsEnabled = loadedHaptics;
    });
    _logger.log(kLogSourceProject, LogLevel.info,
        'Loaded project "${_activeProject.name}" (${_activeProject.id}) at boot');
    await repo?.setActiveProjectId(_activeProject.id);
    _startRunSession();
    _startScanLoop();
  }

  /// (Re)arms the scan loop, mode-aware: fixed mode ticks on a
  /// `Timer.periodic`; free-run re-arms a zero-delay `Timer` after each tick
  /// so the event loop (and therefore the UI) still gets a chance to paint
  /// between scans instead of the loop starving it. A slow supervisor timer
  /// always runs alongside either mode so an external `System.AlarmReset`
  /// write (e.g. from HMI/logic, not the Clear Fault button) still clears a
  /// latched fault even while the scan loop itself is halted.
  ///
  /// Free-run only re-arms the next zero-delay timer while `isRunning` is
  /// true and `_faulted` is false — paused/faulted goes fully idle (no
  /// scheduled timer at all) instead of spinning an indefinite no-op
  /// zero-delay chain. `_startScanLoop()` is called again on the
  /// stopped -> running toggle (see the run/pause `IconButton` below) to
  /// resume the chain.
  void _startScanLoop() {
    _scanTimer?.cancel();
    if (_freeRun) {
      void arm() {
        _scanTimer = Timer(Duration.zero, () {
          if (!isRunning || _faulted) {
            // Paused/faulted: go idle, do not re-arm. Resumed by the next
            // _startScanLoop() call (run toggle or free-run/speed change).
            return;
          }
          _executeScan();
          arm();
        });
      }
      if (isRunning && !_faulted) {
        arm();
      }
    } else {
      _scanTimer = Timer.periodic(Duration(milliseconds: scanSpeedMs), (timer) {
        if (isRunning && !_faulted) {
          _executeScan();
        }
      });
    }
    _supervisorTimer?.cancel();
    _supervisorTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (_faulted && consumeAlarmReset(_activeProject)) {
        setState(_clearFault);
      }
    });
  }

  /// Test-only hook: forces the shell into a faulted state (as if the
  /// watchdog had tripped mid-scan) without needing to drive an actual
  /// scan-tick fault through a program. Used by widget tests to exercise the
  /// fault banner / Clear Fault flow deterministically.
  @visibleForTesting
  void debugForceFault(String task) => setState(() {
        _faulted = true;
        _faultTaskName = task;
        _faultCode = 1;
        isRunning = false;
      });

  /// Test-only hook: the currently active project, for asserting on task /
  /// program state directly without driving dialog UI.
  @visibleForTesting
  PlcProject get debugActiveProject => _activeProject;

  /// Test-only hook: whether the shell currently holds a latched watchdog
  /// fault, for asserting fault state directly without scraping banner text.
  @visibleForTesting
  bool get debugFaulted => _faulted;

  /// Test-only hook: the shell's [LiveTick], so widget tests can pulse it
  /// directly (mirroring what `_repaintThrottle` does each scan) without
  /// needing a full scan-timer tick to elapse.
  @visibleForTesting
  LiveTick get debugLiveTick => _liveTick;

  /// Test-only hook: the shell's [AppLogger], so widget tests can assert on
  /// recorded entries directly (source/level/message) instead of scraping
  /// the (Task 5) Logs screen.
  @visibleForTesting
  AppLogger get debugLogger => _logger;

  /// Test-only hook: the current center-workspace view id (`'HMI:<id>'`,
  /// `'PROGRAM:<name>'`, `'MEMORY'`, `'GATEWAY'`, `'LOGS'`, ...), for
  /// asserting navigation state directly rather than scraping widget text.
  @visibleForTesting
  String get debugActiveViewId => _activeViewId;

  /// Test-only hook: sets the active view id directly, bypassing the left
  /// dock's `onTap`/`Navigator.pop` handling in `_selectView` (which needs a
  /// real `BuildContext` and drawer state) — used to put the shell in a
  /// known view (e.g. `'LOGS'`) before exercising a project switch.
  @visibleForTesting
  void debugSetActiveViewId(String id) => setState(() => _activeViewId = id);

  /// Test-only hook: the shell's current UI refresh rate (Hz), so a widget
  /// test can assert on it directly instead of poking at `_repaintThrottle`'s
  /// private window.
  @visibleForTesting
  int get debugRefreshHz => _refreshHz;

  @visibleForTesting
  bool get debugHapticsEnabled => _hapticsEnabled;

  /// Sets whether HMI haptic feedback is enabled: updates `_hapticsEnabled`
  /// (rebuilding so the HMI builder picks up the new value) and best-effort
  /// persists it to the global `haptics_enabled` SharedPreferences key. Called
  /// by the SoftPLC Settings dialog's Save button; `@visibleForTesting` so the
  /// apply/persist path is directly testable without driving the dialog UI.
  @visibleForTesting
  Future<void> applyHapticsEnabled(bool enabled) async {
    if (mounted) {
      setState(() => _hapticsEnabled = enabled);
    } else {
      _hapticsEnabled = enabled;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kHapticsEnabledKey, enabled);
    } catch (_) {
      // Best-effort persistence: `_hapticsEnabled` still applies for this
      // session even if the write fails (e.g. platform channel unavailable).
    }
  }

  /// Re-tunes the UI refresh rate: clamps [hz] to 1-30, swaps in a freshly
  /// windowed `_repaintThrottle` (disposing the old one first — its
  /// coalescing window is fixed at construction, see `NotifyThrottle`), and
  /// best-effort persists the clamped value to the global `ui_refresh_hz`
  /// SharedPreferences key so it survives the next boot. Called by the
  /// SoftPLC Settings dialog's Save button; also `@visibleForTesting` so the
  /// clamp/apply/persist path is directly testable without driving the
  /// dialog UI.
  @visibleForTesting
  Future<void> applyRefreshHz(int hz) async {
    final clamped = clampRefreshHz(hz);
    if (mounted) {
      setState(() {
        _refreshHz = clamped;
        _repaintThrottle.dispose();
        _repaintThrottle = NotifyThrottle(_liveTick.pulse, window: refreshWindow(clamped));
      });
    } else {
      _refreshHz = clamped;
      _repaintThrottle.dispose();
      _repaintThrottle = NotifyThrottle(_liveTick.pulse, window: refreshWindow(clamped));
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kUiRefreshHzKey, clamped);
    } catch (_) {
      // Best-effort persistence: `_refreshHz` still applies for this
      // session even if the write fails (e.g. platform channel unavailable).
    }
  }

  /// Opens the SoftPLC Settings dialog (UI refresh-rate field + haptics
  /// toggle), prefilled with the shell's current `_refreshHz`/`_hapticsEnabled`.
  /// A non-null result (Save was pressed with a parseable rate) is applied via
  /// [applyRefreshHz] (clamps + re-tunes + persists) and [applyHapticsEnabled]
  /// (updates + persists).
  Future<void> _openSoftPlcSettings(BuildContext context) async {
    final result = await showAdaptiveWidthDialog<SoftPlcSettingsResult>(
      context,
      child: SoftPlcSettingsDialog(
        initialRefreshHz: _refreshHz,
        initialHapticsEnabled: _hapticsEnabled,
      ),
    );
    if (result != null) {
      await applyRefreshHz(result.refreshHz);
      await applyHapticsEnabled(result.hapticsEnabled);
    }
  }

  /// Test-only hook: how many times this State's `build()` has run, so a
  /// widget test can assert that driving scans via [debugRunScan] does NOT
  /// rebuild the whole shell (only structural transitions — a fault first
  /// tripping, or an AlarmReset-driven clear — do that).
  @visibleForTesting
  int get debugBuildCount => _buildCount;

  /// Test-only hook: runs one scan tick synchronously via the same
  /// `_executeScan` the real Timer-driven scan loop calls, without needing a
  /// real `Timer` to elapse.
  @visibleForTesting
  void debugRunScan() => _executeScan();

  /// Test-only hook: the shell's [TagHistorian], so a widget test can assert
  /// on captured samples directly without driving a trend chart HMI widget.
  @visibleForTesting
  TagHistorian get historianForTest => _historian;

  /// Test-only hook: re-syncs the historian's buffers to the active
  /// project's current pens, mirroring what every project-switch site (and
  /// the initial load) does — needed after a test mutates
  /// `debugActiveProject.trends` directly (bypassing the switch/load paths).
  @visibleForTesting
  void syncHistorianForTest() => _historian.syncPens(_activeProject.trends);

  /// Test-only hook: overrides the per-task measured execution time used by
  /// `runScanTick`'s watchdog check (see `ScanTickRuntime.elapsedForTest`),
  /// so a test can deterministically trip a task's watchdog fault on the
  /// next [debugRunScan] instead of needing a task to genuinely overrun.
  @visibleForTesting
  void debugSetScanElapsedForTest(int ms) => _scan.elapsedForTest = ms;

  /// Test-only hook: adds [proj] to the in-memory project catalog (mirrors
  /// what `_createNewProject`/`_importProject` do) so it's a valid target
  /// for `debugSwitchToProject` — the project switcher UI only ever offers
  /// projects already in `_allProjects`.
  @visibleForTesting
  void debugAddProject(PlcProject proj) => setState(() => _allProjects.add(proj));

  /// Test-only hook: drives the same project-replacement path as picking
  /// [proj] from the project switcher UI. Used by widget tests to exercise
  /// `_switchActiveProject` (and therefore `_beginProjectSession`) without
  /// needing to drive the picker dialog.
  @visibleForTesting
  void debugSwitchToProject(PlcProject proj) => _switchActiveProject(proj);

  /// Test-only hook: drives the same state-mutation tail `_importProject`
  /// runs once it has a decoded [imported] project in hand — i.e.
  /// everything after the file picker/decode steps. Those earlier steps go
  /// through the real `file_picker` plugin's platform channel, which a
  /// widget test can't answer with a real file: `PlatformFile.bytes` is a
  /// `Uint8List`, but a mocked method channel reply round-trips through the
  /// channel's codec (JSON on desktop), which cannot reproduce a `Uint8List`
  /// — the plugin's own decoding throws and `_importProject` treats that
  /// exactly like "file picker failed". This hook exercises
  /// `_applyImportedProject` directly instead, the same way
  /// `debugSwitchToProject` exercises `_switchActiveProject` directly.
  @visibleForTesting
  Future<void> debugImportProject(PlcProject imported) => _applyImportedProject(imported);

  /// Test-only hook: appends [t] to the active project's task list.
  @visibleForTesting
  void debugAddTask(PlcTask t) => setState(() => _activeProject.tasks.add(t));

  /// Test-only hook: exercises the [_deleteTask] orphan-guard logic directly.
  @visibleForTesting
  bool debugDeleteTask(PlcTask t) => _deleteTask(t);

  /// Test-only hook: exercises the Add-Program dialog's "＋ New task…" save
  /// path directly — creates [taskName]/[taskType] (with [periodMs] /
  /// [triggerTag] / [watchdogMs] as applicable), adds it to the active
  /// project, then creates [programName]/[language] and assigns it to the
  /// new task. The dialog itself calls the same path so UI and test share
  /// one implementation.
  @visibleForTesting
  bool debugAddProgramToNewTask({
    required String programName,
    required String language,
    required String taskName,
    required String taskType,
    int periodMs = 100,
    String triggerTag = '',
    int watchdogMs = 0,
  }) =>
      _addProgramToNewTask(
        programName: programName,
        language: language,
        taskName: taskName,
        taskType: taskType,
        periodMs: periodMs,
        triggerTag: triggerTag,
        watchdogMs: watchdogMs,
      );

  /// Clears the historian and resyncs it to `_activeProject`'s current
  /// trend pens, then records a `kLogSourceHistorian` entry noting the pen
  /// count. Called by every project-CRUD path that swaps `_activeProject`
  /// (switch / create / duplicate / delete / reset / import / undo-redo) so
  /// a project's trend buffers never straddle into another project's. Must
  /// be called AFTER `_activeProject` is reassigned to the new project.
  void _resyncHistorian() {
    _historian.clear();
    _historian.syncPens(_activeProject.trends);
    _logger.log(
      kLogSourceHistorian,
      LogLevel.info,
      'Historian resynced (${_activeProject.trends.length} pen(s)) for "${_activeProject.name}"',
    );
  }

  /// Reset all per-run-session runtime state when the active project is
  /// replaced (switch / undo-redo / create / duplicate / delete / reset /
  /// import): scheduler, watchdog fault, scan-time stats, and timers. A
  /// replaced project must never inherit another project's fault or telemetry.
  void _beginProjectSession() {
    _scan.resetSession();
    _logger.log(kLogSourceSim, LogLevel.info,
        'Sim engine state reset (new project session: "${_activeProject.name}")');
    _logger.log(kLogSourceScheduler, LogLevel.info,
        'Task scheduler state reset (new project session: "${_activeProject.name}")');
    _faulted = false;
    _faultTaskName = '';
    _faultCode = 0;
    _sessionScans = 0;
    _lastScanMs = 0;
    _maxScanMs = 0;
    _minScanMs = 0;
    _uptime
      ..reset()
      ..start();
    _sinceLast
      ..reset()
      ..start();
  }

  /// (Re)starts a run session: resets the scheduler/engine runtimes and the
  /// per-session scan-time stats, and (re)starts the uptime/free-run clocks.
  /// Called on boot and on every stopped -> running transition.
  void _startRunSession() {
    _scan.resetSession();
    _logger.log(kLogSourceScan, LogLevel.info, 'Scan engine started');
    _sessionScans = 0;
    _lastScanMs = _maxScanMs = _minScanMs = 0;
    _uptime
      ..reset()
      ..start();
    _sinceLast
      ..reset()
      ..start();
  }

  void _executeScan() {
    if (_faulted) {
      return;
    }
    final dtMs = _freeRun
        ? (_sinceLast.elapsedMilliseconds.clamp(0, 1000))
        : scanSpeedMs;
    _sinceLast
      ..reset()
      ..start();
    final tickSw = Stopwatch()..start();

    final result = runScanTick(_activeProject, dtMs, _scan);

    tickSw.stop();
    final now = DateTime.now();

    // Plain model writes below — NOT wrapped in setState. These fields
    // (scanCount, _sessionScans, _lastScanMs/_maxScanMs/_minScanMs) are read
    // by on-screen surfaces only via the `System` tag through a
    // LiveTick-driven `ListenableBuilder` (see the toolbar Scan Count above),
    // so mutating them directly here is safe — `_repaintThrottle.request()`
    // below is what actually schedules the next repaint, throttled to
    // `_refreshHz`, instead of an unconditional whole-shell rebuild every scan.
    scanCount++;
    _sessionScans++;
    _lastScanMs = tickSw.elapsedMicroseconds / 1000.0;
    if (_sessionScans == 1 || _lastScanMs > _maxScanMs) {
      _maxScanMs = _lastScanMs;
    }
    if (_sessionScans == 1 || _lastScanMs < _minScanMs) {
      _minScanMs = _lastScanMs;
    }
    // A fault first becoming true is a rare structural transition — it flips
    // the fault banner into existence and halts the scan loop, so it still
    // needs an immediate shell rebuild rather than waiting on the throttled
    // tick.
    if (result.faulted && !_faulted) {
      // A transition (guarded by `!_faulted`), not a per-tick event — this
      // fires once when the watchdog trips, never once per scan cycle.
      _logger.log(
        kLogSourceScan,
        LogLevel.warn,
        'Watchdog tripped: task "${result.faultTask}" exceeded its watchdog (code ${result.faultCode})',
      );
      setState(() {
        _faulted = true;
        _faultTaskName = result.faultTask;
        _faultCode = result.faultCode;
        isRunning = false;
      });
    }
    updateSystemStatus(_activeProject, SystemSnapshot(
      fault: _faulted,
      faultTask: _faultTaskName,
      faultCode: _faultCode,
      running: isRunning && !_faulted,
      firstScan: result.firstScan,
      scanCount: _sessionScans,
      scanTimeMs: _lastScanMs,
      maxScanTimeMs: _maxScanMs,
      minScanTimeMs: _minScanMs,
      freeRun: _freeRun,
      uptimeMs: _uptime.elapsedMilliseconds,
      year: now.year, month: now.month, day: now.day,
      hour: now.hour, minute: now.minute, second: now.second,
      dateTime: _formatClock(now),
    ));
    _historian.sample(
      _activeProject.trends,
      (path) {
        final v = readPath(_activeProject, path);
        if (v is bool) {
          return v ? 1.0 : 0.0;
        }
        if (v is num) {
          return v.toDouble();
        }
        return null; // non-numeric (e.g. STRING) is skipped
      },
      DateTime.now().millisecondsSinceEpoch,
    );
    if (consumeAlarmReset(_activeProject)) {
      // An AlarmReset-driven clear is also a rare structural transition
      // (drops the fault banner) — keep it under a targeted setState.
      setState(_clearFault);
    }
    _repaintThrottle.request();
  }

  String _two(int v) => v.toString().padLeft(2, '0');
  String _formatClock(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

  void _clearFault() {
    _faulted = false;
    _faultTaskName = '';
    _faultCode = 0;
    _maxScanMs = 0;
    _minScanMs = 0;
  }

  void _switchActiveProject(PlcProject proj) {
    // Flush any pending edit on the project we're leaving before switching
    // away from it, so a rapid switch right after an edit can't drop it.
    _flushPendingAutosave();
    // OPC UA / Modbus hosting config is per-project — stop the servers
    // before switching so a previous project's port/map doesn't keep serving.
    unawaited(_opcuaHost.stop());
    unawaited(_modbusHost.stop());
    unawaited(_mqttHost.disconnect());
    unawaited(_dnpHost.stop());
    unawaited(_enipHost.stop());
    unawaited(_s7Host.stop());
    unawaited(_finsHost.stop());
    unawaited(_slmpHost.stop());
    ensureSystemTag(proj);
    setState(() {
      _activeProject = proj;
      _resyncHistorian();
      _rekeyViewForProject(proj);
      scanCount = 0;
      _beginProjectSession();
      _history.reset(_snapshot());
      _editorRevision++;
    });
    _logger.log(kLogSourceProject, LogLevel.info,
        'Switched to project "${proj.name}" (${proj.id})');
    unawaited(_repo?.setActiveProjectId(proj.id));
  }

  /// Whether [viewId] is keyed to the active project's HMIs/programs and
  /// should therefore be re-derived whenever the active project changes
  /// (switch/create/duplicate/delete/reset/import) — as opposed to being
  /// source-independent and left alone.
  ///
  /// 'LOGS' is the one view id known to be project-independent (it shows
  /// the app-level diagnostics log, which must survive a project change).
  /// MEMORY/SIMIO:rules/PID_AUTOTUNE/INTERACTION/GATEWAY also render
  /// per-project content today and are deliberately NOT exempted here —
  /// whether they too should survive a project change is a separate,
  /// open product question; this predicate only encodes the LOGS rule
  /// that already existed for `_switchActiveProject`, applied consistently.
  bool _isProjectScopedView(String viewId) => viewId != 'LOGS';

  /// Re-keys `_activeViewId` for [proj] after a project-mutating operation,
  /// unless the currently active view is project-independent (see
  /// [_isProjectScopedView]) — in that case `_activeViewId` is left
  /// untouched so the user isn't silently bounced off it. Must be called
  /// from inside the mutation's `setState` block, after `_activeProject`
  /// has already been reassigned to [proj].
  ///
  /// [fallbackToView] is what `_activeViewId` becomes when [proj] has
  /// neither HMIs nor programs. `_switchActiveProject` omits it (leaving
  /// `_activeViewId` untouched in that case), matching its pre-existing
  /// behavior; every CRUD path (create/duplicate/delete/reset/import)
  /// passes `'MEMORY'`, also matching their pre-existing behavior. This
  /// method only centralizes the preserve-LOGS decision — it does not
  /// change what any call site did when there's no HMI/program to land on.
  void _rekeyViewForProject(PlcProject proj, {String? fallbackToView}) {
    if (!_isProjectScopedView(_activeViewId)) {
      return;
    }
    if (proj.hmis.isNotEmpty) {
      _activeViewId = 'HMI:${proj.hmis.first.id}';
    } else if (proj.programs.isNotEmpty) {
      _activeViewId = 'PROGRAM:${proj.programs.first.name}';
    } else if (fallbackToView != null) {
      _activeViewId = fallbackToView;
    }
  }

  // ── Autosave ─────────────────────────────────────────────────────────

  /// Call after any in-memory mutation of [_activeProject] to (re)start the
  /// debounce window and refresh the UI. Cheap/no-op-safe to call from
  /// every editor callback — repeated calls just push the save out further.
  void _markDirtyAndAutosave() {
    setState(() {});
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(_autosaveDebounce, _runAutosave);
  }

  Future<void> _runAutosave() async {
    _history.capture(_snapshot());
    final repo = _repo;
    if (repo == null) return;
    setState(() {
      _saveInFlight = true;
      _saveFailed = false;
    });
    final projectToSave = _activeProject;
    try {
      await repo.saveProject(projectToSave);
      _logger.log(kLogSourceProject, LogLevel.info,
          'Saved project "${projectToSave.name}" (${projectToSave.id})');
      if (!mounted) return;
      setState(() {
        _saveInFlight = false;
        _savedIndicatorVisible = true;
        _saveFailed = false;
      });
    } catch (e) {
      // Don't let this become an unhandled Future error — reflect the
      // failure in the indicator instead of masking it.
      _logger.log(
        kLogSourceProject,
        LogLevel.error,
        'Autosave failed for project "${projectToSave.name}" (${projectToSave.id})',
        detail: e.toString(),
      );
      if (!mounted) return;
      setState(() {
        _saveInFlight = false;
        _savedIndicatorVisible = false;
        _saveFailed = true;
      });
    }
  }

  /// If a debounced autosave is pending, run it immediately instead of
  /// waiting out the timer (used before switching/closing a project so an
  /// edit made just before the switch isn't lost).
  void _flushPendingAutosave() {
    if (_autosaveTimer == null || !_autosaveTimer!.isActive) return;
    _autosaveTimer!.cancel();
    unawaited(_runAutosave());
  }

  // ── Undo / Redo ──────────────────────────────────────────────────────

  /// Moves one step back in the project history and applies it, if any.
  /// Cancels a pending debounced autosave and captures the current state
  /// first, so an in-flight (not-yet-captured) edit isn't lost off the
  /// front of the undo stack.
  void _undo() {
    _autosaveTimer?.cancel();
    _history.capture(_snapshot());
    final snap = _history.undo();
    if (snap != null) {
      _applySnapshot(snap);
    }
  }

  /// Moves one step forward in the project history and applies it, if any.
  void _redo() {
    _autosaveTimer?.cancel();
    _history.capture(_snapshot());
    final snap = _history.redo();
    if (snap != null) {
      _applySnapshot(snap);
    }
  }

  /// Restores [json] (a `PlcProject.toJson()` snapshot) as the active
  /// project: swaps it into `_allProjects` (by id) and `_activeProject`,
  /// bumps `_editorRevision` so the center editor rebuilds fresh, clears all
  /// runtimes (their internal state no longer matches the restored
  /// project), and re-validates the active view. Schedules a debounced
  /// persist afterward rather than re-capturing synchronously — the
  /// restored snapshot already equals the history baseline, so the next
  /// `_history.capture` call is a no-op.
  void _applySnapshot(String json) {
    final proj = PlcProject.fromJson(jsonDecode(json) as Map<String, dynamic>);
    // The stored snapshot has the System tag's value neutralized (see
    // `_snapshot`) — restore it to well-formed defaults; the running scan
    // loop repopulates the live status fields on the next tick.
    ensureSystemTag(proj);
    setState(() {
      final i = _allProjects.indexWhere((p) => p.id == proj.id);
      if (i != -1) {
        _allProjects[i] = proj;
      }
      _activeProject = proj;
      _resyncHistorian();
      _editorRevision++;
      _beginProjectSession();
      _ensureValidView();
    });
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(_autosaveDebounce, _runAutosave);
  }

  /// Defensive re-validation of `_activeViewId` after a snapshot restore: if
  /// it points at a program or HMI that no longer exists in the (possibly
  /// older/newer) restored project, fall back to the first available HMI or
  /// program, mirroring `_switchActiveProject`'s fallback logic.
  void _ensureValidView() {
    if (_activeViewId.startsWith('HMI:')) {
      final hmiId = _activeViewId.replaceFirst('HMI:', '');
      if (_activeProject.hmis.any((h) => h.id == hmiId)) return;
    } else if (_activeViewId.startsWith('PROGRAM:')) {
      final progName = _activeViewId.replaceFirst('PROGRAM:', '');
      if (_activeProject.programs.any((p) => p.name == progName)) return;
    } else {
      // MEMORY / SIMIO:rules / PID_AUTOTUNE / INTERACTION / GATEWAY / LOGS
      // are always valid views — none of them are keyed to this project's
      // HMIs/programs, so anything not prefixed `HMI:`/`PROGRAM:` is valid
      // regardless of which project is active.
      return;
    }
    if (_activeProject.hmis.isNotEmpty) {
      _activeViewId = 'HMI:${_activeProject.hmis.first.id}';
    } else if (_activeProject.programs.isNotEmpty) {
      _activeViewId = 'PROGRAM:${_activeProject.programs.first.name}';
    } else {
      _activeViewId = 'MEMORY';
    }
  }

  // ── Project CRUD ─────────────────────────────────────────────────────

  /// Prompts for a single line of text via [showAdaptiveWidthDialog] (so it
  /// never overflows a phone) and returns the trimmed result, or null if the
  /// user cancelled or entered nothing.
  Future<String?> _promptForName(
    BuildContext context, {
    required String title,
    required String initialValue,
    required String confirmLabel,
  }) {
    final controller = TextEditingController(text: initialValue);
    return showAdaptiveWidthDialog<String>(
      context,
      child: AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Project Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              Navigator.pop(context, name.isNotEmpty ? name : null);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
  }) async {
    final result = await showAdaptiveWidthDialog<bool>(
      context,
      child: AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _createNewProject() async {
    final repo = _repo;
    if (repo == null) return;
    final name = await _promptForName(
      context,
      title: 'New Project',
      initialValue: 'New Project',
      confirmLabel: 'Create',
    );
    if (name == null) return;

    // Protocol config (incl. hosting) is per-project — stop before switching
    // `_activeProject` to the newly created blank project.
    await _opcuaHost.stop();
    await _modbusHost.stop();
    await _mqttHost.disconnect();
    await _dnpHost.stop();
    await _enipHost.stop();
    await _s7Host.stop();
    await _finsHost.stop();
    await _slmpHost.stop();

    final blank = PlcProject(
      id: 'proj_new_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      controllerName: 'PLC_01',
      tags: [],
      structDefs: [],
      programs: [],
      tasks: [],
      hmis: [],
    );
    await repo.saveProject(blank);
    await repo.setActiveProjectId(blank.id);
    if (!mounted) return;
    setState(() {
      _allProjects.add(blank);
      _activeProject = blank;
      _resyncHistorian();
      _rekeyViewForProject(blank, fallbackToView: 'MEMORY');
      scanCount = 0;
      _beginProjectSession();
      _history.reset(_snapshot());
      _editorRevision++;
    });
    _logger.log(kLogSourceProject, LogLevel.info,
        'Created project "${blank.name}" (${blank.id})');
  }

  Future<void> _duplicateActiveProject() async {
    final repo = _repo;
    if (repo == null) return;
    final originalName = _activeProject.name;
    _flushPendingAutosave();
    // Protocol config (incl. hosting) is per-project — stop before switching
    // `_activeProject` to the duplicate.
    await _opcuaHost.stop();
    await _modbusHost.stop();
    await _mqttHost.disconnect();
    await _dnpHost.stop();
    await _enipHost.stop();
    await _s7Host.stop();
    await _finsHost.stop();
    await _slmpHost.stop();
    final newId = await repo.duplicateProject(_activeProject.id, newName: '${_activeProject.name} Copy');
    final copy = await repo.loadProject(newId);
    if (copy == null) return;
    await repo.setActiveProjectId(copy.id);
    if (!mounted) return;
    setState(() {
      _allProjects.add(copy);
      _activeProject = copy;
      _resyncHistorian();
      _rekeyViewForProject(copy, fallbackToView: 'MEMORY');
      scanCount = 0;
      _beginProjectSession();
      _history.reset(_snapshot());
      _editorRevision++;
    });
    _logger.log(kLogSourceProject, LogLevel.info,
        'Duplicated project "$originalName" as "${copy.name}" (${copy.id})');
  }

  Future<void> _renameActiveProject() async {
    final repo = _repo;
    if (repo == null) return;
    final oldName = _activeProject.name;
    final name = await _promptForName(
      context,
      title: 'Rename Project',
      initialValue: _activeProject.name,
      confirmLabel: 'Rename',
    );
    if (name == null) return;
    await repo.renameProject(_activeProject.id, name);
    if (!mounted) return;
    setState(() {
      _activeProject.name = name;
      // Rename is a project-level operation (like the other CRUD paths): reset
      // the undo history to the renamed state so a later undo can't revert the
      // rename off a stale pre-rename baseline. The active content/view is
      // unchanged, so the editor is not re-keyed (editor state is preserved).
      _history.reset(_snapshot());
    });
    _logger.log(kLogSourceProject, LogLevel.info,
        'Renamed project ${_activeProject.id} from "$oldName" to "$name"');
  }

  Future<void> _deleteActiveProject() async {
    final repo = _repo;
    if (repo == null) return;
    final confirmed = await _confirm(
      context,
      title: 'Delete Project',
      message: 'Delete "${_activeProject.name}"? This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;

    _autosaveTimer?.cancel();
    // Protocol config (incl. hosting) is per-project — stop before deleting.
    await _opcuaHost.stop();
    await _modbusHost.stop();
    await _mqttHost.disconnect();
    await _dnpHost.stop();
    await _enipHost.stop();
    await _s7Host.stop();
    await _finsHost.stop();
    await _slmpHost.stop();
    final deletedId = _activeProject.id;
    final deletedName = _activeProject.name;
    await repo.deleteProject(deletedId);

    var remaining = _allProjects.where((p) => p.id != deletedId).toList();
    if (remaining.isEmpty) {
      await repo.seedDefaultsIfEmpty();
      final catalog = await repo.listProjects();
      remaining = [];
      for (final s in catalog) {
        final p = await repo.loadProject(s.id);
        if (p != null) remaining.add(p);
      }
    }
    if (remaining.isEmpty) {
      // The catalog genuinely yields nothing even after reseeding (e.g. a
      // corrupt store that can't be written/read back). Fall back to
      // in-memory defaults for THIS session only rather than an unguarded
      // `.first` — `repo` itself is left untouched so future saves still
      // go through it.
      remaining = DefaultProjects.all();
    }
    final next = remaining.first;
    await repo.setActiveProjectId(next.id);
    if (!mounted) return;
    setState(() {
      _allProjects = remaining;
      _activeProject = next;
      _resyncHistorian();
      _rekeyViewForProject(next, fallbackToView: 'MEMORY');
      scanCount = 0;
      _beginProjectSession();
      _history.reset(_snapshot());
      _editorRevision++;
    });
    _logger.log(kLogSourceProject, LogLevel.info,
        'Deleted project "$deletedName" ($deletedId)');
  }

  Future<void> _resetToDefaults() async {
    final repo = _repo;
    if (repo == null) return;
    final confirmed = await _confirm(
      context,
      title: 'Reset to Defaults',
      message: 'This deletes ALL projects (including your edits) and restores the built-in defaults. Continue?',
      confirmLabel: 'Reset',
    );
    if (!confirmed) return;

    _autosaveTimer?.cancel();
    // Protocol config (incl. hosting) is per-project — stop before reset.
    await _opcuaHost.stop();
    await _modbusHost.stop();
    await _mqttHost.disconnect();
    await _dnpHost.stop();
    await _enipHost.stop();
    await _s7Host.stop();
    await _finsHost.stop();
    await _slmpHost.stop();
    await repo.resetToDefaults();
    final catalog = await repo.listProjects();
    var loaded = <PlcProject>[];
    for (final s in catalog) {
      final p = await repo.loadProject(s.id);
      if (p != null) loaded.add(p);
    }
    if (loaded.isEmpty) {
      // resetToDefaults should always leave the catalog non-empty, but
      // guard against a corrupt store yielding nothing back rather than
      // an unguarded `.first`.
      loaded = DefaultProjects.all();
    }
    final first = loaded.first;
    await repo.setActiveProjectId(first.id);
    if (!mounted) return;
    setState(() {
      _allProjects = loaded;
      _activeProject = first;
      _resyncHistorian();
      _rekeyViewForProject(first, fallbackToView: 'MEMORY');
      scanCount = 0;
      _beginProjectSession();
      _history.reset(_snapshot());
      _editorRevision++;
    });
    _logger.log(kLogSourceProject, LogLevel.warn, 'Reset all projects to defaults');
  }

  // ── Export / Import (cross-device transfer) ─────────────────────────
  //
  // There is no cloud sync in this app, so moving a project between a
  // phone and a computer happens by hand: export writes the active
  // project to a `.splc.json` file and hands it to the OS share/save
  // sheet; import reads a `.splc.json` file back in. The actual
  // encode/decode is the pure `ProjectTransfer` service (unit-tested
  // without plugins); these two methods are the thin plugin-touching
  // wrappers around it.

  Future<void> _exportActiveProject() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final json = ProjectTransfer.encodeProject(_activeProject);
      final fileName = ProjectTransfer.suggestFileName(_activeProject);
      final bytes = Uint8List.fromList(utf8.encode(json));
      await Share.shareXFiles(
        [XFile.fromData(bytes, name: fileName, mimeType: 'application/json')],
        fileNameOverrides: [fileName],
        subject: fileName,
      );
      _logger.log(kLogSourceProject, LogLevel.info,
          'Exported project "${_activeProject.name}" as $fileName');
    } catch (e) {
      _logger.log(
        kLogSourceProject,
        LogLevel.warn,
        'Export failed for project "${_activeProject.name}"',
        detail: e.toString(),
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't export: something went wrong sharing the file")),
      );
    }
  }

  Future<void> _importProject() async {
    final messenger = ScaffoldMessenger.of(context);
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
    } catch (e) {
      _logger.log(kLogSourceProject, LogLevel.warn, 'Import: file picker failed',
          detail: e.toString());
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't open the file picker")),
      );
      return;
    }
    if (picked == null || picked.files.isEmpty) return; // user cancelled

    final file = picked.files.single;
    String? text;
    try {
      final bytes = file.bytes;
      if (bytes != null) {
        text = utf8.decode(bytes);
      }
    } catch (e) {
      _logger.log(kLogSourceProject, LogLevel.warn,
          'Import: failed to decode the selected file as UTF-8', detail: e.toString());
      text = null;
    }
    if (text == null) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't import: unable to read the selected file")),
      );
      return;
    }

    PlcProject imported;
    try {
      imported = ProjectTransfer.decodeProject(text);
    } on FormatException catch (e) {
      _logger.log(kLogSourceProject, LogLevel.warn, 'Import: not a valid project file',
          detail: e.toString());
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't import: not a valid project file")),
      );
      return;
    } catch (e) {
      _logger.log(kLogSourceProject, LogLevel.warn, 'Import: not a valid project file',
          detail: e.toString());
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't import: not a valid project file")),
      );
      return;
    }

    final existingIds = _allProjects.map((p) => p.id).toSet();
    imported = ProjectTransfer.reassignIdIfColliding(imported, existingIds);

    await _applyImportedProject(imported);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text('Imported "${imported.name}"')));
  }

  /// Applies a decoded/collision-resolved [imported] project as the new
  /// active project: stops the per-project protocol hosts, persists it
  /// (when a repository is available), and swaps it into the in-memory
  /// session. Split out of `_importProject` so the plugin-touching file
  /// picker step (untestable via a mocked platform channel — see
  /// `debugImportProject`'s doc comment) is separate from this pure
  /// state-mutation tail.
  Future<void> _applyImportedProject(PlcProject imported) async {
    _flushPendingAutosave();
    // Protocol config (incl. hosting) is per-project — stop before import
    // switches `_activeProject` out from under a running host.
    await _opcuaHost.stop();
    await _modbusHost.stop();
    await _mqttHost.disconnect();
    await _dnpHost.stop();
    await _enipHost.stop();
    await _s7Host.stop();
    await _finsHost.stop();
    await _slmpHost.stop();
    final repo = _repo;
    if (repo != null) {
      await repo.saveProject(imported);
      await repo.setActiveProjectId(imported.id);
    }
    // Import into the in-memory session either way (also covers the
    // non-persistent fallback where `_repo` is null).
    if (!mounted) return;
    setState(() {
      _allProjects.add(imported);
      _activeProject = imported;
      _resyncHistorian();
      _rekeyViewForProject(imported, fallbackToView: 'MEMORY');
      scanCount = 0;
      _beginProjectSession();
      _history.reset(_snapshot());
      _editorRevision++;
    });
    _logger.log(kLogSourceProject, LogLevel.info,
        'Imported project "${imported.name}" (${imported.id})');
  }

  /// Renders the autosave status indicator. On [compact] widths the label
  /// text is dropped (icon + tooltip only) so the indicator can't push the
  /// AppBar title/actions into overflow on narrow phones (360/320px) —
  /// the tooltip still carries the full message on long-press/hover.
  Widget _buildSaveStatus({required bool compact}) {
    if (_repo == null) {
      // Persistence is genuinely unavailable this session (in-memory
      // fallback truly engaged) — never pretend to save. Visible but
      // unobtrusive so a real failure is surfaced rather than masked.
      return Tooltip(
        message: 'Storage unavailable — changes will not be saved between sessions',
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.amber),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 12, color: Colors.amberAccent),
              if (!compact) ...[
                const SizedBox(width: 4),
                const Text('Not saved', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
              ],
            ],
          ),
        ),
      );
    }
    if (_saveInFlight) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amberAccent)),
          if (!compact) ...[
            const SizedBox(width: 6),
            const Text('Saving…', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
          ],
        ],
      );
    }
    if (_saveFailed) {
      return Tooltip(
        message: 'The last save attempt failed. Your edits are still in memory.',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 12, color: Colors.redAccent),
            if (!compact) ...[
              const SizedBox(width: 4),
              const Text('Save failed ⚠', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
            ],
          ],
        ),
      );
    }
    if (_savedIndicatorVisible) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 12, color: Colors.greenAccent),
          if (!compact) ...[
            const SizedBox(width: 4),
            const Text('Saved', style: TextStyle(fontSize: 11, color: Colors.greenAccent)),
          ],
        ],
      );
    }
    return const SizedBox.shrink();
  }

  void _deleteProgram(String progName) {
    setState(() {
      _activeProject.programs.removeWhere((p) => p.name == progName);
      for (var task in _activeProject.tasks) {
        task.programNames.remove(progName);
      }
      if (_activeViewId == 'PROGRAM:$progName') {
        if (_activeProject.hmis.isNotEmpty) {
          _activeViewId = 'HMI:${_activeProject.hmis.first.id}';
        } else {
          _activeViewId = 'MEMORY';
        }
      }
    });
    _markDirtyAndAutosave();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Program "$progName" deleted')));
  }

  /// Delete [task], unless doing so would leave any of its programs in no
  /// other task ("orphaned"). Returns true if deleted, false if refused.
  bool _deleteTask(PlcTask task) {
    for (final prog in task.programNames) {
      final elsewhere = _activeProject.tasks.any((t) => t != task && t.programNames.contains(prog));
      if (!elsewhere) {
        return false; // 'prog' would be orphaned
      }
    }
    setState(() => _activeProject.tasks.remove(task));
    _markDirtyAndAutosave();
    return true;
  }

  /// Attempts to delete [task] via [_deleteTask]; on refusal, shows a
  /// SnackBar naming the program that would be left with no task.
  void _confirmDeleteTask(PlcTask task) {
    if (_deleteTask(task)) {
      return;
    }
    final orphan = task.programNames.firstWhere(
      (prog) => !_activeProject.tasks.any((t) => t != task && t.programNames.contains(prog)),
      orElse: () => '',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Can\'t delete — "$orphan" would be left with no task. Assign it elsewhere first.')),
    );
  }

  void _addNewHmiDashboard() {
    showDialog(
      context: context,
      builder: (ctx) {
        final titleCtrl = TextEditingController(text: 'Custom HMI Dashboard');
        return AlertDialog(
          title: const Text('Add New HMI Dashboard'),
          content: TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Dashboard Title')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final newHmi = HmiScreenDef(
                  id: 'hmi_${DateTime.now().millisecondsSinceEpoch}',
                  title: titleCtrl.text,
                  layoutType: 'GridDashboard',
                  components: [],
                );
                setState(() {
                  _activeProject.hmis.add(newHmi);
                  _activeViewId = 'HMI:${newHmi.id}';
                });
                _markDirtyAndAutosave();
                Navigator.pop(ctx);
              },
              child: const Text('Create HMI Dashboard'),
            ),
          ],
        );
      },
    );
  }

  void _openTagDock(BuildContext context) {
    if (context.isExpanded) {
      setState(() => isTagDockVisible = !isTagDockVisible);
    } else {
      _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    _buildCount++;
    if (_booting) {
      return const Scaffold(
        backgroundColor: Color(0xFF0F172A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.cyanAccent),
              SizedBox(height: 16),
              Text('Loading projects…', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    final expanded = context.isExpanded;
    final compact = context.isCompact;
    final short = context.isShort;
    // The Scan Loop Speed bar always shows on taller viewports; on a short
    // (landscape-phone) viewport it is collapsed until the app-bar toggle
    // reveals it, to reclaim vertical space.
    final showScanBar = !short || _scanBarVisibleInShort;

    return LiveTickScope(
      notifier: _liveTick,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
          const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _redo,
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
          const SingleActivator(LogicalKeyboardKey.keyY, meta: true): _redo,
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): _redo,
        },
        child: Focus(
          autofocus: true,
          child: _buildScaffold(context,
              expanded: expanded, compact: compact, short: short, showScanBar: showScanBar),
        ),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context,
      {required bool expanded, required bool compact, required bool short, required bool showScanBar}) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Row(
          children: [
            // Dropped on compact widths: the AppBar actions row is already
            // busy (run/pause, tag toggle, undo/redo, overflow menu), so
            // this purely-decorative icon is the cheapest thing to shed to
            // keep the title's Flexible text from being squeezed into an
            // overflow, including during transient (mid-animation, e.g.
            // Drawer opening) frames where the available width briefly
            // narrows further than its settled value.
            if (!compact) ...[
              const Icon(Icons.memory, color: Colors.cyan, size: 22),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                'Soft PLC Simulator — ${_activeProject.name}',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            SizedBox(width: compact ? 4 : 10),
            _buildSaveStatus(compact: compact),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        // Shorter bar on a short (landscape-phone) viewport to reclaim height.
        toolbarHeight: short ? 46 : null,
        actions: _buildAppBarActions(context, compact: compact, short: short),
      ),
      drawer: expanded ? null : Drawer(child: _buildLeftDockContent()),
      endDrawer: expanded
          ? null
          : Drawer(
              width: math.min(340, MediaQuery.sizeOf(context).width * 0.9),
              child: TagInspectorDock(
                project: _activeProject,
                tags: _activeProject.tags,
                onTagStateChanged: _markDirtyAndAutosave,
                onClose: () {
                  Navigator.pop(context);
                  setState(() => isTagDockVisible = false);
                },
              ),
            ),
      body: Column(
        children: [
          // Watchdog fault banner. Placed at the very top of the body (above
          // the scan toolbar) so it can never be pushed off-screen or cause a
          // RenderFlex overflow — it's a plain top-of-column block, not
          // competing with the toolbar's Row for width.
          if (_faulted)
            MaterialBanner(
              backgroundColor: Colors.red.shade900,
              content: Text(
                'PLC FAULT — watchdog on task "$_faultTaskName" (code $_faultCode). '
                'Scan halted.',
                style: const TextStyle(color: Colors.white),
              ),
              leading: const Icon(Icons.warning_amber, color: Colors.white),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      // Pulse System.AlarmReset so any logic/HMI observers
                      // watching that tag also see the reset edge, not just
                      // the shell's own fault flag.
                      writePath(_activeProject, 'System.AlarmReset', true);
                      consumeAlarmReset(_activeProject);
                      _clearFault();
                    });
                  },
                  child: const Text('Clear Fault', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),

          // PLC Execution Controls Toolbar (Scan Speed Slider cleanly placed to avoid clipping)
          if (showScanBar) ...[
          Container(
            key: const Key('scanSpeedBar'),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: short ? 2 : 6),
            color: const Color(0xFF0F172A),
            child: Row(
              children: [
                const Icon(Icons.speed, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                if (!compact && !short) ...[
                  const Text('SCAN LOOP SPEED:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: SliderTheme(
                    // Slimmer slider (thinner track, smaller thumb/overlay) on a
                    // short viewport so the on-demand bar stays low-profile.
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: short ? 2 : null,
                      thumbShape: short ? const RoundSliderThumbShape(enabledThumbRadius: 6) : null,
                      overlayShape: short ? const RoundSliderOverlayShape(overlayRadius: 12) : null,
                    ),
                    child: Slider(
                      value: scanSpeedMs.toDouble(),
                      min: 50.0,
                      max: 2000.0,
                      divisions: 39,
                      activeColor: scanSpeedMs > 500 ? Colors.amber : Colors.cyan,
                      onChanged: (val) {
                        setState(() {
                          scanSpeedMs = val.round();
                        });
                        _startScanLoop();
                      },
                    ),
                  ),
                ),
                Text(
                  (compact || short) ? '${scanSpeedMs}ms' : '${scanSpeedMs}ms ${scanSpeedMs >= 500 ? "(Slow Mo Step)" : ""}',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: scanSpeedMs >= 500 ? Colors.amberAccent : Colors.cyanAccent,
                  ),
                ),
                if (!compact && !short) ...[
                  const Spacer(),
                  // Reads the reserved `System.ScanCount` tag (written every
                  // scan by `updateSystemStatus`) inside a LiveTick-driven
                  // ListenableBuilder, so this counter keeps repainting once
                  // a later phase removes the shell's per-scan setState. A
                  // `Builder` gets a BuildContext BELOW the `LiveTickScope`
                  // this same `build()` method creates — the outer `context`
                  // parameter is the shell's own element, an ANCESTOR of
                  // that scope, so `LiveTickScope.of` would fail to find it.
                  Builder(
                    builder: (context) => ListenableBuilder(
                      listenable: LiveTickScope.of(context),
                      builder: (context, child) {
                        final count = readPath(_activeProject, 'System.ScanCount');
                        return Text('Scan Count: $count', style: const TextStyle(fontSize: 12, color: Colors.grey, fontFamily: 'monospace'));
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          ],

          // Main Shell Layout
          Expanded(
            child: expanded
                ? Row(
                    children: [
                      // LEFT DOCK: Project Tree & Navigation Explorer
                      _buildLeftDockExplorer(),

                      const VerticalDivider(width: 1, color: Colors.white12),

                      // CENTER WORKSPACE: Active View (HMI, Language Editors, or Memory Manager)
                      Expanded(
                        child: KeyedSubtree(
                          key: ValueKey('editor-$_editorRevision-$_activeViewId'),
                          child: _buildCenterWorkspace(),
                        ),
                      ),

                      // RIGHT DOCK: Toggleable Tag Inspector & Forcing Matrix
                      if (isTagDockVisible) ...[
                        const VerticalDivider(width: 1, color: Colors.white12),
                        TagInspectorDock(
                          project: _activeProject,
                          tags: _activeProject.tags,
                          onTagStateChanged: _markDirtyAndAutosave,
                          onClose: () => setState(() => isTagDockVisible = false),
                        ),
                      ],
                    ],
                  )
                : KeyedSubtree(
                    key: ValueKey('editor-$_editorRevision-$_activeViewId'),
                    child: _buildCenterWorkspace(),
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildAppBarActions(BuildContext context, {required bool compact, required bool short}) {
    // Run / Pause Toggle. Compact iconSize/padding matches undo/redo/
    // freeRunToggle below — with the free-run toggle added, the compact
    // AppBar now packs 6 tap targets at 320/360px, so every action here must
    // shed the default 48px tap-target padding to avoid squeezing
    // NavigationToolbar's custom layout (which, unlike a Flex, can silently
    // overlap the leading hamburger under the actions row instead of
    // throwing an overflow error when it runs out of room).
    final runToggle = IconButton(
      icon: Icon(
        isRunning ? Icons.pause_circle_filled : Icons.play_circle_fill,
        color: isRunning ? Colors.amber : Colors.greenAccent,
        size: compact ? 22 : 26,
      ),
      tooltip: isRunning ? 'Pause Scan Loop' : 'Run Scan Loop',
      padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : const EdgeInsets.all(8),
      constraints: compact ? const BoxConstraints() : null,
      onPressed: () {
        final resuming = !isRunning;
        setState(() {
          if (resuming) {
            _startRunSession();
          }
          isRunning = !isRunning;
        });
        if (resuming) {
          // Stopped -> running: re-arm the free-run zero-delay chain, which
          // idled while paused (see _startScanLoop). No-op cost in fixed
          // mode — _startScanLoop() cancels+recreates the same
          // Timer.periodic, it does not double-schedule.
          _startScanLoop();
        } else {
          _logger.log(kLogSourceScan, LogLevel.info, 'Scan engine paused');
        }
      },
    );

    // Free-run / fixed-scan mode toggle. Compact iconSize/padding matches the
    // undo/redo buttons below so it doesn't push the already-tight compact
    // AppBar (run/pause + tag toggle + undo/redo + overflow at 320/360px)
    // into overflow.
    final freeRunToggle = IconButton(
      icon: Icon(
        _freeRun ? Icons.fast_forward : Icons.timer_outlined,
        color: _freeRun ? Colors.orangeAccent : Colors.grey,
        size: compact ? 20 : 24,
      ),
      tooltip: _freeRun ? 'Free-run (as fast as allowed)' : 'Fixed scan (${scanSpeedMs}ms)',
      padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : const EdgeInsets.all(8),
      constraints: compact ? const BoxConstraints() : null,
      onPressed: () {
        setState(() => _freeRun = !_freeRun);
        _startScanLoop();
      },
    );

    // Show/hide the (collapsed-by-default) Scan Loop Speed bar — only surfaced
    // on a short (landscape-phone) viewport, where the bar is hidden to
    // reclaim vertical space.
    final scanBarToggle = IconButton(
      icon: Icon(Icons.speed, color: _scanBarVisibleInShort ? Colors.cyanAccent : Colors.grey, size: compact ? 20 : 24),
      tooltip: _scanBarVisibleInShort ? 'Hide scan speed bar' : 'Show scan speed bar',
      padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : const EdgeInsets.all(8),
      constraints: compact ? const BoxConstraints() : null,
      onPressed: () => setState(() => _scanBarVisibleInShort = !_scanBarVisibleInShort),
    );

    // Toggle Tag Inspector Side Dock / End Drawer
    final tagToggle = IconButton(
      icon: Icon(Icons.table_chart, color: isTagDockVisible ? Colors.cyanAccent : Colors.grey, size: compact ? 20 : 24),
      tooltip: 'Toggle Tag Inspector Side Dock',
      padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : const EdgeInsets.all(8),
      constraints: compact ? const BoxConstraints() : null,
      onPressed: () => _openTagDock(context),
    );

    // Opens the SoftPLC Settings dialog (UI refresh rate, etc.). Only used
    // inline on expanded/medium widths — the compact layout instead surfaces
    // it as a menu entry in the overflow `PopupMenuButton` below, to avoid
    // adding another inline tap target to the already-tight compact row.
    final settingsButton = IconButton(
      icon: const Icon(Icons.settings, color: Colors.grey),
      tooltip: 'SoftPLC Settings',
      onPressed: () => _openSoftPlcSettings(context),
    );

    // Undo / Redo project history. On compact widths the AppBar is already
    // tight (run/pause + tag toggle + these two + overflow menu all have to
    // fit at 360px), so trim the tap-target padding down from the default
    // 48px minimum to keep the row from overflowing.
    final undoButton = IconButton(
      icon: const Icon(Icons.undo),
      tooltip: 'Undo',
      onPressed: _history.canUndo ? _undo : null,
      iconSize: compact ? 20 : 24,
      padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : const EdgeInsets.all(8),
      constraints: compact ? const BoxConstraints() : null,
    );
    final redoButton = IconButton(
      icon: const Icon(Icons.redo),
      tooltip: 'Redo',
      onPressed: _history.canRedo ? _redo : null,
      iconSize: compact ? 20 : 24,
      padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : const EdgeInsets.all(8),
      constraints: compact ? const BoxConstraints() : null,
    );

    if (!compact) {
      // Expanded / medium: keep the full original action set.
      return [
        runToggle,

        // Step Scan Button (for step-by-step debugging)
        IconButton(
          icon: const Icon(Icons.skip_next, color: Colors.cyanAccent, size: 26),
          tooltip: 'Execute Single Scan Step (Step Scan)',
          onPressed: () => _executeScan(),
        ),

        undoButton,
        redoButton,
        freeRunToggle,
        if (short) scanBarToggle,

        const SizedBox(width: 12),

        // Status Badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isRunning ? Colors.green.withValues(alpha: 0.2) : Colors.amber.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isRunning ? Colors.green : Colors.amber),
          ),
          child: Text(
            isRunning ? 'RUNNING' : 'PAUSED',
            style: TextStyle(color: isRunning ? Colors.green : Colors.amber, fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),

        const SizedBox(width: 16),

        tagToggle,
        settingsButton,

        const SizedBox(width: 12),
      ];
    }

    // Compact: keep only run/stop + tag-toggle + undo/redo inline; overflow
    // the rest into a menu. Undo/Redo use their own small footprint
    // (default IconButton constraints already trimmed by the AppBar) so
    // adding two more icons here does not overflow at 320px.
    //
    // The free-run toggle deliberately goes into this overflow menu rather
    // than inline: empirically, a 6th inline IconButton in this row (even
    // with every button's tap target trimmed down) pushes the AppBar's
    // internal NavigationToolbar layout — a CustomMultiChildLayout, not a
    // Flex, so it never throws a RenderFlex-overflow assertion — past a
    // threshold where it silently paints the trailing actions group
    // overlapping the leading hamburger button at 320px width, making the
    // hamburger untappable. Routing it through the menu instead keeps this
    // row at its known-good size while still exposing the toggle from the
    // app-bar actions on compact widths.
    return [
      runToggle,
      tagToggle,
      undoButton,
      redoButton,
      PopupMenuButton<String>(
        tooltip: 'More actions',
        icon: const Icon(Icons.more_vert),
        onSelected: (value) {
          if (value == 'step') {
            _executeScan();
          } else if (value == 'freerun') {
            setState(() => _freeRun = !_freeRun);
            _startScanLoop();
          } else if (value == 'scanbar') {
            setState(() => _scanBarVisibleInShort = !_scanBarVisibleInShort);
          } else if (value == 'settings') {
            _openSoftPlcSettings(context);
          }
        },
        itemBuilder: (ctx) => [
          const PopupMenuItem(
            value: 'step',
            child: ListTile(
              leading: Icon(Icons.skip_next),
              title: Text('Step Scan'),
            ),
          ),
          PopupMenuItem(
            value: 'freerun',
            child: ListTile(
              leading: Icon(_freeRun ? Icons.fast_forward : Icons.timer_outlined, color: _freeRun ? Colors.orangeAccent : Colors.grey),
              title: Text(_freeRun ? 'Free-run (as fast as allowed)' : 'Fixed scan (${scanSpeedMs}ms)'),
            ),
          ),
          if (short)
            PopupMenuItem(
              value: 'scanbar',
              child: ListTile(
                leading: Icon(Icons.speed, color: _scanBarVisibleInShort ? Colors.cyanAccent : Colors.grey),
                title: Text(_scanBarVisibleInShort ? 'Hide scan speed bar' : 'Show scan speed bar'),
              ),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'settings',
            child: ListTile(
              leading: Icon(Icons.settings),
              title: Text('Settings'),
            ),
          ),
          PopupMenuItem(
            enabled: false,
            child: ListTile(
              leading: Icon(
                isRunning ? Icons.circle : Icons.pause_circle,
                color: isRunning ? Colors.green : Colors.amber,
                size: 16,
              ),
              title: Text(isRunning ? 'RUNNING' : 'PAUSED'),
            ),
          ),
        ],
      ),
      const SizedBox(width: 4),
    ];
  }

  Widget _buildLeftDockExplorer() {
    return Container(
      width: 280,
      color: const Color(0xFF0F172A),
      child: _buildLeftDockContent(),
    );
  }

  /// Selects [viewId] and, if this content is hosted inside a [Drawer]
  /// (i.e. we're on a compact width where the drawer is the only way the
  /// left dock is shown), closes the drawer first so the newly active view
  /// is visible immediately.
  void _selectView(BuildContext context, String viewId) {
    if (!context.isExpanded) {
      Navigator.pop(context);
    }
    setState(() => _activeViewId = viewId);
  }

  /// The inner content of the left dock — shared by the inline (expanded,
  /// fixed width 280) dock and the compact `Drawer` (which supplies its own
  /// width), so it must not declare a fixed width itself.
  Widget _buildLeftDockContent() {
    return Container(
      color: const Color(0xFF0F172A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Projects Switcher Header
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF1E293B),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('SELECT PROJECT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey, letterSpacing: 0.5)),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: DropdownButton<String>(
                        value: _activeProject.id,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF1E293B),
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                        items: _allProjects.map((p) {
                          final isActive = p.id == _activeProject.id;
                          return DropdownMenuItem(
                            value: p.id,
                            child: Row(
                              children: [
                                Icon(isActive ? Icons.check_circle : Icons.folder, size: 16, color: isActive ? Colors.greenAccent : Colors.grey),
                                const SizedBox(width: 8),
                                Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                              ],
                            ),
                          );
                        }).toList(),
                        onChanged: (id) {
                          if (id != null) {
                            final selected = _allProjects.firstWhere((p) => p.id == id);
                            _switchActiveProject(selected);
                          }
                        },
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Project actions',
                      icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
                      padding: EdgeInsets.zero,
                      color: const Color(0xFF1E293B),
                      onSelected: (value) {
                        switch (value) {
                          case 'new':
                            _createNewProject();
                            break;
                          case 'duplicate':
                            _duplicateActiveProject();
                            break;
                          case 'rename':
                            _renameActiveProject();
                            break;
                          case 'delete':
                            _deleteActiveProject();
                            break;
                          case 'reset':
                            _resetToDefaults();
                            break;
                          case 'export':
                            _exportActiveProject();
                            break;
                          case 'import':
                            _importProject();
                            break;
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'new',
                          child: _ProjectMenuEntry(icon: Icons.add, label: 'New Project'),
                        ),
                        PopupMenuItem(
                          value: 'duplicate',
                          child: _ProjectMenuEntry(icon: Icons.copy_all, label: 'Duplicate Project'),
                        ),
                        PopupMenuItem(
                          value: 'rename',
                          child: _ProjectMenuEntry(icon: Icons.drive_file_rename_outline, label: 'Rename Project'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: _ProjectMenuEntry(icon: Icons.delete_outline, label: 'Delete Project'),
                        ),
                        PopupMenuItem(
                          value: 'reset',
                          child: _ProjectMenuEntry(icon: Icons.restore, label: 'Reset to Defaults'),
                        ),
                        PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'export',
                          child: _ProjectMenuEntry(icon: Icons.ios_share, label: 'Export Project'),
                        ),
                        PopupMenuItem(
                          value: 'import',
                          child: _ProjectMenuEntry(icon: Icons.file_open_outlined, label: 'Import Project'),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Active Project Tree Navigation
          Expanded(
            child: ListView(
              key: const Key('nav_tree'),
              padding: const EdgeInsets.all(8),
              children: [
                // Project Header Info
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.account_tree, color: Colors.cyan, size: 20),
                    title: Text(_activeProject.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Text('${_activeProject.controllerName} (${_activeProject.scanPeriodMs}ms)', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ),
                ),

                const Divider(height: 16, color: Colors.white12),

                // SECTION 1: HMI Dashboards Folder
                _buildTreeFolderHeader('HMI DASHBOARDS', Icons.dashboard_outlined),
                ..._activeProject.hmis.map((hmi) {
                  final isSelected = _activeViewId == 'HMI:${hmi.id}';
                  return Container(
                    margin: const EdgeInsets.only(left: 12, top: 2),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.monitor, size: 16, color: isSelected ? Colors.cyanAccent : Colors.grey),
                        title: Text(hmi.title, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                        onTap: () => _selectView(context, 'HMI:${hmi.id}'),
                      ),
                    ),
                  );
                }),

                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 4, bottom: 8),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text('Add HMI Dashboard', style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.tealAccent,
                      side: const BorderSide(color: Colors.tealAccent),
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    ),
                    onPressed: _addNewHmiDashboard,
                  ),
                ),

                const SizedBox(height: 8),

                // SECTION 2: MEMORY (Tags & Structs)
                _buildTreeFolderHeader('MEMORY (TAGS & STRUCTS)', Icons.storage),
                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'MEMORY' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.memory, size: 16, color: _activeViewId == 'MEMORY' ? Colors.cyanAccent : Colors.tealAccent),
                      title: Text(
                        'Tags & Structs (${_activeProject.tags.length} Tags, ${_activeProject.structDefs.length} Structs)',
                        style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'MEMORY' ? FontWeight.bold : FontWeight.normal),
                      ),
                      onTap: () => _selectView(context, 'MEMORY'),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'SIMIO:rules' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.sensors, size: 16, color: _activeViewId == 'SIMIO:rules' ? Colors.cyanAccent : Colors.tealAccent),
                      title: Text(
                        'SIMULATED I/O (${_activeProject.simRules.length})',
                        style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'SIMIO:rules' ? FontWeight.bold : FontWeight.normal),
                      ),
                      onTap: () => _selectView(context, 'SIMIO:rules'),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'PID_AUTOTUNE' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.tune, size: 16, color: _activeViewId == 'PID_AUTOTUNE' ? Colors.cyanAccent : Colors.tealAccent),
                      title: Text(
                        'PID AUTO-TUNE',
                        style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'PID_AUTOTUNE' ? FontWeight.bold : FontWeight.normal),
                      ),
                      onTap: () => _selectView(context, 'PID_AUTOTUNE'),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'INTERACTION' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.grain, size: 16, color: _activeViewId == 'INTERACTION' ? Colors.cyanAccent : Colors.tealAccent),
                      title: Text(
                        'INTERACTION ANALYSIS',
                        style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'INTERACTION' ? FontWeight.bold : FontWeight.normal),
                      ),
                      onTap: () => _selectView(context, 'INTERACTION'),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'GATEWAY' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.hub, size: 16, color: _activeViewId == 'GATEWAY' ? Colors.cyanAccent : Colors.tealAccent),
                      title: Text(
                        'Outbound Protocols',
                        style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'GATEWAY' ? FontWeight.bold : FontWeight.normal),
                      ),
                      onTap: () => _selectView(context, 'GATEWAY'),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                Container(
                  margin: const EdgeInsets.only(left: 12, top: 2),
                  decoration: BoxDecoration(
                    color: _activeViewId == 'LOGS' ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.list_alt, size: 16, color: _activeViewId == 'LOGS' ? Colors.cyanAccent : Colors.tealAccent),
                      title: Text(
                        'Logs',
                        style: TextStyle(fontSize: 11, fontWeight: _activeViewId == 'LOGS' ? FontWeight.bold : FontWeight.normal),
                      ),
                      onTap: () => _selectView(context, 'LOGS'),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // SECTION 3: Tasks & Programs Classified by Task Type & Language
                _buildTreeFolderHeader('TASKS & IEC 61131-3 LOGIC', Icons.folder_special_outlined),

                _buildTaskCategoryFolder('Startup Tasks', Icons.play_arrow, 'Startup'),
                _buildTaskCategoryFolder('Continuous Tasks', Icons.loop, 'Continuous'),
                _buildTaskCategoryFolder('Periodic Tasks', Icons.timer, 'Periodic'),
                _buildTaskCategoryFolder('Event Tasks', Icons.bolt, 'Event'),

                const SizedBox(height: 16),

                // Add Task Button
                OutlinedButton.icon(
                  icon: const Icon(Icons.add_task, size: 16),
                  label: const Text('Add Task'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.tealAccent,
                    side: const BorderSide(color: Colors.tealAccent),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: _showAddTaskDialog,
                ),

                const SizedBox(height: 8),

                // Add Program Button
                OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add New Program'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.cyan,
                    side: const BorderSide(color: Colors.cyan),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: _showAddProgramDialog,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeFolderHeader(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey, letterSpacing: 0.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCategoryFolder(String title, IconData icon, String taskType) {
    final tasksOfType = _activeProject.tasks.where((t) => t.type == taskType).toList();
    final programCount = tasksOfType.fold<int>(0, (sum, t) => sum + t.programNames.length);

    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: Colors.tealAccent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$title ($programCount)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
                ),
              ),
            ],
          ),

          if (tasksOfType.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 20, top: 2, bottom: 4),
              child: Text('(none configured)', style: TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic)),
            )
          else
            ...tasksOfType.map(_buildTaskRow),
        ],
      ),
    );
  }

  /// A single task row: task name + enabled indicator + edit/delete
  /// IconButtons, with its assigned programs listed underneath (indented).
  Widget _buildTaskRow(PlcTask task) {
    return Container(
      margin: const EdgeInsets.only(left: 20, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                task.enabled ? Icons.check_circle_outline : Icons.pause_circle_outline,
                size: 12,
                color: task.enabled ? Colors.greenAccent : Colors.grey,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 14, color: Colors.cyanAccent),
                iconSize: 14,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                tooltip: 'Edit Task',
                onPressed: () => _showEditTaskDialog(task),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent),
                iconSize: 14,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                tooltip: 'Delete Task',
                onPressed: () => _confirmDeleteTask(task),
              ),
            ],
          ),
          if (task.programNames.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 16, top: 2, bottom: 4),
              child: Text('(no programs assigned)', style: TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic)),
            )
          else
            ...task.programNames.map(_buildProgramRow),
        ],
      ),
    );
  }

  Widget _buildProgramRow(String progName) {
    final prog = _activeProject.programs.firstWhere((p) => p.name == progName, orElse: () => PlcProgram(name: progName, language: 'StructuredText'));
    final isSelected = _activeViewId == 'PROGRAM:$progName';

    String badgeText = 'ST';
    Color badgeColor = Colors.blue;
    if (prog.language == 'LadderLogic') { badgeText = 'LD'; badgeColor = Colors.orange; }
    if (prog.language == 'FunctionBlockDiagram') { badgeText = 'FBD'; badgeColor = Colors.teal; }
    if (prog.language == 'SequentialFunctionChart') { badgeText = 'SFC'; badgeColor = Colors.purple; }

    return Container(
      margin: const EdgeInsets.only(left: 16, top: 2),
      decoration: BoxDecoration(
        color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
          leading: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(badgeText, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
          ),
          title: Text(prog.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Delete Program',
            onPressed: () => _deleteProgram(prog.name),
          ),
          onTap: () => _selectView(context, 'PROGRAM:$progName'),
        ),
      ),
    );
  }

  /// Shared save path for "Add Program" whether it assigns to an existing
  /// task or (via the "＋ New task…" sentinel) creates one on the spot. The
  /// dialog and [debugAddProgramToNewTask] both funnel through this so the
  /// UI and the test exercise one implementation.
  /// Creates [taskName]/[taskType] and files a new [programName] under it.
  /// Returns false (no mutation) if [taskName] collides with an existing task
  /// name (case-insensitive) — task names must stay unique.
  bool _addProgramToNewTask({
    required String programName,
    required String language,
    required String taskName,
    required String taskType,
    int periodMs = 100,
    String triggerTag = '',
    int watchdogMs = 0,
  }) {
    if (isTaskNameTaken(_activeProject.tasks, taskName)) {
      return false;
    }
    final newTask = PlcTask(
      name: taskName,
      type: taskType,
      periodMs: periodMs,
      programNames: [],
      triggerTag: taskType == 'Event' ? triggerTag : '',
      watchdogMs: watchdogMs,
    );
    final newProg = PlcProgram(
      name: programName,
      language: language,
      stSource: '// Write ST Code for $programName\n',
    );
    setState(() {
      _activeProject.tasks.add(newTask);
      _activeProject.programs.add(newProg);
      if (!newTask.programNames.contains(newProg.name)) {
        newTask.programNames.add(newProg.name);
      }
      _activeViewId = 'PROGRAM:${newProg.name}';
    });
    _markDirtyAndAutosave();
    return true;
  }

  void _showAddProgramDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: 'NewProgram');
        String language = 'StructuredText';

        if (_activeProject.tasks.isEmpty) {
          _activeProject.tasks.add(PlcTask(name: 'MainTask', type: 'Continuous', periodMs: 100, programNames: []));
        }
        String taskName = _activeProject.tasks.first.name;
        bool isNewTask = false;
        final newTaskNameCtrl = TextEditingController(text: 'NewTask');
        String newTaskType = 'Continuous';
        final newTaskPeriodCtrl = TextEditingController(text: '100');
        final newTaskWatchdogCtrl = TextEditingController(text: '0');
        String newTaskTriggerTag = '';

        return AlertDialog(
          title: const Text('Add New Program to Project'),
          content: StatefulBuilder(
            builder: (context, setDlgState) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Program Name')),
                  const SizedBox(height: 12),
                  DropdownButton<String>(
                    value: language,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 'StructuredText', child: Text('Structured Text (ST)')),
                      DropdownMenuItem(value: 'LadderLogic', child: Text('Ladder Logic (LD)')),
                      DropdownMenuItem(value: 'FunctionBlockDiagram', child: Text('Function Block Diagram (FBD)')),
                      DropdownMenuItem(value: 'SequentialFunctionChart', child: Text('Sequential Function Chart (SFC)')),
                    ],
                    onChanged: (val) => setDlgState(() => language = val!),
                  ),
                  const SizedBox(height: 12),
                  DropdownButton<String>(
                    value: isNewTask ? _kNewTaskSentinel : taskName,
                    isExpanded: true,
                    items: [
                      ..._activeProject.tasks.map((t) => DropdownMenuItem(value: t.name, child: Text('${t.name} (${t.type})'))),
                      const DropdownMenuItem(value: _kNewTaskSentinel, child: Text(_kNewTaskSentinel)),
                    ],
                    onChanged: (val) => setDlgState(() {
                      if (val == _kNewTaskSentinel) {
                        isNewTask = true;
                      } else {
                        isNewTask = false;
                        taskName = val!;
                      }
                    }),
                  ),
                  if (isNewTask) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: newTaskNameCtrl,
                      decoration: const InputDecoration(labelText: 'New Task Name'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButton<String>(
                      value: newTaskType,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: 'Startup', child: Text('Startup')),
                        DropdownMenuItem(value: 'Continuous', child: Text('Continuous')),
                        DropdownMenuItem(value: 'Periodic', child: Text('Periodic')),
                        DropdownMenuItem(value: 'Event', child: Text('Event')),
                      ],
                      onChanged: (val) => setDlgState(() => newTaskType = val!),
                    ),
                    if (newTaskType == 'Periodic') ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: newTaskPeriodCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Period (ms)'),
                      ),
                    ],
                    if (newTaskType == 'Event') ...[
                      const SizedBox(height: 12),
                      TagAutocompleteField(
                        options: leafAndNodePaths(_activeProject),
                        initialValue: newTaskTriggerTag,
                        label: 'Trigger Tag (BOOL)',
                        onChanged: (val) => newTaskTriggerTag = val,
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: newTaskWatchdogCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Watchdog (ms, 0 = disabled)'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (isNewTask) {
                  final newName = newTaskNameCtrl.text.trim().isEmpty ? 'NewTask' : newTaskNameCtrl.text.trim();
                  if (isTaskNameTaken(_activeProject.tasks, newName)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('A task named "$newName" already exists. Choose a unique name.')),
                    );
                    return;
                  }
                  _addProgramToNewTask(
                    programName: nameCtrl.text,
                    language: language,
                    taskName: newName,
                    taskType: newTaskType,
                    periodMs: int.tryParse(newTaskPeriodCtrl.text) ?? 100,
                    triggerTag: newTaskTriggerTag,
                    watchdogMs: int.tryParse(newTaskWatchdogCtrl.text) ?? 0,
                  );
                } else {
                  final newProg = PlcProgram(
                    name: nameCtrl.text,
                    language: language,
                    stSource: '// Write ST Code for ${nameCtrl.text}\n',
                  );
                  setState(() {
                    _activeProject.programs.add(newProg);
                    final t = _activeProject.tasks.firstWhere((tk) => tk.name == taskName);
                    if (!t.programNames.contains(newProg.name)) {
                      t.programNames.add(newProg.name);
                    }
                    _activeViewId = 'PROGRAM:${newProg.name}';
                  });
                  _markDirtyAndAutosave();
                }
                Navigator.pop(ctx);
              },
              child: const Text('Add Program'),
            ),
          ],
        );
      },
    );
  }

  void _showAddTaskDialog() {
    _showTaskFormDialog(existing: null);
  }

  void _showEditTaskDialog(PlcTask task) {
    _showTaskFormDialog(existing: task);
  }

  /// Shared AlertDialog for both creating a new task ([existing] == null)
  /// and editing an existing one.
  void _showTaskFormDialog({required PlcTask? existing}) {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? 'NewTask');
    String type = existing?.type ?? 'Continuous';
    final periodCtrl = TextEditingController(text: '${existing?.periodMs ?? 100}');
    final watchdogCtrl = TextEditingController(text: '${existing?.watchdogMs ?? 0}');
    String triggerTag = existing?.triggerTag ?? '';
    bool enabled = existing?.enabled ?? true;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit Task' : 'Add New Task'),
          content: StatefulBuilder(
            builder: (context, setDlgState) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Task Name')),
                  const SizedBox(height: 12),
                  DropdownButton<String>(
                    value: type,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 'Startup', child: Text('Startup')),
                      DropdownMenuItem(value: 'Continuous', child: Text('Continuous')),
                      DropdownMenuItem(value: 'Periodic', child: Text('Periodic')),
                      DropdownMenuItem(value: 'Event', child: Text('Event')),
                    ],
                    onChanged: (val) => setDlgState(() => type = val!),
                  ),
                  if (type == 'Periodic') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: periodCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Period (ms)'),
                    ),
                  ],
                  if (type == 'Event') ...[
                    const SizedBox(height: 12),
                    TagAutocompleteField(
                      options: leafAndNodePaths(_activeProject),
                      initialValue: triggerTag,
                      label: 'Trigger Tag (BOOL)',
                      onChanged: (val) => triggerTag = val,
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: watchdogCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Watchdog (ms, 0 = disabled)'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(child: Text('Enabled')),
                      Switch(
                        value: enabled,
                        onChanged: (val) => setDlgState(() => enabled = val),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final name = nameCtrl.text.trim().isEmpty ? 'NewTask' : nameCtrl.text.trim();
                if (isTaskNameTaken(_activeProject.tasks, name, excluding: existing)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('A task named "$name" already exists. Choose a unique name.')),
                  );
                  return;
                }
                final periodMs = int.tryParse(periodCtrl.text) ?? 100;
                final watchdogMs = int.tryParse(watchdogCtrl.text) ?? 0;
                setState(() {
                  if (isEdit) {
                    existing.name = name;
                    existing.type = type;
                    existing.periodMs = periodMs;
                    existing.triggerTag = type == 'Event' ? triggerTag : '';
                    existing.watchdogMs = watchdogMs;
                    existing.enabled = enabled;
                  } else {
                    _activeProject.tasks.add(PlcTask(
                      name: name,
                      type: type,
                      periodMs: periodMs,
                      programNames: [],
                      enabled: enabled,
                      triggerTag: type == 'Event' ? triggerTag : '',
                      watchdogMs: watchdogMs,
                    ));
                  }
                });
                _markDirtyAndAutosave();
                Navigator.pop(ctx);
              },
              child: Text(isEdit ? 'Save Task' : 'Add Task'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCenterWorkspace() {
    if (_activeViewId.startsWith('HMI:')) {
      final hmiId = _activeViewId.replaceFirst('HMI:', '');
      final hmi = _activeProject.hmis.firstWhere((h) => h.id == hmiId, orElse: () => _activeProject.hmis.first);
      return HmiDashboardBuilderScreen(
        currentProject: _activeProject,
        hmiScreen: hmi,
        onScanTriggered: () => setState(() => _executeScan()),
        onProjectUpdated: _markDirtyAndAutosave,
        historian: _historian,
        hapticsEnabled: _hapticsEnabled,
      );
    } else if (_activeViewId == 'MEMORY') {
      return MemoryManagerScreen(
        currentProject: _activeProject,
        onProjectUpdated: _markDirtyAndAutosave,
        historian: _historian,
      );
    } else if (_activeViewId.startsWith('PROGRAM:')) {
      final progName = _activeViewId.replaceFirst('PROGRAM:', '');
      final prog = _activeProject.programs.firstWhere((p) => p.name == progName, orElse: () => _activeProject.programs.first);

      // Render Editor according to IEC Language
      if (prog.language == 'LadderLogic') {
        return LdEditorScreen(
          currentProject: _activeProject,
          program: prog,
          onProgramUpdated: _markDirtyAndAutosave,
          monitor: _scan.ldMonitor,
          scanRunning: isRunning && !_faulted,
        );
      } else if (prog.language == 'FunctionBlockDiagram') {
        return FbdEditorScreen(
          currentProject: _activeProject,
          program: prog,
          onProgramUpdated: _markDirtyAndAutosave,
        );
      } else if (prog.language == 'SequentialFunctionChart') {
        return SfcEditorScreen(
          currentProject: _activeProject,
          program: prog,
          onProgramUpdated: _markDirtyAndAutosave,
          sfcRuntime: _scan.sfc,
          scanRunning: isRunning && !_faulted,
        );
      } else {
        return StEditorScreen(
          currentProject: _activeProject,
          onSaveProgram: (updated) {
            setState(() {
              final idx = _activeProject.programs.indexWhere((p) => p.name == updated.name);
              if (idx != -1) {
                _activeProject.programs[idx] = updated;
              }
            });
            _markDirtyAndAutosave();
          },
        );
      }
    } else if (_activeViewId == 'SIMIO:rules') {
      return SimulatedIoScreen(
        currentProject: _activeProject,
        onProjectUpdated: _markDirtyAndAutosave,
      );
    } else if (_activeViewId == 'PID_AUTOTUNE') {
      return PidAutoTuneScreen(
        currentProject: _activeProject,
        onProjectUpdated: _markDirtyAndAutosave,
      );
    } else if (_activeViewId == 'INTERACTION') {
      return InteractionAnalysisScreen(
        currentProject: _activeProject,
        onProjectUpdated: _markDirtyAndAutosave,
      );
    } else if (_activeViewId == 'GATEWAY') {
      return GatewayScreen(
        currentProject: _activeProject,
        host: _opcuaHost,
        modbusHost: _modbusHost,
        mqttHost: _mqttHost,
        dnpHost: _dnpHost,
        enipHost: _enipHost,
        s7Host: _s7Host,
        finsHost: _finsHost,
        slmpHost: _slmpHost,
        onProjectUpdated: _markDirtyAndAutosave,
      );
    } else if (_activeViewId == 'LOGS') {
      return LogsScreen(logger: _logger);
    }
    return const Center(child: Text('Select an HMI, Memory, or Program from the Left Dock'));
  }
}

/// A single row (icon + label) inside the project ⋮ overflow menu's
/// [PopupMenuItem]s. Kept as a tiny standalone widget (rather than inline
/// `Row`s) so every entry gets identical dark-theme styling for free.
class _ProjectMenuEntry extends StatelessWidget {
  const _ProjectMenuEntry({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ],
    );
  }
}
