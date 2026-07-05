import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/project_model.dart';
import '../models/sim_engine.dart';
import '../models/ld_exec.dart';
import '../models/fbd_exec.dart';
import '../models/sfc_exec.dart';
import '../models/st_exec.dart';
import '../data/default_projects.dart';
import '../data/project_repository.dart';
import '../data/project_transfer.dart';
import '../ui/responsive.dart';
import '../widgets/tag_inspector_dock.dart';
import 'st_editor_screen.dart';
import 'ld_editor_screen.dart';
import 'fbd_editor_screen.dart';
import 'sfc_editor_screen.dart';
import 'memory_manager_screen.dart';
import 'hmi_dashboard_builder_screen.dart';
import 'simulated_io_screen.dart';

/// Debounce window between the last project mutation and the autosave write.
const Duration _autosaveDebounce = Duration(milliseconds: 800);

class WorkspaceShell extends StatefulWidget {
  /// Optional injection seam so tests (and callers that already own a
  /// [ProjectRepository]) can share one backing store with the shell instead
  /// of it always minting its own via [SharedPreferences.getInstance].
  final ProjectRepository? repository;

  const WorkspaceShell({super.key, this.repository});

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
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
  final SimRuntime _simRuntime = SimRuntime();
  final LdExecRuntime _ldRuntime = LdExecRuntime();
  final FbdRuntime _fbdRuntime = FbdRuntime();
  final SfcRuntime _sfcRuntime = SfcRuntime();
  final StRuntime _stRuntime = StRuntime();

  // Side Dock Inspector State
  bool isTagDockVisible = true;

  // Autosave status. `_saveFailed` is a third state (alongside
  // saving/saved) surfaced when a save actually throws, so a failure is
  // visible instead of silently swallowed.
  Timer? _autosaveTimer;
  bool _saveInFlight = false;
  bool _savedIndicatorVisible = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _autosaveTimer?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    ProjectRepository? repo;
    List<PlcProject> loadedProjects = [];
    PlcProject? active;

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
      SharedPreferences? prefs;
      try {
        prefs = await SharedPreferences.getInstance();
      } catch (_) {
        prefs = null;
      }
      repo = prefs != null ? ProjectRepository(prefs) : null;
    }

    if (repo != null) {
      // Prefs (or an injected repository) are available. Keep `repo`
      // non-null even if seeding/loading below throws, so the key
      // invariant holds: prefs available => _repo stays non-null => edits
      // persist. A failure here only affects what's shown THIS session,
      // never whether autosave has somewhere to write.
      try {
        await repo.seedDefaultsIfEmpty();

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
      } catch (_) {
        // A later boot step (seed/list/load) threw despite prefs being
        // available. Don't revert to a null repo — that would silently
        // disable persistence for the whole session. Just fall back to
        // in-memory defaults for THIS session's initial view; `_repo`
        // stays non-null so autosave still writes through.
        loadedProjects = [];
        active = null;
      }
    }

    if (loadedProjects.isEmpty) {
      loadedProjects = DefaultProjects.all();
      active = loadedProjects.first;
    }

    if (!mounted) return;
    setState(() {
      _repo = repo;
      _allProjects = loadedProjects;
      _activeProject = active ?? loadedProjects.first;
      if (_activeProject.hmis.isNotEmpty) {
        _activeViewId = 'HMI:${_activeProject.hmis.first.id}';
      } else if (_activeProject.programs.isNotEmpty) {
        _activeViewId = 'PROGRAM:${_activeProject.programs.first.name}';
      } else {
        _activeViewId = 'MEMORY';
      }
      _booting = false;
    });
    await repo?.setActiveProjectId(_activeProject.id);
    _startScanLoop();
  }

  void _startScanLoop() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(Duration(milliseconds: scanSpeedMs), (timer) {
      if (isRunning) {
        _executeScan();
      }
    });
  }

  void _executeScan() {
    setState(() {
      scanCount++;
      applySimRules(_activeProject, _activeProject.simRules, scanSpeedMs, _simRuntime);
      executeLdPrograms(_activeProject, scanSpeedMs, _ldRuntime);
      executeFbdPrograms(_activeProject, scanSpeedMs, _fbdRuntime);
      executeSfcPrograms(_activeProject, scanSpeedMs, _sfcRuntime);
      executeStPrograms(_activeProject, scanSpeedMs, _stRuntime);
    });
  }

  void _switchActiveProject(PlcProject proj) {
    // Flush any pending edit on the project we're leaving before switching
    // away from it, so a rapid switch right after an edit can't drop it.
    _flushPendingAutosave();
    setState(() {
      _activeProject = proj;
      if (proj.hmis.isNotEmpty) {
        _activeViewId = 'HMI:${proj.hmis.first.id}';
      } else if (proj.programs.isNotEmpty) {
        _activeViewId = 'PROGRAM:${proj.programs.first.name}';
      }
      scanCount = 0;
      _simRuntime.byRuleId.clear();
      _ldRuntime.clear();
      _fbdRuntime.clear();
      _sfcRuntime.clear();
      _stRuntime.clear();
    });
    unawaited(_repo?.setActiveProjectId(proj.id));
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
    final repo = _repo;
    if (repo == null) return;
    setState(() {
      _saveInFlight = true;
      _saveFailed = false;
    });
    final projectToSave = _activeProject;
    try {
      await repo.saveProject(projectToSave);
      if (!mounted) return;
      setState(() {
        _saveInFlight = false;
        _savedIndicatorVisible = true;
        _saveFailed = false;
      });
    } catch (_) {
      // Don't let this become an unhandled Future error — reflect the
      // failure in the indicator instead of masking it.
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
      _activeViewId = 'MEMORY';
      scanCount = 0;
      _simRuntime.byRuleId.clear();
      _ldRuntime.clear();
      _fbdRuntime.clear();
      _sfcRuntime.clear();
      _stRuntime.clear();
    });
  }

  Future<void> _duplicateActiveProject() async {
    final repo = _repo;
    if (repo == null) return;
    _flushPendingAutosave();
    final newId = await repo.duplicateProject(_activeProject.id, newName: '${_activeProject.name} Copy');
    final copy = await repo.loadProject(newId);
    if (copy == null) return;
    await repo.setActiveProjectId(copy.id);
    if (!mounted) return;
    setState(() {
      _allProjects.add(copy);
      _activeProject = copy;
      if (copy.hmis.isNotEmpty) {
        _activeViewId = 'HMI:${copy.hmis.first.id}';
      } else if (copy.programs.isNotEmpty) {
        _activeViewId = 'PROGRAM:${copy.programs.first.name}';
      } else {
        _activeViewId = 'MEMORY';
      }
      scanCount = 0;
      _simRuntime.byRuleId.clear();
      _ldRuntime.clear();
      _fbdRuntime.clear();
      _sfcRuntime.clear();
      _stRuntime.clear();
    });
  }

  Future<void> _renameActiveProject() async {
    final repo = _repo;
    if (repo == null) return;
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
    });
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
    final deletedId = _activeProject.id;
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
      if (next.hmis.isNotEmpty) {
        _activeViewId = 'HMI:${next.hmis.first.id}';
      } else if (next.programs.isNotEmpty) {
        _activeViewId = 'PROGRAM:${next.programs.first.name}';
      } else {
        _activeViewId = 'MEMORY';
      }
      scanCount = 0;
      _simRuntime.byRuleId.clear();
      _ldRuntime.clear();
      _fbdRuntime.clear();
      _sfcRuntime.clear();
      _stRuntime.clear();
    });
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
      if (first.hmis.isNotEmpty) {
        _activeViewId = 'HMI:${first.hmis.first.id}';
      } else if (first.programs.isNotEmpty) {
        _activeViewId = 'PROGRAM:${first.programs.first.name}';
      } else {
        _activeViewId = 'MEMORY';
      }
      scanCount = 0;
      _simRuntime.byRuleId.clear();
      _ldRuntime.clear();
      _fbdRuntime.clear();
      _sfcRuntime.clear();
      _stRuntime.clear();
    });
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
    } catch (_) {
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
    } catch (_) {
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
    } catch (_) {
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
    } on FormatException {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't import: not a valid project file")),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't import: not a valid project file")),
      );
      return;
    }

    final existingIds = _allProjects.map((p) => p.id).toSet();
    imported = ProjectTransfer.reassignIdIfColliding(imported, existingIds);

    _flushPendingAutosave();
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
      if (imported.hmis.isNotEmpty) {
        _activeViewId = 'HMI:${imported.hmis.first.id}';
      } else if (imported.programs.isNotEmpty) {
        _activeViewId = 'PROGRAM:${imported.programs.first.name}';
      } else {
        _activeViewId = 'MEMORY';
      }
      scanCount = 0;
      _simRuntime.byRuleId.clear();
      _ldRuntime.clear();
      _fbdRuntime.clear();
      _sfcRuntime.clear();
      _stRuntime.clear();
    });
    messenger.showSnackBar(SnackBar(content: Text('Imported "${imported.name}"')));
  }

  Widget _projectCrudButton({required IconData icon, required String tooltip, required VoidCallback onTap}) {
    return touchable(
      IconButton(
        icon: Icon(icon, size: 16, color: Colors.grey),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        onPressed: onTap,
      ),
    );
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

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.memory, color: Colors.cyan, size: 22),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'Soft PLC Simulator — ${_activeProject.name}',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(width: 10),
            _buildSaveStatus(compact: compact),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        actions: _buildAppBarActions(context, compact: compact),
      ),
      drawer: expanded ? null : Drawer(child: _buildLeftDockContent()),
      endDrawer: expanded
          ? null
          : Drawer(
              width: math.min(340, MediaQuery.sizeOf(context).width * 0.9),
              child: TagInspectorDock(
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
          // PLC Execution Controls Toolbar (Scan Speed Slider cleanly placed to avoid clipping)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: const Color(0xFF0F172A),
            child: Row(
              children: [
                const Icon(Icons.speed, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                if (!compact) ...[
                  const Text('SCAN LOOP SPEED:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                  const SizedBox(width: 12),
                ],
                Expanded(
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
                Text(
                  compact ? '${scanSpeedMs}ms' : '${scanSpeedMs}ms ${scanSpeedMs >= 500 ? "(Slow Mo Step)" : ""}',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: scanSpeedMs >= 500 ? Colors.amberAccent : Colors.cyanAccent,
                  ),
                ),
                if (!compact) ...[
                  const Spacer(),
                  Text('Scan Count: $scanCount', style: const TextStyle(fontSize: 12, color: Colors.grey, fontFamily: 'monospace')),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),

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
                        child: _buildCenterWorkspace(),
                      ),

                      // RIGHT DOCK: Toggleable Tag Inspector & Forcing Matrix
                      if (isTagDockVisible) ...[
                        const VerticalDivider(width: 1, color: Colors.white12),
                        TagInspectorDock(
                          tags: _activeProject.tags,
                          onTagStateChanged: _markDirtyAndAutosave,
                          onClose: () => setState(() => isTagDockVisible = false),
                        ),
                      ],
                    ],
                  )
                : _buildCenterWorkspace(),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildAppBarActions(BuildContext context, {required bool compact}) {
    // Run / Pause Toggle
    final runToggle = IconButton(
      icon: Icon(
        isRunning ? Icons.pause_circle_filled : Icons.play_circle_fill,
        color: isRunning ? Colors.amber : Colors.greenAccent,
        size: 26,
      ),
      tooltip: isRunning ? 'Pause Scan Loop' : 'Run Scan Loop',
      onPressed: () {
        setState(() {
          isRunning = !isRunning;
        });
      },
    );

    // Toggle Tag Inspector Side Dock / End Drawer
    final tagToggle = IconButton(
      icon: Icon(Icons.table_chart, color: isTagDockVisible ? Colors.cyanAccent : Colors.grey, size: 24),
      tooltip: 'Toggle Tag Inspector Side Dock',
      onPressed: () => _openTagDock(context),
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

        const SizedBox(width: 12),
      ];
    }

    // Compact: keep only run/stop + tag-toggle inline; overflow the rest into a menu.
    return [
      runToggle,
      tagToggle,
      PopupMenuButton<String>(
        tooltip: 'More actions',
        icon: const Icon(Icons.more_vert),
        onSelected: (value) {
          if (value == 'step') {
            _executeScan();
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
                DropdownButton<String>(
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
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    _projectCrudButton(icon: Icons.add, tooltip: 'New Project', onTap: _createNewProject),
                    _projectCrudButton(icon: Icons.copy_all, tooltip: 'Duplicate Project', onTap: _duplicateActiveProject),
                    _projectCrudButton(icon: Icons.drive_file_rename_outline, tooltip: 'Rename Project', onTap: _renameActiveProject),
                    _projectCrudButton(icon: Icons.delete_outline, tooltip: 'Delete Project', onTap: _deleteActiveProject),
                    _projectCrudButton(icon: Icons.restore, tooltip: 'Reset to Defaults', onTap: _resetToDefaults),
                    _projectCrudButton(icon: Icons.ios_share, tooltip: 'Export Project (.splc.json)', onTap: _exportActiveProject),
                    _projectCrudButton(icon: Icons.file_open_outlined, tooltip: 'Import Project (.splc.json)', onTap: _importProject),
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

                const SizedBox(height: 12),

                // SECTION 3: Tasks & Programs Classified by Task Type & Language
                _buildTreeFolderHeader('TASKS & IEC 61131-3 LOGIC', Icons.folder_special_outlined),

                _buildTaskCategoryFolder('Startup Tasks', Icons.play_arrow, 'Startup'),
                _buildTaskCategoryFolder('Continuous Tasks', Icons.loop, 'Continuous'),
                _buildTaskCategoryFolder('Periodic Tasks', Icons.timer, 'Periodic'),
                _buildTaskCategoryFolder('Event Tasks', Icons.bolt, 'Event'),

                const SizedBox(height: 16),

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
    final programsInTaskType = <String>[];
    for (var task in _activeProject.tasks.where((t) => t.type == taskType)) {
      programsInTaskType.addAll(task.programNames);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: Colors.tealAccent),
              const SizedBox(width: 6),
              Text('$title (${programsInTaskType.length})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70)),
            ],
          ),

          if (programsInTaskType.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 20, top: 2, bottom: 4),
              child: Text('(none configured)', style: TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic)),
            )
          else
            ...programsInTaskType.map((progName) {
              final prog = _activeProject.programs.firstWhere((p) => p.name == progName, orElse: () => PlcProgram(name: progName, language: 'StructuredText'));
              final isSelected = _activeViewId == 'PROGRAM:$progName';

              String badgeText = 'ST';
              Color badgeColor = Colors.blue;
              if (prog.language == 'LadderLogic') { badgeText = 'LD'; badgeColor = Colors.orange; }
              if (prog.language == 'FunctionBlockDiagram') { badgeText = 'FBD'; badgeColor = Colors.teal; }
              if (prog.language == 'SequentialFunctionChart') { badgeText = 'SFC'; badgeColor = Colors.purple; }

              return Container(
                margin: const EdgeInsets.only(left: 20, top: 2),
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
                    title: Text(prog.name, style: TextStyle(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
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
            }),
        ],
      ),
    );
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

        return AlertDialog(
          title: const Text('Add New Program to Project'),
          content: StatefulBuilder(
            builder: (context, setDlgState) => Column(
              mainAxisSize: MainAxisSize.min,
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
                  value: taskName,
                  isExpanded: true,
                  items: _activeProject.tasks.map((t) => DropdownMenuItem(value: t.name, child: Text('${t.name} (${t.type})'))).toList(),
                  onChanged: (val) => setDlgState(() => taskName = val!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
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
                Navigator.pop(ctx);
              },
              child: const Text('Add Program'),
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
      );
    } else if (_activeViewId == 'MEMORY') {
      return MemoryManagerScreen(
        currentProject: _activeProject,
        onProjectUpdated: _markDirtyAndAutosave,
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
    }
    return const Center(child: Text('Select an HMI, Memory, or Program from the Left Dock'));
  }
}
