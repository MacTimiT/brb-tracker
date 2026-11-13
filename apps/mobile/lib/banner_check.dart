import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

class BannerCheck extends StatelessWidget {
  const BannerCheck({super.key, required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('BRB screenshot check'),
      actions: [
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy OCR details',
          onPressed: () async {
            final text = {
              'checks': [
                for (final raw in result['checks'] as List)
                  Map<String, dynamic>.from(raw as Map)..remove('mask'),
              ],
            };
            await Clipboard.setData(
              ClipboardData(
                text: const JsonEncoder.withIndent('  ').convert(text),
              ),
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('OCR details copied.')),
              );
            }
          },
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'This check runs only on your phone. It tests the saved screenshot, not frames decoded from the VOD. Share the OCR details and mask to help diagnose a missed banner.',
        ),
        for (final check in result['checks'] as List) ...[
          const SizedBox(height: 20),
          Text(
            '${check['width']} × ${check['height']} · ${check['matched'] == true ? 'Banner matched' : 'No match'}',
          ),
          if (check['mask'] != null)
            Image.memory(base64Decode(check['mask'] as String))
          else
            const Text('No usable red mask found in the banner crop.'),
          for (final text in check['texts'] as List)
            SelectableText(
              (text as String).trim().isEmpty ? '(OCR returned no text)' : text,
            ),
        ],
      ],
    ),
  );
}
