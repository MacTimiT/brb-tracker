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
  testWidgets('Entry screen and offline report', (tester) async {
    await tester.pumpWidget(const BrbApp());
    expect(find.text('BRB Tracker'), findsOneWidget);
    expect(find.text('Your phone. The whole pipeline.'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    await tester.tap(find.text('Explore sample report'));
    await tester.pumpAndSettle();
    expect(find.text('Break report'), findsOneWidget);
    expect(find.textContaining('Invented for demonstration'), findsOneWidget);
    expect(find.textContaining('6 breaks'), findsOneWidget);
    expect(find.text('Publish to GitHub dashboard'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
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
}
