import 'package:xml/xml.dart';

import 'import_ir.dart';

/// Parses a PLCopen TC6 XML document into the vendor-neutral IR. Throws
/// [FormatException] (with a clear message) ONLY when [xml] is not
/// well-formed or its root is not a PLCopen `<project>`. Valid-but-unexpected
/// content becomes an [ImportWarning] on the returned project — never a throw.
/// The `xml` package is confined to this file.
ImportedProject parsePlcOpen(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException catch (e) {
    throw FormatException('Not well-formed XML: ${e.message}');
  }
  final root = doc.rootElement;
  if (root.name.local != 'project') {
    throw FormatException(
        'Not a PLCopen document: root element is <${root.name.local}>, expected <project>.');
  }
  final warnings = <ImportWarning>[];

  final projectName =
      _findElement(root, 'contentHeader')?.getAttribute('name') ??
          'Imported Project';

  // DUTs first (so var/field type normalization can recognize them).
  final types = <ImportedType>[];
  for (final dt in _descendants(root, 'dataType')) {
    final name = dt.getAttribute('name') ?? '';
    final struct = _findElement(dt, 'struct');
    final fields = <ImportedField>[];
    if (struct != null) {
      for (final v in struct.childElements
          .where((e) => e.name.local == 'variable')) {
        fields.add(_field(v));
      }
    }
    types.add(ImportedType(name: name, fields: fields));
  }
  final dutNames = types.map((t) => t.name).toSet();

  // Global vars (resource/config globalVars).
  final globals = <ImportedVar>[];
  for (final gv in _descendants(root, 'globalVars')) {
    for (final v
        in gv.childElements.where((e) => e.name.local == 'variable')) {
      globals.add(_var(v, VarScope.global, dutNames));
    }
  }

  // POUs.
  final pous = <ImportedPou>[];
  for (final p in _descendants(root, 'pou')) {
    pous.add(_pou(p, dutNames, warnings));
  }

  return ImportedProject(
      name: projectName,
      types: types,
      globalVars: globals,
      pous: pous,
      warnings: warnings);
}

ImportedField _field(XmlElement v) {
  final typeEl = _findElement(v, 'type');
  final baseName = _baseTypeName(typeEl);
  return ImportedField(
    name: v.getAttribute('name') ?? '',
    baseType: baseName,
    arrayLength: _arrayLen(typeEl),
    initialValue: _initialText(v),
  );
}

ImportedVar _var(XmlElement v, VarScope scope, Set<String> dutNames) {
  final typeEl = _findElement(v, 'type');
  return ImportedVar(
    name: v.getAttribute('name') ?? '',
    baseType: _baseTypeName(typeEl),
    arrayLength: _arrayLen(typeEl),
    initialValue: _initialText(v),
    scope: scope,
    retain: (v.getAttribute('retain') ?? 'false').toLowerCase() == 'true',
  );
}

ImportedPou _pou(
    XmlElement p, Set<String> dutNames, List<ImportWarning> warnings) {
  final name = p.getAttribute('name') ?? '';
  final kind = switch (p.getAttribute('pouType') ?? 'program') {
    'functionBlock' => PouKind.functionBlock,
    'function' => PouKind.function,
    _ => PouKind.program,
  };
  final locals = <ImportedVar>[];
  final iface = _findElement(p, 'interface');
  if (iface != null) {
    for (final section in iface.childElements) {
      final scope = switch (section.name.local) {
        'inputVars' => VarScope.input,
        'outputVars' => VarScope.output,
        'inOutVars' => VarScope.inOut,
        'tempVars' => VarScope.temp,
        'externalVars' => VarScope.external,
        _ => VarScope.local,
      };
      for (final v
          in section.childElements.where((e) => e.name.local == 'variable')) {
        locals.add(_var(v, scope, dutNames));
      }
    }
  }
  final body = _findElement(p, 'body');
  XmlElement? langEl;
  if (body != null) {
    for (final e in body.childElements) {
      if (const {'ST', 'IL', 'LD', 'FBD', 'SFC'}.contains(e.name.local)) {
        langEl = e;
        break;
      }
    }
  }
  final lang = switch (langEl?.name.local) {
    'IL' => PouLanguage.il,
    'LD' => PouLanguage.ld,
    'FBD' => PouLanguage.fbd,
    'SFC' => PouLanguage.sfc,
    'ST' => PouLanguage.st,
    _ => null,
  };
  final PouBody pouBody;
  final PouLanguage resolvedLang;
  if (lang == null) {
    // No recognized body language element: default to ST with empty source
    // and record an info warning rather than throwing.
    resolvedLang = PouLanguage.st;
    pouBody = TextBody('');
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: 'POU "$name": no recognizable body language element found.'));
  } else if (lang == PouLanguage.st || lang == PouLanguage.il) {
    resolvedLang = lang;
    pouBody = TextBody((langEl?.innerText ?? '').trim());
  } else {
    resolvedLang = lang;
    pouBody = _graphBody(langEl, warnings, name);
  }
  return ImportedPou(
      name: name,
      kind: kind,
      lang: resolvedLang,
      localVars: locals,
      body: pouBody);
}

GraphBody _graphBody(
    XmlElement? langEl, List<ImportWarning> warnings, String pouName) {
  final nodes = <IrGraphNode>[];
  final conns = <IrConnection>[];
  if (langEl == null) {
    return GraphBody(nodes: nodes, connections: conns);
  }
  for (final el in langEl.childElements) {
    final localIdStr = el.getAttribute('localId');
    if (localIdStr == null) {
      continue; // non-element children without a localId aren't graph nodes
    }
    final localId = int.tryParse(localIdStr) ?? -1;
    final pos = _findElement(el, 'position');
    final attrs = <String, String>{};
    for (final a in el.attributes) {
      attrs[a.name.local] = a.value;
    }
    final varEl = _findElement(el, 'variable');
    if (varEl != null) {
      attrs['variable'] = varEl.innerText.trim();
    }
    nodes.add(IrGraphNode(
      localId: localId,
      elementType: el.name.local,
      x: double.tryParse(pos?.getAttribute('x') ?? '') ?? 0,
      y: double.tryParse(pos?.getAttribute('y') ?? '') ?? 0,
      attributes: attrs,
    ));
    // Each <connectionPointIn><connection refLocalId=…/> is an edge into this
    // node. connectionPointIn is a direct child for simple elements like
    // <contact>/<coil>, but for a <block> (function-block call) it nests two
    // levels deeper under <inputVariables><variable>. Search descendants
    // (which also covers the direct-child case) so no connection is silently
    // dropped, mirroring the descendant-based `_findElement` helper.
    for (final cpi in _descendants(el, 'connectionPointIn')) {
      for (final c in cpi.findElements('connection')) {
        final from = int.tryParse(c.getAttribute('refLocalId') ?? '') ?? -1;
        conns.add(IrConnection(
            toLocalId: localId, toPort: 0, fromLocalId: from, fromPort: 0));
      }
    }
  }
  if (nodes.isEmpty) {
    warnings.add(ImportWarning(
        severity: WarningSeverity.info,
        message: 'POU "$pouName": graphical body had no recognizable elements.'));
  }
  return GraphBody(nodes: nodes, connections: conns);
}

// --- small helpers ---

XmlElement? _findElement(XmlElement e, String local) {
  for (final d in e.descendantElements) {
    if (d.name.local == local) {
      return d;
    }
  }
  return null;
}

Iterable<XmlElement> _descendants(XmlElement e, String local) =>
    e.descendantElements.where((d) => d.name.local == local);

/// Returns the raw base-type name straight from the XML: an elementary IEC
/// type gives its element name (`BOOL`, `INT`, …); a `<derived name="X"/>`
/// gives the DUT name `X`. Normalization to the app's type set happens later
/// (Task 4 mapper) via `normalizeType`.
String _baseTypeName(XmlElement? typeEl) {
  if (typeEl == null) {
    return 'INT';
  }
  final derived = _findElement(typeEl, 'derived');
  if (derived != null) {
    return derived.getAttribute('name') ?? 'INT';
  }
  // <array><baseType>...</baseType></array> — the element base type lives
  // inside <baseType>, not directly under <array>.
  final arrEl = _findElement(typeEl, 'array');
  final arrBaseType = arrEl != null ? _findElement(arrEl, 'baseType') : null;
  final scope = arrBaseType ?? typeEl;
  for (final c in scope.childElements) {
    // Note: a <derived> here would already have been returned above by the
    // descendant-based check at the top of this function.
    return c.name.local; // e.g. BOOL/INT/REAL/...
  }
  return 'INT';
}

int _arrayLen(XmlElement? typeEl) {
  if (typeEl == null) {
    return 0;
  }
  final dim = _findElement(typeEl, 'dimension');
  if (dim == null) {
    return 0;
  }
  final lo = int.tryParse(dim.getAttribute('lower') ?? '0') ?? 0;
  final hi = int.tryParse(dim.getAttribute('upper') ?? '0') ?? 0;
  final n = hi - lo + 1;
  return n > 0 ? n : 0;
}

String? _initialText(XmlElement v) {
  final iv = _findElement(v, 'initialValue');
  if (iv == null) {
    return null;
  }
  final sv = _findElement(iv, 'simpleValue');
  return sv?.getAttribute('value');
}
