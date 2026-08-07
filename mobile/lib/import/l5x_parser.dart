import 'package:xml/xml.dart';

import 'import_ir.dart';

/// Upper bound on a parsed array dimension. L5X files are free to declare
/// arbitrarily large `Dimension`/`Dimensions` values, but the mapper
/// eagerly allocates a default-value list of that length (`List.generate`).
/// An unbounded (or hostile/typo'd) dimension would exhaust memory and throw
/// an uncatchable OutOfMemoryError-class `Error` — bypassing the UI's
/// `on FormatException` guard. Dimensions beyond this cap are clamped and an
/// [ImportWarning] is recorded instead. (Matches plcopen_parser.dart's
/// `_kMaxArrayLen`; not shared across files to keep each parser independent.)
const _kMaxL5xArrayLen = 65535;

/// Parses a single L5X array-dimension token (already isolated from any
/// multi-dimensional `Dimensions` string by the caller), clamping to
/// [_kMaxL5xArrayLen] and recording an info [ImportWarning] naming
/// [ownerLabel] when clamped. Negative/unparseable values become 0.
int _l5xArrayLen(
    String? raw, List<ImportWarning> warnings, String ownerLabel) {
  final n = int.tryParse(raw ?? '0') ?? 0;
  if (n <= 0) return 0;
  if (n > _kMaxL5xArrayLen) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: array dimension $n exceeds the supported '
            'maximum ($_kMaxL5xArrayLen) and was clamped; verify the '
            'imported size.'));
    return _kMaxL5xArrayLen;
  }
  return n;
}

/// Parses a Rockwell L5X (Studio 5000 / Logix Designer export) document into
/// the vendor-neutral IR. Throws [FormatException] ONLY when [xml] is not
/// well-formed or its root is not `<RSLogix5000Content>`. Valid-but-unsupported
/// content becomes an [ImportWarning] on the returned project — never a throw.
/// The `xml` package is confined to this file.
ImportedProject parseL5x(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException catch (e) {
    throw FormatException('Not well-formed XML: ${e.message}');
  }
  final root = doc.rootElement;
  if (root.name.local != 'RSLogix5000Content') {
    throw FormatException('Not an L5X document: root element is '
        '<${root.name.local}>, expected <RSLogix5000Content>.');
  }
  final warnings = <ImportWarning>[];
  final controller = _firstChild(root, 'Controller');
  final name = controller?.getAttribute('Name') ??
      root.getAttribute('TargetName') ??
      'Imported L5X Project';

  final types = _l5xTypes(controller, warnings);
  final pous = <ImportedPou>[];
  final globalVars = _l5xTags(controller, warnings);

  pous.addAll(_l5xAois(controller, warnings));
  pous.addAll(_l5xRoutines(controller, warnings));

  return ImportedProject(
      name: name, types: types, globalVars: globalVars, pous: pous,
      warnings: warnings);
}

/// First direct child element named [local], or null.
XmlElement? _firstChild(XmlElement e, String local) {
  for (final c in e.findElements(local)) {
    return c;
  }
  return null;
}

/// Direct child elements named [local] (possibly empty).
Iterable<XmlElement> _children(XmlElement e, String local) => e.findElements(local);

/// Parses an L5X scalar literal honoring [radix]. Handles a radix-prefixed form
/// (`16#ffff_0000`, `2#1010`, `8#17`) and the `Radix` attribute (Hex/Binary/
/// Octal/Decimal/Float). Underscores in digit groups are ignored. Returns an
/// `int` or `double`, or null if unparseable. (BOOL "1"/"0" come through as
/// int 1/0; the mapper coerces to bool by the field/var type.)
dynamic _l5xScalar(String raw, String? radix) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  // Radix-prefixed literal: <base>#<digits>.
  final hash = t.indexOf('#');
  if (hash > 0) {
    final base = int.tryParse(t.substring(0, hash));
    final digits = t.substring(hash + 1).replaceAll('_', '');
    if (base != null && base >= 2 && base <= 36) {
      final v = int.tryParse(digits, radix: base);
      if (v != null) return v;
    }
  }
  switch (radix) {
    case 'Hex':
      return int.tryParse(t.replaceAll('_', ''), radix: 16);
    case 'Binary':
      return int.tryParse(t.replaceAll('_', ''), radix: 2);
    case 'Octal':
      return int.tryParse(t.replaceAll('_', ''), radix: 8);
    case 'Float':
    case 'Exponential':
      return double.tryParse(t);
    default:
      final i = int.tryParse(t.replaceAll('_', ''));
      return i ?? double.tryParse(t);
  }
}

/// Scalar `initialValue` from an element's `<DefaultData Format="Decorated">
/// <DataValue Value= Radix=/>`, or null.
dynamic _defaultDataScalar(XmlElement owner) {
  for (final dd in _children(owner, 'DefaultData')) {
    final dv = _firstChild(dd, 'DataValue');
    if (dv != null) {
      final v = dv.getAttribute('Value');
      if (v != null) return _l5xScalar(v, dv.getAttribute('Radix'));
    }
  }
  return null;
}

/// Maps user `<DataType>`s under the controller to `ImportedType`s.
List<ImportedType> _l5xTypes(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedType>[];
  if (controller == null) return out;
  for (final dts in _children(controller, 'DataTypes')) {
    for (final dt in _children(dts, 'DataType')) {
      if ((dt.getAttribute('Class') ?? 'User') != 'User') continue;
      final tname = dt.getAttribute('Name') ?? '';
      if (tname.isEmpty) continue;
      final fields = <ImportedField>[];
      for (final members in _children(dt, 'Members')) {
        for (final m in _children(members, 'Member')) {
          if (m.getAttribute('Hidden') == 'true') continue; // internal host member
          final mn = m.getAttribute('Name') ?? '';
          if (mn.isEmpty) continue;
          if (m.getAttribute('Target') != null && m.getAttribute('BitNumber') != null) {
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'DataType "$tname" member "$mn" is a bit overlay of '
                    '"${m.getAttribute('Target')}.${m.getAttribute('BitNumber')}" '
                    '— imported as a plain BOOL (no bit aliasing).'));
            fields.add(ImportedField(name: mn, baseType: 'BOOL', arrayLength: 0));
            continue;
          }
          fields.add(ImportedField(
            name: mn,
            baseType: m.getAttribute('DataType') ?? 'DINT',
            arrayLength: _l5xArrayLen(m.getAttribute('Dimension'), warnings,
                'DataType "$tname" member "$mn"'),
            initialValue: _defaultDataScalar(m),
          ));
        }
      }
      out.add(ImportedType(name: tname, fields: fields));
    }
  }
  return out;
}

/// Concatenated CDATA of a routine's `<STContent><Line>`s (in document order).
String _stLines(XmlElement routine) {
  final lines = <String>[];
  for (final st in _children(routine, 'STContent')) {
    for (final ln in _children(st, 'Line')) {
      lines.add(ln.innerText.trim());
    }
  }
  return lines.join('\n');
}

/// Upper bound on a usable L5X FBD element `ID`. Anything above it (or absent,
/// unparseable, or negative) is treated as malformed and gets a unique
/// negative synthetic id instead, reproducing `plcopen_parser.dart`'s
/// `_graphBody` contract: distinct negative ids keep
/// `weaklyConnectedComponents` from merging two unrelated malformed nodes, and
/// the FBD translator's `localId < 0` gate still stubs their component.
const int _kMaxL5xFbdId = 1 << 31;

/// L5X FBD elements that are pure annotations: they carry an `ID` (or link to
/// one) but never participate in dataflow, so they are dropped entirely rather
/// than kept as opaque stub nodes. Everything else unrecognized IS kept (see
/// `_l5xFbdBody`), so a `<JSR>`/`<SBR>`/`<Ret>` network stubs visibly instead
/// of silently disappearing.
const Set<String> _kL5xFbdAnnotationElements = {'TextBox', 'Attachment'};

/// Rockwell FBD block/function mnemonics that alias onto an IEC built-in.
/// Applied to `<Block Type=>` / `<Function Type=>` only: an
/// `<AddOnInstruction Name=>` is a user type name and is never aliased.
/// `TONR`/`TOFR` are BEST-EFFORT (retentive accumulation and the `Reset` pin
/// are not modeled) and carry an extra verify warning.
const Map<String, String> _kL5xFbdTypeAliases = {
  'EQU': 'EQ',
  'NEQ': 'NE',
  'GEQ': 'GE',
  'LEQ': 'LE',
  'GRT': 'GT',
  'LES': 'LT',
  'BAND': 'AND',
  'BOR': 'OR',
  'BNOT': 'NOT',
  'TONR': 'TON',
  'TOFR': 'TOF',
  // Logix one-shots map exactly onto the IEC edge detectors.
  'OSRI': 'R_TRIG',
  'OSFI': 'F_TRIG',
};

/// Pin renames keyed by the ROCKWELL (pre-alias) type name. Rockwell FBD wires
/// carry `SourceA`/`SourceB`/`Dest` (math + compares) and `In<k>`/`Out` (bit
/// functions); `_assertPin` compares literally against the IEC registry
/// (`fbd_pins.dart`), so without these a type-only alias would make EVERY
/// math/compare network stub with `unresolved-pin` (spec resolution R1).
/// Math types are listed even though their TYPE is unchanged.
const Map<String, Map<String, String>> _kL5xFbdPinAliases = {
  'ADD': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'SUB': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'MUL': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'DIV': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'EQU': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'NEQ': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'GEQ': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'LEQ': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'GRT': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'LES': {'SourceA': 'IN1', 'SourceB': 'IN2', 'Dest': 'OUT'},
  'BNOT': {'In': 'IN', 'Out': 'OUT'},
  'TONR': {'TimerEnable': 'IN', 'PRE': 'PT', 'Preset': 'PT', 'DN': 'Q', 'ACC': 'ET'},
  'TOFR': {'TimerEnable': 'IN', 'PRE': 'PT', 'Preset': 'PT', 'DN': 'Q', 'ACC': 'ET'},
  // SEL and CTUD keep their IEC-identical TYPE names, so they pass
  // `kFbdBuiltinBlockTypes` and would otherwise die in `_assertPin` with
  // `unresolved-pin` and NO inventory entry. IEC SEL is
  // `OUT = G ? IN1 : IN0`; Logix SEL is `Out = SelectorIn ? In2 : In1`.
  'SEL': {'SelectorIn': 'G', 'In1': 'IN0', 'In2': 'IN1', 'Out': 'OUT'},
  // CTUD is BEST-EFFORT (like TONR/TOFR): the mapped pins are the ones whose
  // meaning is unambiguous; anything else passes through and stubs.
  'CTUD': {
    'CUEnable': 'CU',
    'CDEnable': 'CD',
    'Reset': 'R',
    'Load': 'LD',
    'PRE': 'PV',
    'ACC': 'CV',
    'DN': 'QU',
  },
  'OSRI': {'InputBit': 'CLK', 'OutputBit': 'Q'},
  'OSFI': {'InputBit': 'CLK', 'OutputBit': 'Q'},
};

/// Extensible bit functions whose pins are `In<k>`/`Out` (mapped by regex to
/// `IN<k>`/`OUT`).
const Set<String> _kL5xFbdBitFunctions = {'BAND', 'BOR'};

final RegExp _kL5xFbdBitFunctionPin = RegExp(r'^In(\d+)$');

/// Rewrites a Rockwell pin name to its IEC equivalent, given the endpoint
/// node's ROCKWELL type. Anything unmapped (including `EnableIn`/`EnableOut`)
/// passes through VERBATIM and, if it is not a real IEC pin, `_assertPin`
/// stubs that network — faithful-or-stub preserved.
String? _aliasL5xFbdPin(String? abType, String? pin) {
  if (pin == null || pin.isEmpty || abType == null) {
    return pin;
  }
  final mapped = _kL5xFbdPinAliases[abType]?[pin];
  if (mapped != null) {
    return mapped;
  }
  if (_kL5xFbdBitFunctions.contains(abType)) {
    if (pin == 'Out') return 'OUT';
    final m = _kL5xFbdBitFunctionPin.firstMatch(pin);
    if (m != null) return 'IN${m.group(1)}';
  }
  return pin;
}

/// Aliases whose IEC target is only an APPROXIMATION of the Rockwell block, so
/// each carries an `abOriginal` breadcrumb and a prominent verify warning.
/// (`TONR`/`TOFR` lose retentive accumulation and the `Reset` pin;
/// `OSRI`/`OSFI` lose Logix's separate storage/output bits.)
const Set<String> _kL5xFbdBestEffortTypes = {'TONR', 'TOFR', 'OSRI', 'OSFI'};

/// The `<Sheet>` elements of an FBD routine body, in ascending `<Sheet
/// Number>` order. A sheet without a `Number` (the schema allows it, though
/// real exports always carry one) keeps its DOCUMENT-order position relative
/// to its neighbours: its sort key sits just after the previous sheet's. The
/// sort is stable, so equal keys keep document order too. This ordering drives
/// both offsetting passes in `_l5xFbdBody`, so network numbering and
/// y-offsetting always read in a predictable sheet sequence.
List<XmlElement> _l5xFbdSheets(XmlElement routine) {
  final sheets = <XmlElement>[];
  for (final content in _children(routine, 'FBDContent')) {
    sheets.addAll(_children(content, 'Sheet'));
  }
  final keys = <double>[];
  var prev = -1.0;
  for (final s in sheets) {
    final n = int.tryParse(s.getAttribute('Number') ?? '');
    final k = n != null ? n.toDouble() : prev + 0.5;
    keys.add(k);
    prev = k;
  }
  final order = List<int>.generate(sheets.length, (i) => i)
    ..sort((a, b) {
      final c = keys[a].compareTo(keys[b]);
      return c != 0 ? c : a.compareTo(b); // stable
    });
  return [for (final i in order) sheets[i]];
}

/// Resolves Logix `ICon`/`OCon` connector pairs into direct wires, ROUTINE-wide
/// (connector names link across sheets), mutating [nodes]/[conns] in place.
///
/// `oconNames`-keyed wires are the PRODUCER wires (a real block's output flows
/// INTO the named output connector) and `iconNames`-keyed ones the CONSUMER
/// wires (the named input connector flows OUT to a real block's input). For
/// every name present in both, the cross-product of direct wires is emitted,
/// then those connector nodes and their wires are dropped.
///
/// An UNMATCHED connector keeps its node (whose `elementType` is `ICon`/`OCon`,
/// which `_translateComponent`'s element-kind pre-flight does not recognize),
/// so the affected component stubs as `unsupported-element` rather than
/// silently losing a data path, plus one info warning per connector name.
///
/// Two shapes are deliberately routed to that unmatched path rather than
/// spliced:
///  * an UNNAMED connector (blank `Name`) never even reaches this function's
///    maps (the caller does not register it) — two blank names are not the
///    same connector, and splicing them would wire unrelated networks together;
///  * CHAINED connectors (a wire whose source is an `ICon` and whose target is
///    an `OCon`) have no real producer or consumer to splice, as do the two
///    malformed shapes with the same consequence — a wire OUT of an `OCon`
///    (a sink) or INTO an `ICon` (a source). Splicing any of them would emit a
///    direct wire whose endpoint is a connector node this function then drops,
///    and the translator silently swallows a wire whose endpoint node does not
///    exist, so the data path would vanish without a stub.
/// Never throws.
void _resolveL5xFbdConnectors(
    List<IrGraphNode> nodes,
    List<IrConnection> conns,
    Map<int, String> iconNames,
    Map<int, String> oconNames,
    List<ImportWarning> warnings,
    String ownerLabel) {
  if (iconNames.isEmpty && oconNames.isEmpty) {
    return;
  }
  final producers = <String, List<IrConnection>>{};
  final consumers = <String, List<IrConnection>>{};
  final chained = <String>{};
  for (final c in conns) {
    // The two WELL-FORMED roles: a wire INTO an OCon produces for that name, a
    // wire OUT OF an ICon consumes it.
    final toO = oconNames[c.toLocalId];
    final fromI = iconNames[c.fromLocalId];
    // The two MALFORMED roles: an OCon is a sink, so nothing flows out of it,
    // and an ICon is a source, so nothing flows into it. Either shape (like
    // the ICon -> OCon chain) leaves the name with no real block to splice
    // onto, and splicing anyway would emit a direct wire whose endpoint is a
    // connector node this function then DROPS — a wire referencing a
    // non-existent node, which the translator silently swallows (its component
    // scan only keeps edges with both endpoints present). Route every such
    // name to the unmatched path instead, so it stubs visibly.
    final fromO = oconNames[c.fromLocalId];
    final toI = iconNames[c.toLocalId];
    if ((fromI != null && toO != null) || fromO != null || toI != null) {
      for (final name in [toO, fromI, fromO, toI]) {
        if (name != null) chained.add(name);
      }
      continue;
    }
    if (toO != null) (producers[toO] ??= []).add(c);
    if (fromI != null) (consumers[fromI] ??= []).add(c);
  }

  final matched = <String>{};
  final direct = <IrConnection>[];
  for (final entry in producers.entries) {
    if (chained.contains(entry.key)) continue;
    final cons = consumers[entry.key];
    if (cons == null) continue;
    matched.add(entry.key);
    for (final p in entry.value) {
      for (final c in cons) {
        direct.add(IrConnection(
          fromLocalId: p.fromLocalId,
          fromPin: p.fromPin,
          toLocalId: c.toLocalId,
          toPin: c.toPin,
        ));
      }
    }
  }

  final dropIds = <int>{
    for (final e in iconNames.entries)
      if (matched.contains(e.value)) e.key,
    for (final e in oconNames.entries)
      if (matched.contains(e.value)) e.key,
  };
  nodes.removeWhere((n) => dropIds.contains(n.localId));
  conns.removeWhere(
      (c) => dropIds.contains(c.fromLocalId) || dropIds.contains(c.toLocalId));
  conns.addAll(direct);

  final unmatched = <String>{...iconNames.values, ...oconNames.values}
      .difference(matched)
      .toList()
    ..sort();
  for (final name in unmatched) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: unmatched connector "$name" — the affected '
            'network is not translated.'));
  }
}

/// Builds the vendor-neutral [GraphBody] for one L5X FBD routine body
/// (`<FBDContent><Sheet>...`), shared by the program-routine arm and the AOI
/// arm. [ownerLabel] is the human label used in warnings, e.g.
/// `'Routine "Prog_Main"'` or `'AOI "Pump"'`.
///
/// Emits EXACTLY the IR attribute keys `plcopen_parser.dart`'s `_graphBody`
/// emits (`variable`, `typeName`, `instanceName`), so `translateFbdBody` needs
/// no changes. `hasNegatedPin` is never emitted: Logix FBD has no pin
/// inversion (`BNOT` is an explicit element).
///
/// Two passes per sheet — nodes first, then wires — because pin aliasing needs
/// the endpoint node's type to be known, and because a wire endpoint is
/// resolved through the node pass's `assignedByRawId` map (an endpoint that
/// names no element gets a `danglingWire` placeholder node so the wire is
/// never silently dropped). Never throws: every attribute read is null-tolerant
/// and an absent/empty `<FBDContent>` yields an empty body.
///
/// MULTI-SHEET: every `<Sheet>` of the routine merges into ONE `GraphBody`
/// (`_l5xFbdSheets` fixes the order). Later sheets get a localId offset
/// (`maxAssignedIdSoFar + 1`) so raw ids that repeat per sheet cannot collide,
/// and a y offset (`maxYSeenSoFar + 200`, computed on the ALREADY-offset y
/// values) so `weaklyConnectedComponents`' layout ordering numbers networks
/// sheet by sheet instead of interleaving them. Synthetic negative ids are
/// never offset. `ICon`/`OCon` pairs are resolved after the merge.
GraphBody _l5xFbdBody(
    XmlElement routine, List<ImportWarning> warnings, String ownerLabel) {
  final nodes = <IrGraphNode>[];
  final conns = <IrConnection>[];
  // ROUTINE-WIDE (not per-sheet) synthetic-id counter: a malformed-id element
  // on sheet 1 and one on sheet 2 must still get distinct ids.
  var malformedId = -1;
  final ignoredKinds = <String>[];
  var ignoredCount = 0;
  // Connector nodes, collected routine-wide: assigned localId -> name. ONLY
  // named connectors are registered; an unnamed one can never be matched (two
  // blank names are not the same connector), so it must not enter these maps.
  final iconNames = <int, String>{};
  final oconNames = <int, String>{};
  var unnamedConnectors = 0;
  // Raw ids that a LATER element on the same sheet tried to reuse (see the
  // duplicate handling in pass 1).
  final duplicateRawIds = <String>[];
  // Assigned localId -> the node's ROCKWELL type (pre-alias). Populated for
  // BOTH Block/Function AND AddOnInstruction nodes, but ONLY used to drive
  // pin aliasing for ids also present in `aliasEligibleIds` — the
  // EnableIn/EnableOut heads-up below reads it unconditionally (it applies to
  // AOI calls too).
  final abTypeById = <int, String>{};
  // localIds of Block/Function nodes ONLY. An AddOnInstruction's `Name` is a
  // user type name and is NEVER aliased — not the type, and (this is the
  // part a naive `abType`-string gate misses) not its PINS either: an AOI
  // that happens to be named "SEL" must not get its wires silently rewritten
  // to the built-in SEL's G/IN0/IN1 just because the strings match. Gating
  // pin aliasing on ELEMENT KIND (via this set) rather than on the abType
  // string keeps that true.
  final aliasEligibleIds = <int>{};
  final verifyWarned = <String>{};
  final enableWarned = <String>{};
  // Sheet-merge state.
  var idOffset = 0;
  var maxAssignedId = -1;
  var yBase = 0.0;
  // Nullable so the FIRST node's y seeds the running max instead of an assumed
  // 0.0 (a sheet whose elements all sit at negative `Y` would otherwise be
  // treated as reaching down to 0).
  double? maxYSeen;
  var firstSheet = true;

  for (final sheet in _l5xFbdSheets(routine)) {
    if (!firstSheet) {
      idOffset = maxAssignedId + 1;
      // MONOTONIC: the base only ever grows. Taking the running max (rather
      // than assigning `maxYSeen + 200` outright) keeps a sheet whose `Y`s are
      // far more negative than the previous sheet's from pulling the base
      // BACKWARDS, which would invert the sheet order outright. It is a layout
      // hint for component ordering, not a hard separation guarantee: two
      // sheets that both use negative coordinates can still overlap, which
      // costs network ORDER only, never correctness of the graph itself.
      final nextBase = (maxYSeen ?? 0) + 200;
      if (nextBase > yBase) yBase = nextBase;
    }
    firstSheet = false;
    // Raw `ID` -> the localId actually assigned to that element, so pass 2
    // can resolve a wire endpoint to a REAL node (including one that was
    // given a synthetic negative id for an out-of-range `ID`). Wire
    // endpoints are sheet-local, so this map is per sheet.
    final assignedByRawId = <int, int>{};

    // Pass 1 — nodes.
    for (final el in sheet.childElements) {
      final tag = el.name.local;
      if (tag == 'Wire' || tag == 'FeedbackWire') {
        continue; // pass 2
      }
      if (_kL5xFbdAnnotationElements.contains(tag)) {
        ignoredCount++;
        if (!ignoredKinds.contains(tag)) ignoredKinds.add(tag);
        continue;
      }
      final parsed = int.tryParse(el.getAttribute('ID') ?? '');
      // A raw `ID` a previous element on this sheet already claimed. Letting
      // the duplicate keep that id would DELETE a real element: two nodes
      // sharing a localId collapse to one in `weaklyConnectedComponents`' byId
      // map, the wires re-point onto the survivor, and the component then
      // translates CLEANLY as the wrong logic. So the duplicate is demoted to
      // a synthetic negative id (tripping the translator's `localId < 0` gate,
      // which stubs its component visibly) and does NOT re-register the raw
      // id, so wires keep resolving to the ORIGINAL element.
      final duplicate =
          parsed != null && parsed >= 0 && assignedByRawId.containsKey(parsed);
      final int localId;
      if (parsed == null ||
          parsed < 0 ||
          parsed > _kMaxL5xFbdId ||
          duplicate) {
        localId = malformedId--; // never offset
      } else {
        localId = parsed + idOffset;
        if (localId > maxAssignedId) maxAssignedId = localId;
      }
      if (duplicate) {
        duplicateRawIds.add('$parsed');
      } else if (parsed != null && parsed >= 0) {
        // Recorded even when the element got a SYNTHETIC id (out-of-range
        // `ID`), so a wire naming that raw id still resolves to the real
        // (stubbing) node rather than to a placeholder.
        assignedByRawId[parsed] = localId;
      }
      final y = (double.tryParse(el.getAttribute('Y') ?? '') ?? 0) + yBase;
      if (maxYSeen == null || y > maxYSeen) maxYSeen = y;

      final attrs = <String, String>{};
      final String elementType;
      switch (tag) {
        case 'IRef':
          {
            elementType = 'inVariable';
            attrs['variable'] = (el.getAttribute('Operand') ?? '').trim();
            break;
          }
        case 'ORef':
          {
            elementType = 'outVariable';
            attrs['variable'] = (el.getAttribute('Operand') ?? '').trim();
            break;
          }
        case 'Block':
        case 'Function':
          {
            elementType = 'block';
            final abType = (el.getAttribute('Type') ?? '').trim();
            final aliased = _kL5xFbdTypeAliases[abType] ?? abType;
            attrs['typeName'] = aliased;
            abTypeById[localId] = abType;
            aliasEligibleIds.add(localId);
            if (_kL5xFbdBestEffortTypes.contains(abType)) {
              // IR-only breadcrumb: translateFbdBody copies attributes through
              // and only reads the keys it knows, so an unknown key is
              // silently ignored (there is no native field to carry it).
              attrs['abOriginal'] = abType;
              if (verifyWarned.add(abType)) {
                warnings.add(ImportWarning(
                    severity: WarningSeverity.warning,
                    message: '$ownerLabel: Rockwell $abType mapped best-effort '
                        'to the IEC $aliased block — behaviour differs '
                        '(retentive/reset, extra pins); verify.'));
              }
            }
            if (tag == 'Block') {
              final operand = (el.getAttribute('Operand') ?? '').trim();
              if (operand.isNotEmpty) attrs['instanceName'] = operand;
            }
            break;
          }
        case 'AddOnInstruction':
          {
            // An AOI's `Name` is a user type name and is NEVER aliased — not
            // the type, and not its PINS either, even when the name happens
            // to match a built-in mnemonic (e.g. an AOI named "SEL"). Its
            // localId is deliberately NOT added to `aliasEligibleIds`, so
            // pass 2's pin aliasing skips it; `abTypeById` is still recorded
            // (below) purely so the EnableIn/EnableOut heads-up can name it.
            elementType = 'block';
            attrs['typeName'] = (el.getAttribute('Name') ?? '').trim();
            if (attrs['typeName']!.isNotEmpty) {
              abTypeById[localId] = attrs['typeName']!; // never aliased
            }
            final operand = (el.getAttribute('Operand') ?? '').trim();
            if (operand.isNotEmpty) attrs['instanceName'] = operand;
            break;
          }
        case 'ICon':
        case 'OCon':
          {
            elementType = tag;
            final cname = (el.getAttribute('Name') ?? '').trim();
            attrs['connectorName'] = cname;
            if (cname.isEmpty) {
              // Unnamed: NOT registered, so it can never be spliced. The node
              // stays, so its component stubs (`unsupported-element`).
              unnamedConnectors++;
            } else if (tag == 'ICon') {
              iconNames[localId] = cname;
            } else {
              oconNames[localId] = cname;
            }
            break;
          }
        default:
          {
            // Kept, NOT ignored: the raw element name is not one of the
            // translator's known elementType strings, so this node's whole
            // component stubs as `unsupported-element` instead of vanishing.
            elementType = tag;
            break;
          }
      }
      nodes.add(IrGraphNode(
        localId: localId,
        elementType: elementType,
        x: double.tryParse(el.getAttribute('X') ?? '') ?? 0,
        y: y,
        attributes: attrs,
      ));
    }

    // Resolves one wire endpoint to a real node id. An endpoint that names
    // no element on this sheet (absent, unparseable, negative, or an id no
    // element carries) gets a fresh `danglingWire` PLACEHOLDER node instead
    // of dropping the wire: dropping it would silently delete a data path
    // and let the consumer's component translate as though that input were
    // simply unwired. The placeholder's negative id + unknown elementType
    // make the consumer's component stub (`unsupported-element`). Resolution
    // goes through `assignedByRawId`, so the per-sheet offset is applied
    // exactly once and out-of-range ids land on the real synthetic-id node.
    int resolveEndpoint(String? raw) {
      final parsed = int.tryParse(raw ?? '');
      final hit = parsed == null ? null : assignedByRawId[parsed];
      if (hit != null) {
        return hit;
      }
      final id = malformedId--;
      nodes.add(IrGraphNode(
          localId: id, elementType: 'danglingWire', y: yBase));
      return id;
    }

    // Pass 2 — wires. Wires live inside their own `<Sheet>`, so every
    // reference is sheet-local. `<FeedbackWire>` (a wire closing a feedback
    // loop) carries the identical attribute set as `<Wire>` and maps the same
    // way; the cyclic graph it creates is handled by the executor's existing
    // dataflow-cycle fallback.
    for (final el in sheet.childElements) {
      final tag = el.name.local;
      if (tag != 'Wire' && tag != 'FeedbackWire') {
        continue;
      }
      final rawFromPin = el.getAttribute('FromParam');
      final rawToPin = el.getAttribute('ToParam');
      final fromId = resolveEndpoint(el.getAttribute('FromID'));
      final toId = resolveEndpoint(el.getAttribute('ToID'));

      // Logix `EnableIn`/`EnableOut` are a rung-condition concept with no pin
      // on the IEC block an aliased type maps to — and none on an imported AOI
      // either, where they are INTERNAL vars (see l5x_parser's AOI arm). A
      // WIRED one is left unaliased and follows the existing unmapped-pin path
      // (the network stubs with `unresolved-pin`); this heads-up just makes
      // that a named, diagnosable condition instead of a generic pin stub. An
      // UNWIRED one never reaches here. The gate is simply "the endpoint is a
      // block": narrowing it to aliased built-ins would miss the AOI case.
      for (final e in [
        MapEntry(abTypeById[fromId], rawFromPin),
        MapEntry(abTypeById[toId], rawToPin),
      ]) {
        final t = e.key;
        final pin = e.value;
        if (t == null || pin == null) continue;
        if (pin != 'EnableIn' && pin != 'EnableOut') continue;
        if (enableWarned.add('$t|$pin')) {
          warnings.add(ImportWarning(
              severity: WarningSeverity.info,
              message: '$ownerLabel: EnableIn/EnableOut wired on "$t" — the '
                  'block it maps to has no such pin, so that network is '
                  'not translated.'));
        }
      }

      conns.add(IrConnection(
        fromLocalId: fromId,
        fromPin: _aliasL5xFbdPin(
            aliasEligibleIds.contains(fromId) ? abTypeById[fromId] : null,
            rawFromPin),
        toLocalId: toId,
        toPin: _aliasL5xFbdPin(
            aliasEligibleIds.contains(toId) ? abTypeById[toId] : null,
            rawToPin),
      ));
    }
  }

  _resolveL5xFbdConnectors(
      nodes, conns, iconNames, oconNames, warnings, ownerLabel);

  if (duplicateRawIds.isNotEmpty) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.warning,
        message: '$ownerLabel: ${duplicateRawIds.length} element(s) reuse a '
            'duplicate ID already used on the same sheet '
            '(${duplicateRawIds.join(', ')}) — each duplicate was given a '
            'synthetic id so its network is not translated, rather than '
            'silently replacing the element that claimed the id first.'));
  }

  if (unnamedConnectors > 0) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: $unnamedConnectors unmatched connector(s) '
            '(unnamed) — a connector with no Name can never be matched, so the '
            'affected networks are not translated.'));
  }

  if (ignoredCount > 0) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: $ignoredCount element(s) ignored '
            '(${ignoredKinds.join(', ')}).'));
  }
  return GraphBody(nodes: nodes, connections: conns);
}

VarScope _usageScope(String? usage) => switch (usage) {
      'Input' => VarScope.input,
      'Output' => VarScope.output,
      'InOut' => VarScope.inOut,
      _ => VarScope.local,
    };

/// Maps `<AddOnInstructionDefinition>`s to functionBlock POUs. The existing
/// `mapImportedFbs` turns these into FbDefinitions (AOI-typed tags then resolve).
List<ImportedPou> _l5xAois(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedPou>[];
  if (controller == null) return out;
  for (final defs in _children(controller, 'AddOnInstructionDefinitions')) {
    for (final aoi in _children(defs, 'AddOnInstructionDefinition')) {
      final name = aoi.getAttribute('Name') ?? '';
      if (name.isEmpty) continue;
      // Logic routine: named "Logic" else the first routine. Resolved BEFORE
      // the parameter loop because an RLL-logic AOI keeps EnableIn/EnableOut
      // while every other logic language keeps the historic skip.
      XmlElement? logic;
      for (final rs in _children(aoi, 'Routines')) {
        for (final r in _children(rs, 'Routine')) {
          logic ??= r;
          if (r.getAttribute('Name') == 'Logic') logic = r;
        }
      }
      final logicType = logic?.getAttribute('Type');
      final isRll = logicType == 'RLL';

      final vars = <ImportedVar>[];
      for (final params in _children(aoi, 'Parameters')) {
        for (final p in _children(params, 'Parameter')) {
          final pn = p.getAttribute('Name') ?? '';
          if (pn.isEmpty) continue;
          if (pn == 'EnableIn' || pn == 'EnableOut') {
            if (!isRll) continue; // ST/FBD/SFC AOIs: historic skip, unchanged
            // Rockwell RLL AOI logic commonly does XIC(EnableIn)/OTE(EnableOut).
            // Retained as INTERNAL vars so those references resolve per
            // instance via LdScope instead of falling through to absent
            // globals. The body only runs when the call executes, so
            // EnableIn = true during execution is the faithful mapping.
            vars.add(ImportedVar(name: pn, baseType: 'BOOL',
                scope: VarScope.local, initialValue: pn == 'EnableIn'));
            continue;
          }
          vars.add(ImportedVar(
            name: pn,
            baseType: p.getAttribute('DataType') ?? 'DINT',
            arrayLength: _l5xArrayLen(p.getAttribute('Dimensions'), warnings,
                'AOI "$name" parameter "$pn"'),
            scope: _usageScope(p.getAttribute('Usage')),
            initialValue: _defaultDataScalar(p),
          ));
        }
      }
      for (final lts in _children(aoi, 'LocalTags')) {
        for (final lt in _children(lts, 'LocalTag')) {
          final ln = lt.getAttribute('Name') ?? '';
          if (ln.isEmpty) continue;
          vars.add(ImportedVar(
            name: ln,
            baseType: lt.getAttribute('DataType') ?? 'DINT',
            arrayLength: _l5xArrayLen(lt.getAttribute('Dimensions'), warnings,
                'AOI "$name" local tag "$ln"'),
            scope: VarScope.local,
            initialValue: _defaultDataScalar(lt),
          ));
        }
      }

      PouBody body = TextBody('');
      var lang = PouLanguage.st;
      if (logic != null) {
        if (logicType == 'ST') {
          body = TextBody(_stLines(logic));
        } else if (isRll) {
          // Same rung capture _l5xRoutines uses; the mapper compiles it via
          // compileRllRungs into the FB's native ladder body.
          final rungs = <RllRung>[];
          for (final content in _children(logic, 'RLLContent')) {
            for (final rung in _children(content, 'Rung')) {
              final num = int.tryParse(rung.getAttribute('Number') ?? '') ?? rungs.length;
              final text = (_firstChild(rung, 'Text')?.innerText ?? '').trim();
              final comment = _firstChild(rung, 'Comment')?.innerText.trim() ?? '';
              rungs.add(RllRung(number: num, text: text, comment: comment));
            }
          }
          body = NeutralLadderBody(rungs: rungs);
          lang = PouLanguage.ld;
        } else {
          warnings.add(ImportWarning(severity: WarningSeverity.info,
              message: 'AOI "$name" logic is ${logicType ?? '?'} — interface '
                  'imported, logic not yet translated.'));
        }
      }
      out.add(ImportedPou(name: name, kind: PouKind.functionBlock,
          lang: lang, localVars: vars, body: body));
    }
  }
  return out;
}

/// Maps each `<Routine>` in each `<Program>` to a program POU named
/// `Program_Routine`. ST inlines its lines; RLL captures each rung's neutral
/// text + comment into a `NeutralLadderBody`; FBD parses its structured
/// `<FBDContent>` into a `GraphBody` (translated per network by
/// `ir_to_project`); SFC still becomes an empty graphical body (the mapper's
/// existing whole-POU stub) + a count-carrying warning.
List<ImportedPou> _l5xRoutines(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedPou>[];
  if (controller == null) return out;
  for (final progs in _children(controller, 'Programs')) {
    for (final prog in _children(progs, 'Program')) {
      final progName = prog.getAttribute('Name') ?? 'Program';
      for (final rs in _children(prog, 'Routines')) {
        for (final r in _children(rs, 'Routine')) {
          final rName = r.getAttribute('Name') ?? 'Routine';
          final name = '${progName}_$rName';
          final type = r.getAttribute('Type');
          switch (type) {
            case 'ST':
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.st, localVars: const [],
                  body: TextBody(_stLines(r))));
              break;
            case 'RLL':
              final rungs = <RllRung>[];
              for (final content in _children(r, 'RLLContent')) {
                for (final rung in _children(content, 'Rung')) {
                  final num = int.tryParse(rung.getAttribute('Number') ?? '') ?? rungs.length;
                  final text = (_firstChild(rung, 'Text')?.innerText ?? '').trim();
                  final comment = _firstChild(rung, 'Comment')?.innerText.trim() ?? '';
                  rungs.add(RllRung(number: num, text: text, comment: comment));
                }
              }
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.ld, localVars: const [],
                  body: NeutralLadderBody(rungs: rungs)));
              break;
            case 'FBD':
              // The structured <FBDContent> parses into a real GraphBody;
              // `ir_to_project`'s existing FBD arm translates it per network
              // (faithful-or-stub). A routine where NOTHING translates keeps
              // today's whole-POU stub via that arm's existing `else`.
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.fbd, localVars: const [],
                  body: _l5xFbdBody(r, warnings, 'Routine "$name"')));
              break;
            case 'SFC':
              warnings.add(ImportWarning(severity: WarningSeverity.warning,
                  message: 'Routine "$name" (SFC): graphical body not yet '
                      'translated.'));
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.sfc, localVars: const [],
                  body: SfcBody(nodes: const [], edges: const [], actions: const [])));
              break;
            default:
              warnings.add(ImportWarning(severity: WarningSeverity.info,
                  message: 'Routine "$name": unsupported type "${type ?? '?'}" — skipped.'));
          }
        }
      }
    }
  }
  return out;
}

/// Maps controller-scoped and program-scoped `<Tag>`s to global `ImportedVar`s.
/// Scalar tags hydrate their value from Decorated `<DataValue>`; composite/array
/// tags default to the type default (initialValue null). The mapper's existing
/// sanitize+dedup handles cross-program name collisions.
List<ImportedVar> _l5xTags(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedVar>[];
  if (controller == null) return out;

  ImportedVar? tagToVar(XmlElement tag) {
    final tn = tag.getAttribute('Name') ?? '';
    if (tn.isEmpty) return null;
    final dims = tag.getAttribute('Dimensions') ?? '';
    final dimTokens =
        dims.trim().isEmpty ? const <String>[] : dims.trim().split(RegExp(r'\s+'));
    final firstDim = _l5xArrayLen(
        dimTokens.isEmpty ? null : dimTokens.first, warnings, 'Tag "$tn"');
    if (dimTokens.length > 1) {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Tag "$tn": multi-dimensional array flattened to $firstDim.'));
    }
    // Scalar value from a Decorated <DataValue> directly under <Data>.
    dynamic initial;
    for (final data in _children(tag, 'Data')) {
      if (data.getAttribute('Format') != 'Decorated') continue;
      final dv = _firstChild(data, 'DataValue');
      if (dv != null && dv.getAttribute('Value') != null) {
        initial = _l5xScalar(dv.getAttribute('Value')!, dv.getAttribute('Radix'));
      }
      // A <Structure>/<ArrayMember> tag stays null -> type default (foundation).
    }
    return ImportedVar(
      name: tn,
      baseType: tag.getAttribute('DataType') ?? 'DINT',
      arrayLength: firstDim,
      scope: VarScope.global,
      initialValue: initial,
    );
  }

  // Controller-scoped tags.
  for (final tags in _children(controller, 'Tags')) {
    for (final tag in _children(tags, 'Tag')) {
      final v = tagToVar(tag);
      if (v != null) out.add(v);
    }
  }
  // Program-scoped tags (flat).
  for (final progs in _children(controller, 'Programs')) {
    for (final prog in _children(progs, 'Program')) {
      for (final tags in _children(prog, 'Tags')) {
        for (final tag in _children(tags, 'Tag')) {
          final v = tagToVar(tag);
          if (v != null) out.add(v);
        }
      }
    }
  }
  return out;
}
