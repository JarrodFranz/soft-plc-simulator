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
      warnings: warnings, dialect: ImportDialect.l5x);
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

/// Upper bound on a usable L5X element `ID`, shared by the FBD and SFC
/// builders. Anything above it (or absent, unparseable, or negative) is
/// treated as malformed and gets a unique negative synthetic id instead,
/// reproducing `plcopen_parser.dart`'s `_graphBody` contract: distinct
/// negative ids keep `weaklyConnectedComponents` from merging two unrelated
/// malformed nodes, and the FBD translator's `localId < 0` gate still stubs
/// their component. On the SFC path the same rejection keeps a raw `ID` out
/// of the synthetic-id namespace that branch connectors and the poison node
/// draw from — see `_l5xSfcBody`.
const int _kMaxL5xElementId = 1 << 31;

/// L5X graphical elements that are pure annotations: they carry an `ID` (or
/// link to one) but never participate in dataflow or control flow, so they are
/// dropped entirely rather than kept as opaque stub nodes. Shared by the FBD
/// and SFC builders. Everything else unrecognized IS surfaced (see
/// `_l5xFbdBody` and `_l5xSfcBody`), so a `<JSR>`/`<SBR>`/`<Ret>` network or a
/// `<Stop>` element stubs visibly instead of silently disappearing.
const Set<String> _kL5xAnnotationElements = {'TextBox', 'Attachment'};

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
      if (_kL5xAnnotationElements.contains(tag)) {
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
          parsed > _kMaxL5xElementId ||
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

/// Joined `<STContent><Line>` text under [owner]'s direct [wrapper] child
/// (`'Body'` for a `<Step>`/`<Action>`, `'Condition'` for a `<Transition>`),
/// each line trimmed, joined with `\n`, then trimmed as a whole. Returns `''`
/// when absent, empty or whitespace-only. Never throws.
String _l5xSfcSt(XmlElement owner, String wrapper) {
  final lines = <String>[];
  for (final w in _children(owner, wrapper)) {
    for (final st in _children(w, 'STContent')) {
      for (final ln in _children(st, 'Line')) {
        lines.add(ln.innerText.trim());
      }
    }
  }
  return lines.join('\n').trim();
}

/// Element kinds `_l5xSfcBody`'s link classifier can resolve an endpoint to.
/// Unmappable elements (`<Stop>`, `<SbrRet>`, an unknown tag) are deliberately
/// NOT registered here: they poison the chart, and a link naming one must take
/// the `dangling link` path rather than resolve to a node that does not exist.
///
/// `branch` and `leg` are NOT node kinds: a `<Branch>` is synthesized into a
/// PAIR of connector nodes (see [_L5xSfcBranch]) and a `<Leg>` is only ever a
/// link ENDPOINT. They live here because the classifier resolves an endpoint to
/// one of these five outcomes.
enum _L5xSfcKind { step, transition, branch, leg }

/// Per-`<Branch>` synthesis state. L5X models a branch as ONE element with
/// `<Leg>` children plus a flat `<DirectedLink>` list; the neutral IR (and
/// IEC 61131-3, and `sfc_exec`) models it as TWO connector nodes, an opening
/// divergence and a closing convergence, with ordinary edges between them and
/// the elements on each leg. This class holds the synthesized pair's reserved
/// ids and the four link buckets §3's decision table reads.
///
/// Leg MEMBERSHIP is never computed: only each leg's head and tail matter, and
/// both fall straight out of the endpoint classifier.
class _L5xSfcBranch {
  _L5xSfcBranch({
    required this.rawId,
    required this.divId,
    required this.convId,
    required this.divKind,
    required this.convKind,
    required this.flow,
  });

  /// The raw `ID` attribute text, used verbatim in warnings.
  final String rawId;

  /// Reserved at REGISTRATION (pass 1), from the routine-wide synthetic-id
  /// counter, for every branch with a recognized `BranchType` — even when one
  /// side is later dropped. That makes id allocation a pure function of
  /// document order, independent of the link list.
  final int divId, convId;
  final SfcNodeKind divKind, convKind;

  /// `BranchFlow`, READ BUT NOT TRUSTED: emission is derived from link
  /// topology, so an export that splits a branch into separate `Diverge` and
  /// `Converge` elements and one that emits a single paired element both work
  /// without a mode switch.
  final String? flow;

  /// Node ids feeding / fed by each synthesized connector.
  final List<int> divIn = [], divOut = [], convIn = [], convOut = [];

  /// §3's emission rule, in full: a side is emitted whenever EITHER of its
  /// bits is set, and dropped when both are clear. (All 16 rows of the
  /// decision table satisfy this; a side with exactly one bit set is emitted
  /// AND recorded as a defect, so the element count stays honest.)
  bool get emitDiv => divIn.isNotEmpty || divOut.isNotEmpty;
  bool get emitConv => convIn.isNotEmpty || convOut.isNotEmpty;

  bool get isSelection => divKind == SfcNodeKind.selDiv;
}

/// Human name for a resolved endpoint kind, used inside branch cause clauses.
String _l5xSfcKindName(_L5xSfcKind? k) => switch (k) {
      _L5xSfcKind.step => 'step',
      _L5xSfcKind.transition => 'transition',
      _L5xSfcKind.branch => 'branch',
      _L5xSfcKind.leg => 'leg',
      null => 'unknown element',
    };

/// §3's shape validation for one branch, run only on EMITTED connectors and
/// only when the emission table found no defect, so one defect can never be
/// reported twice. Asserts the neighbour kinds `translateSfcBody`'s
/// `upstreamSteps`/`downstreamSteps` require:
///
///   selDiv  <- exactly one step;  -> transitions
///   selConv <- transitions;       -> exactly one step
///   simDiv  <- exactly one transition; -> steps
///   simConv <- steps;             -> exactly one transition
///
/// Why validate here rather than letting `translateSfcBody` catch it: the
/// translator's gates are reached ONLY from a transition's pred/succ walk, so
/// a malformed connector that is on no transition's walk would be IGNORED and
/// the steps behind it would become unreachable islands that vanish without a
/// word. The translator's own gates remain as a backstop.
///
/// The four inlet/outlet KIND checks are DEFENCE IN DEPTH: §3's unified
/// classifier derives the trunk role FROM the neighbour's kind, so `divIn` and
/// `convOut` can only ever hold correctly-kinded nodes today. They are kept
/// against a future classifier change and asserted absent by test.
void _l5xSfcValidateShape(_L5xSfcBranch br, Map<int, _L5xSfcKind> kindById,
    void Function(_L5xSfcBranch, String) defect) {
  final side = br.isSelection ? 'selection' : 'simultaneous';
  // Selection diverges into TRANSITIONS and converges out to a STEP;
  // simultaneous is the mirror. That asymmetry is the single fact synthesis
  // must get right.
  final trunkKind =
      br.isSelection ? _L5xSfcKind.step : _L5xSfcKind.transition;
  final legKind =
      br.isSelection ? _L5xSfcKind.transition : _L5xSfcKind.step;

  if (br.emitDiv) {
    if (br.divIn.length != 1) {
      defect(br, '$side divergence has ${br.divIn.length} inlets, expected 1');
      return;
    }
    final inletKind = kindById[br.divIn.single];
    if (inletKind != trunkKind) {
      defect(
          br,
          '$side divergence inlet is a ${_l5xSfcKindName(inletKind)}, '
          'expected ${_l5xSfcKindName(trunkKind)}');
      return;
    }
    for (final n in br.divOut) {
      final k = kindById[n];
      if (k != legKind) {
        defect(
            br,
            '$side leg head is a ${_l5xSfcKindName(k)}, '
            'expected ${_l5xSfcKindName(legKind)}');
        return;
      }
    }
  }
  if (br.emitConv) {
    for (final n in br.convIn) {
      final k = kindById[n];
      if (k != legKind) {
        defect(
            br,
            '$side leg tail is a ${_l5xSfcKindName(k)}, '
            'expected ${_l5xSfcKindName(legKind)}');
        return;
      }
    }
    if (br.convOut.length != 1) {
      defect(br, '$side convergence has ${br.convOut.length} outlets, expected 1');
      return;
    }
    final outletKind = kindById[br.convOut.single];
    if (outletKind != trunkKind) {
      defect(
          br,
          '$side convergence outlet is a ${_l5xSfcKindName(outletKind)}, '
          'expected ${_l5xSfcKindName(trunkKind)}');
      return;
    }
  }
}

/// Parses one `<Routine Type="SFC">`'s `<SFCContent>` into the neutral
/// [SfcBody] the shared `translateSfcBody` consumes — the SFC analog of
/// [_l5xFbdBody]. [ownerLabel] is the human label used in warnings, e.g.
/// `'Routine "Main_Seq"'`.
///
/// Pure, deterministic, NEVER THROWS: every attribute read is null-tolerant,
/// document order (of elements, then of the `<DirectedLink>` list) is the sole
/// tiebreaker, and an absent/empty `<SFCContent>` yields an empty body.
///
/// Emits exactly the IR shapes `plcopen_parser.dart`'s `_sfcBody` emits, so
/// `translateSfcBody` and `ir_to_project`'s `body is SfcBody` arm need ZERO
/// changes. `refBodies`/`graphicalRefs` are always empty (Logix has no external
/// action/transition POUs) and `SfcNodeKind.jump` is never emitted (Logix
/// expresses a loop-back as an ordinary `<DirectedLink>` to an earlier
/// element, not as a distinct jump element).
///
/// MULTI-CONTAINER: every `<SFCContent>` of the routine merges into ONE body,
/// in document order, with NO id or y offsetting — an SFC routine is a single
/// chart with routine-unique `ID`s, and offsetting would break the absolute
/// `<DirectedLink>` ids. A duplicate `ID` across containers is therefore a
/// defect handled by the ID gate, not papered over.
///
/// NEVER SILENT: any element this builder cannot map, any structurally broken
/// branch, any dangling link and any ID collision sets the routine-level
/// `unrepresentable` flag, which appends a POISON NODE (a step carrying a
/// self-edge) in pass 4. `translateSfcBody`'s step->step edge scan is
/// unconditional over `body.edges` and precedes every warning it emits, so a
/// poisoned body always stubs `complex-topology` with EXACTLY ONE warning —
/// the same two-message shape the PLCopen SFC path produces for any stub. See
/// `docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md` §4.
SfcBody _l5xSfcBody(
    XmlElement routine, List<ImportWarning> warnings, String ownerLabel) {
  final nodes = <SfcNode>[];
  final edges = <SfcEdge>[];
  final actions = <SfcActionAssoc>[];
  // The ONE routine-wide synthetic-id counter: malformed/duplicate ids, the
  // branch connectors and the poison node all draw from it, so no two
  // synthetic ids can collide. The gate's `parsed < 0` rejection below is what
  // stops a RAW id from colliding with them.
  var malformedId = -1;
  var unrepresentable = false;
  final ignoredKinds = <String>[];
  var ignoredCount = 0;
  // Assigned localIds of dropped <TextBox>/<Attachment>. Logix anchors an
  // annotation to the element it comments on; that anchor is a documentation
  // relationship, not control flow, so a link touching one is discarded
  // WITHOUT poisoning.
  //
  // Keyed by the ACCEPTED localId, never by the raw attribute: an annotation
  // is the one non-node kind whose id IS dereferenced, so it runs the same ID
  // gate as everything else (see pass 1).
  final annotationIds = <int>{};
  // Raw `ID` -> assigned localId. Only ACCEPTED ids are registered: a rejected
  // one must never resolve, or a link naming it would silently retarget onto
  // the element that was demoted.
  final assignedByRawId = <int, int>{};
  // Assigned localId -> kind, read by the link classifier.
  final kindById = <int, _L5xSfcKind>{};
  // Branch bookkeeping. `branches` is document order — the order every branch
  // warning and every connector node/edge is emitted in.
  final branches = <_L5xSfcBranch>[];
  final branchByLocalId = <int, _L5xSfcBranch>{};
  final legToBranch = <int, _L5xSfcBranch>{};
  // localIds belonging to a branch (or leg) whose `BranchType` was not
  // recognized. A link touching one is discarded whole: that branch already
  // emitted the one actionable breadcrumb, and N `dangling link` messages
  // would bury it.
  final unrecognizedIds = <int>{};
  // At most ONE `branch shape not representable` cause per branch. Precedence:
  // connector-adjacent (pass 2a) > emission-table cause > shape-validation
  // cause; first recorded wins. Emission happens in pass 3, in branch document
  // order, so message order is deterministic.
  final branchDefect = <_L5xSfcBranch, String>{};
  void defect(_L5xSfcBranch br, String cause) {
    branchDefect.putIfAbsent(br, () => cause);
    unrepresentable = true;
  }

  /// The ID gate: absent / unparseable / negative / out-of-range / duplicate
  /// all get a unique synthetic negative id, an info breadcrumb and the poison
  /// flag. Duplicate severity stays `info` (unlike the FBD builder's
  /// `warning`) because here the stub is whole-POU and the loud message
  /// already exists twice — translator + mapper.
  int gateId(XmlElement el) {
    final raw = el.getAttribute('ID');
    final parsed = int.tryParse(raw ?? '');
    final duplicate =
        parsed != null && parsed >= 0 && assignedByRawId.containsKey(parsed);
    if (parsed == null ||
        parsed < 0 ||
        parsed > _kMaxL5xElementId ||
        duplicate) {
      unrepresentable = true;
      warnings.add(ImportWarning(
          severity: WarningSeverity.info,
          message: duplicate
              ? '$ownerLabel: <${el.name.local}> reuses a duplicate ID '
                  '($parsed) — it was given a synthetic id and the chart is '
                  'not translated.'
              : '$ownerLabel: <${el.name.local}> has a malformed ID '
                  '(${raw == null ? 'absent' : '"$raw"'}) — the chart is not '
                  'translated.'));
      return malformedId--;
    }
    assignedByRawId[parsed] = parsed; // no offsetting: localId IS the raw id
    return parsed;
  }

  // ---- Pass 1 — register elements, in document order.
  for (final content in _children(routine, 'SFCContent')) {
    for (final el in content.childElements) {
      final tag = el.name.local;
      if (tag == 'DirectedLink') {
        continue; // pass 2a
      }
      if (_kL5xAnnotationElements.contains(tag)) {
        ignoredCount++;
        if (!ignoredKinds.contains(tag)) ignoredKinds.add(tag);
        // An annotation is not a node, but its id IS dereferenced (pass 2a
        // discards a link anchored to one), so an annotation that CARRIES an
        // `ID` MUST run the same ID gate as every other ID-bearing element.
        // Ungated, a <TextBox> reusing a real element's `ID` would claim that
        // id in `annotationIds` without a duplicate-ID warning and without
        // poisoning, and pass 2a would then silently discard every link naming
        // the REAL element — a chart that translates cleanly as the wrong
        // logic, the exact CL-19 shape. Gated, the collision is an ordinary
        // duplicate in either document order.
        //
        // An annotation with NO `ID` attribute is skipped entirely: it can
        // never be named by a <DirectedLink>, so it can never swallow a link,
        // and poisoning a whole chart over a cosmetic element that cannot
        // change the logic would be a false positive.
        if (el.getAttribute('ID') != null) annotationIds.add(gateId(el));
        continue;
      }
      final localId = gateId(el);
      final x = double.tryParse(el.getAttribute('X') ?? '') ?? 0;
      final y = double.tryParse(el.getAttribute('Y') ?? '') ?? 0;
      final name =
          (el.getAttribute('Operand') ?? el.getAttribute('Name') ?? '').trim();
      switch (tag) {
        case 'Step':
          {
            nodes.add(SfcNode(
              localId: localId,
              kind: SfcNodeKind.step,
              name: name,
              initial: el.getAttribute('InitialStep') == 'true',
              x: x,
              y: y,
            ));
            kindById[localId] = _L5xSfcKind.step;
            // Actions come from XML NESTING, not from a link (contrast
            // PLCopen's <actionBlock> + connectionPointIn), so stepLocalId is
            // always a real step id here.
            final actionEls = _children(el, 'Action').toList();
            if (actionEls.isEmpty) {
              final inline = _l5xSfcSt(el, 'Body');
              if (inline.isNotEmpty) {
                actions.add(SfcActionAssoc(
                    stepLocalId: localId,
                    qualifier: 'N',
                    source: SfcActInline(inline)));
              }
            } else {
              for (final a in actionEls) {
                final q = (a.getAttribute('Qualifier') ?? '').trim();
                actions.add(SfcActionAssoc(
                  stepLocalId: localId,
                  qualifier: q.isEmpty ? 'N' : q,
                  source: SfcActInline(_l5xSfcSt(a, 'Body')),
                ));
              }
            }
            break;
          }
        case 'Transition':
          {
            var cond = _l5xSfcSt(el, 'Condition');
            // `conditionSt` is evaluated as a boolean EXPRESSION by sfc_exec,
            // so a single trailing statement terminator would fail to parse.
            if (cond.endsWith(';')) {
              cond = cond.substring(0, cond.length - 1).trimRight();
            }
            nodes.add(SfcNode(
              localId: localId,
              kind: SfcNodeKind.transition,
              name: name,
              x: x,
              y: y,
              condition: cond.isEmpty ? SfcCondNone() : SfcCondInline(cond),
            ));
            kindById[localId] = _L5xSfcKind.transition;
            break;
          }
        case 'Branch':
          {
            // No 1:1 IR node — a <Branch> is synthesized into a PAIR of
            // connector nodes in pass 3, wired from link topology.
            final rawId = el.getAttribute('ID') ?? '';
            final type = (el.getAttribute('BranchType') ?? '').trim();
            final divKind = switch (type) {
              'Selection' => SfcNodeKind.selDiv,
              'Simultaneous' => SfcNodeKind.simDiv,
              _ => null,
            };
            if (divKind == null) {
              unrepresentable = true;
              warnings.add(ImportWarning(
                  severity: WarningSeverity.info,
                  message: '$ownerLabel: <Branch ID="$rawId"> branch type '
                      '"$type" not recognized — the chart is not translated.'));
              // The branch AND its legs are registered as unrecognized (the
              // legs still run the ID gate, so duplicate detection stays
              // honest), which makes every incident link a silent discard
              // rather than N `dangling link` breadcrumbs burying the one
              // actionable cause.
              unrecognizedIds.add(localId);
              for (final leg in _children(el, 'Leg')) {
                unrecognizedIds.add(gateId(leg));
              }
              break; // no connectors synthesized
            }
            final convKind = divKind == SfcNodeKind.selDiv
                ? SfcNodeKind.selConv
                : SfcNodeKind.simConv;
            // Two ids from the ONE routine-wide counter, reserved in
            // document order.
            final divId = malformedId--;
            final convId = malformedId--;
            final br = _L5xSfcBranch(
              rawId: rawId,
              divId: divId,
              convId: convId,
              divKind: divKind,
              convKind: convKind,
              flow: el.getAttribute('BranchFlow')?.trim(),
            );
            branches.add(br);
            branchByLocalId[localId] = br;
            kindById[localId] = _L5xSfcKind.branch;
            // A <Leg>'s `ID` is a LINK ENDPOINT, not a node. The walk stops
            // here: a <Branch> nested as a child of a <Leg> is never
            // registered, so any link naming it dangles -> visible stub.
            for (final leg in _children(el, 'Leg')) {
              final legId = gateId(leg);
              legToBranch[legId] = br;
              kindById[legId] = _L5xSfcKind.leg;
            }
            break;
          }
        default:
          {
            // <Stop>, <SbrRet>, <JSR>, a top-level <Leg>, any future tag: no
            // representable equivalent. Deliberately NOT registered in
            // `kindById` and NOT emitted as a node, so nothing downstream can
            // mistake it for a mappable element — the poison flag is what
            // makes it visible.
            unrepresentable = true;
            warnings.add(ImportWarning(
                severity: WarningSeverity.info,
                message: '$ownerLabel: <$tag ID="${el.getAttribute('ID') ?? ''}"> '
                    'has no representable equivalent — the chart is not '
                    'translated.'));
            break;
          }
      }
    }
  }

  // ---- Pass 2a — collect and classify links, in document order.
  final pending = <SfcEdge>[];
  for (final content in _children(routine, 'SFCContent')) {
    for (final el in _children(content, 'DirectedLink')) {
      final fromAttr = el.getAttribute('FromID');
      final toAttr = el.getAttribute('ToID');
      final fromRaw = int.tryParse(fromAttr ?? '');
      final toRaw = int.tryParse(toAttr ?? '');
      final fromId = fromRaw == null ? null : assignedByRawId[fromRaw];
      final toId = toRaw == null ? null : assignedByRawId[toRaw];
      // (1) An annotation anchor is documentation, not control flow. Keyed off
      // the ACCEPTED id: an annotation whose raw `ID` was rejected (malformed,
      // out of range, or a duplicate) never registered in `assignedByRawId`,
      // so it can never swallow another element's links — it poisoned the
      // chart instead.
      if ((fromId != null && annotationIds.contains(fromId)) ||
          (toId != null && annotationIds.contains(toId))) {
        continue;
      }
      // (2) A link touching an unrecognized-BranchType branch (or its legs).
      // That branch already emitted the one actionable breadcrumb plus the
      // poison flag; N `dangling link` messages would bury it.
      if ((fromId != null && unrecognizedIds.contains(fromId)) ||
          (toId != null && unrecognizedIds.contains(toId))) {
        continue;
      }
      final fromKind = fromId == null ? null : kindById[fromId];
      final toKind = toId == null ? null : kindById[toId];
      // (3) An endpoint naming no MAPPABLE element. The edge is still emitted
      // against a fresh synthetic id: dropping it would silently delete a
      // control path. A resolvable connector side uses the DIRECTION fallback
      // purely so the edge has an endpoint — the body is already poisoned, so
      // no reading of that edge can matter.
      if (fromKind == null || toKind == null) {
        unrepresentable = true;
        warnings.add(ImportWarning(
            severity: WarningSeverity.info,
            message: '$ownerLabel: <DirectedLink FromID="${fromAttr ?? ''}" '
                'ToID="${toAttr ?? ''}"> is a dangling link (endpoint names no '
                'element) — the chart is not translated.'));
        int side(int? id, _L5xSfcKind? kind, bool isFrom) {
          if (kind == null) return malformedId--;
          if (kind == _L5xSfcKind.leg) {
            final b = legToBranch[id]!;
            return isFrom ? b.divId : b.convId;
          }
          if (kind == _L5xSfcKind.branch) {
            final b = branchByLocalId[id]!;
            return isFrom ? b.divId : b.convId;
          }
          return id!;
        }

        pending.add(SfcEdge(
            fromLocalId: side(fromId, fromKind, true),
            toLocalId: side(toId, toKind, false)));
        continue;
      }
      final fromConn =
          fromKind == _L5xSfcKind.branch || fromKind == _L5xSfcKind.leg;
      final toConn = toKind == _L5xSfcKind.branch || toKind == _L5xSfcKind.leg;
      // (4) CONNECTOR-ADJACENT: a leg head or tail that is ITSELF a branch,
      // giving a div->div / conv->conv / div->conv edge with no step or
      // transition between. upstream/downstreamSteps see through only ONE
      // connector, so a connector chain has no representable resolution. No
      // edge is emitted (there is no non-arbitrary connector id to attach it
      // to); the cause clause is the loud, named record of the link.
      if (fromConn && toConn) {
        final br = fromKind == _L5xSfcKind.leg
            ? legToBranch[fromId]!
            : branchByLocalId[fromId]!;
        defect(br, 'branch is directly adjacent to another branch');
        continue;
      }
      // (5) Exactly one connector endpoint: §3's unified endpoint classifier.
      // There is deliberately NO mode switch and no mixed-convention rule — in
      // the paired encoding a branch's TRUNK links must name the <Branch> id
      // while its LEG links name <Leg> ids, so every paired branch mixes both
      // forms by construction.
      if (fromConn || toConn) {
        final connKind = fromConn ? fromKind : toKind;
        final connId = fromConn ? fromId! : toId!;
        final otherKind = fromConn ? toKind : fromKind;
        final otherId = fromConn ? toId! : fromId!;
        final br = connKind == _L5xSfcKind.leg
            ? legToBranch[connId]!
            : branchByLocalId[connId]!;
        if (connKind == _L5xSfcKind.leg) {
          // LEG endpoints resolve BY DIRECTION. Unambiguous: a leg id can only
          // ever mean "the branch-side end of this leg", and which end is
          // fixed by the arrow.
          if (fromConn) {
            br.divOut.add(otherId);
          } else {
            br.convIn.add(otherId);
          }
        } else {
          // BRANCH endpoints resolve BY THE OTHER ENDPOINT'S KIND. The naive
          // direction rule agrees on every trunk link but is strictly worse on
          // a leg-role link expressed through the branch id: it would read
          // `FromID == B -> T1` as a convergence outlet and wire conv -> T1, a
          // silently wrong chart that still passes every shape check.
          final legKind = br.isSelection
              ? _L5xSfcKind.transition // selection legs open/close on transitions
              : _L5xSfcKind.step; // simultaneous legs open/close on steps
          final isLegRole = otherKind == legKind;
          if (fromConn) {
            (isLegRole ? br.divOut : br.convOut).add(otherId);
          } else {
            (isLegRole ? br.convIn : br.divIn).add(otherId);
          }
        }
        continue;
      }
      // (6) An ordinary edge.
      pending.add(SfcEdge(fromLocalId: fromId!, toLocalId: toId!));
    }
  }

  // ---- Pass 3 — synthesize branch connectors (§3), in branch document order.
  // Connector nodes and their edges are appended BEFORE the ordinary edges, so
  // a single ordered edge list falls out.
  for (final br in branches) {
    final emitDiv = br.emitDiv;
    final emitConv = br.emitConv;
    // The 4-bit emission decision table, in full. Every one of the 16
    // combinations is covered: a side with exactly one bit set is a defect, a
    // branch no link touches is a defect, and where two causes could apply the
    // DIVERGENCE-side cause wins (deterministic, and it is the upstream defect
    // — the one a user fixes first).
    if (!emitDiv && !emitConv) {
      defect(br, 'branch has no links');
    } else if (emitDiv && (br.divIn.isEmpty || br.divOut.isEmpty)) {
      defect(
          br,
          br.divIn.isNotEmpty
              ? 'divergence has no legs'
              : 'divergence has no inlet');
    } else if (emitConv && (br.convIn.isEmpty || br.convOut.isEmpty)) {
      defect(
          br,
          br.convIn.isNotEmpty
              ? 'convergence has no outlet'
              : 'convergence has no inlet');
    }
    if (!branchDefect.containsKey(br)) {
      _l5xSfcValidateShape(br, kindById, defect);
    }
    // BranchFlow contradicting the derived topology is a breadcrumb, not a
    // defect: the links are what the chart actually says.
    if ((br.flow == 'Diverge' && emitConv) ||
        (br.flow == 'Converge' && emitDiv)) {
      warnings.add(ImportWarning(
          severity: WarningSeverity.info,
          message: '$ownerLabel: <Branch ID="${br.rawId}"> branch flow '
              'mismatch: BranchFlow="${br.flow}" but the links describe '
              '${emitDiv && emitConv ? 'both a divergence and a convergence' : emitDiv ? 'a divergence' : 'a convergence'}'
              ' — the links win.'));
    }
    if (emitDiv) {
      nodes.add(SfcNode(localId: br.divId, kind: br.divKind));
    }
    if (emitConv) {
      nodes.add(SfcNode(localId: br.convId, kind: br.convKind));
    }
    if (emitDiv) {
      for (final n in br.divIn) {
        edges.add(SfcEdge(fromLocalId: n, toLocalId: br.divId));
      }
      for (final n in br.divOut) {
        edges.add(SfcEdge(fromLocalId: br.divId, toLocalId: n));
      }
    }
    if (emitConv) {
      for (final n in br.convIn) {
        edges.add(SfcEdge(fromLocalId: n, toLocalId: br.convId));
      }
      for (final n in br.convOut) {
        edges.add(SfcEdge(fromLocalId: br.convId, toLocalId: n));
      }
    }
    final cause = branchDefect[br];
    if (cause != null) {
      warnings.add(ImportWarning(
          severity: WarningSeverity.info,
          message: '$ownerLabel: <Branch ID="${br.rawId}"> branch shape not '
              'representable ($cause) — the chart is not translated.'));
    }
  }

  // ---- Pass 2b — the remaining edges, in their original document order.
  // (Pass 3 above appended the connector nodes and their edges BEFORE this,
  // so connector edges lead the list. Nothing in translateSfcBody depends on
  // edge order; this is determinism and presentation, not semantics.)
  edges.addAll(pending);

  // ---- Pass 4 — finalize.
  if (ignoredCount > 0) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: '$ownerLabel: $ignoredCount element(s) ignored '
            '(${ignoredKinds.join(', ')}).'));
  }
  if (unrepresentable) {
    // The poison node. `_build`'s step->step edge scan is unconditional over
    // `body.edges` and runs before the succ/pred maps, before actions are
    // grouped, and before any warning-emitting statement, so this ALWAYS
    // throws `_SfcStub('complex-topology', 'step directly wired to step
    // (missing transition)')` — position-independent, edge-order-independent,
    // deterministic, and with no stray translator infos.
    final pid = malformedId--;
    nodes.add(SfcNode(
        localId: pid, kind: SfcNodeKind.step, name: '#unrepresentable'));
    edges.add(SfcEdge(fromLocalId: pid, toLocalId: pid));
  }
  return SfcBody(
      nodes: nodes,
      edges: edges,
      actions: actions,
      refBodies: const {},
      graphicalRefs: const {});
}

VarScope _usageScope(String? usage) => switch (usage) {
      'Input' => VarScope.input,
      'Output' => VarScope.output,
      'InOut' => VarScope.inOut,
      _ => VarScope.local,
    };

/// Maps `<AddOnInstructionDefinition>`s to functionBlock POUs. `mapImportedFbs`
/// turns these into FbDefinitions (AOI-typed tags then resolve): ST logic
/// becomes the FB's ST source, RLL logic a `NeutralLadderBody` compiled to a
/// ladder body, FBD logic a `GraphBody` translated to an FBD body. SFC logic
/// is still interface-only.
List<ImportedPou> _l5xAois(XmlElement? controller, List<ImportWarning> warnings) {
  final out = <ImportedPou>[];
  if (controller == null) return out;
  for (final defs in _children(controller, 'AddOnInstructionDefinitions')) {
    for (final aoi in _children(defs, 'AddOnInstructionDefinition')) {
      final name = aoi.getAttribute('Name') ?? '';
      if (name.isEmpty) continue;
      // Logic routine: named "Logic" else the first routine. Resolved BEFORE
      // the parameter loop because RLL- and FBD-logic AOIs keep
      // EnableIn/EnableOut; ST/SFC keep the historic skip.
      XmlElement? logic;
      for (final rs in _children(aoi, 'Routines')) {
        for (final r in _children(rs, 'Routine')) {
          logic ??= r;
          if (r.getAttribute('Name') == 'Logic') logic = r;
        }
      }
      final logicType = logic?.getAttribute('Type');
      final isRll = logicType == 'RLL';
      final isFbd = logicType == 'FBD';
      // Rockwell re-evaluates EnableIn on every call, and both graphical
      // logic languages routinely reference EnableIn/EnableOut, so both keep
      // them as internal vars. ST/SFC-logic AOIs keep the historic skip.
      final keepsEnableParams = isRll || isFbd;

      final vars = <ImportedVar>[];
      for (final params in _children(aoi, 'Parameters')) {
        for (final p in _children(params, 'Parameter')) {
          final pn = p.getAttribute('Name') ?? '';
          if (pn.isEmpty) continue;
          if (pn == 'EnableIn' || pn == 'EnableOut') {
            if (!keepsEnableParams) continue; // ST/SFC AOIs: historic skip
            // Both graphical logic languages reference these routinely: RLL
            // does XIC(EnableIn)/OTE(EnableOut), FBD wires them as sheet pins.
            // Retained as INTERNAL vars so those references resolve per
            // instance via the scoped executor instead of falling through to
            // absent globals. The body only runs when the call executes, so
            // EnableIn = true during execution is the faithful mapping.
            // ST/SFC-logic AOIs keep the historic skip (see
            // `keepsEnableParams`).
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
        } else if (isFbd) {
          // Same sheet parse _l5xRoutines uses; the mapper compiles it via
          // translateFbdBody into the FB's native FBD body.
          body = _l5xFbdBody(logic, warnings, 'AOI "$name"');
          lang = PouLanguage.fbd;
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
/// `ir_to_project`); SFC parses its structured `<SFCContent>` into an
/// `SfcBody` (translated whole-POU by `ir_to_project`).
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
              // <SFCContent> parses into a real SfcBody; ir_to_project's
              // existing `body is SfcBody` arm translates it whole-POU
              // (faithful-or-stub) via the shared translateSfcBody. A chart
              // that does not translate keeps that arm's stub — no
              // parser-level warning, so the message count matches the
              // PLCopen SFC path exactly.
              out.add(ImportedPou(name: name, kind: PouKind.program,
                  lang: PouLanguage.sfc, localVars: const [],
                  body: _l5xSfcBody(r, warnings, 'Routine "$name"')));
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
