import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openlocate/state/app_state.dart';
import 'package:openlocate/ui/widgets.dart';

void main() {
  test('interval and age formatting', () {
    expect(formatInterval(15), '15 s');
    expect(formatInterval(300), '5 min');
    expect(formatInterval(3600), '1 h');
    expect(formatAgo(DateTime.now()), 'now');
  });

  testWidgets('avatar shows initials', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Avatar(name: 'Mahfoud Outmani', id: 'abc')));
    expect(find.text('MO'), findsOneWidget);
  });
}
