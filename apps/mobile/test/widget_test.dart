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
        .setMockMethodCallHandler(channel, (call) async => homeResponse(call));
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
      expect(find.text('VODs'), findsOneWidget);
      await tester.tap(find.text('Scan options'));
      await tester.pumpAndSettle();
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
    'saved quality is used for multiple VODs queued from the archive',
    (tester) async {
      final submitted = <Map<dynamic, dynamic>>[];
      Map<dynamic, dynamic> preferences = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'scan_settings':
                return jsonEncode(preferences);
              case 'save_scan_settings':
                preferences = call.arguments as Map;
              case 'start':
                submitted.add(call.arguments as Map);
                return '{"id":"queued"}';
              case 'list_streams':
                return jsonEncode({
                  'streams': [
                    {'id': 'fixture0001', 'title': 'First VOD'},
                    {'id': 'fixture0002', 'title': 'Second VOD'},
                  ],
                  'next': null,
                });
            }
            return homeResponse(call);
          });
      await tester.pumpWidget(const BrbApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan options'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('360p (smaller)').last);
      await tester.pumpAndSettle();
      expect(preferences['download_height'], 360);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const BrbApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('First VOD'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second VOD'));
      await tester.pumpAndSettle();
      expect(submitted.map((input) => input['download_height']), [360, 360]);
      expect(submitted.map((input) => input['title']), [
        'First VOD',
        'Second VOD',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('scan controls fit a narrow phone with large text', (
    tester,
  ) async {
    narrowPhone(tester);
    tester.view.viewPadding = const FakeViewPadding(bottom: 42);
    tester.view.padding = const FakeViewPadding(bottom: 42);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(const BrbApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scan options'));
    await tester.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;
    final scanMode = find.byType(DropdownButtonFormField<bool>);
    await tester.scrollUntilVisible(
      scanMode.hitTestable(),
      160,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(scanMode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detailed (2s)').last);
    await tester.pumpAndSettle();

    final settings = find.text('Files & detection settings');
    await tester.scrollUntilVisible(
      settings.hitTestable(),
      170,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(settings);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Check VOD frame at timestamp').hitTestable(),
      150,
      scrollable: scrollable,
    );
    final dashboard = find.text('Open Dashboard');
    await tester.scrollUntilVisible(
      dashboard.hitTestable(),
      180,
      scrollable: scrollable,
    );
    expect(
      tester.getRect(dashboard).bottom,
      lessThan(tester.getRect(find.byType(NavigationBar)).top),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('long break details and reason picker fit with large text', (
    tester,
  ) async {
    narrowPhone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: ReportScreen(
          initial: {
            'title': 'A long stream title with extra words and a game title',
            'video_id': '9YP_ljMuDQM',
            'breaks': [
              {
                'start_seconds': 6240,
                'end_seconds': 6470,
                'evidence': 'I need to go help Rachel before I come back.',
                'suggested_reason': 'Help Rachel',
                'reason': 'Mental Break',
              },
            ],
          },
          api: LocalApi(),
          jobId: 'local-job',
        ),
      ),
    );
    final picker = find.byType(DropdownButton<String>);
    await tester.scrollUntilVisible(picker.hitTestable(), 160);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.text('Help Rachel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('publishing settings fit with large text', (tester) async {
    narrowPhone(tester);
    const storage = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      storage,
      (call) async =>
          call.arguments['key'] == 'github_token' ? 'test-token' : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(storage, null));
    tester.view.viewPadding = const FakeViewPadding(bottom: 42);
    tester.view.padding = const FakeViewPadding(bottom: 42);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(const BrbApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('GitHub publishing settings'));
    await tester.pumpAndSettle();
    final owner = find.widgetWithText(TextField, 'Repository owner');
    final repo = find.widgetWithText(TextField, 'Repository name');
    expect(tester.getRect(repo).top - tester.getRect(owner).bottom, 16);
    expect(find.text('MacTimiT'), findsOneWidget);
    expect(find.text('brb-tracker'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save securely').hitTestable(),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

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
    'active download shows its current phase and percentage',
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
                : homeResponse(call),
          );
      await tester.pumpWidget(const BrbApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scans'));
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
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
          return homeResponse(call);
        });
    await tester.pumpWidget(const BrbApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan options'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://www.youtube.com/watch?v=9YP_ljMuDQM',
    );
    await tester.tap(find.text('Files & detection settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check VOD frame at timestamp'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '1:43:55');
    await tester.tap(find.text('Check frame'));
    await tester.pumpAndSettle();
    expect(started?['probe_seconds'], 6235.0);
    expect(started?['url'], 'https://www.youtube.com/watch?v=9YP_ljMuDQM');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

void narrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 650);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.6;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

String? homeResponse(MethodCall call) => switch (call.method) {
  'list' => '[]',
  'scan_settings' => '{}',
  'list_streams' => '{"streams":[],"next":null}',
  _ => null,
};
