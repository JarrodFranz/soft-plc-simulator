// Integration test for WS6 Task 3: boot-from-repository + debounced
// autosave. Drives the REAL shell (WorkspaceShell) against a shared mock
// SharedPreferences-backed ProjectRepository, mutates a tag via the Tag
// Inspector end-drawer the way a user would, waits past the autosave
// debounce, then boots a SECOND shell against the SAME backing store and
// asserts the edit survived — i.e. it was actually persisted, not just held
// in memory.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/data/project_repository.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'package:soft_plc_mobile/widgets/tag_inspector_dock.dart';
import 'support/responsive_test_utils.dart';

Widget _app(ProjectRepository repo) => MaterialApp(home: WorkspaceShell(repository: repo));

/// A [SharedPreferencesStorePlatform] whose `getAllWithParameters` always
/// throws, simulating a genuinely-unavailable persistence backend (as
/// opposed to just an unregistered platform channel, which never settles
/// at all inside `testWidgets`' FakeAsync zone — see the "not saved"
/// indicator test below for why this fake is needed instead).
class _ThrowingSharedPreferencesStore extends SharedPreferencesStorePlatform {
  @override
  Future<Map<String, Object>> getAll() {
    throw StateError('forced test failure: persistence backend unavailable');
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) {
    throw StateError('forced test failure: persistence backend unavailable');
  }

  @override
  Future<bool> clear() async => true;

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async => true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async => true;

  @override
  Future<bool> remove(String key) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('edit via Tag Inspector survives a fresh shell boot (autosave persisted)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repo = ProjectRepository(prefs);

    // --- First shell: boot, seed, mutate a tag, let the debounce fire. ---
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Sanity: booting seeded the defaults into the same backing store.
    final seeded = await repo.listProjects();
    expect(seeded.length, DefaultProjects.all().length);

    // The motor project (first default project) boots as the active
    // project; its first tag is Start_PB (BOOL, initial value false). Tap
    // its value pill in the inline Tag Inspector dock (desktop => inline,
    // not an end-drawer) to flip it via the same code path a user would use.
    // Scope the search to the tag's own Card (found via its name Text) so we
    // don't accidentally hit an unrelated "false " Text elsewhere in the
    // shell chrome (e.g. status badges).
    expect(find.byType(TagInspectorDock), findsOneWidget);
    final startPbCard = find.ancestor(of: find.text('Start_PB'), matching: find.byType(Card)).first;
    final valuePill = find.descendant(of: startPbCard, matching: find.text('false ')).first;
    await tester.tap(valuePill);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Let the ~800ms autosave debounce elapse, then settle any pending
    // save-status rebuilds.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Confirm the write actually landed in the shared backing store (not
    // just in the widget's in-memory copy) before even booting a second
    // shell — this isolates "did autosave fire" from "does boot restore it".
    final activeId = await repo.getActiveProjectId();
    expect(activeId, isNotNull);
    final persisted = await repo.loadProject(activeId!);
    expect(persisted, isNotNull);
    expect(persisted!.tags.first.name, 'Start_PB');
    expect(persisted.tags.first.value, true, reason: 'autosave must have persisted the flipped tag value');

    // --- Second shell: fresh instance, same repository/prefs. ---
    final repo2 = ProjectRepository(prefs);
    await tester.pumpWidget(_app(repo2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The freshly-booted shell must restore the same active project with
    // the mutated value — proving the edit survived a full app restart.
    final reloadedActive = await repo2.loadProject(activeId);
    expect(reloadedActive, isNotNull);
    expect(reloadedActive!.tags.first.value, true);

    // And the UI reflects it too: the tag inspector shows the persisted
    // (flipped) value, not the original default.
    final reloadedCard = find.ancestor(of: find.text('Start_PB'), matching: find.byType(Card)).first;
    expect(find.descendant(of: reloadedCard, matching: find.text('true ')), findsOneWidget);
  });

  testWidgets('boot shows no overflow at phone and desktop widths', (tester) async {
    for (final size in [phoneSize, desktopSize]) {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = ProjectRepository(prefs);
      await setSurface(tester, size);
      await tester.pumpWidget(_app(repo));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'no overflow expected at ${size.width}x${size.height}');
    }
  });

  testWidgets('active project id is restored on boot after switching', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repo = ProjectRepository(prefs);

    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    final catalog = await repo.listProjects();
    final second = catalog[1];

    // Switch via the SELECT PROJECT dropdown, exactly like a user would.
    final dropdown = find.byType(DropdownButton<String>).first;
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    final option = find.text(second.name).last;
    await tester.tap(option);
    await tester.pumpAndSettle();

    expect(await repo.getActiveProjectId(), second.id);

    // A fresh shell against the same store must boot directly into it.
    final repo2 = ProjectRepository(prefs);
    await tester.pumpWidget(_app(repo2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining(second.name), findsWidgets);
  });

  testWidgets(
    'non-injected boot with working prefs persists an edit (real getInstance path, no timeout race)',
    (tester) async {
      // Critical-finding regression: boot used to RACE SharedPreferences
      // .getInstance() against a fixed ~5s timer. On a slow-but-working
      // device the timer could win and _repo would be permanently null
      // (in-memory only) for the whole session, even though prefs were
      // available all along. This test builds WorkspaceShell() WITHOUT an
      // injected repository (i.e. the shell must call
      // SharedPreferences.getInstance() itself), but WITH mock initial
      // values set first so the real getInstance() path resolves and
      // works — proving the non-injected path uses real prefs whenever
      // they're available, with no dependence on a timeout window.
      SharedPreferences.setMockInitialValues({});

      await setSurface(tester, desktopSize);
      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The "Not saved" fallback chip must NOT be showing — prefs are
      // available, so _repo must be non-null.
      expect(find.text('Not saved'), findsNothing);

      // Boot seeded the defaults into real (mocked) SharedPreferences.
      final verifyPrefs = await SharedPreferences.getInstance();
      final verifyRepo = ProjectRepository(verifyPrefs);
      final seeded = await verifyRepo.listProjects();
      expect(seeded.length, DefaultProjects.all().length);

      // Flip the first tag's value via the Tag Inspector, exactly like a
      // user would, then let the autosave debounce elapse.
      expect(find.byType(TagInspectorDock), findsOneWidget);
      final startPbCard = find.ancestor(of: find.text('Start_PB'), matching: find.byType(Card)).first;
      final valuePill = find.descendant(of: startPbCard, matching: find.text('false ')).first;
      await tester.tap(valuePill);
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Reload via a FRESH ProjectRepository over the same real
      // (mocked) SharedPreferences instance — proving the non-injected
      // boot path persisted through the real getInstance() call, not an
      // in-memory fallback.
      final activeId = await verifyRepo.getActiveProjectId();
      expect(activeId, isNotNull);
      final reloaded = await verifyRepo.loadProject(activeId!);
      expect(reloaded, isNotNull);
      expect(reloaded!.tags.first.name, 'Start_PB');
      expect(
        reloaded.tags.first.value,
        true,
        reason: 'the non-injected boot path must use real SharedPreferences whenever it is available, '
            'with no timeout race that could silently fall back to in-memory-only storage',
      );
    },
  );

  testWidgets(
    'shows a visible "not saved" indicator (no overflow) when persistence is genuinely unavailable',
    (tester) async {
      // CRITICAL/IMPORTANT finding 3: when _repo == null (in-memory
      // fallback truly engaged), the app must never silently pretend to
      // save. Swap in a SharedPreferencesStorePlatform that genuinely
      // throws so boot lands on the null-repo fallback, then assert the
      // amber "not saved" indicator is showing and that it never causes
      // an AppBar overflow — including at the narrowest supported phone
      // widths (360/320).
      //
      // SharedPreferences.getInstance() memoizes its result in a static
      // Completer, and setMockInitialValues() (used by earlier tests in
      // this file) replaces SharedPreferencesStorePlatform.instance with
      // an in-memory fake — so a MethodChannel-level mock would never
      // even be consulted. resetStatic() clears the memoized Completer so
      // getInstance() re-reads SharedPreferencesStorePlatform.instance,
      // which we point at the throwing fake below.
      final originalPlatform = SharedPreferencesStorePlatform.instance;
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _ThrowingSharedPreferencesStore();

      for (final size in [phoneSize, smallPhoneSize, desktopSize]) {
        await setSurface(tester, size);
        await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'no overflow expected at ${size.width}');
        expect(
          find.byIcon(Icons.warning_amber_rounded),
          findsOneWidget,
          reason: '"not saved" indicator must be visible when _repo is null (forced store failure) at ${size.width}',
        );
      }

      // Restore the platform instance and clear the memoized Completer so
      // neither leaks into other tests in this file/run.
      SharedPreferencesStorePlatform.instance = originalPlatform;
      SharedPreferences.resetStatic();
    },
  );
}
