import 'package:xml/xml.dart';

import 'import_ir.dart';

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
  final globalVars = <ImportedVar>[];

  // Tasks 3–5 fill pous/globalVars from `controller`.

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
            arrayLength: int.tryParse(m.getAttribute('Dimension') ?? '0') ?? 0,
            initialValue: _defaultDataScalar(m),
          ));
        }
      }
      out.add(ImportedType(name: tname, fields: fields));
    }
  }
  return out;
}
