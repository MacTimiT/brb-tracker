import 'package:brb_tracker_windows/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offers rate-limited downloads and offline scanning', (
    tester,
  ) async {
    await tester.pumpWidget(const BrbTracker());

    expect(find.text('5'), findsOneWidget);
    expect(find.text('Media download cap'), findsOneWidget);
    expect(find.text('Choose local video'), findsOneWidget);
    await tester.ensureVisible(find.text('Download and scan'));
    await tester.tap(find.text('Download and scan'));
    await tester.pump();
    expect(find.text('Paste a link or choose a local video.'), findsOneWidget);
  });
}
