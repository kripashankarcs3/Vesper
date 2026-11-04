import 'package:flutter_test/flutter_test.dart';
import 'package:wa_shield/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const WAShieldApp());
    expect(find.byType(WAShieldApp), findsOneWidget);
  });
}
