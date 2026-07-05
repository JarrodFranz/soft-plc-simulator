# Responsive & Adaptive Layout (WS5) — Design Spec

**Date:** 2026-07-05
**Status:** Approved by delegation (user: make the app suitable for phone AND
web-on-a-monitor; scope decision — graphical canvases are "view + structured
edit" on phone, precise free-drag stays desktop-first).
**Author:** Claude (pairing with Jarrod)

The IEC 61131-3 editor/simulator is currently a desktop-first 3-pane IDE with
**no width-based responsiveness**. This workstream makes every screen adapt to
the available width so it is usable on a phone (~360–400 px) and on a desktop
browser at any window size, without a separate mobile app.

## Principle: adapt to WIDTH, not platform

All adaptation keys on the current layout width (via `MediaQuery`/`LayoutBuilder`),
never on `Platform.isAndroid`/`kIsWeb`. A desktop browser narrowed to phone
width gets the phone treatment; a tablet in landscape gets the desktop
treatment. One code path, driven by breakpoints.

### Breakpoints (`mobile/lib/ui/responsive.dart` — new)

```dart
abstract class Breakpoints {
  static const double compact = 640;  // < 640: phone / narrow window
  static const double medium  = 840;  // 640–840: large phone landscape / small tablet
  // >= 840: expanded (desktop, web-on-monitor, tablet landscape)
}

enum WidthClass { compact, medium, expanded }

extension ResponsiveContext on BuildContext {
  double get widthPx => MediaQuery.sizeOf(this).width;
  WidthClass get widthClass { ... }        // from widthPx
  bool get isCompact  => widthClass == WidthClass.compact;   // < 640
  bool get isExpanded => widthClass == WidthClass.expanded;  // >= 840
}
```

- **compact (< 640):** single-pane; docks/palettes become drawers/sheets.
- **medium (640–840):** single-pane center, but docks can be wider sheets; the
  left project tree may show as a permanent-narrow rail only if it fits — for
  simplicity WS5 treats medium like compact for the shell (drawers) and like
  expanded for in-screen palettes where they fit. (Kept minimal; the two real
  targets are compact and expanded.)
- **expanded (>= 840):** the current multi-pane IDE, unchanged.

### Shared helpers (same file)

- `adaptiveDialog(context, {required Widget child, double desiredWidth})` —
  wraps `Dialog` with `insetPadding` and a `maxWidth = min(desiredWidth,
  screenWidth - 32)` so no dialog ever exceeds the viewport. Replaces every
  hardcoded `width: 420/440/460` dialog.
- `kMinTouch = 44.0` — minimum finger hit-target; a `touchable(...)` helper
  wraps small icon buttons to guarantee the hit area on compact without
  changing their visual size.

## Per-area design

### 1. Shell (`workspace_shell.dart`)

- **Expanded (>= 840):** unchanged 3-pane — left project-tree dock (280),
  center workspace, right Tag Inspector dock (340, user-toggled).
- **Compact (< 840):**
  - Left project-tree dock → a **`Drawer`** opened by a hamburger in the AppBar.
    (Reuse the existing `_buildLeftDockExplorer()` content as the drawer body.)
  - Tag Inspector dock → an **`endDrawer`** (slide-in from right) opened by the
    existing tag-toggle, now an AppBar action. (Reuse `TagInspectorDock`; drop
    its hardcoded 340 width when inside the drawer — make width adaptive:
    `min(340, screenWidth * 0.9)`.)
  - Center workspace fills the width.
  - **Scan toolbar:** the fixed `SizedBox(width: 220)` slider becomes
    `Expanded`; the "(Slow Mo Step)" and "Scan Count" texts hide on compact
    (or move under the slider). No overflow at 360.
  - **AppBar:** actions that don't fit collapse into a `PopupMenuButton` (⋮) on
    compact; keep the run/stop + hamburger + tag-toggle visible.
  - Selecting a destination in the drawer closes it (Navigator.pop) then swaps
    the center view, same `_activeViewId` routing as today.

### 2. Dialogs (global, cheap win)

Replace the hardcoded dialog widths with `adaptiveDialog(...)`:
- `ld_editor_screen.dart` node dialog (was 420)
- `hmi_dashboard_builder_screen.dart` component dialog (was 440)
- `simulated_io_screen.dart` rule dialog (was 460)
- `st_editor_screen.dart` autocomplete overlay: add `maxWidth` clamp.
Each still looks the same on desktop; fits within the viewport on phone.

### 3. Form/table screens

- **`st_editor_screen.dart`:** the fixed 280 program-selector sidebar shows
  inline on expanded; on compact it collapses — the program list moves to a
  `Drawer` (or a dropdown above the editor), and the code editor fills the
  width. The "Compile & Apply to PLC" button shrinks to an icon+short label on
  compact. Autocomplete overlay width-clamped.
- **`project_manager_screen.dart`:** the 3-across property `TextField` row and
  the 2-across preset buttons wrap to a `Column` (or `Wrap`) on compact; add
  `TextOverflow.ellipsis` to `ListTile` trailing/subtitle text.
- **`simulated_io_screen.dart`:** the condition-editor row (mixed flex + fixed
  56) wraps on compact so operand controls stack; dialog via `adaptiveDialog`;
  rule-card title gets `ellipsis`.
- **`tag_inspector_dock.dart`:** width adaptive (see shell); enlarge the 18px
  close button and Force button hit targets to `kMinTouch`; value pill text
  `ellipsis`.

### 4. Memory Manager (`memory_manager_screen.dart`)

- **Expanded:** keep the 7-column `DataTable` (with its existing horizontal
  scroll).
- **Compact:** render the same tag/member tree as a **vertical card list** —
  one card per tag showing name, path, type, live value, quality, I/O class as
  stacked label/value rows, with the expand/collapse control for struct/array/
  bit children preserved. No 7-column horizontal scrolling on a phone.
- Enlarge the 16px expand/delete hit targets on compact.

### 5. Graphical editors — "view + structured edit" on compact

Per the scope decision: on compact these canvases are **pan/zoom viewers** with
add/delete/configure via taps → dialogs/sheets; precise free-drag positioning
stays an expanded-only affordance.

- **Palette (FBD/SFC/HMI, all 260 fixed):** inline on expanded; on compact it
  becomes an **on-demand bottom sheet / overlay** opened by a toolbar button or
  FAB ("Add block/step/widget"). Generalize the toggle HMI already has; default
  hidden on compact so the canvas gets full width.
- **FBD canvas:** wrap the absolute-positioned `Stack` in an `InteractiveViewer`
  (pan/zoom) so the wide drawing area is reachable on a phone. Free block drag
  (`onPanUpdate`) remains for expanded; on compact, tap a block → configure
  sheet (retitle, rebind tag, delete). Block cards stay 180 but are reachable
  via pan/zoom.
- **SFC canvas:** the 450px step/transition cards become
  `width: min(450, availableWidth - margins)` so they fit a phone column; the
  vertical `ListView` already scrolls. Add/edit steps & transitions via the
  existing dialogs (reachable on compact).
- **HMI builder:** fix the card-width formula that subtracts a fixed 320 (it
  goes negative at 360) — base it on the true available canvas width from
  `LayoutBuilder`, not `MediaQuery.width - 320`. Auto-hide the palette on
  compact (it already has a toggle). RUN mode must be fully usable on a phone
  (it's how an operator would use the HMI on the floor).
- **LD editor:** the mode-button toolbar wraps (`Wrap`) or horizontal-scrolls
  on compact; the canvas keeps its existing `LayoutBuilder` min-width +
  horizontal scroll; enlarge the 16px branch drag handles' hit area (transparent
  padding) so they're usable — but per scope, branch-drag editing is expanded-
  first; on compact the rung is pan/scroll viewable and elements are
  added/configured via taps → dialogs.

## Cross-cutting hygiene (applies everywhere touched)

- No `RenderFlex` overflow at 360×640 or 320×568 (smallest supported).
- Every screen's scrollable content is actually scrollable (no unbounded
  `Column` under a short viewport).
- `TextOverflow.ellipsis` / `Flexible` on the flagged labels.
- Interactive icon targets ≥ `kMinTouch` on compact.
- Dark theme preserved; existing desktop appearance unchanged at >= 840.

## Testing

Verification is by **Flutter widget tests at fixed surface sizes** (Chrome
screenshots are unreliable in this environment). For each adapted screen:
- Pump it at a phone size (e.g. `tester.view.physicalSize = 360×740`) and a
  desktop size (`1400×900`); assert `tester.takeException()` is null (no
  overflow) in both.
- Assert the adaptive structure: on compact the shell exposes a `Drawer`
  (hamburger present) and NO inline 280 left dock; on expanded the inline dock
  is present and there is no hamburger. Memory Manager shows a `DataTable` on
  expanded and cards (no `DataTable`) on compact.
- Existing 103 tests must still pass; `flutter analyze` zero; `flutter build web
  --release` succeeds.

A shared test helper sets/reset the surface size so tests are deterministic.

## Global constraints (unchanged)

No third-party/reference-editor branding · dark theme · `flutter analyze` zero
issues · no RenderFlex overflow (now enforced at phone sizes too) · engines in
`mobile/lib/models` stay untouched (this is a pure UI/layout workstream — no
scan/execution behavior changes).

## Out of scope (deferred)

- Precise finger free-drag repositioning of graphical blocks/steps on compact
  (expanded-only per scope).
- Platform packaging / native mobile builds, gestures beyond pan/zoom, haptics
  (Phase 7).
- Persisting a user-chosen layout density or dock sizes.
- Landscape-specific special cases beyond what width breakpoints already give.
