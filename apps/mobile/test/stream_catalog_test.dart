import 'dart:async';
import 'dart:convert';

import 'package:brb_tracker/local_api.dart';
import 'package:brb_client/published_scans.dart';
import 'package:brb_tracker/stream_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('reads real published VOD IDs and rejects an invalid snapshot', () {
    final bytes = utf8.encode(
      jsonEncode({
        'schema_version': 1,
        'reports': [
          {
            'schema_version': 1,
            'id': 'local-scan',
            'video_id': '9YP_ljMuDQM',
            'breaks': [],
          },
          {'schema_version': 1, 'id': 'rHgIE7SB3kI'},
          {'schema_version': 1, 'video_id': 'stream00003', 'is_demo': true},
          {'schema_version': 1, 'id': 'local-only-report'},
        ],
      }),
    );
    expect(parseDashboardPublishedScans(bytes), {'9YP_ljMuDQM', 'rHgIE7SB3kI'});
    expect(
      () => parseDashboardPublishedScans(utf8.encode('{}')),
      throwsFormatException,
    );
  });

  testWidgets('distinguishes local and published VODs and refreshes the filter', (
    tester,
  ) async {
    const channel = MethodChannel('published-catalog-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cached_streams') return null;
      return '{"streams":[{"id":"stream00001","title":"From another device"},{"id":"stream00002","title":"Local VOD"},{"id":"stream00003","title":"New VOD"}],"next":null}';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Set<String>? remote;
    String? queued;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamCatalog(
            api: LocalApi(channel: channel),
            completed: const {'stream00002': 'local-scan'},
            queued: const {},
            openReport: (_) async {},
            queueStream: (id, _) async => queued = id,
            loadPublished: () async => remote ?? (throw StateError('offline')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Unpublished'))
          .onSelected,
      isNull,
    );
    expect(find.text('No report yet'), findsNothing);
    expect(find.text('Scanned on this device'), findsOneWidget);
    remote = {'stream00001'};
    await tester.tap(find.text('Refresh VODs'));
    await tester.pumpAndSettle();
    expect(find.text('Published'), findsOneWidget);
    expect(find.text('No report yet'), findsOneWidget);
    await tester.tap(find.text('From another device'));
    expect(queued, isNull);
    await tester.tap(find.text('Unpublished'));
    await tester.pumpAndSettle();
    expect(find.text('From another device'), findsNothing);
    expect(find.text('Local VOD'), findsOneWidget);
    dashboardPublication.value = ('stream00002', Object());
    await tester.pumpAndSettle();
    expect(find.text('Local VOD'), findsNothing);
    expect(find.text('New VOD'), findsOneWidget);
    remote = null;
    await tester.tap(find.text('Refresh VODs'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Showing the last synced status'),
      findsOneWidget,
    );
    expect(find.text('From another device'), findsNothing);
  });

  testWidgets('shows saved reports and appends older streams on scroll', (
    tester,
  ) async {
    const channel = MethodChannel('catalog-test');
    final offsets = <int>[];
    String? opened;
    String? queuedId;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cached_streams') return null;
      final start = call.arguments['start'] as int;
      offsets.add(start);
      return jsonEncode({
        'streams': [
          for (var index = start; index <= (start == 1 ? 20 : 22); index++)
            {
              'id': 'stream${index.toString().padLeft(5, '0')}',
              'title': 'Stream $index',
            },
        ],
        'next': start == 1 ? 21 : null,
      });
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamCatalog(
            api: LocalApi(channel: channel),
            loadPublished: () async => {},
            completed: const {'stream00001': 'saved-scan'},
            queued: const {'stream00002'},
            openReport: (id) async => opened = id,
            queueStream: (id, title) async => queuedId = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(offsets, [1]);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('In scan queue'), findsOneWidget);
    await tester.tap(find.text('Stream 2'));
    expect(queuedId, isNull);
    await tester.tap(find.text('Stream 1'));
    expect(opened, 'saved-scan');
    await tester.scrollUntilVisible(find.text('Stream 22'), 300);
    expect(offsets, [1, 21]);
    await tester.tap(find.text('Stream 22'));
    await tester.pumpAndSettle();
    expect(queuedId, 'stream00022');
  });

  testWidgets(
    'cached archive is available while refreshing and can be filtered',
    (tester) async {
      const channel = MethodChannel('cached-catalog-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final fresh = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cached_streams') {
          return '{"streams":[{"id":"stream00001","title":"Cached report"},{"id":"stream00002","title":"New stream"}],"next":null}';
        }
        return fresh.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreamCatalog(
              api: LocalApi(channel: channel),
              loadPublished: () async => {},
              completed: const {'stream00001': 'saved-scan'},
              queued: const {},
              openReport: (_) async {},
              queueStream: (_, _) async {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Cached report'), findsOneWidget);
      await tester.tap(find.text('Scanned here'));
      await tester.pump();
      expect(find.text('New stream'), findsNothing);
      fresh.complete(
        '{"streams":[{"id":"stream00001","title":"Refreshed report"},{"id":"stream00002","title":"New stream"}],"next":null}',
      );
      await tester.pumpAndSettle();
      expect(find.text('Refreshed report'), findsOneWidget);
      await tester.tap(find.text('Unscanned here'));
      await tester.pumpAndSettle();
      expect(find.text('New stream'), findsOneWidget);
      expect(find.text('Refreshed report'), findsNothing);
    },
  );
}
