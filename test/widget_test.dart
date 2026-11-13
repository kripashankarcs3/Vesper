import 'package:flutter_test/flutter_test.dart';
import 'package:wa_shield/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const VesperApp());
    expect(find.byType(VesperApp), findsOneWidget);
  });
}
