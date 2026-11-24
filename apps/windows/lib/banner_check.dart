import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'desktop_worker.dart';

double? parseTimestamp(String input) {
  final fields = input.trim().split(':');
  if (fields.length > 3) return null;
  var seconds = 0.0;
  for (final (index, field) in fields.indexed) {
    final part = double.tryParse(field);
    if (part == null ||
        !part.isFinite ||
        part < 0 ||
        (index > 0 && part >= 60) ||
        (index < fields.length - 1 && part != part.truncateToDouble())) {
      return null;
    }
    seconds = 60 * seconds + part;
  }
  return seconds.isFinite ? seconds : null;
}

class BannerCheckPage extends StatefulWidget {
  const BannerCheckPage({
    super.key,
    required this.worker,
    required this.profile,
  });

  final DesktopWorker worker;
  final String profile;

  @override
  State<BannerCheckPage> createState() => _BannerCheckPageState();
}

class _BannerCheckPageState extends State<BannerCheckPage> {
  final timestamp = TextEditingController(text: '0:00');
  WorkerSession? session;
  WorkerEvent? result;
  String? error;
  bool busy = false;

  @override
  void dispose() {
    timestamp.dispose();
    if (session case final WorkerSession active) unawaited(active.cancel());
    super.dispose();
  }

  Future<void> check({required bool video}) async {
    final seconds = video ? parseTimestamp(timestamp.text) : null;
    if (video && seconds == null) {
      setState(() => error = 'Enter seconds or a timestamp such as 1:43:55.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: video ? 'Video' : 'Screenshot',
            extensions: video
                ? ['mp4', 'mkv', 'webm', 'mov']
                : ['png', 'jpg', 'jpeg', 'webp'],
          ),
        ],
      );
      if (!mounted || file == null) return;
      final worker = await widget.worker.scan([
        '--check-banner',
        file.path,
        '--profile',
        widget.profile,
        if (seconds != null) ...['--frame-at', '$seconds'],
      ]);
      if (!mounted) {
        await worker.cancel();
        return;
      }
      session = worker;
      WorkerEvent? banner;
      String? workerError;
      await for (final event in worker.events) {
        if (event['event'] == 'banner') banner = event;
        if (event['event'] == 'error') {
          workerError = event['message'] as String?;
        }
      }
      if (await worker.exitCode != 0 || banner == null) {
        throw StateError(workerError ?? 'The banner check failed.');
      }
      if (mounted) setState(() => result = banner);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      session = null;
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final banner = result;
    return Scaffold(
      appBar: AppBar(title: const Text('BRB banner check')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Banner profile · ${widget.profile == 'full_frame' ? 'Full frame' : 'Gamin4Hope'}',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => check(video: false),
                child: const Text('Check a screenshot'),
              ),
              SizedBox(
                width: 184,
                child: TextField(
                  controller: timestamp,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Video timestamp',
                  ),
                ),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => check(video: true),
                child: const Text('Check a local video frame'),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error case final String message) Text(message),
          if (banner != null) ...[
            const SizedBox(height: 20),
            Text(
              '${banner['width']} × ${banner['height']} · ${banner['matched'] == true ? 'Banner matched' : 'No banner match'}',
            ),
            if (banner['mask'] case final String mask when mask.isNotEmpty)
              Image.memory(
                base64Decode(mask),
                alignment: Alignment.centerLeft,
                fit: BoxFit.scaleDown,
              ),
            SelectableText(
              (banner['text'] as String).isEmpty
                  ? 'No OCR text'
                  : banner['text'] as String,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  final details = Map.of(banner)
                    ..remove('mask')
                    ..remove('event');
                  await Clipboard.setData(
                    ClipboardData(text: jsonEncode(details)),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Banner details copied')),
                    );
                  }
                },
                child: const Text('Copy banner details'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
