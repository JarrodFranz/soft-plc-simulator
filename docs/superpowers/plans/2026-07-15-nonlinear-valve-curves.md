# Nonlinear Valve Curves Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a selectable valve characteristic (linear / equal-percentage / quick-opening, fixed shapes) to the Simulated I/O analog-gain path, so a valve %→flow mapping can be nonlinear.

**Architecture:** A pure `valve_curve.dart` helper transforms the `source/refValue` fraction; `SimRule` gains a `valveCurve` field (default `'linear'` → numerically identical to today); `_gain` in `sim_engine.dart` routes the fraction through the helper (only the `integrate`/`ramp` analog-gain path); the Simulated I/O rule editor gains a dropdown shown for `integrate`/`ramp` rules with an actuator.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`. Package name `soft_plc_mobile`.

## Global Constraints

- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control flow; zero `flutter analyze` warnings.
- No RenderFlex overflow at 320 / 360 / 1400.
- Pure Dart (no Flutter imports) in `mobile/lib/models/` incl. new `models/valve_curve.dart`.
- Additive persistence: `valveCurve` defaults to `'linear'`; a rule with no `valve_curve` loads as linear and is behaviourally identical; default projects' 20-scan scan-equivalence stays green.
- Deterministic/pure (no clock/random).

## Key facts (verified against the code)

- `mobile/lib/models/project_model.dart:549` — `class SimRule { String id; String name; bool enabled; String targetPath; String behavior; int delayMs; int onMs; int offMs; double ratePerSec; double targetValue; double minValue; double maxValue; List<SimClause> condition; String sourcePath; double refValue; double tauSec; }`, with a constructor (all fields defaulted) and `fromJson`/`toJson` that always emit every field (json keys: `id,name,enabled,target,behavior,delay_ms,on_ms,off_ms,rate,target_value,min,max,condition,source,ref_value,tau_sec`).
- `mobile/lib/models/sim_engine.dart:123-124` — `double _gain(PlcProject p, SimRule r) => (r.sourcePath.isEmpty || r.refValue == 0) ? 1.0 : _asDouble(readPath(p, r.sourcePath)) / r.refValue;`. Used at `:167` (ramp) and `:181` (integrate) as `rule.ratePerSec * dt * _gain(p, rule)`. `dt` is in seconds. Entry point: `void applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt)`; runtime `SimRuntime()`.
- `mobile/lib/screens/simulated_io_screen.dart:250` — `_behaviorParams(SimRule r, bool numeric, List<String> paths, StateSetter setDlg)` returns the per-behaviour fields. Inside `if (numeric)` (i.e. `ramp`/`integrate`), after `_numField('= 100% rate at', r.refValue, ...)` at line 280, is where the actuator (`sourcePath`) + refValue live. `_numField(label, value, onChanged)` and `TagAutocompleteField(...)` helpers exist. Dialog rebuilds via `setDlg(() => ...)`.
- Existing sim engine tests are in `mobile/test/` (search `sim_engine`); serialization round-trip tests in `mobile/test/serialization_roundtrip_test.dart`.

---

### Task 1: Pure valve-curve helper

**Files:**
- Create: `mobile/lib/models/valve_curve.dart`
- Test: `mobile/test/valve_curve_test.dart`

**Interfaces:**
- Produces: `const String kValveLinear`, `kValveEqualPercentage`, `kValveQuickOpening`; `const double kEqualPercentageR`; `double valveCurveGain(String curve, double fraction)`.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/valve_curve_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/valve_curve.dart';

void main() {
  test('linear passes the fraction through unchanged (incl. out of range)', () {
    expect(valveCurveGain(kValveLinear, 0.0), 0.0);
    expect(valveCurveGain(kValveLinear, 0.37), 0.37);
    expect(valveCurveGain(kValveLinear, 1.5), 1.5);
    expect(valveCurveGain(kValveLinear, -0.2), -0.2);
    // Unknown curve also falls back to linear passthrough.
    expect(valveCurveGain('bogus', 0.42), 0.42);
  });

  test('equal-percentage: endpoints, convex, clamped', () {
    expect(valveCurveGain(kValveEqualPercentage, 0.0), closeTo(0.0, 1e-9));
    expect(valveCurveGain(kValveEqualPercentage, 1.0), closeTo(1.0, 1e-9));
    // Convex: at half travel the gain is well below 0.5.
    expect(valveCurveGain(kValveEqualPercentage, 0.5), lessThan(0.5));
    // Clamped to [0,1].
    expect(valveCurveGain(kValveEqualPercentage, 1.5),
        closeTo(valveCurveGain(kValveEqualPercentage, 1.0), 1e-9));
    expect(valveCurveGain(kValveEqualPercentage, -0.3),
        closeTo(valveCurveGain(kValveEqualPercentage, 0.0), 1e-9));
  });

  test('quick-opening: endpoints, concave, clamped', () {
    expect(valveCurveGain(kValveQuickOpening, 0.0), closeTo(0.0, 1e-9));
    expect(valveCurveGain(kValveQuickOpening, 1.0), closeTo(1.0, 1e-9));
    // Concave: at half travel the gain is above 0.5 (sqrt(0.5) ~= 0.707).
    expect(valveCurveGain(kValveQuickOpening, 0.5), greaterThan(0.5));
    expect(valveCurveGain(kValveQuickOpening, 1.7),
        closeTo(valveCurveGain(kValveQuickOpening, 1.0), 1e-9));
  });

  test('both curves are monotonic increasing on [0,1]', () {
    for (final c in [kValveEqualPercentage, kValveQuickOpening]) {
      double prev = -1;
      for (var i = 0; i <= 10; i++) {
        final g = valveCurveGain(c, i / 10);
        expect(g, greaterThanOrEqualTo(prev));
        prev = g;
      }
    }
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/valve_curve_test.dart`
Expected: FAIL — `valve_curve.dart` / `valveCurveGain` undefined.

- [ ] **Step 3: Implement the helper**

Create `mobile/lib/models/valve_curve.dart`:

```dart
import 'dart:math' as math;

/// The three supported valve characteristics.
const String kValveLinear = 'linear';
const String kValveEqualPercentage = 'equalPercentage';
const String kValveQuickOpening = 'quickOpening';

/// Equal-percentage rangeability (fixed, standard).
const double kEqualPercentageR = 50.0;

/// Maps a raw valve fraction (`source / refValue`, typically 0..1) to an
/// effective gain through the selected valve characteristic.
///
/// - `linear` (or any unknown value): returns [fraction] unchanged, including
///   values > 1 or < 0 — numerically identical to the pre-feature behaviour.
/// - `equalPercentage`: fraction clamped to [0,1], then `(R^f - 1)/(R - 1)`
///   with R = 50 — convex; endpoints 0->0, 1->1.
/// - `quickOpening`: fraction clamped to [0,1], then `sqrt(f)` — concave;
///   endpoints 0->0, 1->1.
double valveCurveGain(String curve, double fraction) {
  switch (curve) {
    case kValveEqualPercentage:
      final f = fraction.clamp(0.0, 1.0);
      return (math.pow(kEqualPercentageR, f) - 1) / (kEqualPercentageR - 1);
    case kValveQuickOpening:
      final f = fraction.clamp(0.0, 1.0);
      return math.sqrt(f);
    default:
      return fraction;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/valve_curve_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/valve_curve.dart mobile/test/valve_curve_test.dart
git commit -m "feat(sim): pure nonlinear valve-curve helper (linear/equal-pct/quick-opening)"
```

---

### Task 2: `SimRule.valveCurve` field + engine wiring

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`SimRule`)
- Modify: `mobile/lib/models/sim_engine.dart` (`_gain`)
- Test: `mobile/test/valve_curve_engine_test.dart` (create)

**Interfaces:**
- Consumes: `valveCurveGain` (Task 1).
- Produces: `SimRule.valveCurve` (String, default `'linear'`, json key `valve_curve`).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/valve_curve_engine_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';

PlcProject _projWith(String curve) {
  final proj = PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [
      PlcTag(name: 'Valve', path: 'Valve', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
      PlcTag(name: 'Level', path: 'Level', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
    ],
    structDefs: [], programs: [], tasks: [], hmis: [],
  );
  proj.simRules.add(SimRule(
    id: 'r', name: 'fill', targetPath: 'Level', behavior: 'integrate',
    ratePerSec: 100.0, minValue: 0.0, maxValue: 1000.0,
    sourcePath: 'Valve', refValue: 100.0, valveCurve: curve,
  ));
  return proj;
}

void main() {
  test('equal-percentage integrates less than linear at a low valve %', () {
    final lin = _projWith('linear');
    final eq = _projWith('equalPercentage');
    final rtL = SimRuntime();
    final rtE = SimRuntime();
    // One 1-second scan; Valve=20 -> fraction 0.2.
    applySimRules(lin, lin.simRules, 1000, rtL);
    applySimRules(eq, eq.simRules, 1000, rtE);
    final linLevel = lin.tags.firstWhere((t) => t.name == 'Level').value as num;
    final eqLevel = eq.tags.firstWhere((t) => t.name == 'Level').value as num;
    // linear: 100*1*0.2 = 20; equal-pct gain(0.2) ~ 0.024 -> ~2.4.
    expect(linLevel, closeTo(20.0, 1e-6));
    expect(eqLevel, lessThan(linLevel));
    expect(eqLevel, greaterThan(0.0));
  });

  test('linear (default) reproduces the pre-feature accumulation exactly', () {
    final lin = _projWith('linear');
    final rt = SimRuntime();
    applySimRules(lin, lin.simRules, 1000, rt);
    expect(lin.tags.firstWhere((t) => t.name == 'Level').value as num, closeTo(20.0, 1e-9));
  });

  test('SimRule.valveCurve round-trips; absent key loads as linear', () {
    final r = SimRule(
      id: 'r', name: 'n', targetPath: 'L', behavior: 'integrate',
      sourcePath: 'V', refValue: 100.0, valveCurve: 'quickOpening');
    expect(SimRule.fromJson(r.toJson()).valveCurve, 'quickOpening');
    final legacy = Map<String, dynamic>.from(r.toJson())..remove('valve_curve');
    expect(SimRule.fromJson(legacy).valveCurve, 'linear');
  });
}
```

(If a `SimRule` with an empty `condition` is not "active" in the engine, add `condition: [SimClause(...)]` that evaluates true — read `sim_engine.dart` to confirm; adjust the fixture only, not the assertions. `integrate` rules in the default projects run with conditions, so an always-true clause may be required.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/valve_curve_engine_test.dart`
Expected: FAIL — `SimRule` has no `valveCurve` param.

- [ ] **Step 3: Add the model field**

In `mobile/lib/models/project_model.dart` `SimRule`:
- Add the field near `tauSec`: `String valveCurve;`
- Constructor named param: `this.valveCurve = 'linear',`
- `fromJson`: add `valveCurve: j['valve_curve'] ?? 'linear',`
- `toJson`: add `'valve_curve': valveCurve,`

(Use the literal `'linear'` — do NOT import `valve_curve.dart` into the model, to keep the model dependency-free.)

- [ ] **Step 4: Route the fraction through the curve in `_gain`**

In `mobile/lib/models/sim_engine.dart`, add the import at the top:

```dart
import 'valve_curve.dart';
```

Replace `_gain` with:

```dart
double _gain(PlcProject p, SimRule r) {
  if (r.sourcePath.isEmpty || r.refValue == 0) {
    return 1.0;
  }
  final fraction = _asDouble(readPath(p, r.sourcePath)) / r.refValue;
  return valveCurveGain(r.valveCurve, fraction);
}
```

(The `integrate`/`ramp` call sites are unchanged. For `valveCurve == 'linear'` this returns exactly `fraction`.)

- [ ] **Step 5: Run test to verify it passes**

Run: `cd mobile && flutter test test/valve_curve_engine_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the existing sim + round-trip suites (no regression)**

Run: `cd mobile && flutter test test/sim_engine_test.dart test/serialization_roundtrip_test.dart`
Expected: PASS (linear default → identical numerics; `valve_curve` is additive and round-trips).

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/models/project_model.dart mobile/lib/models/sim_engine.dart mobile/test/valve_curve_engine_test.dart
git commit -m "feat(sim): SimRule.valveCurve + _gain routes the actuator fraction through the curve"
```

---

### Task 3: Editor dropdown

**Files:**
- Modify: `mobile/lib/screens/simulated_io_screen.dart` (`_behaviorParams`)
- Test: `mobile/test/simulated_io_valve_curve_test.dart` (create)

**Interfaces:**
- Consumes: `kValveLinear`/`kValveEqualPercentage`/`kValveQuickOpening` (Task 1), `SimRule.valveCurve` (Task 2).

**Context:** In `_behaviorParams`, inside the `if (numeric)` block (ramp/integrate), after the `_numField('= 100% rate at', r.refValue, ...)` line, add a Valve characteristic `DropdownButtonFormField<String>` bound to `r.valveCurve`, shown only when `r.sourcePath` is non-empty (the actuator is set).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/simulated_io_valve_curve_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/simulated_io_screen.dart';

void main() {
  testWidgets('valve-curve dropdown shows for an integrate rule with an actuator', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'Valve', path: 'Valve', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
        PlcTag(name: 'Level', path: 'Level', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    proj.simRules.add(SimRule(
      id: 'r', name: 'fill', targetPath: 'Level', behavior: 'integrate',
      ratePerSec: 100.0, sourcePath: 'Valve', refValue: 100.0));

    await tester.pumpWidget(MaterialApp(
      home: SimulatedIoScreen(currentProject: proj, onProjectUpdated: () {}),
    ));
    await tester.pumpAndSettle();

    // Open the rule editor (tap the rule row / an edit affordance).
    await tester.tap(find.text('fill').first);
    await tester.pumpAndSettle();

    // The valve-characteristic control is present.
    expect(find.textContaining('Valve characteristic'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
```

(Confirm `SimulatedIoScreen`'s real constructor params by reading `simulated_io_screen.dart` — adjust the pump + the "open editor" tap to the actual row-tap/edit flow if it differs; keep the assertion that the valve-characteristic control renders.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mobile && flutter test test/simulated_io_valve_curve_test.dart`
Expected: FAIL — no 'Valve characteristic' control.

- [ ] **Step 3: Add the dropdown**

In `mobile/lib/screens/simulated_io_screen.dart`, add the import:

```dart
import '../models/valve_curve.dart';
```

In `_behaviorParams`, immediately after the `w.add(_numField('= 100% rate at', r.refValue, (v) => r.refValue = v));` line (inside `if (numeric)`), add:

```dart
      if (r.sourcePath.isNotEmpty) {
        w.add(const Padding(
          padding: EdgeInsets.only(top: 10, bottom: 2),
          child: Text('Valve characteristic', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
        ));
        w.add(DropdownButtonFormField<String>(
          initialValue: (r.valveCurve == kValveEqualPercentage || r.valveCurve == kValveQuickOpening)
              ? r.valveCurve
              : kValveLinear,
          isExpanded: true,
          decoration: const InputDecoration(isDense: true),
          items: const [
            DropdownMenuItem(value: kValveLinear, child: Text('Linear', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: kValveEqualPercentage, child: Text('Equal-percentage', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: kValveQuickOpening, child: Text('Quick-opening', style: TextStyle(fontSize: 12))),
          ],
          onChanged: (v) => setDlg(() => r.valveCurve = v ?? kValveLinear),
        ));
      }
```

(Match the file's existing `DropdownButtonFormField` style — the behaviour dropdown at line ~198 is the pattern. If the installed Flutter uses `value:` rather than `initialValue:` for `DropdownButtonFormField`, match whatever the existing behaviour dropdown uses.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mobile && flutter test test/simulated_io_valve_curve_test.dart`
Expected: PASS.

- [ ] **Step 5: Overflow guard + analyze + commit**

Run: `cd mobile && flutter analyze`
Expected: No issues.

```bash
git add mobile/lib/screens/simulated_io_screen.dart mobile/test/simulated_io_valve_curve_test.dart
git commit -m "feat(sim): valve-characteristic dropdown in the Simulated I/O rule editor"
```

---

### Task 4: Validation, docs, roadmap/readme

**Files:**
- Modify: `docs/simulated-io.md` (or the closest existing sim doc; else create `docs/valve-curves.md`), `ROADMAP.md`, `README.md`

- [ ] **Step 1: Full green gate**

Run: `cd mobile && flutter analyze`
Expected: No issues.

Run: `cd mobile && flutter test`
Expected: All tests PASS (existing suite + the new valve-curve tests).

Run: `cd mobile && flutter build web --release`
Expected: Builds.

- [ ] **Step 2: Docs**

Document nonlinear valve curves: the three characteristics (linear passthrough; equal-percentage `(50^f−1)/49`, convex; quick-opening `sqrt(f)`, concave), that they apply to an `integrate`/`ramp` rule's actuator gain (`source/refValue`) only, that linear is the default and behaviour-identical, and that nothing new-shaped is persisted beyond the additive `valve_curve` field. Add to the existing Simulated I/O doc if one exists (search `docs/` for `simulated`), else create `docs/valve-curves.md`.

- [ ] **Step 3: Update ROADMAP.md + README.md**

In `ROADMAP.md` Phase 9, mark nonlinear valve curves as shipped (match the existing Phase 9 deliverable bullet style — Phase 9 lists "nonlinear valve curves" under the planned/⏳ enhancements; move it to ✅). In `README.md`, add a brief mention to the Simulated I/O feature bullet. Keep the hard rule: no "OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix" branding, no reverse-engineering wording.

- [ ] **Step 4: Commit**

```bash
git add docs ROADMAP.md README.md
git commit -m "docs(sim): nonlinear valve curves — docs + roadmap/readme"
```

---

## Self-Review

**Spec coverage:**
- Pure curve helper (linear passthrough, equal-pct convex, quick-opening concave, clamped) → Task 1. ✓
- `SimRule.valveCurve` additive field + json → Task 2. ✓
- `_gain` routes the fraction through the curve; only integrate/ramp; linear identical → Task 2. ✓
- Editor dropdown shown only for integrate/ramp with an actuator → Task 3. ✓
- Testing (pure curve, engine numeric guard + linear-identical, round-trip incl. absent-key→linear, widget, overflow) → Tasks 1-3. ✓
- Docs/roadmap/readme → Task 4. ✓
- Optional default-project showcase → intentionally omitted (spec left it a plan-time call; kept out to avoid shifting a default project's simulated behaviour without a dedicated re-baseline).

**Placeholder scan:** No TBD/TODO. Every code step shows code. The "read X and adjust the fixture" notes are real reconciliation instructions (constructor param shapes, empty-condition activeness, DropdownButtonFormField `value` vs `initialValue`), not logic placeholders.

**Type consistency:** `valveCurveGain(String, double) → double`; constants `kValveLinear`/`kValveEqualPercentage`/`kValveQuickOpening`/`kEqualPercentageR` used identically in Tasks 1/2/3. `SimRule.valveCurve` (String, default `'linear'`, json `valve_curve`) consistent across Tasks 2/3. Engine `_gain` signature unchanged.
