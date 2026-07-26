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

  final types = <ImportedType>[];
  final pous = <ImportedPou>[];
  final globalVars = <ImportedVar>[];

  // Tasks 2–5 fill types/pous/globalVars from `controller`.

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
// ignore: unused_element
Iterable<XmlElement> _children(XmlElement e, String local) => e.findElements(local);
