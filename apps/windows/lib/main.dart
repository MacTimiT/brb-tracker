import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

void main() => runApp(const BrbTracker());

class BrbTracker extends StatelessWidget {
  const BrbTracker({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BRB Tracker',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffaf2028)),
      scaffoldBackgroundColor: const Color(0xfff5f0e8),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
      ),
    ),
    home: const ScanPage(),
  );
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final form = GlobalKey<FormState>();
  final url = TextEditingController();
  final limit = TextEditingController(text: '5');
  final output = TextEditingController(
    text:
        '${Platform.environment['USERPROFILE'] ?? Directory.current.path}\\Documents\\BRB Tracker',
  );
  late final AppLifecycleListener lifecycle;
  XFile? video;
  XFile? transcript;
  int height = 480;
  int interval = 2;
  String profile = 'gamin4hope';
  Process? worker;
  bool busy = false;
  bool cancelled = false;
  String phase = '';
  String? error;
  String? reportPath;
  Map<String, dynamic>? report;
  double? fraction;
  double? speed;
  int? bytes;

  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (busy) {
          await stop();
          return AppExitResponse.cancel;
        }
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    lifecycle.dispose();
    url.dispose();
    limit.dispose();
    output.dispose();
    super.dispose();
  }

  Future<void> chooseFile({required bool captions}) async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: captions ? 'Transcripts' : 'Videos',
            extensions: captions
                ? ['vtt', 'json3', 'json']
                : ['mp4', 'mkv', 'webm', 'mov'],
          ),
        ],
      );
      if (!mounted || file == null || busy) return;
      setState(() {
        if (captions) {
          transcript = file;
        } else {
          video = file;
        }
      });
    } on Exception catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> chooseOutput() async {
    try {
      final path = await getDirectoryPath();
      if (mounted && path != null && !busy) output.text = path;
    } on Exception catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  double? get speedLimit =>
      double.tryParse(limit.text.trim().replaceAll(',', '.'));

  Future<void> start() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      cancelled = false;
      phase = 'Preparing the scan';
      error = null;
      report = null;
      reportPath = null;
      fraction = null;
      speed = null;
      bytes = null;
    });

    try {
      final root = await Directory(output.text.trim()).create(recursive: true);
      final scan = await root.createTemp('Scan-');
      final app = File(Platform.resolvedExecutable).parent.path;
      final process = await Process.start('$app\\worker\\brb-worker.exe', [
        '--runtime',
        '$app\\tools',
        '--output',
        scan.path,
        if (video != null) ...['--video', video!.path],
        if (url.text.trim().isNotEmpty) ...['--url', url.text.trim()],
        if (transcript != null) ...['--transcript', transcript!.path],
        '--profile',
        profile,
        '--interval',
        '$interval',
        '--height',
        '$height',
        '--limit-mbps',
        video == null ? '$speedLimit' : '0',
      ], runInShell: false);
      worker = process;
      String lastError = '';
      final logs = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) => lastError = line);
      final events = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach(onEvent);
      if (cancelled) await terminate(process);
      final exitCode = await process.exitCode;
      await Future.wait([logs, events]);
      if (!mounted) return;
      if (!cancelled && report == null && error == null) {
        error = lastError.isEmpty
            ? 'The scan worker exited with code $exitCode.'
            : lastError;
      }
    } on Exception catch (e) {
      if (mounted && !cancelled) error = 'Could not run the scan. $e';
    } finally {
      worker = null;
      if (mounted) {
        setState(() {
          busy = false;
          phase = cancelled ? 'Scan cancelled' : phase;
        });
      }
    }
  }

  void onEvent(String line) {
    if (!mounted || cancelled) return;
    final Map<String, dynamic> event;
    try {
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) return;
      event = value;
    } on FormatException {
      return;
    }
    setState(() {
      switch (event['event']) {
        case 'progress':
          phase = event['phase'] as String;
          fraction = (event['fraction'] as num?)?.toDouble().clamp(0, 1);
          speed = (event['speed'] as num?)?.toDouble();
          bytes = (event['bytes'] as num?)?.toInt();
        case 'complete':
          reportPath = event['path'] as String;
          report = event['report'] as Map<String, dynamic>;
          phase = 'Scan complete';
          fraction = 1;
        case 'error':
          error = event['message'] as String;
          phase = 'Scan failed';
      }
    });
  }

  Future<void> terminate(Process process) async {
    try {
      final result = await Process.run('taskkill.exe', [
        '/PID',
        '${process.pid}',
        '/T',
        '/F',
      ]);
      if (result.exitCode != 0) process.kill();
    } on ProcessException {
      process.kill();
    }
  }

  Future<void> stop() async {
    if (!busy || cancelled) return;
    setState(() {
      cancelled = true;
      phase = 'Cancelling scan';
    });
    if (worker case final Process process) await terminate(process);
  }

  Future<void> openReportFolder() async {
    try {
      await Process.start('explorer.exe', [
        File(reportPath!).parent.path,
      ], mode: ProcessStartMode.detached);
    } on ProcessException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  String duration(num value) {
    final seconds = value.round();
    String padded(int number) => number.toString().padLeft(2, '0');
    return '${seconds ~/ 3600}:${padded(seconds ~/ 60 % 60)}:${padded(seconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final completed = report;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'BRB Tracker',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Scan a VOD for BRB screens and save a local report.',
                    ),
                    const SizedBox(height: 20),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Form(
                          key: form,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextFormField(
                                controller: url,
                                enabled: !busy,
                                decoration: InputDecoration(
                                  labelText: video == null
                                      ? 'YouTube VOD link'
                                      : 'YouTube source link (optional)',
                                ),
                                validator: (value) =>
                                    video == null &&
                                        (value ?? '').trim().isEmpty
                                    ? 'Paste a link or choose a local video.'
                                    : null,
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => chooseFile(captions: false),
                                    icon: const Icon(Icons.video_file_outlined),
                                    label: Text(
                                      video?.name ?? 'Choose local video',
                                    ),
                                  ),
                                  if (video != null)
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => setState(() => video = null),
                                      child: const Text('Clear video'),
                                    ),
                                  OutlinedButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => chooseFile(captions: true),
                                    icon: const Icon(Icons.subtitles_outlined),
                                    label: Text(
                                      transcript?.name ?? 'Choose transcript',
                                    ),
                                  ),
                                  if (transcript != null)
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => setState(
                                              () => transcript = null,
                                            ),
                                      child: const Text('Clear transcript'),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  SizedBox(
                                    width: 204,
                                    child: TextFormField(
                                      controller: limit,
                                      enabled: !busy && video == null,
                                      decoration: const InputDecoration(
                                        labelText: 'Media download cap',
                                        suffixText: 'Mbps',
                                        helperText: '0 allows unlimited speed',
                                      ),
                                      validator: (_) {
                                        if (video != null) return null;
                                        final cap = speedLimit;
                                        return cap != null &&
                                                cap.isFinite &&
                                                (cap == 0 ||
                                                    (cap >= .1 && cap <= 10000))
                                            ? null
                                            : 'Use 0 or 0.1–10,000';
                                      },
                                    ),
                                  ),
                                  SizedBox(
                                    width: 160,
                                    child: DropdownButtonFormField<int>(
                                      initialValue: height,
                                      isExpanded: true,
                                      decoration: const InputDecoration(
                                        labelText: 'Max quality',
                                      ),
                                      items: [
                                        for (final value in [
                                          360,
                                          480,
                                          720,
                                          1080,
                                        ])
                                          DropdownMenuItem(
                                            value: value,
                                            child: Text('${value}p'),
                                          ),
                                      ],
                                      onChanged: busy || video != null
                                          ? null
                                          : (value) =>
                                                setState(() => height = value!),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 160,
                                    child: DropdownButtonFormField<int>(
                                      initialValue: interval,
                                      isExpanded: true,
                                      decoration: const InputDecoration(
                                        labelText: 'Sample every',
                                      ),
                                      items: const [
                                        DropdownMenuItem(
                                          value: 2,
                                          child: Text(
                                            '2 seconds',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: 5,
                                          child: Text(
                                            '5 seconds',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                      onChanged: busy
                                          ? null
                                          : (value) => setState(
                                              () => interval = value!,
                                            ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 185,
                                    child: DropdownButtonFormField<String>(
                                      initialValue: profile,
                                      isExpanded: true,
                                      decoration: const InputDecoration(
                                        labelText: 'Banner profile',
                                      ),
                                      items: const [
                                        DropdownMenuItem(
                                          value: 'gamin4hope',
                                          child: Text(
                                            'Gamin4Hope',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: 'full_frame',
                                          child: Text(
                                            'Full frame',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                      onChanged: busy
                                          ? null
                                          : (value) => setState(
                                              () => profile = value!,
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: output,
                                enabled: !busy,
                                decoration: InputDecoration(
                                  labelText: 'Save videos and reports in',
                                  suffixIcon: IconButton(
                                    onPressed: busy ? null : chooseOutput,
                                    icon: const Icon(Icons.folder_open),
                                    tooltip: 'Choose output folder',
                                  ),
                                ),
                                validator: (value) =>
                                    (value ?? '').trim().isEmpty
                                    ? 'Choose an output folder.'
                                    : null,
                              ),
                              const SizedBox(height: 16),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FilledButton.icon(
                                  onPressed: busy ? null : start,
                                  icon: const Icon(Icons.play_arrow),
                                  label: Text(
                                    video == null
                                        ? 'Download and scan'
                                        : 'Scan local video',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (busy || phase.isNotEmpty || error != null)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                phase,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              if (busy) ...[
                                const SizedBox(height: 8),
                                LinearProgressIndicator(value: fraction),
                                const SizedBox(height: 6),
                                Text(
                                  [
                                    if (fraction != null)
                                      '${(100 * fraction!).floor()}%',
                                    if (bytes != null)
                                      '${(bytes! / 1000000).toStringAsFixed(1)} MB',
                                    if (speed != null)
                                      '${(speed! * 8 / 1000000).toStringAsFixed(1)} Mbps',
                                  ].join(' · '),
                                ),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton(
                                    onPressed: cancelled ? null : stop,
                                    child: const Text('Cancel'),
                                  ),
                                ),
                              ],
                              if (error case final String message)
                                SelectableText(
                                  message,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (completed != null) ...[
                      const SizedBox(height: 12),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                completed['title'] as String,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text(
                                '${(completed['breaks'] as List).length} breaks found',
                              ),
                              for (final warning
                                  in completed['warnings'] as List)
                                Text(warning.toString()),
                              const SizedBox(height: 10),
                              SelectableText(reportPath!),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: OutlinedButton.icon(
                                  onPressed: openReportFolder,
                                  icon: const Icon(Icons.folder_open),
                                  label: const Text('Open results folder'),
                                ),
                              ),
                              for (final item in completed['breaks'] as List)
                                ListTile(
                                  title: Text(
                                    '${duration(item['start_seconds'] as num)} – ${duration(item['end_seconds'] as num)}',
                                  ),
                                  subtitle: Text(
                                    '${item['reason']}${item['evidence'] == '' ? '' : ' · ${item['evidence']}'}',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
