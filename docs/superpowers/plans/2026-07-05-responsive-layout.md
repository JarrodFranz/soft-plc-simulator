# Responsive & Adaptive Layout (WS5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every screen adapt to the available width so the app is usable on a phone (~360 px) and on a desktop browser at any size, using one width-based responsive foundation — without changing any scan/execution behavior.

**Architecture:** A shared `mobile/lib/ui/responsive.dart` (breakpoints, `BuildContext` extensions, an adaptive-width dialog, a touch-target helper) drives per-screen adaptation. Below 840 px the shell's docks become a `Drawer`/`endDrawer`, editor palettes become on-demand sheets, the Memory Manager table becomes a card list, and all fixed-width dialogs clamp to the viewport. At ≥ 840 px the current desktop 3-pane IDE is unchanged. Verification is by widget tests pumped at phone and desktop surface sizes asserting no `RenderFlex` overflow and the correct adaptive structure.

**Tech Stack:** Flutter / Dart (web + mobile), `flutter test` (widget tests), `flutter analyze`.

## Global Constraints

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved; the desktop appearance at ≥ 840 px must be visually unchanged from today.
- `flutter analyze` reports **zero** issues. Braces on all flow-control; prefer `const`; `x.isNotEmpty` not `x.length >= 1`; `withValues(alpha:)` not `withOpacity`; `initialValue:` not `value:` on `DropdownButtonFormField`.
- **No `RenderFlex` overflow** at 360×740 AND 320×568, and none at 1400×900.
- Width-based adaptation only — NEVER branch on `Platform.*`/`kIsWeb`.
- This is a **pure UI/layout** workstream: do NOT change anything in `mobile/lib/models/` (engines) or the default project data logic. The existing 103 tests must keep passing.
- All shell commands run from `mobile/`.

**Sequencing:** Task 1 (foundation) is a dependency for all others. Tasks 2–5 adapt independent screen groups and can be reviewed separately. Task 6 is whole-app validation.

---

### Task 1: Responsive foundation + test utilities

**Files:**
- Create: `mobile/lib/ui/responsive.dart`
- Create: `mobile/test/support/responsive_test_utils.dart`
- Test: `mobile/test/responsive_test.dart`

**Interfaces produced (used by all later tasks):**
- `Breakpoints.compact` (640), `Breakpoints.expanded` (840); `enum WidthClass { compact, medium, expanded }`.
- `extension ResponsiveContext on BuildContext`: `double widthPx`, `WidthClass widthClass`, `bool isCompact` (< 640), `bool isExpanded` (≥ 840).
- `const double kMinTouch = 44.0;` and `Widget touchable(Widget child, {VoidCallback? onTap})`.
- `Future<T?> showAdaptiveWidthDialog<T>(BuildContext, {required Widget child, double desiredWidth})`.
- Test utils: `Future<void> setSurface(WidgetTester, Size)`, `const phoneSize = Size(360,740)`, `const desktopSize = Size(1400,900)`.

- [ ] **Step 1: Write the foundation `mobile/lib/ui/responsive.dart`**

```dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Width breakpoints (logical px). Adaptation keys on WIDTH, never platform.
abstract class Breakpoints {
  static const double compact = 640; // < 640: phone / narrow window
  static const double expanded = 840; // >= 840: desktop / web-on-monitor
}

enum WidthClass { compact, medium, expanded }

extension ResponsiveContext on BuildContext {
  double get widthPx => MediaQuery.sizeOf(this).width;

  WidthClass get widthClass {
    final w = widthPx;
    if (w < Breakpoints.compact) {
      return WidthClass.compact;
    }
    if (w < Breakpoints.expanded) {
      return WidthClass.medium;
    }
    return WidthClass.expanded;
  }

  bool get isCompact => widthPx < Breakpoints.compact;
  bool get isExpanded => widthPx >= Breakpoints.expanded;
}

/// Minimum finger hit-target (Material spec).
const double kMinTouch = 44.0;

/// Guarantees a >= [kMinTouch] hit area around [child] without changing its
/// visual size — for small icon buttons on touch screens.
Widget touchable(Widget child, {VoidCallback? onTap}) {
  final box = ConstrainedBox(
    constraints: const BoxConstraints(minWidth: kMinTouch, minHeight: kMinTouch),
    child: Center(child: child),
  );
  if (onTap == null) {
    return box;
  }
  return InkWell(onTap: onTap, child: box);
}

/// Shows a dialog whose content width never exceeds the viewport (min of
/// [desiredWidth] and screen width minus inset). Replaces hardcoded dialog
/// widths so nothing overflows on a phone.
Future<T?> showAdaptiveWidthDialog<T>(
  BuildContext context, {
  required Widget child,
  double desiredWidth = 440,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) {
      final maxW = math.min(desiredWidth, MediaQuery.sizeOf(ctx).width - 32);
      return Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: child,
        ),
      );
    },
  );
}
```

- [ ] **Step 2: Write the test utilities `mobile/test/support/responsive_test_utils.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sets the test surface to a fixed logical size (dpr = 1 so logical == given),
/// and restores it after the test.
Future<void> setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

const Size phoneSize = Size(360, 740);
const Size smallPhoneSize = Size(320, 568);
const Size desktopSize = Size(1400, 900);
```

- [ ] **Step 3: Write tests `mobile/test/responsive_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/ui/responsive.dart';
import 'support/responsive_test_utils.dart';

void main() {
  testWidgets('widthClass / isCompact / isExpanded reflect surface width',
      (tester) async {
    late WidthClass wc;
    late bool compact;
    late bool expanded;
    Widget probe() => MaterialApp(
          home: Builder(builder: (ctx) {
            wc = ctx.widthClass;
            compact = ctx.isCompact;
            expanded = ctx.isExpanded;
            return const SizedBox();
          }),
        );

    await setSurface(tester, phoneSize);
    await tester.pumpWidget(probe());
    expect(wc, WidthClass.compact);
    expect(compact, isTrue);
    expect(expanded, isFalse);

    await setSurface(tester, const Size(760, 900));
    await tester.pumpWidget(probe());
    expect(wc, WidthClass.medium);
    expect(compact, isFalse);
    expect(expanded, isFalse);

    await setSurface(tester, desktopSize);
    await tester.pumpWidget(probe());
    expect(wc, WidthClass.expanded);
    expect(expanded, isTrue);
  });

  testWidgets('showAdaptiveWidthDialog clamps to viewport on a phone',
      (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showAdaptiveWidthDialog(ctx,
                  desiredWidth: 460, child: const SizedBox(height: 80)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final box = tester.getSize(find.byType(ConstrainedBox).first);
    expect(box.width, lessThanOrEqualTo(360 - 32));
    expect(tester.takeException(), isNull);
  });

  testWidgets('touchable guarantees a >= kMinTouch hit area', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: touchable(const Icon(Icons.close, size: 16)))),
    ));
    final size = tester.getSize(find.byType(ConstrainedBox).first);
    expect(size.width, greaterThanOrEqualTo(kMinTouch));
    expect(size.height, greaterThanOrEqualTo(kMinTouch));
  });
}
```

- [ ] **Step 4: Run → PASS (3 tests). Step 5: `flutter analyze` → No issues found!**

- [ ] **Step 6: Commit**

```bash
git add mobile/lib/ui/responsive.dart mobile/test/support/responsive_test_utils.dart mobile/test/responsive_test.dart
git commit -m "feat(ui): width-based responsive foundation (breakpoints, adaptive dialog, touch helper)"
```

---

### Task 2: Adaptive shell (drawers, fluid toolbar, AppBar overflow)

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart`
- Test: `mobile/test/shell_responsive_test.dart`

**Interfaces:** consumes Task 1 (`context.isExpanded`, etc.).

**Behavior spec (implement to make the tests pass):**
- At **≥ 840** (`isExpanded`): the body is the current 3-pane `Row` — inline `_buildLeftDockExplorer()` (280) + center + optional inline `TagInspectorDock`. No `Scaffold.drawer`. Visually unchanged.
- At **< 840** (not expanded): 
  - `Scaffold.drawer:` a `Drawer` whose body is the existing left-dock explorer content (extract the inner content of `_buildLeftDockExplorer()` so it can render both inline with `width:280` AND inside a `Drawer` without the fixed width). AppBar gets an automatic hamburger (leading) — do NOT also render the inline left dock.
  - `Scaffold.endDrawer:` a `Drawer` containing `TagInspectorDock` (width adaptive: `min(340, screenWidth*0.9)`), opened by the existing tag-toggle AppBar action (`Scaffold.of(context).openEndDrawer()`), NOT the inline right dock.
  - Center workspace fills the width (the body is just the center workspace).
  - Scan toolbar: replace `SizedBox(width: 220)` around the `Slider` with `Expanded`; wrap the row so the "(Slow Mo Step)"/"Scan Count" texts are hidden (`if (!context.isCompact)`) on compact. Must not overflow at 360.
  - AppBar trailing actions: keep run/stop + tag-toggle; move any that don't fit into a `PopupMenuButton`. (Keep it simple: on compact, show the 2–3 most important actions + a ⋮ menu for the rest.)
  - Selecting a destination from the drawer calls `Navigator.pop(context)` then the existing view-swap.
- Runtime/scan behavior unchanged (do not touch `_executeScan`, engines, or `_activeViewId` routing semantics — only where the panels are mounted).

- [ ] **Step 1: Write `mobile/test/shell_responsive_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

Widget _app() => const MaterialApp(home: WorkspaceShell());

void main() {
  testWidgets('phone: shell exposes a Drawer and no overflow', (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsWidgets); // drawer(s) registered
    // A hamburger opens the project drawer.
    final hamburger = find.byTooltip('Open navigation menu');
    expect(hamburger, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop: inline docks, no hamburger, no overflow', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small phone (320x568): no overflow', (tester) async {
    await setSurface(tester, smallPhoneSize);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
```

(If `WorkspaceShell` needs a non-const constructor or a parameter, adjust `_app()` to match the real signature — read the file first.)

- [ ] **Step 2: Run → FAIL. Step 3: Implement the adaptive shell** per the behavior spec (extract the left-dock content helper; add `drawer`/`endDrawer` on compact; fluid toolbar; AppBar overflow). Keep the expanded path byte-for-byte equivalent to today where practical.
- [ ] **Step 4: Run tests → PASS. Step 5: `flutter analyze` → clean; `flutter test` → full suite passes.**
- [ ] **Step 6: Commit** `feat(ui): adaptive shell — project drawer + tag end-drawer + fluid scan toolbar on compact`.

---

### Task 3: Dialogs + form/table screens (ST editor, project manager, simulated I/O, tag inspector)

**Files:**
- Modify: `mobile/lib/screens/st_editor_screen.dart`, `mobile/lib/screens/project_manager_screen.dart`, `mobile/lib/screens/simulated_io_screen.dart`, `mobile/lib/widgets/tag_inspector_dock.dart`
- Test: `mobile/test/forms_responsive_test.dart`

**Behavior spec:**
- **Dialogs:** convert the fixed-width dialogs to `showAdaptiveWidthDialog` (or wrap their body in the same `ConstrainedBox(maxWidth: min(desired, width-32))`): simulated I/O rule dialog (was 460). ST autocomplete overlay: add `maxWidth: min(360, screenWidth-32)`.
- **st_editor_screen.dart:** program-selector sidebar (280) inline on expanded; on compact move the program list into the `Scaffold.drawer` (or a dropdown above the editor) and let the code editor fill width; "Compile & Apply to PLC" → icon + short label on compact.
- **project_manager_screen.dart:** the 3-across `TextField` property row and 2-across preset buttons become a `Wrap`/`Column` on compact; add `TextOverflow.ellipsis` on the flagged `ListTile` subtitle/trailing texts.
- **simulated_io_screen.dart:** condition-editor row wraps on compact so operand controls stack (no fixed-56 squeeze); rule-card title `ellipsis`.
- **tag_inspector_dock.dart:** width adaptive (`min(340, screenWidth*0.9)`); wrap the 18px close button and Force button in `touchable(...)`; value pill text `ellipsis`.

- [ ] **Step 1: Write `mobile/test/forms_responsive_test.dart`** — pump each of the four screens at `phoneSize` and `desktopSize`, assert `tester.takeException()` is null in both. (Construct each screen with a default project from `DefaultProjects.all()`; read each screen's constructor signature first.) For simulated I/O, open the rule dialog on a phone and assert no overflow.
- [ ] **Step 2: Run → (dialog/overflow failures expected). Step 3: Implement** the adaptations above.
- [ ] **Step 4: Tests → PASS; `flutter analyze` clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(ui): adaptive form screens + viewport-clamped dialogs (ST, project, sim I/O, tag dock)`.

---

### Task 4: Memory Manager — table on desktop, cards on phone

**Files:**
- Modify: `mobile/lib/screens/memory_manager_screen.dart`
- Test: `mobile/test/memory_responsive_test.dart`

**Behavior spec:**
- Expanded (`isExpanded`): keep the existing 7-column `DataTable` (with its horizontal scroll).
- Compact: render the same tag/member hierarchy as a **vertical card list** — one `Card` per row with stacked label/value lines (Name, Path, Type, Live Value, Quality, I/O Class) and the existing expand/collapse control for struct/array/bit children. No `DataTable` in the compact tree.
- Enlarge the 16px expand/delete hit targets via `touchable(...)` on compact.
- The live-value cells must still update each scan (preserve the existing value-read path; only the layout changes).

- [ ] **Step 1: Write `mobile/test/memory_responsive_test.dart`** — pump `MemoryManagerScreen` with a struct-bearing default project (e.g. one with a TIMER/DUT tag) at `desktopSize` → expect `find.byType(DataTable)` findsOneWidget; at `phoneSize` → expect `find.byType(DataTable)` findsNothing and `tester.takeException()` null; expand a struct row on phone and assert children appear.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** the card fallback (extract a `_tagRowData` model so both the table and the cards render the same resolved values).
- [ ] **Step 4: Tests → PASS; analyze clean; full suite passes.**
- [ ] **Step 5: Commit** `feat(ui): Memory Manager card layout on compact, DataTable on desktop`.

---

### Task 5: Graphical editors — collapsible palettes + pan/zoom canvases (view + structured edit)

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart`, `mobile/lib/screens/sfc_editor_screen.dart`, `mobile/lib/screens/hmi_dashboard_builder_screen.dart`, `mobile/lib/screens/ld_editor_screen.dart`
- Test: `mobile/test/editors_responsive_test.dart`

**Behavior spec (per the "view + structured edit on compact" scope):**
- **Palettes (FBD/SFC/HMI, 260 fixed):** inline on expanded; on compact NOT inline — opened on demand as a bottom sheet / overlay via a toolbar button or `FloatingActionButton` ("Add …"). Default hidden on compact so the canvas is full width. (HMI already has `isPaletteVisible`; generalize: force-hidden inline on compact, surface via the sheet.)
- **FBD canvas:** wrap the absolute-positioned `Stack` in an `InteractiveViewer` (pan + zoom) so the wide area is reachable on a phone; keep free drag on expanded; on compact, tapping a block opens its existing configure dialog. Also convert that dialog via `showAdaptiveWidthDialog`.
- **SFC canvas:** step/transition card `width` → `min(450, availableWidth - margins)` using `LayoutBuilder`; the vertical `ListView` already scrolls.
- **HMI builder:** replace the `MediaQuery.width - 320` card-width math with the true available canvas width from a `LayoutBuilder` around the canvas (never negative); auto-hide the palette inline on compact; convert the component dialog (was 440) via `showAdaptiveWidthDialog`; RUN mode fully usable at phone width (no overflow).
- **LD editor:** wrap the mode-button toolbar in a `Wrap` (or horizontal `SingleChildScrollView`) so it never overflows on compact; keep the canvas `LayoutBuilder` min-width + horizontal scroll; wrap the 16px branch drag handles in `touchable(...)`; convert the node dialog (was 420) via `showAdaptiveWidthDialog`.

- [ ] **Step 1: Write `mobile/test/editors_responsive_test.dart`** — for each of the four editors, pump with a project that has the relevant program (FBD: proj_fbd_hvac; SFC: proj_sfc_filling; LD: proj_conveyor/motor; HMI: a project with an HMI screen) at `phoneSize` and `desktopSize`; assert `tester.takeException()` null at both. On compact, assert the inline 260 palette is NOT shown (e.g. the palette's search field / a known palette-only widget is absent until the sheet is opened) and that a "add"/palette toggle affordance exists.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** the adaptations. Read each editor fully first; preserve the expanded (desktop) layout and all existing editing behavior at ≥ 840.
- [ ] **Step 4: Tests → PASS; analyze clean; full suite passes; `flutter build web --release` succeeds.**
- [ ] **Step 5: Commit** `feat(ui): responsive graphical editors — collapsible palettes, pan/zoom canvases, fluid cards`.

---

### Task 6: Whole-app responsive validation + polish

**Files:**
- Create: `mobile/test/app_responsive_smoke_test.dart`

**Behavior spec:** a smoke test that, for EACH default project and EACH primary view (HMI, each language editor, Memory, Simulated I/O, Project Manager), pumps the shell at `phoneSize`, `smallPhoneSize`, and `desktopSize`, navigates to the view, and asserts `tester.takeException()` is null (no overflow anywhere). This is the safety net that catches any screen missed by Tasks 2–5.

- [ ] **Step 1: Write the smoke test** driving `WorkspaceShell` — switch projects via the drawer/dropdown and switch views, at all three sizes. Keep it pragmatic (it need not exercise every leaf, but must visit every top-level view of at least the "all languages" water project plus one of each editor type).
- [ ] **Step 2:** `flutter test` → all pass · `flutter analyze` → No issues found! · `flutter build web --release` → succeeds · `grep -ri "openplc\|beremiz" lib test` → no matches.
- [ ] **Step 3: Commit** `test(ui): whole-app responsive smoke tests at phone and desktop sizes`.

---

## Self-review notes

- **Spec coverage:** foundation + adaptive dialog + touch helper (Task 1) ✓; shell drawers/toolbar/appbar (Task 2) ✓; dialogs clamp + ST/project/simIO/tag-dock adapt (Task 3) ✓; Memory table→cards (Task 4) ✓; FBD/SFC/HMI palettes→sheets + canvases pan/zoom + LD toolbar/handles (Task 5) ✓; whole-app overflow smoke net (Task 6) ✓; width-based (never platform) ✓; engines untouched ✓.
- **Type consistency:** `context.isCompact`/`isExpanded`, `showAdaptiveWidthDialog`, `touchable`, `setSurface`/`phoneSize`/`desktopSize` used identically across tasks.
- **Verification is deterministic** via fixed surface sizes + `takeException()` (no reliance on Chrome screenshots).
- **Risk note:** Task 2 (shell) and Task 5 (editors) are the largest; both keep the ≥ 840 path unchanged and gate all new structure behind `isCompact`/`!isExpanded` so desktop can't regress. Reviewers should confirm the expanded path is untouched and the compact path never overflows.
