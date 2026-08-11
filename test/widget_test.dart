import 'package:bambu_rfid/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BambuRFID app boots', (tester) async {
    await tester.pumpWidget(const BambuRfidApp());
    expect(find.text('BambuRFID'), findsOneWidget);
  });
}
