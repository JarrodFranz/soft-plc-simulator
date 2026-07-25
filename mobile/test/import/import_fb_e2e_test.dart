// Task 4 (final) of the custom-FB import mapping feature: an end-to-end
// proof, from a handcrafted-but-spec-faithful PLCopen TC6 XML string, that
// an ST-bodied `functionBlock` POU imports as a native `FbDefinition` AND a
// LD `<block>` call site in another POU routes to a real FB-instance
// `LdNode` (not the unsupported-block stub) — and that the translated rung
// actually EXECUTES the FB's ST body when scanned.
//
// Pipeline entry point (verbatim, same two calls `debugImportXml` uses in
// workspace_shell.dart): `parsePlcOpen(xml)` -> `ImportedProject` ->
// `mapImportedProject(ir, projectName: ..., projectId: ...)` -> `ImportResult`.
// Purely `import_ir`/`plcopen_parser`/`ir_to_project` plumbing, so this is a
// plain `test()`, no widget harness needed.
//
// XML shape note (documented adjustment — see brief step 1): real TC6 uses
// `<expression>` inside `<inVariable>`/`<outVariable>` for the bound
// tag/literal, but `plcopen_parser.dart`'s `_graphBody` only ever looks for a
// descendant element named `<variable>` (`_findElement(el, 'variable')`) to
// populate `IrGraphNode.attributes['variable']` — the SAME lookup it uses for
// `<contact>`/`<coil>`, which per TC6 legitimately carry `<variable>`. This
// fixture therefore uses `<variable>PV</variable>` / `<variable>2.0</variable>`
// inside its `<inVariable>`/`<outVariable>` nodes instead of `<expression>`,
// matching the dialect this codebase's existing fixtures
// (`basic.xml`/`fbd_block.xml`) already rely on. Everything else — element
// nesting, localId/position, connectionPointIn/Out, formalParameter, the
// block's own top-level connectionPointIn/Out for power flow vs the nested
// inputVariables/outputVariables for data pins — mirrors real TC6 exactly and
// the exact IR shape already proven by
// `ld_translate_test.dart`'s "LD custom-FB call block -> FB-call node with
// pinBindings + instance tag" test.
//
// Execution note: this test is what first exercises a custom-FB call whose
// `pinBindings` value is a LITERAL (the `Gain<-2.0` wiring) all the way
// through `ld_exec.dart`'s FB dispatch. That dispatch previously called
// `readPath(p, tag)` unconditionally on every input pin binding — correct for
// a tag reference, but a literal like `'2.0'` is not a tag path, so it
// resolved to `null` and the FB body's `Gain` silently stayed unbound/zero.
// Fixed in `ld_exec.dart` (custom-FB input resolution) with a fallback: an
// unresolved tag path is now parsed as a numeric literal before being
// dropped, mirroring how compare/math blocks already accept a literal OR a
// tag in `operandA`/`operandB` (`_operandValue`). A resolved tag read is
// never affected — see `fb_ld_exec_test.dart`'s existing tag-bound-pin
// coverage, still green.
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

const String _kFbXml = '''
<?xml version="1.0" encoding="utf-8"?>
<project xmlns="http://www.plcopen.org/xml/tc6_0201">
  <contentHeader name="FbImportE2E"/>
  <types>
    <dataTypes/>
    <pous>
      <pou name="Scaler" pouType="functionBlock">
        <interface>
          <inputVars>
            <variable name="In"><type><REAL/></type></variable>
            <variable name="Gain"><type><REAL/></type></variable>
          </inputVars>
          <outputVars>
            <variable name="Out"><type><REAL/></type></variable>
          </outputVars>
        </interface>
        <body><ST><xhtml xmlns="http://www.w3.org/1999/xhtml">Out := In * Gain;</xhtml></ST></body>
      </pou>
      <pou name="Main" pouType="program">
        <interface><localVars/></interface>
        <body><LD>
          <leftPowerRail localId="100"><position x="0" y="0"/><connectionPointOut/></leftPowerRail>
          <rightPowerRail localId="200"><position x="300" y="0"/>
            <connectionPointIn><connection refLocalId="1"/></connectionPointIn>
          </rightPowerRail>
          <block localId="1" typeName="Scaler" instanceName="S1">
            <position x="60" y="20"/>
            <connectionPointIn><connection refLocalId="100"/></connectionPointIn>
            <inputVariables>
              <variable formalParameter="In">
                <connectionPointIn><connection refLocalId="2"/></connectionPointIn>
              </variable>
              <variable formalParameter="Gain">
                <connectionPointIn><connection refLocalId="3"/></connectionPointIn>
              </variable>
            </inputVariables>
            <outputVariables>
              <variable formalParameter="Out"><connectionPointOut/></variable>
            </outputVariables>
          </block>
          <inVariable localId="2"><position x="10" y="20"/><variable>PV</variable>
            <connectionPointOut/></inVariable>
          <inVariable localId="3"><position x="10" y="60"/><variable>2.0</variable>
            <connectionPointOut/></inVariable>
          <outVariable localId="4"><position x="150" y="20"/><variable>CV</variable>
            <connectionPointIn><connection refLocalId="1" formalParameter="Out"/></connectionPointIn>
          </outVariable>
        </LD></body>
      </pou>
    </pous>
  </types>
  <instances>
    <configurations>
      <configuration name="Config">
        <resource name="Res">
          <globalVars>
            <variable name="PV"><type><REAL/></type><initialValue><simpleValue value="0.0"/></initialValue></variable>
            <variable name="CV"><type><REAL/></type><initialValue><simpleValue value="0.0"/></initialValue></variable>
          </globalVars>
        </resource>
      </configuration>
    </configurations>
  </instances>
</project>
''';

void main() {
  test('ST functionBlock POU imports as a native FB and its LD call routes '
      'to an executing FB instance', () {
    // --- pipeline: parse XML -> ImportedProject -> mapImportedProject. ---
    final ir = parsePlcOpen(_kFbXml);
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'fb_e2e_test');
    final p = res.project;

    // FB imported as a native FbDefinition.
    expect(p.fbDefinitions.map((f) => f.name), contains('Scaler'));
    expect(res.report.importedFbCount, 1);

    // Main is a real LD program (not a stub) with an FB-call node.
    final main = p.programs.firstWhere((pr) => pr.name == 'Main');
    expect(main.language, 'LadderLogic');
    expect(main.rungs, isNotEmpty, reason: 'a stub program has no rungs');
    final fbNode = main.rungs
        .expand((r) => r.nodes)
        .firstWhere((n) => n.kind == LdKind.block && n.blockType == 'Scaler');
    expect(fbNode.pinBindings['In'], 'PV');
    expect(fbNode.pinBindings['Gain'], '2.0');
    expect(fbNode.pinBindings['Out'], 'CV');

    // Instance tag exists, struct-typed to the FB.
    final instanceTag = p.tags.firstWhere((t) => t.name == 'S1');
    expect(instanceTag.dataType, 'Scaler');

    // And it RUNS: set PV, execute the LD program, CV == PV * Gain (2.0).
    writePath(p, 'PV', 21.0);
    final rt = LdExecRuntime();
    executeLdPrograms(p, 100, rt);
    expect(readPath(p, 'CV'), 42.0);
  });
}
