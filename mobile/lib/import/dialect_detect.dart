import 'import_ir.dart';
export 'import_ir.dart' show ImportDialect;

/// Cheap sniff of the leading markup (no full parse) to recognize the vendor
/// dialect. PLCopen TC6 documents have a `<project>` root and a namespace
/// containing `plcopen` (e.g. http://www.plcopen.org/xml/tc6_0201). Returns
/// null for anything not yet recognized. Never throws.
ImportDialect? detectDialect(String xml) {
  final head = xml.length > 4096 ? xml.substring(0, 4096) : xml;
  final lower = head.toLowerCase();
  final rootIdx = lower.indexOf('<project');
  if (rootIdx < 0) {
    return null;
  }
  // A real root, and its markup mentions the PLCopen namespace.
  if (lower.contains('plcopen') || lower.contains('tc6')) {
    return ImportDialect.plcOpen;
  }
  return null;
}
