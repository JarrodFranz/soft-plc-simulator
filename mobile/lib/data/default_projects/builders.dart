// Shared construction helpers for the seven built-in default projects.
//
// Dart privacy is LIBRARY-scoped, so the ladder shorthands that used to be
// private statics on `DefaultProjects` (`_xic`, `_ote`, …) cannot be shared
// across the one-file-per-project split. They are promoted to public
// top-level functions here, `ld`-prefixed so they never collide with model
// identifiers. `buildRung`/`BranchSpec` still come from `models/ld_graph.dart`.
library;

import '../../models/project_model.dart';

// ── Contacts ─────────────────────────────────────────────────────────────
LdNode ldXic(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'normal', comment: c);
LdNode ldXio(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'negated', comment: c);
LdNode ldXicRising(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'rising', comment: c);
LdNode ldXicFalling(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.contact, variable: v, modifier: 'falling', comment: c);

// ── Coils ────────────────────────────────────────────────────────────────
LdNode ldOte(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'normal', comment: c);
LdNode ldOteNeg(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'negated', comment: c);
LdNode ldOtl(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'set', comment: c);
LdNode ldOtu(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'reset', comment: c);
/// One-scan pulse on the RISING edge of this coil's power flow.
LdNode ldOsr(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'rising', comment: c);
/// One-scan pulse on the FALLING edge of this coil's power flow.
LdNode ldOsf(String v, [String c = '']) =>
    LdNode(id: '', kind: LdKind.coil, variable: v, modifier: 'falling', comment: c);

// ── Blocks ───────────────────────────────────────────────────────────────
LdNode ldTon(String v, int ms, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: 'TON', variable: v, presetMs: ms, comment: c);
LdNode ldTof(String v, int ms, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: 'TOF', variable: v, presetMs: ms, comment: c);

/// Count-up counter. NOTE: `ld_exec.dart` reads the preset from
/// `LdNode.presetMs` — an `int` literal — so a CTU preset can never be a tag
/// reference on the ladder side. Callers that also want the preset visible as
/// a tag must keep the two in sync themselves.
LdNode ldCtu(String v, int preset, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: 'CTU', variable: v, presetMs: preset, comment: c);

/// Comparison block; [type] ∈ `GT LT GE LE EQ NE`. Operands are numeric
/// literals or tag paths (resolved by `_operandValue` in `ld_exec.dart`).
LdNode ldCmp(String type, String a, String b, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: type, operandA: a, operandB: b, comment: c);

/// Arithmetic block; [type] ∈ `ADD SUB MUL DIV`. Writes `a <op> b` into [dest].
LdNode ldMath(String type, String dest, String a, String b, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: type, variable: dest,
    operandA: a, operandB: b, comment: c);

/// MOVE block: writes [src] (literal or tag path) into [dest].
LdNode ldMove(String dest, String src, [String c = '']) => LdNode(
    id: '', kind: LdKind.block, blockType: 'MOVE', variable: dest,
    operandA: src, operandB: '0', comment: c);

/// Custom function-block call: [fbName] is an `FbDefinition.name`, [instance]
/// is the instance tag path, [pins] maps pin name -> tag path (input pins are
/// read from those tags, output pins are written back to them).
LdNode ldFbCall(String fbName, String instance, Map<String, String> pins,
        [String c = '']) =>
    LdNode(
        id: '', kind: LdKind.block, blockType: fbName, variable: instance,
        pinBindings: Map<String, String>.from(pins), comment: c);

// ── Scratch projects for `defaultValueFor(...)` ───────────────────────────

/// Throwaway project used only to resolve built-in composite (TIMER/COUNTER)
/// and scalar-array default values, which do not depend on a project's own
/// structDefs or fbDefinitions.
final PlcProject emptyScratchProject = PlcProject(
  id: '_scratch',
  name: '_scratch',
  controllerName: '_scratch',
  tags: [],
  structDefs: [],
  programs: [],
  tasks: [],
  hmis: [],
);

/// Throwaway project carrying [structDefs] / [fbDefinitions] so
/// `defaultValueFor(...)` can expand a DUT-typed or FB-instance-typed tag's
/// structural default before the real project object exists.
PlcProject scratchProjectFor({
  List<PlcStructDef> structDefs = const [],
  List<FbDefinition> fbDefinitions = const [],
}) =>
    PlcProject(
      id: '_scratch_for',
      name: '_scratch_for',
      controllerName: '_scratch',
      tags: [],
      structDefs: List<PlcStructDef>.from(structDefs),
      programs: [],
      tasks: [],
      hmis: [],
      fbDefinitions: List<FbDefinition>.from(fbDefinitions),
    );
