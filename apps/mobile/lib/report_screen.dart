import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'local_api.dart';
import 'publishing_ui.dart';

const reasons = [
  'Pee',
  'Snack',
  'Drink',
  'Stretch',
  'Technical',
  'Other',
  'Unknown',
];
String timeLabel(num seconds) {
  final s = seconds.round();
  return '${s ~/ 3600}:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.initial, this.api, this.jobId});
  final Map<String, dynamic> initial;
  final LocalApi? api;
  final String? jobId;
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late Map<String, dynamic> report = widget.initial;
  bool saving = false;
  Future<void> review(int index, String reason) async {
    setState(() => saving = true);
    try {
      final updated = await widget.api!.review(widget.jobId!, index, reason);
      if (mounted) setState(() => report = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final breaks = report['breaks'] as List<dynamic>;
    final total = breaks.fold<double>(
      0,
      (value, item) =>
          value +
          (item['end_seconds'] as num).toDouble() -
          (item['start_seconds'] as num).toDouble(),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Break report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy report JSON',
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: const JsonEncoder.withIndent('  ').convert(report),
                ),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Report JSON copied. Save it as a .json file for your records.',
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (report['is_demo'] != true)
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      setState(() => saving = true);
                      try {
                        await publishReport(context, report);
                      } finally {
                        if (mounted) setState(() => saving = false);
                      }
                    },
              icon: const Icon(Icons.cloud_upload),
              label: const Text('Publish to GitHub dashboard'),
            ),
          if (report['is_demo'] == true)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'SAMPLE DATA · Invented for demonstration. These are not Gamin4Hope’s actual breaks.',
                ),
              ),
            ),
          Text(
            report['title'] as String,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            '${breaks.length} breaks · ${timeLabel(total)} away · ${breaks.isEmpty ? '0:00:00' : timeLabel(total / breaks.length)} average',
          ),
          const SizedBox(height: 12),
          for (final warning in (report['warnings'] as List<dynamic>? ?? []))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '$warning',
                style: const TextStyle(color: Colors.amber),
              ),
            ),
          for (var index = 0; index < breaks.length; index++)
            _breakCard(breaks[index] as Map<String, dynamic>, index),
          if (breaks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No BRB screens detected. Short breaks or alternate screen designs may need different detector settings.',
              ),
            ),
        ],
      ),
    );
  }

  Widget _breakCard(Map<String, dynamic> item, int index) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${timeLabel(item['start_seconds'] as num)} → ${timeLabel(item['end_seconds'] as num)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            '${timeLabel((item['end_seconds'] as num) - (item['start_seconds'] as num))} away${item['truncated'] == true ? ' · still BRB at end of video' : ''}',
          ),
          const SizedBox(height: 10),
          Text(
            (item['evidence'] as String).isEmpty
                ? 'No preceding transcript available.'
                : '“${item['evidence']}”',
          ),
          Text(
            'Suggested: ${item['suggested_reason']} · ${item['reviewed'] == true ? 'Reviewed' : 'Needs review'}',
            style: const TextStyle(color: Colors.grey),
          ),
          DropdownButton<String>(
            value: item['reason'] as String,
            isExpanded: true,
            items: reasons
                .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                .toList(),
            onChanged: widget.api == null || saving
                ? null
                : (value) {
                    if (value != null) review(index, value);
                  },
          ),
          if (report['video_id'] != null)
            TextButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Watch at timestamp'),
              onPressed: () async {
                try {
                  final uri = Uri.https('www.youtube.com', '/watch', {
                    'v': report['video_id'] as String,
                    't': '${(item['start_seconds'] as num).floor()}s',
                  });
                  if (!await launchUrl(
                    uri,
                    mode: LaunchMode.externalApplication,
                  )) {
                    throw Exception('Could not open YouTube');
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$e')));
                  }
                }
              },
            ),
        ],
      ),
    ),
  );
}
