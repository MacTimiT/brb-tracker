import 'job_progress.dart';

import 'dart:async';

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
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFBC2028),
        brightness: Brightness.light,
        primary: const Color(0xFFBC2028),
        surface: const Color(0xFFF5F2EB),
      ),
      scaffoldBackgroundColor: const Color(0xFFF5F2EB),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF252B2E),
        foregroundColor: Color(0xFFF5F2EB),
        titleTextStyle: TextStyle(fontFamily: 'Barlow', fontSize: 28),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.zero),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        color: Color(0xFFFFFDFA),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Color(0xFFD8D4CB)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const RoundedRectangleBorder(),
          minimumSize: const Size(0, 52),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const RoundedRectangleBorder(),
          minimumSize: const Size(0, 48),
        ),
      ),
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
  final url = TextEditingController();
  Map<String, String>? video;
  Map<String, String>? transcript;
  bool fastScan = true;
  bool speechFallback = true;
  int downloadHeight = 480;
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
        'interval': fastScan ? 5.0 : 2.0,
        'adaptive_scan': fastScan,
        'speech_fallback': speechFallback,
        'download_height': downloadHeight,
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
        title: const Text('GONE4HOPE'),
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
                  applicationVersion: '0.4.0',
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
          Container(
            padding: const EdgeInsets.all(24),
            color: const Color(0xFF252B2E),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ADMIN / GAMIN4HOPE',
                  style: TextStyle(
                    fontFamily: 'Plex',
                    fontSize: 11,
                    color: Color(0xFFF5F2EB),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'NEW SCAN.',
                  style: TextStyle(
                    fontFamily: 'Barlow',
                    fontSize: 56,
                    height: 1,
                    color: Color(0xFFF5F2EB),
                  ),
                ),
                SizedBox(height: 12),
                SizedBox(
                  width: 48,
                  child: Divider(color: Color(0xFFBC2028), thickness: 4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: url,
            enabled: !busy && !running,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: video == null
                  ? 'YouTube VOD URL'
                  : 'YouTube source URL (optional)',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<bool>(
            isExpanded: true,
            initialValue: fastScan,
            decoration: const InputDecoration(labelText: 'Scan mode'),
            items: const [
              DropdownMenuItem(
                value: true,
                child: Text('Fast · 5s scan, 1s edges'),
              ),
              DropdownMenuItem(
                value: false,
                child: Text('Detailed · every 2s'),
              ),
            ],
            onChanged: busy || running
                ? null
                : (value) => setState(() => fastScan = value!),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: downloadHeight,
            decoration: const InputDecoration(labelText: 'Download quality'),
            items: const [
              DropdownMenuItem(
                value: 480,
                child: Text('480p · clearer banner'),
              ),
              DropdownMenuItem(
                value: 360,
                child: Text('360p · smaller download'),
              ),
            ],
            onChanged: busy || running || video != null
                ? null
                : (value) => setState(() => downloadHeight = value!),
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Transcribe speech when captions are missing'),
            subtitle: const Text(
              'Runs on this phone near detected breaks. First use downloads a 41 MB English model; YouTube VODs also need audio.',
            ),
            value: speechFallback,
            onChanged: busy || running
                ? null
                : (value) => setState(() => speechFallback = value),
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Files & detection settings'),
            children: [
              OutlinedButton.icon(
                onPressed: busy || running ? null : () => pick('video'),
                icon: const Icon(Icons.video_file_outlined),
                label: Text(video?['name'] ?? 'Choose local video'),
              ),
              if (video != null)
                TextButton(
                  onPressed: busy || running
                      ? null
                      : () => setState(() => video = null),
                  child: const Text('Use YouTube instead'),
                ),
              OutlinedButton.icon(
                onPressed: busy || running ? null : () => pick('transcript'),
                icon: const Icon(Icons.subtitles_outlined),
                label: Text(
                  transcript?['name'] ?? 'Choose transcript · optional',
                ),
              ),
              if (transcript != null)
                TextButton(
                  onPressed: busy || running
                      ? null
                      : () => setState(() => transcript = null),
                  child: const Text('Clear transcript'),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: detectorProfile,
                decoration: const InputDecoration(labelText: 'BRB banner'),
                items: const [
                  DropdownMenuItem(
                    value: 'gamin4hope',
                    child: Text('Gamin4Hope · red banner'),
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
              const SizedBox(height: 16),
            ],
          ),
          const SizedBox(height: 16),
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
                  : 'Scan VOD',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
            'SAVED SCANS',
            style: TextStyle(
              fontFamily: 'Plex',
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (jobs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No scans yet.'),
            ),
          for (final raw in jobs) _job(raw as Map<String, dynamic>),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: () => launchUrl(
              Uri.https('mactimit.github.io', '/brb-tracker/'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open dashboard'),
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
                    onPressed: jobStage(job) == 'Cancelling'
                        ? null
                        : () => cancel(job['id'] as String),
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
