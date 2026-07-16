// Whole-app responsive smoke test.
//
// Drives the REAL app shell (WorkspaceShell) — not an isolated screen — across
// every primary top-level view (HMI, each IEC 61131-3 language editor, Memory
// Manager, Simulated I/O, and project switching) at phone, small-phone, and
// desktop widths, asserting no overflow (tester.takeException() is null)
// anywhere. This is the cross-cutting safety net for the responsive-layout
// workstream: it catches any screen missed by the per-feature responsive
// tests (shell/forms/memory/editors).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

Widget _app() => const MaterialApp(home: WorkspaceShell());

/// Finds the nav tree content (`ListView` tagged `Key('nav_tree')` in
/// workspace_shell.dart). It is shared by the inline dock (expanded) and the
/// `Drawer` (compact), but only one is ever in the tree at a time for a
/// given layout, so there is exactly one match regardless of width.
Finder _navTree() => find.byKey(const Key('nav_tree'));

/// The tree depth of [element] (distance from the root). Used to pick the
/// SHELL's own "Open navigation menu" hamburger when more than one is on
/// screen (see [_shellHamburger]).
int _depthOf(Element element) {
  var depth = 0;
  Element? current = element;
  while (current != null) {
    depth++;
    Element? parent;
    current.visitAncestorElements((ancestor) {
      parent = ancestor;
      return false;
    });
    current = parent;
  }
  return depth;
}

/// Finds the SHELL's own "Open navigation menu" hamburger — i.e. the button
/// that opens the [Drawer] wrapping [_navTree] — even when a nested
/// center-workspace editor (e.g. the ST editor) has its own `Scaffold` with
/// its own auto-generated drawer button carrying the identical default
/// tooltip text. `find.byTooltip(...).first` is NOT reliable here: Flutter's
/// finder traversal does not guarantee the shell's (structurally shallower)
/// AppBar sorts before a nested editor's, so plain widget/element order
/// cannot disambiguate them. Tree DEPTH can: the shell's own `Scaffold`/
/// `AppBar` is always less deeply nested than any editor it hosts, so the
/// hamburger with the smallest element depth is always the shell's.
Finder _shellHamburger() {
  final candidates = find.byTooltip('Open navigation menu').evaluate().toList();
  candidates.sort((a, b) => _depthOf(a).compareTo(_depthOf(b)));
  final shallowest = candidates.first;
  return find.byElementPredicate((element) => element == shallowest, description: 'shell hamburger (shallowest "Open navigation menu")');
}

/// Opens the drawer on compact widths (a no-op on expanded, where the tree
/// is always inline) and waits until the nav tree is actually present in
/// the widget tree before returning — this is what every caller actually
/// needs, rather than inferring drawer state from hamburger visibility
/// alone (which is fragile: a nested editor's own drawer/hamburger — e.g.
/// the ST editor — can carry the identical tooltip, so more than one
/// candidate can be on screen at once; see [_shellHamburger]).
Future<void> _ensureNavAvailable(WidgetTester tester, {required bool compact}) async {
  if (!compact) return;
  if (_navTree().evaluate().isNotEmpty) {
    // Nav tree (inline dock or open drawer) is already present — nothing to do.
    return;
  }
  final hamburger = find.byTooltip('Open navigation menu');
  expect(hamburger, findsWidgets, reason: 'expected the shell hamburger to be present when the nav tree is not');
  await tester.tap(_shellHamburger());
  await tester.pumpAndSettle();
  expect(_navTree(), findsOneWidget, reason: 'nav tree must be present after opening the drawer');
}

/// Finds the nav tree's `Scrollable`.
Finder _navTreeScrollable() => find.descendant(of: _navTree(), matching: find.byType(Scrollable)).first;

/// Scopes [textFinder] to descendants of the nav tree. This both narrows the
/// search for `scrollUntilVisible`/`ensureVisible` (which require the finder
/// to resolve unambiguously once built) and disambiguates from identical
/// text that may already be rendered in the center workspace — e.g. once an
/// HMI dashboard is the active view, its own AppBar shows the same title as
/// its nav tree entry, so an unscoped `find.text(hmiTitle)` matches twice.
Finder _inNavTree(Finder textFinder) => find.descendant(of: _navTree(), matching: textFinder);

/// Scrolls [destination] (already scoped to the nav tree via [_inNavTree])
/// into view within the nav tree's `Scrollable` (the left-dock tree is a
/// lazily-built `ListView`, so nodes near the bottom — e.g. programs under
/// "TASKS & IEC 61131-3 LOGIC" — are not built until scrolled into the
/// viewport) before tapping it, then taps it the way a user would. Works
/// identically for the inline dock (expanded) and the Drawer's copy of the
/// same content (compact).
///
/// Hand-rolled instead of `WidgetTester.scrollUntilVisible` because that
/// helper assumes the target finder resolves to *at most one* match at all
/// times: it repeatedly evaluates the finder and, once non-empty, calls
/// `element(finder)` which requires exactly one match (`Iterable.single`).
/// Some legitimate destinations here match more than one nav-tree node once
/// fully built — e.g. a program assigned to two IEC task types (both a
/// Startup task and a Continuous task) renders once under each task
/// folder — so this loop tolerates `findsWidgets` (one or more) and always
/// targets `.first` for both the visibility check and the tap.
Future<void> _navigateTo(WidgetTester tester, {required bool compact, required Finder destination}) async {
  await _ensureNavAvailable(tester, compact: compact);
  final scoped = _inNavTree(destination);
  expect(_navTreeScrollable(), findsOneWidget, reason: 'nav tree scrollable must be present before scrolling to a destination');
  var remaining = 40;
  while (scoped.evaluate().isEmpty && remaining > 0) {
    // Re-resolve the scrollable each iteration rather than caching a single
    // Finder result: a stale reference could point at a Scrollable that no
    // longer exists if the tree rebuilds mid-scroll.
    await tester.drag(_navTreeScrollable(), const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 50));
    remaining--;
  }
  await tester.pumpAndSettle();
  expect(scoped, findsWidgets, reason: 'destination must be present in the nav tree (${compact ? "drawer" : "inline dock"})');
  final target = scoped.first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// Switches the active project via the "SELECT PROJECT" dropdown, the same
/// way a user would (open dropdown, tap the named item). Works identically
/// whether the dropdown lives inline (expanded) or inside the Drawer
/// (compact) since it opens the drawer first on compact.
Future<void> _switchProject(WidgetTester tester, {required bool compact, required String projectName}) async {
  await _ensureNavAvailable(tester, compact: compact);
  final dropdown = find.byType(DropdownButton<String>).first;
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  // The open dropdown menu is a scrollable overlay route that opens scrolled
  // to the CURRENTLY ACTIVE project, not to the top — so with 13 default
  // projects the target item can sit either above or below the fold
  // depending on which project is presently selected (notably at 320x568).
  // Reset to the top first, then scroll the menu's own Scrollable downward
  // until the item mounts before tapping — mirroring _navigateTo's nav-tree
  // scroll loop.
  final menuScrollable = find.byType(Scrollable).last;
  final option = find.descendant(of: menuScrollable, matching: find.text(projectName));
  var resetRemaining = 40;
  while (resetRemaining > 0) {
    await tester.drag(menuScrollable, const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 50));
    resetRemaining--;
  }
  var remaining = 40;
  while (option.evaluate().isEmpty && remaining > 0) {
    await tester.drag(menuScrollable, const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 50));
    remaining--;
  }
  await tester.pumpAndSettle();
  expect(option, findsWidgets, reason: 'project "$projectName" must appear in the SELECT PROJECT dropdown');
  final target = option.first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  // WorkspaceShell() boots via the real (non-injected) SharedPreferences
  // .getInstance() path. Mock initial values so that call actually
  // resolves inside the test's FakeAsync zone — an unmocked platform
  // channel invocation never completes there at all (neither resolving
  // nor throwing), so without this the boot Future would hang forever
  // and every pumpAndSettle() below would time out.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Sanity: confirm the "all languages" water project actually has every
  // view type this smoke test claims to exercise, so the test can't silently
  // degrade if default_projects.dart changes shape.
  final allWater = DefaultProjects.all().firstWhere((p) => p.id == 'proj_all_water');
  final stProg = allWater.programs.firstWhere((p) => p.language == 'StructuredText');
  final ldProg = allWater.programs.firstWhere((p) => p.language == 'LadderLogic');
  final fbdProg = allWater.programs.firstWhere((p) => p.language == 'FunctionBlockDiagram');
  final sfcProg = allWater.programs.firstWhere((p) => p.language == 'SequentialFunctionChart');
  final hmiTitle = allWater.hmis.first.title;

  for (final entry in <String, Size>{
    'phone': phoneSize,
    'smallPhone': smallPhoneSize,
    'desktop': desktopSize,
  }.entries) {
    final sizeName = entry.key;
    final size = entry.value;
    final compact = size.width < 640;

    group('$sizeName (${size.width.toInt()}x${size.height.toInt()})', () {
      testWidgets('boots the shell on the default project/view with no overflow', (tester) async {
        await setSurface(tester, size);
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets('visits every primary view of the all-languages water project', (tester) async {
        await setSurface(tester, size);
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();

        // 1. Switch to the "all languages" water project.
        await _switchProject(tester, compact: compact, projectName: allWater.name);

        // 2. HMI dashboard (default view after switching, but navigate
        //    explicitly via the tree to prove the destination is reachable).
        await _navigateTo(tester, compact: compact, destination: find.text(hmiTitle));

        // 3. Memory Manager.
        await _navigateTo(
          tester,
          compact: compact,
          destination: find.textContaining('Tags & Structs'),
        );

        // 4. Simulated I/O.
        await _navigateTo(
          tester,
          compact: compact,
          destination: find.textContaining('SIMULATED I/O'),
        );

        // 5. Each of the four IEC 61131-3 language editors.
        for (final progName in [stProg.name, ldProg.name, fbdProg.name, sfcProg.name]) {
          await _navigateTo(tester, compact: compact, destination: find.text(progName));
        }

        expect(tester.takeException(), isNull);
      });

      testWidgets('visits one editor of each language type across other default projects', (tester) async {
        await setSurface(tester, size);
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();

        // proj_ld_conveyor: dedicated LadderLogic project.
        final ldProject = DefaultProjects.all().firstWhere((p) => p.id == 'proj_ld_conveyor');
        await _switchProject(tester, compact: compact, projectName: ldProject.name);
        final ldOnlyProg = ldProject.programs.firstWhere((p) => p.language == 'LadderLogic');
        await _navigateTo(tester, compact: compact, destination: find.text(ldOnlyProg.name));

        // proj_fbd_hvac: dedicated FunctionBlockDiagram project.
        final fbdProject = DefaultProjects.all().firstWhere((p) => p.id == 'proj_fbd_hvac');
        await _switchProject(tester, compact: compact, projectName: fbdProject.name);
        final fbdOnlyProg = fbdProject.programs.firstWhere((p) => p.language == 'FunctionBlockDiagram');
        await _navigateTo(tester, compact: compact, destination: find.text(fbdOnlyProg.name));

        // proj_sfc_filling: dedicated SequentialFunctionChart project.
        final sfcProject = DefaultProjects.all().firstWhere((p) => p.id == 'proj_sfc_filling');
        await _switchProject(tester, compact: compact, projectName: sfcProject.name);
        final sfcOnlyProg = sfcProject.programs.firstWhere((p) => p.language == 'SequentialFunctionChart');
        await _navigateTo(tester, compact: compact, destination: find.text(sfcOnlyProg.name));

        // proj_st_reactor: dedicated StructuredText project.
        final stProject = DefaultProjects.all().firstWhere((p) => p.id == 'proj_st_reactor');
        await _switchProject(tester, compact: compact, projectName: stProject.name);
        final stOnlyProg = stProject.programs.firstWhere((p) => p.language == 'StructuredText');
        await _navigateTo(tester, compact: compact, destination: find.text(stOnlyProg.name));

        expect(tester.takeException(), isNull);
      });

      testWidgets('visits every default project\'s first HMI dashboard with no overflow', (tester) async {
        await setSurface(tester, size);
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();

        for (final project in DefaultProjects.all()) {
          if (project.hmis.isEmpty) continue;
          await _switchProject(tester, compact: compact, projectName: project.name);
          // Switching projects already lands on the first HMI (or first
          // program if no HMI) per _switchActiveProject — assert no overflow
          // on that landing, which is itself a distinct view per project.
          expect(tester.takeException(), isNull);
        }
      });
    });
  }
}
