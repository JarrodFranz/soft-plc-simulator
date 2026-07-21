import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/widgets/scalar_value_field.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('numeric field emits a coerced int', (tester) async {
    dynamic emitted;
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'INT16', value: 0, onChanged: (v) => emitted = v)));
    await tester.enterText(find.byType(TextField), '42');
    await tester.pump();
    expect(emitted, 42);
  });

  testWidgets('FLOAT64 field emits a coerced double', (tester) async {
    dynamic emitted;
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'FLOAT64', value: 0.0, onChanged: (v) => emitted = v)));
    await tester.enterText(find.byType(TextField), '12.5');
    await tester.pump();
    expect(emitted, 12.5);
  });

  testWidgets('BOOL renders a Switch and emits bool', (tester) async {
    dynamic emitted;
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'BOOL', value: false, onChanged: (v) => emitted = v)));
    expect(find.byType(Switch), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(emitted, true);
  });

  testWidgets('STRING field emits the verbatim string', (tester) async {
    dynamic emitted;
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'STRING', value: '', onChanged: (v) => emitted = v)));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(emitted, 'hello');
  });

  testWidgets('a composite type shows a disabled note, no input', (tester) async {
    await tester.pumpWidget(_host(ScalarValueField(
      dataType: 'SomeStruct', value: const {}, onChanged: (_) {})));
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('struct'), findsOneWidget);
  });
}
