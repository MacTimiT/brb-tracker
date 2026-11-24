import 'dart:convert';
import 'dart:io';

import 'package:brb_tracker_windows/main.dart';
import 'package:brb_tracker_windows/scan_queue.dart';
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

  testWidgets('filters saved downloads and removes unsuccessful scan entries', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'brb-windows-history',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/scan-queue.json');
    final jobs = [
      for (final status in [
        ScanStatus.completed,
        ScanStatus.cancelled,
        ScanStatus.failed,
      ])
        ScanJob(
          folder: '${directory.path}/${status.name}',
          title: '${status.name} VOD',
          arguments: const [],
          status: status,
        ),
    ];
    final failedMedia = Directory('${jobs.last.folder}/Video')
      ..createSync(recursive: true);
    final saved = File('${failedMedia.path}/vod.mp4')
      ..writeAsStringSync('video');
    final cancelledMedia = Directory('${jobs[1].folder}/Video')
      ..createSync(recursive: true);
    File('${cancelledMedia.path}/vod.mp4').createSync();
    File('${cancelledMedia.path}/vod.webm.part').writeAsStringSync('partial');
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'jobs': jobs.map((job) => job.toJson()).toList(),
      }),
    );

    await tester.pumpWidget(BrbTracker(stateDirectory: directory));
    await tester.tap(find.text('Scans').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Video downloaded'), findsOneWidget);
    expect(find.text('No saved download'), findsNWidgets(2));
    await tester.tap(find.text('Downloaded only (1)'));
    await tester.pumpAndSettle();
    expect(find.text('failed VOD'), findsOneWidget);
    expect(find.text('cancelled VOD'), findsNothing);

    Future<void> openRemoveDialog() async {
      await tester.tap(find.byTooltip('Scan actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from history'));
      await tester.pumpAndSettle();
    }

    await openRemoveDialog();
    await tester.tap(find.text('Keep scan'));
    await tester.pumpAndSettle();
    expect(find.text('failed VOD'), findsOneWidget);

    await openRemoveDialog();
    await tester.tap(find.text('Remove scan'));
    await tester.pumpAndSettle();
    expect(find.text('failed VOD'), findsNothing);
    expect(find.text('Downloaded only (0)'), findsOneWidget);
    expect(saved.existsSync(), isTrue);

    await tester.tap(find.text('Downloaded only (0)'));
    await tester.pumpAndSettle();
    final cancelled = find.widgetWithText(ListTile, 'cancelled VOD');
    await tester.tap(
      find.descendant(of: cancelled, matching: find.byTooltip('Scan actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove scan'));
    await tester.pumpAndSettle();
    expect(find.text('cancelled VOD'), findsNothing);
    final persisted =
        (jsonDecode(file.readAsStringSync()) as Map)['jobs'] as List;
    expect(persisted.map((job) => job['status']), ['completed']);
  });
}
