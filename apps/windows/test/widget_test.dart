import 'dart:io';

import 'package:brb_tracker_windows/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('offers rate-limited downloads and offline scanning', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('brb-windows-ui');
    addTearDown(() => directory.deleteSync(recursive: true));
    await tester.pumpWidget(BrbTracker(stateDirectory: directory));

    expect(find.text('5'), findsOneWidget);
    expect(find.text('Media download cap'), findsOneWidget);
    expect(find.text('Choose local video'), findsOneWidget);
    final signIn = find.widgetWithText(CheckboxListTile, 'Use Firefox sign-in');
    expect(tester.widget<CheckboxListTile>(signIn).value, isFalse);
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();
    await tester.tap(signIn);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(signIn).value, isTrue);
    await tester.ensureVisible(find.text('Queue download and scan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Queue download and scan'));
    await tester.pump();
    expect(find.text('Paste a link or choose a local video.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(BrbTracker(stateDirectory: directory));
    await tester.ensureVisible(signIn);
    expect(tester.widget<CheckboxListTile>(signIn).value, isTrue);
  });
}
