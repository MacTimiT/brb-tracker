import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:brb_client/github_publisher.dart';
import 'package:brb_client/publishing_ui.dart';
import 'package:brb_client/stream_catalog.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'desktop_worker.dart';
import 'queue_view.dart';
import 'report_page.dart';
import 'scan_queue.dart';

void main() => runApp(const BrbTracker());

class BrbTracker extends StatelessWidget {
  const BrbTracker({super.key, this.stateDirectory});

  final Directory? stateDirectory;

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
    home: ScanPage(stateDirectory: stateDirectory),
  );
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key, this.stateDirectory});

  final Directory? stateDirectory;

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
  late final ScanQueue queue;
  late final DesktopArchive archive;
  int tab = 1;
  bool archiveOpened = false;

  @override
  void initState() {
    super.initState();
    final directory =
        widget.stateDirectory ??
        Directory(
          '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}${Platform.pathSeparator}BRB Tracker',
        );
    final worker = DesktopWorker();
    queue = ScanQueue(
      File('${directory.path}${Platform.pathSeparator}scan-queue.json'),
      worker.scan,
    )..load();
    archive = DesktopArchive(
      File('${directory.path}${Platform.pathSeparator}streams.json'),
      worker,
    );
    lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await queue.close();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    lifecycle.dispose();
    queue.dispose();
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
      if (!mounted || file == null) return;
      setState(() {
        if (captions) {
          transcript = file;
        } else {
          video = file;
        }
      });
    } on Exception catch (e) {
      showError(e);
    }
  }

  Future<void> chooseOutput() async {
    try {
      final path = await getDirectoryPath();
      if (mounted && path != null) output.text = path;
    } on Exception catch (e) {
      showError(e);
    }
  }

  double? get speedLimit =>
      double.tryParse(limit.text.trim().replaceAll(',', '.'));

  void showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.toString())));
  }

  void start() {
    if (!form.currentState!.validate()) return;
    final link = url.text.trim();
    final id = youtubeVideoId(link);
    if (link.isNotEmpty && id == null) {
      showError('Enter a valid HTTPS YouTube VOD link.');
      return;
    }
    enqueue(
      title: video?.name ?? 'YouTube VOD',
      link: link,
      id: id,
      localVideo: video?.path,
      localTranscript: transcript?.path,
    );
  }

  Future<void> queueStream(String id, String title) async {
    enqueue(title: title, id: id, link: 'https://www.youtube.com/watch?v=$id');
  }

  void enqueue({
    required String title,
    required String link,
    required String? id,
    String? localVideo,
    String? localTranscript,
  }) {
    final cap = localVideo == null ? speedLimit : 0.0;
    if (cap == null || !validCap(cap) || output.text.trim().isEmpty) {
      showError('Set a valid download cap and output folder in Scan options.');
      return;
    }
    try {
      queue.add(
        title: title,
        videoId: id,
        output: output.text.trim(),
        arguments: [
          if (link.isNotEmpty) ...['--url', link],
          if (localVideo != null) ...['--video', localVideo],
          if (localTranscript != null) ...['--transcript', localTranscript],
          if (localVideo != null || title != 'YouTube VOD') ...[
            '--title',
            title,
          ],
          '--profile',
          profile,
          '--interval',
          '$interval',
          '--height',
          '$height',
          '--limit-mbps',
          '$cap',
        ],
      );
      if (tab == 1) setState(() => tab = 2);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Added to the scan queue')));
    } catch (error) {
      showError(error);
    }
  }

  bool validCap(double cap) =>
      cap.isFinite && (cap == 0 || (cap >= .1 && cap <= 10000));

  Future<void> openReport(String folder) =>
      readReport(File('$folder${Platform.pathSeparator}report.json'));

  Future<void> chooseReport() async {
    try {
      final result = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'BRB report', extensions: ['json']),
        ],
      );
      if (result != null) await readReport(File(result.path));
    } catch (error) {
      showError(error);
    }
  }

  Future<void> readReport(File file) async {
    try {
      final report =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      GitHubPublisher.validate(report);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReportPage(file: file, report: report),
        ),
      );
    } catch (error) {
      showError(error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: queue,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('BRB Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Open saved report',
            onPressed: chooseReport,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'GitHub publishing settings',
            onPressed: () => showPublishingSettings(context),
          ),
        ],
      ),
      body: IndexedStack(
        index: tab,
        children: [
          if (archiveOpened)
            StreamCatalog(
              api: archive,
              showRefreshButton: true,
              completed: queue.completed,
              openReport: openReport,
              queued: queue.queued,
              queueStream: queue.ready && queue.storageError == null
                  ? queueStream
                  : null,
            )
          else
            const SizedBox.shrink(),
          scanOptions(context),
          QueueView(queue: queue, openReport: openReport, showError: showError),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() {
          tab = value;
          if (value == 0) archiveOpened = true;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            label: 'VODs',
          ),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Scan options'),
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            label: 'Scans',
          ),
        ],
      ),
    ),
  );

  Widget scanOptions(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Scan options',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 6),
              const Text('Scan a VOD for BRB screens and save a local report.'),
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

                          decoration: InputDecoration(
                            labelText: video == null
                                ? 'YouTube VOD link'
                                : 'YouTube source link (optional)',
                          ),
                          validator: (value) =>
                              video == null && (value ?? '').trim().isEmpty
                              ? 'Paste a link or choose a local video.'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () => chooseFile(captions: false),
                              icon: const Icon(Icons.video_file_outlined),
                              label: Text(video?.name ?? 'Choose local video'),
                            ),
                            if (video != null)
                              TextButton(
                                onPressed: () => setState(() => video = null),
                                child: const Text('Clear video'),
                              ),
                            OutlinedButton.icon(
                              onPressed: () => chooseFile(captions: true),
                              icon: const Icon(Icons.subtitles_outlined),
                              label: Text(
                                transcript?.name ?? 'Choose transcript',
                              ),
                            ),
                            if (transcript != null)
                              TextButton(
                                onPressed: () =>
                                    setState(() => transcript = null),
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
                                enabled: video == null,
                                decoration: const InputDecoration(
                                  labelText: 'Media download cap',
                                  suffixText: 'Mbps',
                                  helperText: '0 allows unlimited speed',
                                ),
                                validator: (_) {
                                  if (video != null) return null;
                                  final cap = speedLimit;
                                  return cap != null && validCap(cap)
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
                                  for (final value in [360, 480, 720, 1080])
                                    DropdownMenuItem(
                                      value: value,
                                      child: Text('${value}p'),
                                    ),
                                ],
                                onChanged: video != null
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
                                onChanged: (value) =>
                                    setState(() => interval = value!),
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
                                onChanged: (value) =>
                                    setState(() => profile = value!),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: output,

                          decoration: InputDecoration(
                            labelText: 'Save videos and reports in',
                            suffixIcon: IconButton(
                              onPressed: chooseOutput,
                              icon: const Icon(Icons.folder_open),
                              tooltip: 'Choose output folder',
                            ),
                          ),
                          validator: (value) => (value ?? '').trim().isEmpty
                              ? 'Choose an output folder.'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            onPressed: queue.ready && queue.storageError == null
                                ? start
                                : null,
                            icon: const Icon(Icons.play_arrow),
                            label: Text(
                              video == null
                                  ? 'Queue download and scan'
                                  : 'Queue local scan',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}
