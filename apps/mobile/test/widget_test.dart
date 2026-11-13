import 'dart:convert';

import 'package:brb_tracker/main.dart';
import 'package:brb_tracker/local_api.dart';
import 'package:brb_tracker/report_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.mactimit.brb_tracker/local');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'list' ? '[]' : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  testWidgets(
    'admin entry has real scan controls and no demo or promotional copy',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const BrbApp());
      expect(find.text('GONE4HOPE'), findsOneWidget);
      expect(find.text('NEW SCAN.'), findsOneWidget);
      expect(find.text('Explore sample report'), findsNothing);
      expect(find.text('Your phone. The whole pipeline.'), findsNothing);
      expect(find.widgetWithText(TextField, 'YouTube VOD URL'), findsOneWidget);
      expect(
        find.text('https://www.youtube.com/live/IW2rEIuKGSs'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'report shows historical VOD date, missing captions and preserves publishing',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReportScreen(
            initial: {
              'schema_version': 1,
              'id': 'old-vod',
              'title': 'Historical stream',
              'is_demo': false,
              'vod_date': '2026-10-22',
              'analyzed_at': '2026-11-12T12:00:00Z',
              'transcript_source': 'none',
              'breaks': <dynamic>[],
            },
          ),
        ),
      );
      expect(find.text('VOD date: 2026-10-22'), findsOneWidget);
      expect(
        find.text('No captions found · review reasons manually.'),
        findsOneWidget,
      );
      expect(find.text('Publish to dashboard'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'active download is labeled as downloading in the job and button',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'list'
                ? jsonEncode([
                    {
                      'id': 'download-job',
                      'status': 'running',
                      'stage': 'Downloading video to this phone',
                      'progress': 0.15,
                      'phase_progress': 0.5,
                    },
                  ])
                : null,
          );
      await tester.pumpWidget(const BrbApp());
      await tester.pumpAndSettle();
      expect(find.text('Downloading video to this phone'), findsOneWidget);
      expect(
        find.text('Downloading video to this phone · 50%'),
        findsOneWidget,
      );
      expect(find.text('Analysis running on this phone'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('Analysis is dispatched to Android with no HTTP service', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'start');
          expect(
            call.arguments['url'],
            'https://www.youtube.com/live/IW2rEIuKGSs',
          );
          expect(call.arguments['interval'], 2);
          return '{"id":"local-job","status":"queued"}';
        });
    final result = await LocalApi().start({
      'url': 'https://www.youtube.com/live/IW2rEIuKGSs',
      'interval': 2,
    });
    expect(result['id'], 'local-job');
  });
  test('Duration formatting supports multi-hour VODs', () {
    expect(timeLabel(3661), '1:01:01');
    expect(timeLabel(0), '0:00:00');
  });
  testWidgets('VOD frame check sends the entered timestamp to Android', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<dynamic, dynamic>? started;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'list') return '[]';
          if (call.method == 'start') {
            started = call.arguments as Map;
            return '{"id":"probe","status":"queued"}';
          }
          return null;
        });
    await tester.pumpWidget(const BrbApp());
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://www.youtube.com/watch?v=9YP_ljMuDQM',
    );
    await tester.tap(find.text('Check VOD frame at timestamp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check frame'));
    await tester.pumpAndSettle();
    expect(started?['probe_seconds'], 6235.0);
    expect(started?['url'], 'https://www.youtube.com/watch?v=9YP_ljMuDQM');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
