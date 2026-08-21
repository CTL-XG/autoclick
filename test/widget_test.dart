import 'package:autoclick/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const AutoClickerApp());
    expect(find.text('NTP 自动点击器'), findsOneWidget);
    await tester.pump();
  });
}
