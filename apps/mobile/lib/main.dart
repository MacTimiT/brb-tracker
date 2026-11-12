import 'job_progress.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'local_api.dart';
import 'publishing_ui.dart';
import 'report_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'BRB Tracker Android',
      'youtubedl-android',
    ], await rootBundle.loadString('assets/licenses/GPL-3.0.txt'));
    yield LicenseEntryWithLineBreaks([
      'Tesseract4Android',
      'tessdata_fast',
    ], await rootBundle.loadString('assets/licenses/Apache-2.0.txt'));
  });
  runApp(const BrbApp());
}

class BrbApp extends StatelessWidget {
  const BrbApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BRB Tracker',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xFFB7F36B),
      scaffoldBackgroundColor: const Color(0xFF101513),
      useMaterial3: true,
    ),
    home: const Home(),
  );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final api = LocalApi();
  final url = TextEditingController(
    text: 'https://www.youtube.com/live/IW2rEIuKGSs',
  );
  Map<String, String>? video;
  Map<String, String>? transcript;
  double interval = 2;
  String detectorProfile = 'gamin4hope';
  List<dynamic> jobs = [];
  bool busy = false;
  bool refreshing = false;
  String? error;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    url.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    timer?.cancel();
    if (state == AppLifecycleState.resumed) {
      refresh();
      startPolling();
    }
  }

  void startPolling() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final result = await api.list();
      if (mounted) {
        setState(() {
          jobs = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Could not read phone analyses: $e');
    } finally {
      refreshing = false;
    }
  }

  Future<void> pick(String kind) async {
    try {
      final value = await api.pick(kind);
      if (value != null && mounted) {
        setState(() {
          if (kind == 'video') {
            video = value;
            url.clear();
          } else {
            transcript = value;
          }
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> start() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.start({
        'url': url.text.trim(),
        'interval': interval,
        'detector_profile': detectorProfile,
        if (video != null) 'video_uri': video!['uri'],
        'title': video?['name'] ?? 'YouTube VOD',
        if (transcript != null) 'transcript_uri': transcript!['uri'],
      });
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> demo() async {
    final report = jsonDecode(
      await rootBundle.loadString('assets/demo-report.json'),
    ) as Map<String, dynamic>;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReportScreen(initial: report)),
    );
  }

  Future<void> openJob(Map<String, dynamic> job) async {
    try {
      final details = await api.get(job['id'] as String);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReportScreen(
            initial: details['report'] as Map<String, dynamic>,
            api: api,
            jobId: job['id'] as String,
          ),
        ),
      );
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> cancel(String id) async {
    try {
      await api.cancel(id);
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> remove(String id) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete local analysis?'),
        content: const Text(
          'This removes its saved report from this phone. Published GitHub reports will remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (answer != true) return;
    try {
      await api.delete(id);
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = jobs.any(
      (job) => job['status'] == 'running' || job['status'] == 'queued',
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('BRB Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: 'GitHub publishing settings',
            onPressed: () => showPublishingSettings(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh local analyses',
            onPressed: refresh,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'licenses') {
                showLicensePage(
                  context: context,
                  applicationName: 'BRB Tracker',
                  applicationVersion: '0.2.2',
                );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'licenses',
                child: Text('Open-source licenses'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Your phone. The whole pipeline.',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Download a VOD, scan BRB screens and classify breaks locally. Review the results, then publish them to your GitHub dashboard.',
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: demo,
            icon: const Icon(Icons.insights),
            label: const Text('Explore sample report'),
          ),
          const SizedBox(height: 24),
          const Text(
            'ANALYZE ON THIS PHONE',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: video == null
                  ? 'YouTube VOD URL'
                  : 'YouTube source URL (optional)',
              helperText: video == null
                  ? 'Downloads a low-resolution MP4 and available English captions.'
                  : 'Used for timestamp links when valid; the selected file is analyzed.',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy || running ? null : () => pick('video'),
            icon: const Icon(Icons.video_file_outlined),
            label: Text(video?['name'] ?? 'Or choose a video on this phone'),
          ),
          if (video != null)
            TextButton(
              onPressed: () => setState(() => video = null),
              child: const Text('Use YouTube download instead'),
            ),
          OutlinedButton.icon(
            onPressed: busy || running ? null : () => pick('transcript'),
            icon: const Icon(Icons.subtitles_outlined),
            label: Text(
              transcript?['name'] ?? 'Optional transcript · JSON / VTT',
            ),
          ),
          if (transcript != null)
            TextButton(
              onPressed: () => setState(() => transcript = null),
              child: const Text('Clear transcript'),
            ),
          DropdownButtonFormField<String>(
            initialValue: detectorProfile,
            decoration: const InputDecoration(labelText: 'BRB detection mode'),
            items: const [
              DropdownMenuItem(
                value: 'gamin4hope',
                child: Text('Gamin4Hope banner'),
              ),
              DropdownMenuItem(
                value: 'full_frame',
                child: Text('Full frame · other layouts'),
              ),
            ],
            onChanged: busy || running
                ? null
                : (value) => setState(() => detectorProfile = value!),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              detectorProfile == 'gamin4hope'
                  ? 'Looks for the red bottom-left BRB banner and excludes the right-side chat.'
                  : 'Reads the whole frame. Use when the BRB banner has moved or changed color.',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          Row(
            children: [
              const Expanded(child: Text('Sample a frame every')),
              DropdownButton<double>(
                value: interval,
                items: [2.0, 5.0, 10.0]
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text('${v.toInt()} seconds'),
                      ),
                    )
                    .toList(),
                onChanged: busy || running
                    ? null
                    : (value) => setState(() => interval = value!),
              ),
            ],
          ),
          const Text(
            'Long VODs can use several GB and take a long time. Use Wi-Fi and a charger. Reasons need captions or an imported transcript; speech-to-text is not bundled.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy || running ? null : start,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              running
                  ? jobStage(
                      jobs.firstWhere(
                        (job) =>
                            job['status'] == 'running' ||
                            job['status'] == 'queued',
                      ),
                    )
                  : 'Analyze locally',
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          const SizedBox(height: 24),
          const Text(
            'SAVED ON THIS PHONE',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          if (jobs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No analyses yet. Start one above.'),
            ),
          for (final raw in jobs) _job(raw as Map<String, dynamic>),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: () => launchUrl(
              Uri.https('mactimit.github.io', '/brb-tracker/'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open GitHub dashboard'),
          ),
          const Text(
            'Videos and OCR stay on this device. Nothing is published until you choose Publish in a completed report. Android can stop long-running work; interrupted analyses must be started again.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _job(Map<String, dynamic> job) {
    final active = job['status'] == 'running' || job['status'] == 'queued';
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text(
              job['title'] as String? ?? 'VOD',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${jobStage(job)}${jobFraction(job) == null ? '' : ' · ${(jobFraction(job)! * 100).round()}%'}${job['error'] == null ? '' : '\n${job['error']}'}',
            ),
            onTap: job['status'] == 'completed' ? () => openJob(job) : null,
            trailing: active
                ? IconButton(
                    onPressed: () => cancel(job['id'] as String),
                    icon: const Icon(Icons.stop_circle_outlined),
                    tooltip: 'Cancel local analysis',
                  )
                : IconButton(
                    onPressed: () => remove(job['id'] as String),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete local analysis',
                  ),
          ),
          if (active) LinearProgressIndicator(value: jobFraction(job)),
        ],
      ),
    );
  }
}
