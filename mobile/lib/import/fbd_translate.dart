import '../models/project_model.dart';
import '../models/fbd_pins.dart';
import '../models/tag_resolver.dart';
import 'graph_segment.dart';
import 'import_ir.dart';

/// Result of translating one FBD `GraphBody` into native `FunctionBlockDiagram`
/// program parts. `networks` includes an empty commented network for every
/// component that could not be translated, so `FbdBlock.network` indices always
/// point at a real header and network numbering matches source order.
/// `translatedNetworkCount > 0` is the mapper's real-program-vs-stub decision.
/// `instanceTags` are struct-typed tags backing custom-FB call blocks (added in
/// the custom-FB routing task).
class FbdTranslation {
  final List<FbdBlock> blocks;
  final List<FbdWire> wires;
  final List<FbdNetwork> networks;
  final List<PlcTag> instanceTags;
  final int translatedNetworkCount;
  final int stubbedNetworkCount;
  final Set<String> unsupportedBlockTypes;
  final Map<String, int> stubReasons;
  final List<ImportWarning> warnings;
  FbdTranslation({
    required this.blocks,
    required this.wires,
    required this.networks,
    required this.instanceTags,
    required this.translatedNetworkCount,
    required this.stubbedNetworkCount,
    required this.unsupportedBlockTypes,
    required this.stubReasons,
    required this.warnings,
  });
}

/// Thrown internally when a component cannot be translated to a real network.
/// [reason] is the `stubReasons` key; [detail] is a human sentence.
class _FbdStub implements Exception {
  final String reason;
  final String detail;
  _FbdStub(this.reason, this.detail);
}

/// The native parts produced for a single translated component.
class _BuiltComponent {
  final List<FbdBlock> blocks;
  final List<FbdWire> wires;
  final List<PlcTag> instanceTags;
  _BuiltComponent(this.blocks, this.wires, this.instanceTags);
}

/// True when [text] is an FBD `CONST` literal: an integer, a double, or a
/// case-insensitive boolean. Used to split `inVariable` text into CONST vs
/// TAG_INPUT.
bool _isLiteral(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  final up = t.toUpperCase();
  if (up == 'TRUE' || up == 'FALSE') return true;
  return int.tryParse(t) != null || double.tryParse(t) != null;
}

/// True when [text] is a bare IEC identifier (a tag reference), not a literal
/// and not a compound expression.
bool _isIdentifier(String text) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(text.trim());

/// Translates a PLCopen FBD [body] into native `FunctionBlockDiagram` parts.
/// Each weakly-connected component becomes one `FbdNetwork` (layout-ordered);
/// an untranslatable component degrades to an empty commented network + a
/// warning. Never throws.
FbdTranslation translateFbdBody(
  GraphBody body, {
  required String pouName,
  Map<String, FbDefinition> fbRegistry = const {},
  Map<String, String> fbRenameMap = const {},
}) {
  final comps = weaklyConnectedComponents(body.nodes, body.connections);

  final blocks = <FbdBlock>[];
  final wires = <FbdWire>[];
  final networks = <FbdNetwork>[];
  final instanceTags = <PlcTag>[];
  final unsupported = <String>{};
  final reasons = <String, int>{};
  final warnings = <ImportWarning>[];
  final usedInstanceNames = <String>{};
  var translated = 0;
  var stubbed = 0;

  // Scratch project so fbdInputPinsFor/fbdOutputPinsFor can resolve custom-FB
  // pin names (Task 4); harmless for built-ins.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: [], tags: [],
      fbDefinitions: fbRegistry.values.toList());

  for (var i = 0; i < comps.length; i++) {
    try {
      final built = _translateComponent(comps[i], i, body.connections, pouName,
          scratch, fbRegistry, fbRenameMap, usedInstanceNames, unsupported);
      for (final b in built.blocks) {
        b.network = i;
      }
      blocks.addAll(built.blocks);
      wires.addAll(built.wires);
      instanceTags.addAll(built.instanceTags);
      networks.add(FbdNetwork(comment: ''));
      translated++;
    } on _FbdStub catch (e) {
      reasons[e.reason] = (reasons[e.reason] ?? 0) + 1;
      warnings.add(ImportWarning(
        severity: WarningSeverity.warning,
        message: 'POU "$pouName" network ${i + 1}: not translated (${e.detail}).',
      ));
      networks.add(FbdNetwork(
          comment: 'Network ${i + 1} not translated on import: ${e.detail}.'));
      stubbed++;
    }
  }

  return FbdTranslation(
    blocks: blocks,
    wires: wires,
    networks: networks,
    instanceTags: instanceTags,
    translatedNetworkCount: translated,
    stubbedNetworkCount: stubbed,
    unsupportedBlockTypes: unsupported,
    stubReasons: reasons,
    warnings: warnings,
  );
}

/// Deterministic block id for a node: unique within the POU (localIds are).
String _blockId(String pouName, int localId) => '${pouName}_n$localId';

/// Translates one component's nodes to native blocks + wires, or throws
/// [_FbdStub]. Instance-name dedup reservations are staged in a LOCAL set
/// seeded from [usedInstanceNames] and merged by the caller only on success (a
/// stubbed component frees its reserved names). [unsupported] is mutated
/// eagerly (persistent inventory). `_BuiltComponent.blocks` carry `network = 0`
/// here; the caller stamps the real index.
_BuiltComponent _translateComponent(
  List<IrGraphNode> nodes,
  int index,
  List<IrConnection> allConnections,
  String pouName,
  PlcProject scratch,
  Map<String, FbDefinition> fbRegistry,
  Map<String, String> fbRenameMap,
  Set<String> usedInstanceNames,
  Set<String> unsupported,
) {
  final memberIds = nodes.map((n) => n.localId).toSet();

  // 1. Reject unsupported element types + negated pins + malformed ids up front.
  for (final n in nodes) {
    // A parser-side unparseable `localId` collapses to -1; multiple such
    // nodes would silently collide (overwrite) in the localId-keyed maps
    // below (blockByLocalId) and in weaklyConnectedComponents' component
    // grouping. Stub rather than risk a silently-dropped/merged node.
    if (n.localId < 0) {
      throw _FbdStub('unsupported-element', 'malformed element id');
    }
    switch (n.elementType) {
      case 'block':
      case 'inVariable':
      case 'outVariable':
        break;
      default:
        throw _FbdStub('unsupported-element', 'unsupported element ${n.elementType}');
    }
    if (n.attributes['hasNegatedPin'] == 'true') {
      throw _FbdStub('negated-pin', 'block "${n.attributes['typeName'] ?? '?'}" has a negated pin');
    }
  }

  // Component-local edges (both endpoints inside this component).
  final edges = [
    for (final e in allConnections)
      if (memberIds.contains(e.fromLocalId) && memberIds.contains(e.toLocalId)) e
  ];

  // 2. Build blocks (staged instance-name set).
  final localUsedNames = <String>{...usedInstanceNames};
  final localInstanceTags = <PlcTag>[];
  final blockByLocalId = <int, FbdBlock>{};
  for (final n in nodes) {
    blockByLocalId[n.localId] = _buildBlock(n, edges, pouName, fbRegistry,
        fbRenameMap, localInstanceTags, localUsedNames, unsupported);
  }

  // 3. Build wires + pin-faithfulness gate.
  final wires = <FbdWire>[];
  // Tracks the resolved target input slot ("blockId|pin") each wire claims,
  // so two DISTINCT wires that resolve to the SAME slot are caught here
  // instead of silently colliding in the executor's `inputWireFor[block][idx]`
  // (later wire overwrites the earlier operand -> wrong logic, a
  // faithful-or-stub breach). Mirrors the executor's own resolution: an
  // explicit toPin wins, else the block's single input pin (when it has
  // exactly one) is the implicit target; anything else is left unresolved
  // (already gated by `_assertPin`'s ambiguous-pin check above).
  final claimedInputSlots = <String>{};
  for (final e in edges) {
    final from = blockByLocalId[e.fromLocalId]!;
    final to = blockByLocalId[e.toLocalId]!;
    final toPin = e.toPin ?? '';
    final fromPin = e.fromPin ?? '';
    _assertPin(scratch, to, toPin, isInput: true);
    _assertPin(scratch, from, fromPin, isInput: false);
    final toPins = fbdInputPinsFor(scratch, to);
    final resolvedToPin =
        toPin.isNotEmpty ? toPin : (toPins.length == 1 ? toPins.first : null);
    if (resolvedToPin != null) {
      final slot = '${to.id}|$resolvedToPin';
      if (!claimedInputSlots.add(slot)) {
        throw _FbdStub('unresolved-pin',
            'multiple wires target the same input pin "$resolvedToPin" on ${to.type}');
      }
    }
    wires.add(FbdWire(
        fromBlockId: from.id, fromPin: fromPin, toBlockId: to.id, toPin: toPin));
  }

  // 4. Gate passed — commit staged names/tags to the caller's sets.
  usedInstanceNames.addAll(localUsedNames);
  return _BuiltComponent(
      blockByLocalId.values.toList(), wires, localInstanceTags);
}

/// Verifies [pin] is on [block]'s resolved input (or output) pin list, allowing
/// an empty pin name only when the block has exactly one pin on that side (the
/// executor's first-pin fallback). Throws [_FbdStub] otherwise.
void _assertPin(PlcProject scratch, FbdBlock block, String pin,
    {required bool isInput}) {
  final pins = isInput
      ? fbdInputPinsFor(scratch, block)
      : fbdOutputPinsFor(scratch, block);
  if (pin.isEmpty) {
    if (pins.length <= 1) return; // single-pin fallback (or a sink/source)
    throw _FbdStub('unresolved-pin',
        'ambiguous ${isInput ? 'input' : 'output'} pin on ${block.type}');
  }
  if (!pins.contains(pin)) {
    throw _FbdStub('unresolved-pin',
        'pin "$pin" not on ${block.type} ${isInput ? 'inputs' : 'outputs'}');
  }
}

/// Builds the native [FbdBlock] for one node, or throws [_FbdStub]. Task 3
/// handles inVariable/outVariable and built-in blocks; the custom-FB branch is
/// added in Task 4.
FbdBlock _buildBlock(
  IrGraphNode node,
  List<IrConnection> edges,
  String pouName,
  Map<String, FbDefinition> fbRegistry,
  Map<String, String> fbRenameMap,
  List<PlcTag> instanceTags,
  Set<String> usedInstanceNames,
  Set<String> unsupported,
) {
  final id = _blockId(pouName, node.localId);
  if (node.elementType == 'inVariable') {
    if (node.attributes['negated'] == 'true') {
      throw _FbdStub('negated-pin',
          'inVariable "${node.attributes['variable'] ?? '?'}" is negated');
    }
    final text = node.attributes['variable']?.trim() ?? '';
    if (_isLiteral(text)) {
      return FbdBlock(id: id, type: 'CONST', title: 'CONST', tagBinding: text,
          x: node.x, y: node.y);
    }
    if (_isIdentifier(text)) {
      return FbdBlock(id: id, type: 'TAG_INPUT', title: text, tagBinding: text,
          x: node.x, y: node.y);
    }
    if (text.isEmpty) {
      throw _FbdStub('unresolved-operand', 'empty inVariable');
    }
    throw _FbdStub('complex-expression', 'compound inVariable "$text"');
  }
  if (node.elementType == 'outVariable') {
    if (node.attributes['negated'] == 'true') {
      throw _FbdStub('negated-pin',
          'outVariable "${node.attributes['variable'] ?? '?'}" is negated');
    }
    final text = node.attributes['variable']?.trim() ?? '';
    if (_isIdentifier(text)) {
      return FbdBlock(id: id, type: 'TAG_OUTPUT', title: text, tagBinding: text,
          x: node.x, y: node.y);
    }
    if (text.isEmpty) {
      throw _FbdStub('unresolved-operand', 'empty outVariable');
    }
    throw _FbdStub('complex-expression', 'compound outVariable "$text"');
  }

  // block
  final typeName = node.attributes['typeName'] ?? '';
  // Custom-FB call: a block whose (renamed) type is a registered FB routes to a
  // native FB-instance block (tagBinding = instance) + a struct-typed instance
  // tag, checked BEFORE the built-in allowlist so a user FB is never mistaken
  // for an unknown built-in.
  final effective = fbRenameMap[typeName] ?? typeName;
  final fb = fbRegistry[effective];
  if (fb != null) {
    final instance = _fbInstanceName(node, pouName, usedInstanceNames);
    // Instance tag default resolved against an fb-aware scratch project so
    // defaultValueFor -> lookupComposite -> fbDefinitionFor expands the FB into
    // its struct-typed default (one field per FB var).
    final scratch = PlcProject(
        id: 'scratch', name: 'scratch', controllerName: 'PLC',
        programs: [], tasks: [], hmis: [], structDefs: [], tags: [],
        fbDefinitions: fbRegistry.values.toList());
    instanceTags.add(PlcTag(
      name: instance, path: instance, dataType: effective,
      value: defaultValueFor(scratch, effective, 0), ioType: 'Internal',
    ));
    return FbdBlock(id: id, type: effective, title: effective,
        tagBinding: instance, x: node.x, y: node.y);
  }
  if (!kFbdBuiltinBlockTypes.contains(typeName)) {
    unsupported.add(typeName.isEmpty ? '?' : typeName);
    throw _FbdStub('unsupported-block', 'unsupported block "$typeName"');
  }
  final block = FbdBlock(id: id, type: typeName, title: typeName,
      x: node.x, y: node.y);
  // Extensible operators (AND/OR/ADD/MUL): inputCount = highest wired IN<n>.
  if (typeName == 'AND' || typeName == 'OR' || typeName == 'ADD' || typeName == 'MUL') {
    var maxPin = 1;
    for (final e in edges) {
      if (e.toLocalId != node.localId) continue;
      final m = RegExp(r'^IN(\d+)$').firstMatch(e.toPin ?? '');
      if (m != null) {
        // tryParse guards against a pin suffix that overflows 64-bit int
        // (int.parse would throw a FormatException, escaping the
        // never-throws contract); fall back to 1 (no widening) for such a
        // malformed/absurd pin name.
        final n = int.tryParse(m.group(1)!) ?? 1;
        if (n > maxPin) maxPin = n;
      }
    }
    block.inputCount = maxPin;
  }
  return block;
}

/// Deterministic instance name for a custom-FB call block: the `instanceName`
/// attribute when it is a valid identifier, else `'${pouName}_fb${localId}'`,
/// de-duplicated within a translation via [used] by appending `_2`, `_3`, ...
String _fbInstanceName(IrGraphNode node, String pouName, Set<String> used) {
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
