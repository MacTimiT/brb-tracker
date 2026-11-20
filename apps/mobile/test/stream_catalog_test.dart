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
    String? chosen;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
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
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                child: const Text('Browse'),
                onPressed: () async {
                  chosen = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => StreamCatalog(
                        api: LocalApi(channel: channel),
                        completed: const {'stream00001': 'saved-scan'},
                        openReport: (id) async {
                          opened = id;
                        },
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    expect(offsets, [1]);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tester.tap(find.text('Stream 1'));
    expect(opened, 'saved-scan');
    await tester.scrollUntilVisible(find.text('Stream 22'), 300);
    expect(offsets, [1, 21]);
    await tester.tap(find.text('Stream 22'));
    await tester.pumpAndSettle();
    expect(chosen, 'stream00022');
  });
}
