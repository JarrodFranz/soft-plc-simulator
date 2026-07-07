import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/widgets/tag_autocomplete_field.dart';

Widget _wrap(Widget child, {double width = 400}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: width,
        child: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('filters options by case-insensitive substring as the user types', (tester) async {
    String? captured;
    await tester.pumpWidget(_wrap(TagAutocompleteField(
      options: const ['JamTimer', 'JamTimer.DN', 'Belt_Motor'],
      initialValue: '',
      onChanged: (v) => captured = v,
    )));

    await tester.enterText(find.byType(TextField), 'Jam');
    await tester.pump();
    await tester.pump();

    expect(find.text('JamTimer'), findsOneWidget);
    expect(find.text('JamTimer.DN'), findsOneWidget);
    expect(find.text('Belt_Motor'), findsNothing);
    expect(captured, 'Jam');
  });

  testWidgets('selecting an option fires onChanged and updates the field text', (tester) async {
    String? captured;
    await tester.pumpWidget(_wrap(TagAutocompleteField(
      options: const ['JamTimer', 'JamTimer.DN', 'Belt_Motor'],
      initialValue: '',
      onChanged: (v) => captured = v,
    )));

    await tester.enterText(find.byType(TextField), 'Jam');
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('JamTimer.DN'));
    await tester.pump();
    await tester.pump();

    expect(captured, 'JamTimer.DN');
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, 'JamTimer.DN');
  });

  testWidgets('selecting an option via mouse click (desktop) applies the selection', (tester) async {
    // On desktop platforms (and for any mouse-driven pointer, per Flutter's
    // EditableText tap-outside-unfocus semantics), a PointerDeviceKind.mouse
    // tap outside the TextField's TapRegion unfocuses the field immediately
    // on pointer-down — before the suggestion's InkWell.onTap fires on
    // pointer-up. Without wrapping the overlay in a TextFieldTapRegion, the
    // focus-loss listener tears down the overlay first, so the tap never
    // reaches the suggestion and the selection is silently dropped. This is
    // exactly how a mouse-driven desktop build of this app behaves.
    String? captured;
    await tester.pumpWidget(_wrap(TagAutocompleteField(
      options: const ['JamTimer', 'JamTimer.DN', 'Belt_Motor'],
      initialValue: '',
      onChanged: (v) => captured = v,
    )));

    await tester.enterText(find.byType(TextField), 'Jam');
    await tester.pump();
    await tester.pump();

    // Down and up are issued as separate steps (with a pump between, as a
    // real pointer-down/pointer-up pair on hardware would have a frame in
    // between) so the focus-loss triggered by pointer-down has a chance to
    // rebuild the tree (and, before the fix, tear down the overlay) before
    // pointer-up is delivered.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('JamTimer.DN')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(captured, 'JamTimer.DN');
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, 'JamTimer.DN');
  });

  testWidgets('free text not in options still fires onChanged when allowFreeText is true', (tester) async {
    String? captured;
    await tester.pumpWidget(_wrap(TagAutocompleteField(
      options: const ['JamTimer', 'JamTimer.DN', 'Belt_Motor'],
      initialValue: '',
      onChanged: (v) => captured = v,
    )));

    await tester.enterText(find.byType(TextField), 'My_New_Tag');
    await tester.pump();
    await tester.pump();

    expect(captured, 'My_New_Tag');
  });

  testWidgets('no overflow at 320 width', (tester) async {
    await tester.pumpWidget(_wrap(
      TagAutocompleteField(
        options: const ['JamTimer', 'JamTimer.DN', 'Belt_Motor', 'Some_Really_Long_Tag_Name_That_Is_Wide'],
        initialValue: '',
        onChanged: (_) {},
        label: 'Tag',
      ),
      width: 320,
    ));

    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
