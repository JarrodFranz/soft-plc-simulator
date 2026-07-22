import '../models/project_model.dart';
import '../models/ld_graph.dart';
import '../models/tag_resolver.dart';
import 'import_ir.dart';

/// Throwaway empty project used only to reach `tag_resolver`'s canonical
/// composite defaults (`defaultValueFor`) for TIMER/COUNTER instance tags —
/// so the structured shape stays in one place (no drift from a hand-written
/// field map). `tag_resolver` imports only `project_model.dart`, so this keeps
/// `ld_translate` Flutter-free with no import cycle.
final PlcProject _scratchProject = PlcProject(
  id: 'scratch',
  name: 'scratch',
  controllerName: 'PLC',
  programs: [],
  tasks: [],
  hmis: [],
  structDefs: [],
  tags: [],
);

/// Result of translating one LD `GraphBody`. `rungs` includes placeholder
/// rungs (for untranslatable components) so program rung numbering matches the
/// source. `translatedRungCount > 0` is the mapper's real-program-vs-stub
/// decision. `instanceTags` are TIMER/COUNTER-typed tags the mapper must add so
/// translated timer/counter blocks have backing state.
class LdTranslation {
  final List<LdRung> rungs;
  final List<ImportWarning> warnings;
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedBlockTypes;
  final Map<String, int> stubReasons;
  final List<PlcTag> instanceTags;
  LdTranslation({
    required this.rungs,
    required this.warnings,
    required this.translatedRungCount,
    required this.stubbedRungCount,
    required this.unsupportedBlockTypes,
    required this.stubReasons,
    required this.instanceTags,
  });
}

/// Parses an IEC 61131 duration literal (`T#5s`, `TIME#500ms`, `T#1m30s`,
/// `T#1.5s`) to milliseconds. Case-insensitive. Returns null if [literal] is
/// not a duration. Supported units: d, h, m, s, ms.
int? parseIecDuration(String literal) {
  var s = literal.trim().toLowerCase();
  if (s.startsWith('time#')) {
    s = s.substring(5);
  } else if (s.startsWith('t#')) {
    s = s.substring(2);
  } else {
    return null;
  }
  if (s.isEmpty) return null;
  // Ordered so 'ms' is matched before 'm'.
  final re = RegExp(r'(\d+(?:\.\d+)?)(ms|d|h|m|s)');
  const unitMs = {'d': 86400000.0, 'h': 3600000.0, 'm': 60000.0, 's': 1000.0, 'ms': 1.0};
  double total = 0;
  var matchedLen = 0;
  for (final m in re.allMatches(s)) {
    matchedLen += m.group(0)!.length;
    total += double.parse(m.group(1)!) * unitMs[m.group(2)]!;
  }
  if (matchedLen != s.length || matchedLen == 0) {
    return null; // stray characters -> not a clean duration
  }
  return total.round();
}

/// One connected component of a PLCopen LD `GraphBody` after the power-rail
/// nodes have been removed — i.e. one rung. [leftRailNodeIds]/[rightRailNodeIds]
/// are the component's own node ids that were directly wired to the
/// left/right rail before the rail nodes were stripped out.
class LdComponent {
  final List<IrGraphNode> nodes;
  final List<IrConnection> edges;
  final Set<int> leftRailNodeIds;
  final Set<int> rightRailNodeIds;
  LdComponent({
    required this.nodes,
    required this.edges,
    required this.leftRailNodeIds,
    required this.rightRailNodeIds,
  });
}

/// Thrown internally when a component cannot be translated to a real rung.
/// [reason] is the `stubReasons` category key; [detail] is a human sentence.
class _StubException implements Exception {
  final String reason;
  final String detail;
  _StubException(this.reason, this.detail);
}

/// One extracted single-level parallel branch: an ordered [chain] of non-main
/// nodes that taps off an upstream anchor (a main node or the left rail) and
/// merges into a downstream anchor (a main node or the right rail).
class _BranchPlan {
  final List<IrGraphNode> chain;
  final bool upstreamIsLeftRail;
  final int? upstreamAnchor; // main node localId when not the left rail
  final bool downstreamIsRightRail;
  final int? downstreamAnchor; // main node localId when not the right rail
  _BranchPlan({
    required this.chain,
    required this.upstreamIsLeftRail,
    required this.upstreamAnchor,
    required this.downstreamIsRightRail,
    required this.downstreamAnchor,
  });
}

/// Translates a PLCopen LD [body] into the app's native executable [LdRung]s.
///
/// Task 3 scope: BOOLEAN ladder (contacts/coils/rails + single-level parallel
/// branches). Any component containing a function block, in/out variable,
/// complex (nested) topology, no coil, or an unsupported modifier combo becomes
/// a commented placeholder rung (2 rails + one L->R wire) plus a
/// [WarningSeverity.warning] naming the POU, rung ordinal, and reason. This
/// function never throws — every untranslatable component degrades to a stub.
LdTranslation translateLdBody(GraphBody body, {required String pouName}) {
  final comps = segmentRungs(body);
  final rungs = <LdRung>[];
  final warnings = <ImportWarning>[];
  final unsupportedBlocks = <String>{};
  final reasons = <String, int>{};
  final instanceTags = <PlcTag>[];
  final usedInstanceNames = <String>{};
  var translated = 0;
  var stubbed = 0;

  for (var i = 0; i < comps.length; i++) {
    try {
      rungs.add(_translateComponent(
          comps[i], i, instanceTags, unsupportedBlocks, usedInstanceNames, pouName));
      translated++;
    } on _StubException catch (e) {
      reasons[e.reason] = (reasons[e.reason] ?? 0) + 1;
      warnings.add(ImportWarning(
        severity: WarningSeverity.warning,
        message: 'POU "$pouName" rung ${i + 1}: not translated (${e.detail}).',
      ));
      rungs.add(LdRung(
        rungIndex: i,
        comment: 'Rung not translated on import: ${e.detail}.',
        nodes: [
          LdNode(id: kLeftRailId, kind: LdKind.leftRail),
          LdNode(id: kRightRailId, kind: LdKind.rightRail),
        ],
        wires: [LdWire(fromId: kLeftRailId, toId: kRightRailId)],
      ));
      stubbed++;
    }
  }

  return LdTranslation(
    rungs: rungs,
    warnings: warnings,
    translatedRungCount: translated,
    stubbedRungCount: stubbed,
    unsupportedBlockTypes: unsupportedBlocks,
    stubReasons: reasons,
    instanceTags: instanceTags,
  );
}

/// Supported function-block types. `blockType` strings match the app's LD
/// engine (`ld_exec.dart`): timers, counters, compares, math, and MOVE.
const Set<String> _kTimerBlocks = {'TON', 'TOF', 'TP'};
const Set<String> _kCounterBlocks = {'CTU', 'CTD', 'CTUD'};
const Set<String> _kCompareBlocks = {'GT', 'LT', 'GE', 'LE', 'EQ', 'NE'};
const Set<String> _kMathBlocks = {'ADD', 'SUB', 'MUL', 'DIV'};
const Set<String> _kSupportedBlocks = {
  ..._kTimerBlocks,
  ..._kCounterBlocks,
  ..._kCompareBlocks,
  ..._kMathBlocks,
  'MOVE',
};

/// True when [blockType] is an instance-backed LD block — a timer
/// (TON/TOF/TP) or counter (CTU/CTD/CTUD) — whose `LdNode.variable` holds the
/// name of its backing instance tag. MOVE/math (ADD/SUB/MUL/DIV) blocks also
/// use `variable`, but for the DESTINATION tag, not an instance name; compare
/// blocks don't use `variable` at all. Callers that rename a renamed
/// instance tag onto its owning block(s) MUST restrict the match to this
/// predicate — otherwise a MOVE/math block whose destination happens to share
/// the pre-rename instance name gets its destination silently retargeted.
/// Pure.
bool isInstanceBackedLdBlock(String blockType) =>
    _kTimerBlocks.contains(blockType) || _kCounterBlocks.contains(blockType);

/// The operand slot a block *data* pin routes into, or null if [pin] is a
/// *power* pin (`IN`/`EN`/`CU`/`CD`/`R`/`LD`, or an implicit contact/coil pin).
/// Data pins fold into operands/preset and are excluded from the power wiring;
/// power pins stay as series/parallel wires. `MOVE.IN` is the sole single-input
/// data source (timers/counters treat `IN` as their enable/count power pin).
String? _dataSlotFor(String blockType, String? pin) {
  switch (pin) {
    case 'IN1':
      return 'A';
    case 'IN2':
      return 'B';
    case 'PT': // timer preset (duration)
    case 'PV': // counter preset (count)
      return 'preset';
    case 'IN':
      return blockType == 'MOVE' ? 'A' : null;
    default:
      return null;
  }
}

/// Translates one [comp] (a single rung) into an executable [LdRung], or throws
/// [_StubException] if it is outside scope.
///
/// Function blocks (Task 4): a block's *data* pins (`IN1`/`IN2`/`PT`/`PV`, and
/// `MOVE.IN`) and the `inVariable`/`outVariable` nodes feeding/consuming them
/// are FOLDED into the block's operands/preset/destination — they are NOT
/// nodes or wires on the ladder. The remaining *power* pins keep the block on
/// the main/branch line exactly like a contact. To keep the Task-3 edge-
/// coverage gate ([_assertFaithfulWiring]) from over-stubbing every block rung,
/// the whole structural pipeline (depths, main line, branches, faithfulness)
/// runs against a REDUCED component: [comp] minus the folded in/out-variable
/// nodes and minus the folded data-pin edges.
LdRung _translateComponent(
  LdComponent comp,
  int index,
  List<PlcTag> instanceTags,
  Set<String> unsupportedBlocks,
  Set<String> usedInstanceNames,
  String pouName,
) {
  // 1. Reject unsupported element types up front (blocks + in/out variables are
  // now accepted; in/out variables must fold away into the reduced view).
  for (final n in comp.nodes) {
    switch (n.elementType) {
      case 'contact':
      case 'coil':
      case 'block':
      case 'inVariable':
      case 'outVariable':
        break;
      default:
        throw _StubException('complex-topology', 'unsupported element ${n.elementType}');
    }
  }

  // 2. Build the reduced power view: fold in/out-variable nodes and data-pin
  // edges out of the structural graph so only power wiring remains.
  //
  // CRITICAL: a value-variable edge may be folded ONLY when it is a genuine
  // DATA connection — an inVariable feeding a block DATA pin (`_dataSlotFor`
  // non-null: IN1/IN2/PT/PV, MOVE.IN) or a math/MOVE block writing its output
  // to an outVariable destination. A value variable wired to a POWER pin (e.g.
  // an inVariable on a counter R/CD/LD or a timer IN) or to a non-block is NOT
  // representable — folding it would silently DROP a power connection before
  // the faithfulness gate ever sees it. Those edges STUB instead.
  final varTypeByLocalId = <int, String>{
    for (final n in comp.nodes)
      if (n.elementType == 'inVariable' || n.elementType == 'outVariable')
        n.localId: n.elementType
  };
  final foldedIds = varTypeByLocalId.keys.toSet();
  final blockByLocalId = <int, IrGraphNode>{
    for (final n in comp.nodes) if (n.elementType == 'block') n.localId: n
  };
  bool isFoldedEdge(IrConnection e) {
    // A block DATA-pin edge (operand/preset) folds regardless of its source.
    final tgtBlock = blockByLocalId[e.toLocalId];
    if (tgtBlock != null &&
        _dataSlotFor(tgtBlock.attributes['typeName'] ?? '', e.toPin) != null) {
      return true;
    }
    // Any OTHER edge touching a folded value variable must be a math/MOVE
    // destination write (block -> outVariable); anything else feeds a power pin
    // or a non-data endpoint and cannot be silently folded away.
    if (foldedIds.contains(e.fromLocalId) || foldedIds.contains(e.toLocalId)) {
      final srcBlock = blockByLocalId[e.fromLocalId];
      final srcType = srcBlock?.attributes['typeName'] ?? '';
      final isDestinationWrite = varTypeByLocalId[e.toLocalId] == 'outVariable' &&
          srcBlock != null &&
          (_kMathBlocks.contains(srcType) || srcType == 'MOVE');
      if (isDestinationWrite) return true;
      throw _StubException('complex-topology', 'value variable feeds a non-data pin');
    }
    return false;
  }

  final reducedNodes = [for (final n in comp.nodes) if (!foldedIds.contains(n.localId)) n];
  final reduced = LdComponent(
    nodes: reducedNodes,
    edges: [for (final e in comp.edges) if (!isFoldedEdge(e)) e],
    leftRailNodeIds: {
      for (final id in comp.leftRailNodeIds) if (!foldedIds.contains(id)) id
    },
    rightRailNodeIds: {
      for (final id in comp.rightRailNodeIds) if (!foldedIds.contains(id)) id
    },
  );

  // 3. Require >= 1 output coil OR >= 1 function block (a block rung — e.g. a
  // bare MOVE — legitimately has no coil).
  final coils = [for (final n in reducedNodes) if (n.elementType == 'coil') n];
  final blocks = [for (final n in reducedNodes) if (n.elementType == 'block') n];
  if (coils.isEmpty && blocks.isEmpty) {
    throw _StubException('no-coil', 'no output coil');
  }

  // 4. Directed power graph over the REDUCED view.
  final depth = _depths(reduced);
  final byId = {for (final n in reducedNodes) n.localId: n};
  final byIdAll = {for (final n in comp.nodes) n.localId: n};
  // Terminal candidates: coils plus blocks (a block can terminate a coil-less
  // rung). For a boolean rung this is exactly the coil set (Task-3 behaviour).
  final terminals = [...coils, ...blocks];
  final mainIds = _mainLine(reduced, terminals, depth);
  final branches = _extractBranches(reduced, mainIds, byId);

  // 5. Map elements to LdNodes and derive BranchSpec index ranges. Blocks are
  // built here (folding their data inputs/destination + appending instance
  // tags); an unsupported/unresolvable block throws _StubException.
  //
  // Per-component staging: THIS rung's instance tags and dedup-name
  // reservations are accumulated in LOCAL buffers and only committed to the
  // shared lists AFTER the faithfulness gate (step 5b) passes. A block rung
  // that maps its block (appending an instance tag) but then stubs at the gate
  // (e.g. a power bridge around the block) must not leak an orphan instance tag
  // that backs no translated block, nor permanently consume its dedup name.
  // `usedInstanceNames` seeds the local set so dedup still sees names committed
  // by earlier successfully-translated rungs; `unsupportedBlocks` is mutated
  // EAGERLY (an inventory that should persist across stubs).
  final localInstanceTags = <PlcTag>[];
  final localUsedInstanceNames = <String>{...usedInstanceNames};
  LdNode mapNode(IrGraphNode n) => n.elementType == 'block'
      ? _buildBlockNode(comp, n, byIdAll, localInstanceTags, unsupportedBlocks,
          localUsedInstanceNames, pouName)
      : _toLdNode(n);
  final mainNodes = [for (final id in mainIds) mapNode(byId[id]!)];
  final mainIndex = {for (var i = 0; i < mainIds.length; i++) mainIds[i]: i};
  final specs = <BranchSpec>[];
  for (final b in branches) {
    final nodes = [for (final n in b.chain) mapNode(n)];
    final startIndex = b.upstreamIsLeftRail ? 0 : mainIndex[b.upstreamAnchor]! + 1;
    final endIndex =
        b.downstreamIsRightRail ? mainNodes.length - 1 : mainIndex[b.downstreamAnchor]! - 1;
    specs.add(BranchSpec(startIndex: startIndex, endIndex: endIndex, nodes: nodes));
  }

  // 5b. Edge-coverage faithfulness gate over the REDUCED power wiring: confirm
  // the main+branch wiring we are about to emit reproduces the reduced edge set
  // and rail attachments. A non-series-parallel bridge/bypass topology whose
  // extra edge got greedily pulled onto the main line (dropping the edge) is
  // caught here and stubbed instead of being emitted as silently-wrong logic.
  _assertFaithfulWiring(reduced, mainIds, branches);

  // 5c. Gate passed — commit this component's instance tags and dedup-name
  // reservations to the shared lists (a stubbed rung never reaches here, so its
  // buffered tag/name are discarded and the name stays reusable).
  usedInstanceNames.addAll(localUsedInstanceNames);
  instanceTags.addAll(localInstanceTags);

  // 6. buildRung assigns ids/rows, builds rails, series-wires main, and wires
  // each branch as a parallel lane spanning main[startIndex..endIndex].
  return buildRung(index: index, main: mainNodes, branches: specs);
}

/// Builds the [LdNode] for a function [block], folding its data inputs
/// (`IN1`/`IN2`/`PT`/`PV`, `MOVE.IN`) into operands/preset and its output
/// `outVariable` into the destination `variable`. Timers/counters get a
/// deterministic instance name and a backing `TIMER`/`COUNTER` [PlcTag] appended
/// to [instanceTags] so `ld_exec` has structured state to read/write. Throws
/// [_StubException] on an unsupported type or an unresolvable data input.
LdNode _buildBlockNode(
  LdComponent comp,
  IrGraphNode node,
  Map<int, IrGraphNode> byId,
  List<PlcTag> instanceTags,
  Set<String> unsupportedBlocks,
  Set<String> usedInstanceNames,
  String pouName,
) {
  final typeName = node.attributes['typeName'] ?? '';
  if (!_kSupportedBlocks.contains(typeName)) {
    unsupportedBlocks.add(typeName.isEmpty ? '?' : typeName);
    throw _StubException('unsupported-block', 'unsupported block "$typeName"');
  }

  // Timer/counter power-pin faithfulness: `ld_exec` drives a timer/counter from
  // a SINGLE primary power input — the count pin for counters (CU for
  // CTU/CTUD, CD for CTD) and `IN` for timers. Separate power pins (counter
  // CD/R/LD, or any second power pin) cannot be represented, so a wired power
  // connection to any non-primary power pin would be dropped or spuriously
  // OR'd into the primary — silently-wrong logic. Determine each incoming
  // power edge's target from its `toPin`: a data-pin edge (`_dataSlotFor`
  // non-null) is a fold, the implicit/primary power edge (null or the primary
  // pin name) is fine, and any other named power pin STUBS. Full CD/R/LD
  // support is a deferred follow-up.
  if (_kTimerBlocks.contains(typeName) || _kCounterBlocks.contains(typeName)) {
    final primaryPin =
        _kTimerBlocks.contains(typeName) ? 'IN' : (typeName == 'CTD' ? 'CD' : 'CU');
    for (final e in comp.edges) {
      if (e.toLocalId != node.localId) continue;
      if (_dataSlotFor(typeName, e.toPin) != null) continue; // data operand/preset
      final pin = e.toPin;
      if (pin != null && pin != primaryPin) {
        throw _StubException(
            'complex-topology', 'block uses an unsupported power pin (CD/R/LD/...)');
      }
    }
  }

  final ld = LdNode(id: '', kind: LdKind.block, blockType: typeName);

  // Fold data inputs: scan the ORIGINAL edges into this block (the reduced view
  // dropped them) and resolve each source to a literal/tag.
  for (final e in comp.edges) {
    if (e.toLocalId != node.localId) continue;
    final slot = _dataSlotFor(typeName, e.toPin);
    if (slot == null) continue; // power pin -> stays a wire
    final src = byId[e.fromLocalId];
    final literal = src?.attributes['variable'];
    if (literal == null || literal.isEmpty) {
      throw _StubException('unresolved-operand', 'unresolved data input on ${e.toPin}');
    }
    switch (slot) {
      case 'A':
        ld.operandA = literal;
        break;
      case 'B':
        ld.operandB = literal;
        break;
      case 'preset':
        if (_kTimerBlocks.contains(typeName)) {
          final ms = parseIecDuration(literal);
          if (ms == null) {
            throw _StubException('unresolved-operand', 'unparseable preset "$literal"');
          }
          ld.presetMs = ms;
        } else {
          final count = int.tryParse(literal.trim());
          if (count == null) {
            throw _StubException('unresolved-operand', 'unparseable preset "$literal"');
          }
          ld.presetMs = count;
        }
        break;
    }
  }

  // Math/MOVE write to a destination supplied by an outVariable on the output.
  if (_kMathBlocks.contains(typeName) || typeName == 'MOVE') {
    String? dest;
    for (final e in comp.edges) {
      if (e.fromLocalId != node.localId) continue;
      final tgt = byId[e.toLocalId];
      if (tgt?.elementType == 'outVariable') {
        dest = tgt?.attributes['variable'];
        break;
      }
    }
    if (dest == null || dest.isEmpty) {
      throw _StubException('unresolved-operand', 'no output destination for $typeName');
    }
    ld.variable = dest;
  }

  // Instance-backed blocks: a deterministic name + backing structured tag.
  final isTimer = _kTimerBlocks.contains(typeName);
  if (isTimer || _kCounterBlocks.contains(typeName)) {
    final name = _instanceName(node, pouName, usedInstanceNames);
    ld.variable = name;
    final typeForTag = isTimer ? 'TIMER' : 'COUNTER';
    instanceTags.add(PlcTag(
      name: name,
      path: name,
      dataType: typeForTag,
      // Canonical structured default from tag_resolver's built-in composites —
      // single source of truth for the field shape. The preset is carried on
      // the LdNode (`presetMs`) and re-synced onto the tag by ld_exec every
      // scan, so it need not be overlaid onto the tag's initial value here.
      value: defaultValueFor(_scratchProject, typeForTag, 0),
      ioType: 'Internal',
    ));
  }
  return ld;
}

/// Deterministic instance name for a timer/counter block: the `instanceName`
/// attribute when it is a valid identifier, else `'${pouName}_fb${localId}'`.
/// De-duplicated within a translation via [used] by appending `_2`, `_3`, ...
String _instanceName(IrGraphNode node, String pouName, Set<String> used) {
  final attr = node.attributes['instanceName'];
  final safe = attr != null && RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(attr);
  final base = safe ? attr : '${pouName}_fb${node.localId}';
  var name = base;
  var i = 2;
  while (used.contains(name)) {
    name = '${base}_$i';
    i++;
  }
  used.add(name);
  return name;
}

/// Longest-path depth of each node measured from the left rail (which sits at
/// depth 0, so a left-rail-attached element is depth 1). Deterministic; a cycle
/// (which should not occur in a valid ladder) is guarded to depth 0.
Map<int, int> _depths(LdComponent comp) {
  final preds = <int, List<int>>{for (final n in comp.nodes) n.localId: <int>[]};
  for (final e in comp.edges) {
    preds[e.toLocalId]?.add(e.fromLocalId);
  }
  final depth = <int, int>{};
  final visiting = <int>{};
  int depthOf(int id) {
    final cached = depth[id];
    if (cached != null) return cached;
    if (!visiting.add(id)) return 0; // cycle guard
    var m = comp.leftRailNodeIds.contains(id) ? 1 : 0;
    for (final p in preds[id] ?? const <int>[]) {
      final d = depthOf(p) + 1;
      if (d > m) m = d;
    }
    visiting.remove(id);
    return depth[id] = m;
  }

  for (final n in comp.nodes) {
    depthOf(n.localId);
  }
  return depth;
}

/// The main series path: the deepest source->terminal chain (tie-break: lowest
/// terminal localId, then at each step the predecessor with highest depth then
/// lowest localId). [terminals] are the rung's output candidates — coils, plus
/// function blocks for a coil-less block rung. Returned rail-to-terminal in
/// power-flow order.
List<int> _mainLine(LdComponent comp, List<IrGraphNode> terminals, Map<int, int> depth) {
  final preds = <int, List<int>>{for (final n in comp.nodes) n.localId: <int>[]};
  for (final e in comp.edges) {
    preds[e.toLocalId]?.add(e.fromLocalId);
  }
  // Pick the terminal for the main line: greatest depth, then lowest id.
  var terminal = terminals.first;
  for (final c in terminals) {
    final dc = depth[c.localId]!;
    final dbest = depth[terminal.localId]!;
    if (dc > dbest || (dc == dbest && c.localId < terminal.localId)) terminal = c;
  }
  final main = <int>[terminal.localId];
  final guard = <int>{terminal.localId};
  var cur = terminal.localId;
  while (true) {
    final ps = preds[cur] ?? const <int>[];
    if (ps.isEmpty) break;
    var best = ps.first;
    for (final p in ps) {
      final dp = depth[p]!;
      final db = depth[best]!;
      if (dp > db || (dp == db && p < best)) best = p;
    }
    if (!guard.add(best)) break; // cycle guard
    main.insert(0, best);
    cur = best;
  }
  return main;
}

/// Extracts single-level parallel branches (non-main nodes). Each branch must be
/// a linear chain of non-main nodes that taps a single upstream anchor (a main
/// node or the left rail) and merges into a single downstream anchor (a main
/// node or the right rail). Anything nested/complex throws [_StubException].
List<_BranchPlan> _extractBranches(
    LdComponent comp, List<int> mainIds, Map<int, IrGraphNode> byId) {
  final mainSet = mainIds.toSet();
  final preds = <int, List<int>>{for (final n in comp.nodes) n.localId: <int>[]};
  final succs = <int, List<int>>{for (final n in comp.nodes) n.localId: <int>[]};
  // De-duplicate by (from,to) so a duplicated connection does not inflate an
  // adjacency count and trip the complex() stub over-conservatively.
  final seenEdge = <String>{};
  for (final e in comp.edges) {
    if (!seenEdge.add('${e.fromLocalId}>${e.toLocalId}')) continue;
    preds[e.toLocalId]?.add(e.fromLocalId);
    succs[e.fromLocalId]?.add(e.toLocalId);
  }
  List<int> nonMainPreds(int id) =>
      [for (final p in preds[id] ?? const <int>[]) if (!mainSet.contains(p)) p];
  List<int> nonMainSuccs(int id) =>
      [for (final s in succs[id] ?? const <int>[]) if (!mainSet.contains(s)) s];
  List<int> mainPreds(int id) =>
      [for (final p in preds[id] ?? const <int>[]) if (mainSet.contains(p)) p];
  List<int> mainSuccs(int id) =>
      [for (final s in succs[id] ?? const <int>[]) if (mainSet.contains(s)) s];

  void complex() => throw _StubException('complex-topology', 'branch structure too complex');

  final visited = <int>{};
  final branches = <_BranchPlan>[];
  for (final n in comp.nodes) {
    if (mainSet.contains(n.localId) || visited.contains(n.localId)) continue;
    // Only start from a chain head (no non-main predecessor).
    if (nonMainPreds(n.localId).isNotEmpty) continue;

    // Walk the linear chain of non-main successors from this head.
    final chain = <IrGraphNode>[];
    var cur = n.localId;
    while (true) {
      if (!visited.add(cur)) complex();
      chain.add(byId[cur]!);
      final nss = nonMainSuccs(cur);
      if (nss.isEmpty) break;
      if (nss.length > 1) complex();
      final next = nss.single;
      if (nonMainPreds(next).length > 1) complex();
      cur = next;
    }

    // Interior nodes must not touch main or the rails (that would be a
    // second-level divergence/convergence, i.e. nested topology).
    for (var ci = 0; ci < chain.length; ci++) {
      final id = chain[ci].localId;
      final isHead = ci == 0;
      final isTail = ci == chain.length - 1;
      if (!isHead && (mainPreds(id).isNotEmpty || comp.leftRailNodeIds.contains(id))) complex();
      if (!isTail && (mainSuccs(id).isNotEmpty || comp.rightRailNodeIds.contains(id))) complex();
    }

    final head = chain.first.localId;
    final tail = chain.last.localId;
    final upFromLeft = comp.leftRailNodeIds.contains(head);
    final upMain = mainPreds(head);
    final downToRight = comp.rightRailNodeIds.contains(tail);
    final downMain = mainSuccs(tail);
    // Exactly one upstream anchor and exactly one downstream anchor.
    if (upMain.length + (upFromLeft ? 1 : 0) != 1) complex();
    if (downMain.length + (downToRight ? 1 : 0) != 1) complex();

    branches.add(_BranchPlan(
      chain: chain,
      upstreamIsLeftRail: upFromLeft,
      upstreamAnchor: upFromLeft ? null : upMain.single,
      downstreamIsRightRail: downToRight,
      downstreamAnchor: downToRight ? null : downMain.single,
    ));
  }

  // Any non-main node not placed on a branch is unreachable/complex.
  for (final n in comp.nodes) {
    if (!mainSet.contains(n.localId) && !visited.contains(n.localId)) complex();
  }
  return branches;
}

/// Reconstructs the exact non-rail (internal) adjacency plus the left/right-rail
/// attachments that `buildRung` will wire from [mainIds] + [branches], then
/// asserts it reproduces [comp]'s own edge set and rail attachments. Throws
/// [_StubException] ('complex-topology') on ANY discrepancy — a missing
/// component edge, an added edge, or a differing rail attachment. This makes
/// `translateLdBody` faithful-or-stub for every topology, closing the silent
/// edge-drop on non-series-parallel bridge/bypass rungs. Pure/deterministic.
void _assertFaithfulWiring(
    LdComponent comp, List<int> mainIds, List<_BranchPlan> branches) {
  final internal = <String>{};
  final leftAttach = <int>{};
  final rightAttach = <int>{};
  String key(int from, int to) => '$from>$to';

  // Main series line: left rail -> main[0] -> ... -> main[last] -> right rail.
  if (mainIds.isNotEmpty) {
    leftAttach.add(mainIds.first);
    for (var i = 0; i + 1 < mainIds.length; i++) {
      internal.add(key(mainIds[i], mainIds[i + 1]));
    }
    rightAttach.add(mainIds.last);
  }

  // Each parallel branch, anchored to the SAME nodes buildRung will use
  // (upstream: left rail or the main node before the span; downstream: right
  // rail or the main node after the span).
  for (final b in branches) {
    final chain = [for (final n in b.chain) n.localId];
    if (b.upstreamIsLeftRail) {
      leftAttach.add(chain.first);
    } else {
      internal.add(key(b.upstreamAnchor!, chain.first));
    }
    for (var i = 0; i + 1 < chain.length; i++) {
      internal.add(key(chain[i], chain[i + 1]));
    }
    if (b.downstreamIsRightRail) {
      rightAttach.add(chain.last);
    } else {
      internal.add(key(chain.last, b.downstreamAnchor!));
    }
  }

  // Component's own edges are already rail-free; reduce (producer->consumer) and
  // de-duplicate so a duplicated connection does not force a spurious mismatch.
  final compInternal = <String>{
    for (final e in comp.edges) key(e.fromLocalId, e.toLocalId)
  };

  bool sameSet<T>(Set<T> a, Set<T> b) => a.length == b.length && a.containsAll(b);
  if (!sameSet(internal, compInternal) ||
      !sameSet(leftAttach, comp.leftRailNodeIds) ||
      !sameSet(rightAttach, comp.rightRailNodeIds)) {
    throw _StubException('complex-topology', 'branch structure too complex');
  }
}

/// Maps a contact/coil IR node to a native [LdNode], applying the modifier rules.
LdNode _toLdNode(IrGraphNode n) {
  final variable = n.attributes['variable'] ?? '';
  if (n.elementType == 'coil') {
    return LdNode(id: '', kind: LdKind.coil, variable: variable, modifier: _coilModifier(n));
  }
  return LdNode(id: '', kind: LdKind.contact, variable: variable, modifier: _contactModifier(n));
}

bool _hasEdge(IrGraphNode n) {
  final e = n.attributes['edge'];
  return e == 'rising' || e == 'falling';
}

String _contactModifier(IrGraphNode n) {
  final negated = n.attributes['negated'] == 'true';
  if (negated && _hasEdge(n)) {
    throw _StubException(
        'unsupported-modifier-combo', 'contact with both negation and edge detection');
  }
  if (negated) return 'negated';
  final edge = n.attributes['edge'];
  if (edge == 'rising') return 'rising';
  if (edge == 'falling') return 'falling';
  return 'normal';
}

String _coilModifier(IrGraphNode n) {
  final negated = n.attributes['negated'] == 'true';
  if (negated && _hasEdge(n)) {
    throw _StubException(
        'unsupported-modifier-combo', 'coil with both negation and edge detection');
  }
  final storage = n.attributes['storage'];
  if (storage == 'set') return 'set';
  if (storage == 'reset') return 'reset';
  if (negated) return 'negated';
  final edge = n.attributes['edge'];
  if (edge == 'rising') return 'rising';
  if (edge == 'falling') return 'falling';
  return 'normal';
}

bool _isLeftRail(String t) => t == 'leftPowerRail';
bool _isRightRail(String t) => t == 'rightPowerRail';

/// Splits [body] into one [LdComponent] per rung by removing the
/// `leftPowerRail`/`rightPowerRail` nodes and taking connected components of
/// the remaining (undirected) graph. Components are ordered top-to-bottom:
/// min `y`, then min `x`, then min `localId`.
List<LdComponent> segmentRungs(GraphBody body) {
  final byId = {for (final n in body.nodes) n.localId: n};
  final railIds = <int>{
    for (final n in body.nodes)
      if (_isLeftRail(n.elementType) || _isRightRail(n.elementType)) n.localId
  };
  final leftRailIds = {
    for (final n in body.nodes) if (_isLeftRail(n.elementType)) n.localId
  };
  final rightRailIds = {
    for (final n in body.nodes) if (_isRightRail(n.elementType)) n.localId
  };

  // Record rail attachment before removing rails.
  final touchesLeft = <int>{};
  final touchesRight = <int>{};
  for (final e in body.connections) {
    if (leftRailIds.contains(e.fromLocalId)) touchesLeft.add(e.toLocalId);
    if (leftRailIds.contains(e.toLocalId)) touchesLeft.add(e.fromLocalId);
    if (rightRailIds.contains(e.fromLocalId)) touchesRight.add(e.toLocalId);
    if (rightRailIds.contains(e.toLocalId)) touchesRight.add(e.fromLocalId);
  }

  // Undirected adjacency over non-rail nodes.
  final adj = <int, Set<int>>{
    for (final n in body.nodes) if (!railIds.contains(n.localId)) n.localId: <int>{}
  };
  for (final e in body.connections) {
    if (railIds.contains(e.fromLocalId) || railIds.contains(e.toLocalId)) continue;
    if (adj.containsKey(e.fromLocalId) && adj.containsKey(e.toLocalId)) {
      adj[e.fromLocalId]!.add(e.toLocalId);
      adj[e.toLocalId]!.add(e.fromLocalId);
    }
  }

  // Connected components (deterministic: iterate node ids in file order).
  final seen = <int>{};
  final comps = <LdComponent>[];
  for (final n in body.nodes) {
    if (railIds.contains(n.localId) || seen.contains(n.localId)) continue;
    final memberIds = <int>[];
    final stack = [n.localId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!seen.add(id)) continue;
      memberIds.add(id);
      for (final m in adj[id] ?? const <int>{}) {
        if (!seen.contains(m)) stack.add(m);
      }
    }
    final memberSet = memberIds.toSet();
    final compNodes = [for (final id in memberIds) byId[id]!];
    final compEdges = [
      for (final e in body.connections)
        if (memberSet.contains(e.fromLocalId) && memberSet.contains(e.toLocalId)) e
    ];
    comps.add(LdComponent(
      nodes: compNodes,
      edges: compEdges,
      leftRailNodeIds: memberSet.intersection(touchesLeft),
      rightRailNodeIds: memberSet.intersection(touchesRight),
    ));
  }

  // Order components top-to-bottom: min y, then min x, then min localId.
  double minY(LdComponent c) => c.nodes.map((n) => n.y).reduce((a, b) => a < b ? a : b);
  double minX(LdComponent c) => c.nodes.map((n) => n.x).reduce((a, b) => a < b ? a : b);
  int minId(LdComponent c) => c.nodes.map((n) => n.localId).reduce((a, b) => a < b ? a : b);
  comps.sort((a, b) {
    final cy = minY(a).compareTo(minY(b));
    if (cy != 0) return cy;
    final cx = minX(a).compareTo(minX(b));
    if (cx != 0) return cx;
    return minId(a).compareTo(minId(b));
  });
  return comps;
}
