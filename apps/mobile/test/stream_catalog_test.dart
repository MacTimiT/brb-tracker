import 'dart:async';
import 'dart:convert';

import 'package:brb_tracker/local_api.dart';
import 'package:brb_tracker/stream_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
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
      await tester.tap(find.text('Scanned'));
      await tester.pump();
      expect(find.text('New stream'), findsNothing);
      fresh.complete(
        '{"streams":[{"id":"stream00001","title":"Refreshed report"},{"id":"stream00002","title":"New stream"}],"next":null}',
      );
      await tester.pumpAndSettle();
      expect(find.text('Refreshed report'), findsOneWidget);
      await tester.tap(find.text('Unscanned'));
      await tester.pumpAndSettle();
      expect(find.text('New stream'), findsOneWidget);
      expect(find.text('Refreshed report'), findsNothing);
    },
  );
}
