import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fb_instance.dart';
import 'package:soft_plc_mobile/models/fbd_pins.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';
import 'package:soft_plc_mobile/screens/fb_editor_screen.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'support/responsive_test_utils.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

FbDefinition _scalerFb() => FbDefinition(
      name: 'Scaler',
      stSource: 'Out := In * Gain;',
      vars: [
        FbVar(name: 'In', dataType: 'FLOAT64', direction: FbVarDir.input),
        FbVar(name: 'Gain', dataType: 'FLOAT64', direction: FbVarDir.input, initialValue: 2.0),
        FbVar(name: 'Out', dataType: 'FLOAT64', direction: FbVarDir.output),
      ],
    );

PlcProject _buildProject({List<FbDefinition>? fbDefinitions, List<PlcTag>? tags}) {
  return PlcProject(
    id: 'proj_test_fb',
    name: 'Test FB Project',
    controllerName: 'TestPLC',
    tags: tags ?? [],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    fbDefinitions: fbDefinitions ?? [],
  );
}

Widget _fbEditorApp(PlcProject project) {
  return MaterialApp(
    home: FbEditorScreen(
      currentProject: project,
      onProjectUpdated: () {},
    ),
  );
}

void main() {
  group('uniqueFbInstanceName — multi-add', () {
    test('adding the same FB name twice yields distinct instance names with '
        'no tag-name collision, per the real bare-then-suffix scheme', () {
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);

      // First instance: no tag named 'Scaler' exists yet, so it gets the bare
      // FB name (no suffix) — the real scheme, not a guessed '_1'.
      final first = uniqueFbInstanceName(project, fb.name);
      expect(first, 'Scaler');
      project.tags.add(createFbInstanceTag(project, fb, name: first));

      // Second instance: 'Scaler' is now taken, so it suffixes to '_2'.
      final second = uniqueFbInstanceName(project, fb.name);
      expect(second, 'Scaler_2');
      project.tags.add(createFbInstanceTag(project, fb, name: second));

      // Third instance: both 'Scaler' and 'Scaler_2' are taken -> '_3'.
      final third = uniqueFbInstanceName(project, fb.name);
      expect(third, 'Scaler_3');

      expect({first, second}, hasLength(2)); // distinct
      final tagNames = project.tags.map((t) => t.name).toList();
      expect(tagNames.toSet().length, tagNames.length); // no collision
      expect(project.tags.every((t) => t.dataType == 'Scaler'), isTrue);
    });
  });

  group('FbEditorScreen — interface (vars) editing', () {
    testWidgets('add a var, set its name/type/direction, lands in fbDefinition.vars', (tester) async {
      await setSurface(tester, desktopSize);
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fb_editor')), findsOneWidget);

      final newIndex = fb.vars.length; // index the new row will land at
      await tester.tap(find.byKey(const Key('fb_add_var')));
      await tester.pumpAndSettle();

      expect(fb.vars.length, newIndex + 1);

      await tester.enterText(find.byKey(Key('fb_var_name_$newIndex')), 'Offset');
      await tester.pumpAndSettle();
      expect(fb.vars[newIndex].name, 'Offset');

      // Change the type dropdown to INT32.
      await tester.tap(find.byKey(Key('fb_var_type_$newIndex')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('INT32').last);
      await tester.pumpAndSettle();
      expect(fb.vars[newIndex].dataType, 'INT32');

      // Change the direction dropdown to output.
      await tester.tap(find.byKey(Key('fb_var_dir_$newIndex')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('output').last);
      await tester.pumpAndSettle();
      expect(fb.vars[newIndex].direction, FbVarDir.output);

      expect(tester.takeException(), isNull);
    });

    testWidgets('deleting a var row removes it from fbDefinition.vars', (tester) async {
      await setSurface(tester, desktopSize);
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      final before = fb.vars.length;
      await tester.tap(find.byKey(const Key('fb_var_delete_0')));
      await tester.pumpAndSettle();

      expect(fb.vars.length, before - 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing the ST body updates fbDefinition.stSource', (tester) async {
      await setSurface(tester, desktopSize);
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('fb_st_body')), 'Out := In + Gain;');
      await tester.pumpAndSettle();

      expect(fb.stSource, 'Out := In + Gain;');
      expect(tester.takeException(), isNull);
    });

    testWidgets('rename an FB via the rename dialog updates fbDefinition.name', (tester) async {
      await setSurface(tester, desktopSize);
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fb_rename_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fb_rename_name_field')), 'GainBlock');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fb_rename_confirm')));
      await tester.pumpAndSettle();

      expect(fb.name, 'GainBlock');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'renaming an FB propagates to a placed LD node, an FBD block, and the '
        'instance tag — the LD node still executes as the FB (not a timer), '
        'the FBD block still resolves pins, and the instance tag data type follows',
        (tester) async {
      await setSurface(tester, desktopSize);
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);

      // A placed instance tag (as the FBD palette / LD picker would create).
      final instanceTag = createFbInstanceTag(project, fb);
      project.tags.add(instanceTag);

      // A placed FBD block of this FB type.
      final fbdBlock = FbdBlock(id: 'b1', type: 'Scaler', title: 'Scaler', tagBinding: instanceTag.name);
      final fbdProgram = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram', fbdBlocks: [fbdBlock]);
      project.programs.add(fbdProgram);

      // A placed LD FB-call node, wired via pinBindings to real scalar tags.
      project.tags.addAll([
        _tag('Enable', 'BOOL', true),
        _tag('InTag', 'FLOAT64', 5.0),
        _tag('GainTag', 'FLOAT64', 2.0),
        _tag('OutTag', 'FLOAT64', 0.0),
      ]);
      final ldNode = LdNode(
        id: 'n1',
        kind: LdKind.block,
        blockType: 'Scaler',
        variable: instanceTag.name,
        pinBindings: {'In': 'InTag', 'Gain': 'GainTag', 'Out': 'OutTag'},
      );
      final rung = buildRung(index: 0, main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Enable'),
        ldNode,
      ]);
      final ldProgram = PlcProgram(name: 'P1', language: 'LadderLogic', rungs: [rung]);
      project.programs.add(ldProgram);

      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fb_rename_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fb_rename_name_field')), 'GainBlock');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fb_rename_confirm')));
      await tester.pumpAndSettle();

      // The definition itself resolves under the new name.
      expect(fbDefinitionFor(project, 'GainBlock'), isNotNull);
      expect(fbDefinitionFor(project, 'Scaler'), isNull);

      // The FBD block's type followed the rename and still resolves pins.
      expect(fbdBlock.type, 'GainBlock');
      expect(fbdInputPinsFor(project, fbdBlock), containsAll(['In', 'Gain']));
      expect(fbdOutputPinsFor(project, fbdBlock), contains('Out'));

      // The instance tag's data type followed the rename.
      expect(instanceTag.dataType, 'GainBlock');

      // The LD node's blockType followed the rename, and it still executes as
      // the FB (computing Out = In * Gain via the ST body) rather than
      // silently falling through to the TON/TOF timer default (which would
      // leave OutTag at its initial 0.0 and instead stamp EN/ACC/DN fields
      // nobody reads).
      expect(ldNode.blockType, 'GainBlock');
      executeLdPrograms(project, 100, LdExecRuntime());
      expect(readPath(project, 'OutTag'), 10.0);

      expect(tester.takeException(), isNull);
    });
  });

  group('FbEditorScreen — responsive', () {
    testWidgets('small phone size (320): no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fb_editor')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone size (360): no overflow', (tester) async {
      await setSurface(tester, phoneSize);
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no FB definitions: empty state renders without overflow', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      expect(find.text('No function blocks defined yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FbEditorScreen — name validation (reserved-name rejection)', () {
    testWidgets('creating a new FB named after a built-in block type (ADD) is rejected', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fb_new_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fb_new_name_field')), 'ADD');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fb_new_confirm')));
      await tester.pumpAndSettle();

      // Rejected: no FB was added, dialog stays open with an error.
      expect(project.fbDefinitions, isEmpty);
      expect(find.text('"ADD" is a reserved built-in block type'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('creating a new FB named after an existing struct def is rejected', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      project.structDefs.add(PlcStructDef(name: 'MyStruct', fields: []));
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fb_new_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fb_new_name_field')), 'MyStruct');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fb_new_confirm')));
      await tester.pumpAndSettle();

      expect(project.fbDefinitions, isEmpty);
      expect(find.text('A struct type named "MyStruct" already exists'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renaming an FB to a builtin composite name (TIMER) is rejected', (tester) async {
      await setSurface(tester, desktopSize);
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);
      await tester.pumpWidget(_fbEditorApp(project));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fb_rename_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fb_rename_name_field')), 'TIMER');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fb_rename_confirm')));
      await tester.pumpAndSettle();

      expect(fb.name, 'Scaler'); // unchanged
      expect(find.text('"TIMER" is a reserved built-in composite type'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FBD editor — Function Block palette', () {
    Widget fbdApp(PlcProject project, PlcProgram program) {
      return MaterialApp(
        home: FbdEditorScreen(
          currentProject: project,
          program: program,
          onProgramUpdated: () {},
        ),
      );
    }

    testWidgets('an FB definition appears as a palette entry; selecting it adds an FbdBlock '
        'with type == fb.name and a new instance tag in project.tags', (tester) async {
      // The palette dock is a real (lazily-built) ListView with ~24 built-in
      // entries ahead of the FB section, so a normal desktop height would
      // leave "Scaler" unbuilt (off the sliver's layout extent) — use a very
      // tall viewport so the whole palette list renders without scrolling.
      await setSurface(tester, const Size(1400, 3600));
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb], tags: [_tag('Motor_Run', 'BOOL', false)]);
      final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram');

      await tester.pumpWidget(fbdApp(project, program));
      await tester.pumpAndSettle();

      // The FB shows up as a named palette entry.
      expect(find.text('Scaler'), findsOneWidget);

      final tagsBefore = project.tags.length;
      final blocksBefore = program.fbdBlocks.length;

      // Its palette card's own "+" is the last add-icon in the (now
      // FB-appended) list — same convention the built-in palette tests use.
      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pumpAndSettle();

      expect(program.fbdBlocks.length, blocksBefore + 1);
      final added = program.fbdBlocks.last;
      expect(added.type, 'Scaler');
      expect(added.tagBinding, isNotEmpty);

      expect(project.tags.length, tagsBefore + 1);
      final newTag = project.tags.last;
      expect(newTag.name, added.tagBinding);
      expect(newTag.dataType, 'Scaler');

      expect(tester.takeException(), isNull);
    });

    testWidgets('adding the same FB twice via the palette yields two distinct instances '
        '(no tag-name collision)', (tester) async {
      await setSurface(tester, const Size(1400, 3600));
      final fb = _scalerFb();
      final project = _buildProject(fbDefinitions: [fb]);
      final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram');

      await tester.pumpWidget(fbdApp(project, program));
      await tester.pumpAndSettle();

      // The editor seeds a default demo circuit on init (existing behavior,
      // unrelated to FBs), so compare against before-counts rather than
      // absolute totals — same convention as the single-add test above.
      final blocksBefore = program.fbdBlocks.length;
      final tagsBefore = project.tags.length;

      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pumpAndSettle();

      final added = program.fbdBlocks.sublist(blocksBefore);
      expect(added.length, 2);
      expect(added.every((b) => b.type == 'Scaler'), isTrue);
      final tagBindings = added.map((b) => b.tagBinding).toList();
      expect(tagBindings.toSet().length, 2); // distinct instance names
      expect(tagBindings, ['Scaler', 'Scaler_2']); // the real bare-then-suffix scheme

      // Both instance tags landed in the project with no name collision.
      expect(project.tags.length, tagsBefore + 2);
      final tagNames = project.tags.map((t) => t.name).toList();
      expect(tagNames.toSet().length, tagNames.length);
      expect(tagNames, containsAll(['Scaler', 'Scaler_2']));

      expect(tester.takeException(), isNull);
    });

    testWidgets('zero FB definitions: palette is unchanged (no Function Blocks section)', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject(tags: [_tag('Motor_Run', 'BOOL', false)]);
      final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram');

      await tester.pumpWidget(fbdApp(project, program));
      await tester.pumpAndSettle();

      expect(find.text('FUNCTION BLOCKS'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('LD editor — Function Blocks block-picker group', () {
    PlcProject buildLdProject(FbDefinition fb) => PlcProject(
          id: 'proj_test_ld_fb',
          name: 'Test LD FB Project',
          controllerName: 'PLC_TEST',
          tags: [], // growable — the FB insert path adds a new instance tag
          structDefs: const [],
          programs: const [],
          tasks: const [],
          hmis: const [],
          fbDefinitions: [fb],
        );

    Widget ldApp(PlcProject project, PlcProgram program) {
      return MaterialApp(
        home: LdEditorScreen(
          currentProject: project,
          program: program,
          onProgramUpdated: () {},
          monitor: LdMonitor(),
          scanRunning: false,
        ),
      );
    }

    testWidgets('picking the FB from the Function Blocks group and inserting it creates '
        'an FB-call block node + instance tag', (tester) async {
      await setSurface(tester, desktopSize);
      final fb = _scalerFb();
      final project = buildLdProject(fb);
      final program = PlcProgram(
        name: 'P1',
        language: 'LadderLogic',
        rungs: [
          buildRung(index: 0, main: [
            LdNode(id: '', kind: LdKind.contact, variable: 'In'),
            LdNode(id: '', kind: LdKind.coil, variable: 'Out'),
          ]),
        ],
      );

      await tester.pumpWidget(ldApp(project, program));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();

      expect(find.text('Function Blocks'), findsOneWidget);
      expect(find.text('Scaler'), findsOneWidget);

      await tester.tap(find.text('Scaler'));
      await tester.pumpAndSettle();

      final addTargets = find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.add && w.size == 14);
      final insertTarget = tester.widget<GestureDetector>(
        find.ancestor(of: addTargets.first, matching: find.byType(GestureDetector)).first,
      );
      final tagsBefore = project.tags.length;
      insertTarget.onTap!();
      await tester.pumpAndSettle();

      final inserted = program.rungs[0].nodes
          .where((n) => n.kind == LdKind.block && n.blockType == 'Scaler')
          .toList();
      expect(inserted.length, 1);
      expect(inserted.first.pinBindings, isEmpty);
      expect(inserted.first.variable, isNotEmpty);

      expect(project.tags.length, tagsBefore + 1);
      expect(project.tags.last.name, inserted.first.variable);
      expect(project.tags.last.dataType, 'Scaler');

      expect(tester.takeException(), isNull);
    });

    for (final size in [smallPhoneSize, desktopSize]) {
      testWidgets('Pin Bindings section (${size.width.toInt()}px): one field per FB var, '
          'entering a tag commits to n.pinBindings on Apply, no overflow', (tester) async {
        await setSurface(tester, size);
        final fb = _scalerFb();
        final project = buildLdProject(fb);
        project.tags.addAll([
          _tag('SensorIn', 'FLOAT64', 0.0),
          _tag('GainVal', 'FLOAT64', 0.0),
          _tag('ScaledOut', 'FLOAT64', 0.0),
        ]);
        final instTag = createFbInstanceTag(project, fb, name: 'Scaler_1');
        project.tags.add(instTag);
        final node = LdNode(id: 'n1', kind: LdKind.block, blockType: 'Scaler', variable: instTag.name);
        final program = PlcProgram(
          name: 'P1',
          language: 'LadderLogic',
          rungs: [buildRung(index: 0, main: [node])],
        );

        await tester.pumpWidget(ldApp(project, program));
        await tester.pumpAndSettle();

        // Open the block's config dialog (two quick taps register as the
        // double-tap that opens it — same convention as the existing GT
        // edit-dialog widget test in ld_editor_test.dart).
        await tester.tap(find.text('Scaler'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('Scaler'));
        await tester.pumpAndSettle();

        expect(find.text('Edit Scaler'), findsOneWidget);
        expect(find.text('Pin Bindings'), findsOneWidget);
        expect(find.byKey(const Key('fb_pin_In')), findsOneWidget);
        expect(find.byKey(const Key('fb_pin_Gain')), findsOneWidget);
        expect(find.byKey(const Key('fb_pin_Out')), findsOneWidget);

        await tester.enterText(
          find.descendant(of: find.byKey(const Key('fb_pin_In')), matching: find.byType(TextField)),
          'SensorIn',
        );
        await tester.enterText(
          find.descendant(of: find.byKey(const Key('fb_pin_Gain')), matching: find.byType(TextField)),
          'GainVal',
        );
        await tester.enterText(
          find.descendant(of: find.byKey(const Key('fb_pin_Out')), matching: find.byType(TextField)),
          'ScaledOut',
        );
        await tester.pumpAndSettle();

        // Not written to the model until Apply is tapped.
        expect(node.pinBindings, isEmpty);

        await tester.tap(find.widgetWithText(ElevatedButton, 'Apply'));
        await tester.pumpAndSettle();

        expect(node.pinBindings, {'In': 'SensorIn', 'Gain': 'GainVal', 'Out': 'ScaledOut'});
        expect(tester.takeException(), isNull); // no overflow at 320px
      });
    }
  });
}
