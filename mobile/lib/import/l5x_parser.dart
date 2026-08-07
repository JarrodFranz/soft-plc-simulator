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
GraphBody _l5xFbdBody(
    XmlElement routine, List<ImportWarning> warnings, String ownerLabel) {
  final nodes = <IrGraphNode>[];
  final conns = <IrConnection>[];
  // ROUTINE-WIDE (not per-sheet) synthetic-id counter: a malformed-id element
  // on sheet 1 and one on sheet 2 must still get distinct ids.
  var malformedId = -1;
  final ignoredKinds = <String>[];
  var ignoredCount = 0;

  for (final content in _children(routine, 'FBDContent')) {
    for (final sheet in _children(content, 'Sheet')) {
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
        final localId = (parsed == null || parsed < 0 || parsed > _kMaxL5xFbdId)
            ? malformedId--
            : parsed;
        if (parsed != null && parsed >= 0) {
          assignedByRawId[parsed] = localId;
        }
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
            {
              elementType = 'block';
              attrs['typeName'] = (el.getAttribute('Type') ?? '').trim();
              final operand = (el.getAttribute('Operand') ?? '').trim();
              if (operand.isNotEmpty) attrs['instanceName'] = operand;
              break;
            }
          case 'Function':
            {
              elementType = 'block';
              attrs['typeName'] = (el.getAttribute('Type') ?? '').trim();
              break;
            }
          case 'AddOnInstruction':
            {
              // An AOI's `Name` is a user type name and is NEVER aliased.
              elementType = 'block';
              attrs['typeName'] = (el.getAttribute('Name') ?? '').trim();
              final operand = (el.getAttribute('Operand') ?? '').trim();
              if (operand.isNotEmpty) attrs['instanceName'] = operand;
              break;
            }
          case 'ICon':
          case 'OCon':
            {
              elementType = tag;
              attrs['connectorName'] = (el.getAttribute('Name') ?? '').trim();
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
          y: double.tryParse(el.getAttribute('Y') ?? '') ?? 0,
          attributes: attrs,
        ));
      }

      // Resolves one wire endpoint to a real node id. An endpoint that names
      // no element on this sheet (absent, unparseable, negative, or an id no
      // element carries) gets a fresh `danglingWire` PLACEHOLDER node instead
      // of dropping the wire: dropping it would silently delete a data path
      // and let the consumer's component translate as though that input were
      // simply unwired. The placeholder's negative id + unknown elementType
      // make the consumer's component stub (`unsupported-element`).
      int resolveEndpoint(String? raw) {
        final parsed = int.tryParse(raw ?? '');
        final hit = parsed == null ? null : assignedByRawId[parsed];
        if (hit != null) {
          return hit;
        }
        final id = malformedId--;
        nodes.add(IrGraphNode(localId: id, elementType: 'danglingWire'));
        return id;
      }

      // Pass 2 — wires. `<FeedbackWire>` (a wire closing a feedback loop)
      // carries the identical attribute set as `<Wire>` and maps the same way;
      // the cyclic graph it creates is handled by the executor's existing
      // dataflow-cycle fallback.
      for (final el in sheet.childElements) {
        final tag = el.name.local;
        if (tag != 'Wire' && tag != 'FeedbackWire') {
          continue;
        }
        conns.add(IrConnection(
          fromLocalId: resolveEndpoint(el.getAttribute('FromID')),
          fromPin: el.getAttribute('FromParam'),
          toLocalId: resolveEndpoint(el.getAttribute('ToID')),
          toPin: el.getAttribute('ToParam'),
        ));
      }
    }
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
