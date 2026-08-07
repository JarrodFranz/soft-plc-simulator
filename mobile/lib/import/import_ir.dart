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
enum ImportDialect { plcOpen, l5x }

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

/// A directed edge in a graphical (LD/FBD/SFC) body: the producer element
/// [fromLocalId] feeds the consumer element [toLocalId].
///
/// [toPin]/[fromPin] carry the PLCopen `formalParameter` pin names so that a
/// multi-input block is unambiguous (e.g. which wire feeds `IN1` vs `IN2`):
///  * [toPin] — the destination input pin, from the `formalParameter` of the
///    `<inputVariables><variable>` wrapping the `<connectionPointIn>`. Null for
///    contact/coil elements, whose single input pin is implicit.
///  * [fromPin] — the source output pin, from the optional `formalParameter` on
///    the `<connection>` element (names the producer block's VAR_OUTPUT). Null
///    when the source pin is implicit/unspecified (e.g. a contact output).
class IrConnection {
  final int toLocalId;
  final String? toPin;
  final int fromLocalId;
  final String? fromPin;
  IrConnection(
      {required this.toLocalId,
      this.toPin,
      required this.fromLocalId,
      this.fromPin});
}

class GraphBody extends PouBody {
  final List<IrGraphNode> nodes;
  final List<IrConnection> connections;
  GraphBody({required this.nodes, required this.connections});
}

class RllRung {
  final int number;
  final String text;     // neutral-text ladder, e.g. 'XIC(Start)OTE(Motor)'
  final String comment;
  RllRung({required this.number, required this.text, this.comment = ''});
}

class NeutralLadderBody extends PouBody {
  final List<RllRung> rungs;
  NeutralLadderBody({required this.rungs});
}

enum SfcNodeKind { step, transition, selDiv, selConv, simDiv, simConv, jump }

/// A transition's condition source.
sealed class SfcCond {}
class SfcCondInline extends SfcCond { final String text; SfcCondInline(this.text); }
class SfcCondRef extends SfcCond { final String name; SfcCondRef(this.name); }
class SfcCondWired extends SfcCond {}
class SfcCondNone extends SfcCond {}

/// A step action's source.
sealed class SfcActSource {}
class SfcActInline extends SfcActSource { final String text; SfcActInline(this.text); }
class SfcActRef extends SfcActSource { final String name; SfcActRef(this.name); }

class SfcActionAssoc {
  final int stepLocalId;
  final String qualifier; // 'N','S','R','P','L','D',...
  final SfcActSource source;
  SfcActionAssoc({required this.stepLocalId, required this.qualifier, required this.source});
}

class SfcNode {
  final int localId;
  final SfcNodeKind kind;
  final double x, y;
  final String name;      // step name / jump targetName / '' otherwise
  final bool initial;     // step only
  final SfcCond? condition; // transition only
  SfcNode({required this.localId, required this.kind, this.x = 0, this.y = 0,
      this.name = '', this.initial = false, this.condition});
}

class SfcEdge {
  final int fromLocalId, toLocalId;
  SfcEdge({required this.fromLocalId, required this.toLocalId});
}

class SfcBody extends PouBody {
  final List<SfcNode> nodes;
  final List<SfcEdge> edges;
  final List<SfcActionAssoc> actions;
  final Map<String, String> refBodies;  // name -> ST source
  final Set<String> graphicalRefs;       // names of referenced graphical (non-ST) bodies
  SfcBody({required this.nodes, required this.edges, required this.actions,
      this.refBodies = const {}, this.graphicalRefs = const {}});
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

  /// Which vendor parser produced this IR. Language mappers use it where a
  /// dialect-specific rule applies — today only `mapImportedFbs`' FBD-bodied
  /// AOI arm, which must NOT change the PLCopen path (a PLCopen `functionBlock`
  /// FBD POU is otherwise indistinguishable from an L5X FBD AOI by
  /// kind/lang/body type alone). Defaults to `plcOpen`, so every existing
  /// construction site compiles unchanged.
  final ImportDialect dialect;

  ImportedProject({required this.name, required this.types,
      required this.globalVars, required this.pous, required this.warnings,
      this.dialect = ImportDialect.plcOpen});
}
