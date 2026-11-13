import 'dart:convert';

import 'package:brb_tracker/banner_check.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'screenshot check shows raw OCR and copies text without image data',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: BannerCheck(
            result: {
              'source_kind': 'video-frame',
              'timestamp_seconds': 8,
              'frame': null,
              'checks': [
                {
                  'width': 640,
                  'height': 360,
                  'matched': false,
                  'texts': ['Be Riqht Back'],
                  'mask': null,
                },
              ],
            },
          ),
        ),
      );
      expect(find.text('640 × 360 · No match'), findsOneWidget);
      expect(find.text('Be Riqht Back'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy OCR details'));
      await tester.pump();
      final copiedResult = jsonDecode(copied!) as Map;
      expect(copiedResult.containsKey('frame'), isFalse);
      expect(copiedResult['timestamp_seconds'], 8);
      final check = (copiedResult['checks'] as List).single as Map;
      expect(check.containsKey('mask'), isFalse);
      expect(check['texts'], ['Be Riqht Back']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
