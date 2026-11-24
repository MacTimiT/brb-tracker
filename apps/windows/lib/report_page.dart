import 'dart:convert';
import 'dart:io';

import 'package:brb_client/github_publisher.dart';
import 'package:brb_client/publishing_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'scan_queue.dart';

class ReportPage extends StatefulWidget {
  const ReportPage({super.key, required this.file, required this.report});

  final File file;
  final Map<String, dynamic> report;

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  bool publishing = false;

  Future<void> publish() async {
    setState(() => publishing = true);
    try {
      await publishReport(context, widget.report);
    } catch (error) {
      if (mounted) showError(error);
    } finally {
      if (mounted) setState(() => publishing = false);
    }
  }

  void showError(Object error) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> review(int index, Map<String, dynamic> item) async {
    final reviewed = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ReasonEditor(item: item),
    );
    if (!mounted || reviewed == null) return;
    final breaks = List<dynamic>.of(widget.report['breaks'] as List)
      ..[index] = reviewed;
    final updated = {...widget.report, 'breaks': breaks};
    try {
      GitHubPublisher.validate(updated);
      final temp = File('${widget.file.path}.tmp');
      temp.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(updated)}\n',
        flush: true,
      );
      temp.renameSync(widget.file.path);
      setState(() => widget.report['breaks'] = breaks);
    } catch (error) {
      showError(error);
    }
  }

  Future<void> watch(Uri link) async {
    try {
      if (!await launchUrl(link, mode: LaunchMode.externalApplication)) {
        throw StateError('Windows could not open the browser.');
      }
    } catch (error) {
      if (mounted) showError(error);
    }
  }

  Future<void> copy(String text, String message) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (error) {
      if (mounted) showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final breaks = (report['breaks'] as List).cast<Map<String, dynamic>>();
    final timeAway = breaks.fold<num>(
      0,
      (total, item) =>
          total + (item['end_seconds'] as num) - (item['start_seconds'] as num),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Break report'),
        actions: [
          IconButton(
            tooltip: 'Copy report JSON',
            icon: const Icon(Icons.copy),
            onPressed: () => copy(
              const JsonEncoder.withIndent('  ').convert(report),
              'Report copied',
            ),
          ),
          IconButton(
            tooltip: 'GitHub publishing settings',
            onPressed: publishing
                ? null
                : () => showPublishingSettings(context),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            report['title'] as String,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '${breaks.length} breaks · ${stamp(timeAway)} away · ${stamp(breaks.isEmpty ? 0 : timeAway / breaks.length)} average',
          ),
          if (report['vod_date'] case final String date)
            Text('VOD date · $date'),
          if (report['is_demo'] == true) const Text('Sample report'),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: publishing || report['is_demo'] == true
                  ? null
                  : publish,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text(publishing ? 'Publishing…' : 'Publish to dashboard'),
            ),
          ),
          ExpansionTile(
            title: const Text('Scan details'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Stream length · ${stamp(report['duration_seconds'] as num)}',
              ),
              if (report['sample_interval_seconds'] case final num interval)
                Text('Sample interval · ${interval}s'),
              if (report['frames_checked'] case final num frames)
                Text('Frames checked · $frames'),
              if (report['transcript_source'] case final String source)
                Text('Transcript · $source'),
              for (final warning in report['warnings'] as List? ?? const [])
                Text(warning.toString()),
            ],
          ),
          const SizedBox(height: 12),
          if (breaks.isEmpty) const Text('No BRB screens detected.'),
          for (final (index, item) in breaks.indexed)
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${stamp(item['start_seconds'] as num)} – ${stamp(item['end_seconds'] as num)}',
                      ),
                      subtitle: Text(
                        [
                          item['reason'],
                          ...(item['additional_reasons'] as List? ?? const []),
                          if ((item['evidence'] as String).isNotEmpty)
                            '\n${item['evidence']}',
                        ].join(' · '),
                      ),
                      trailing: IconButton(
                        onPressed: publishing
                            ? null
                            : () => review(index, item),
                        tooltip: 'Edit reasons',
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ),
                    if (youtubeWatchAt(report, item['start_seconds'] as num)
                        case final Uri link)
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: () => watch(link),
                            icon: const Icon(Icons.play_circle_outline),
                            label: const Text('Watch at timestamp'),
                          ),
                          IconButton(
                            onPressed: () =>
                                copy(link.toString(), 'Timestamp link copied'),
                            tooltip: 'Copy timestamp link',
                            icon: const Icon(Icons.link),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          SelectableText(widget.file.path),
        ],
      ),
    );
  }
}

String stamp(num value) {
  final seconds = value.round();
  String padded(int number) => number.toString().padLeft(2, '0');
  return '${seconds ~/ 3600}:${padded(seconds ~/ 60 % 60)}:${padded(seconds % 60)}';
}

class _ReasonEditor extends StatefulWidget {
  const _ReasonEditor({required this.item});
  final Map<String, dynamic> item;

  @override
  State<_ReasonEditor> createState() => _ReasonEditorState();
}

class _ReasonEditorState extends State<_ReasonEditor> {
  late String primary = widget.item['reason'] as String;
  late final extra = (widget.item['additional_reasons'] as List? ?? const [])
      .cast<String>()
      .toSet();

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Edit break reasons'),
    content: SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: primary,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Primary reason'),
            items: [
              for (final value in GitHubPublisher.reasons)
                DropdownMenuItem(value: value, child: Text(value)),
            ],
            onChanged: (value) => setState(() {
              primary = value!;
              extra.remove(primary);
              if (primary == 'Unknown') extra.clear();
            }),
          ),
          if (primary != 'Unknown') ...[
            const SizedBox(height: 12),
            const Text('Additional reasons'),
            for (final reason in GitHubPublisher.reasons)
              if (reason != 'Unknown' && reason != primary)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(reason),
                  value: extra.contains(reason),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      extra.add(reason);
                    } else {
                      extra.remove(reason);
                    }
                  }),
                ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          ...widget.item,
          'reason': primary,
          'additional_reasons': extra.toList(),
          'reviewed': true,
          'confidence': 'manual',
        }),
        child: const Text('Save reasons'),
      ),
    ],
  );
}
