/// Vendor-neutral intermediate representation for program import. Every
/// vendor parser (PLCopen now; L5X/Siemens later) emits this shape; every
/// language mapper consumes it. Pure data — no Flutter, no interpretation of
/// graphical bodies (a GraphBody is captured losslessly for later
/// per-language translators). See the design spec.
library import_ir;

enum VarScope { global, input, output, inOut, local, temp, external }
enum PouKind { program, functionBlock, function }
enum PouLanguage { st, il, ld, fbd, sfc }
enum WarningSeverity { info, warning }
enum ImportDialect { plcOpen }

class ImportWarning {
  final WarningSeverity severity;
  final String message;
  ImportWarning({required this.severity, required this.message});
}

class ImportedField {
  final String name;
  final String baseType;
  final int arrayLength;
  final dynamic initialValue;
  ImportedField({required this.name, required this.baseType,
      this.arrayLength = 0, this.initialValue});
}

class ImportedType {
  final String name;
  final List<ImportedField> fields;
  ImportedType({required this.name, required this.fields});
}

class ImportedVar {
  final String name;
  final String baseType;
  final int arrayLength;
  final dynamic initialValue;
  final VarScope scope;
  final bool retain;
  ImportedVar({required this.name, required this.baseType,
      this.arrayLength = 0, this.initialValue, required this.scope,
      this.retain = false});
}

sealed class PouBody {}

class TextBody extends PouBody {
  final String source;
  TextBody(this.source);
}

class IrGraphNode {
  final int localId;
  final String elementType;
  final double x;
  final double y;
  final Map<String, String> attributes;
  IrGraphNode({required this.localId, required this.elementType,
      this.x = 0, this.y = 0, Map<String, String>? attributes})
      : attributes = attributes ?? const {};
}

class IrConnection {
  final int toLocalId;
  final int toPort;
  final int fromLocalId;
  final int fromPort;
  IrConnection({required this.toLocalId, this.toPort = 0,
      required this.fromLocalId, this.fromPort = 0});
}

class GraphBody extends PouBody {
  final List<IrGraphNode> nodes;
  final List<IrConnection> connections;
  GraphBody({required this.nodes, required this.connections});
}

class ImportedPou {
  final String name;
  final PouKind kind;
  final PouLanguage lang;
  final List<ImportedVar> localVars;
  final PouBody body;
  ImportedPou({required this.name, required this.kind, required this.lang,
      required this.localVars, required this.body});
}

class ImportedProject {
  final String name;
  final List<ImportedType> types;
  final List<ImportedVar> globalVars;
  final List<ImportedPou> pous;
  final List<ImportWarning> warnings;
  ImportedProject({required this.name, required this.types,
      required this.globalVars, required this.pous, required this.warnings});
}
