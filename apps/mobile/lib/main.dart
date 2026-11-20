import 'banner_check.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'local_api.dart';
import 'publishing_ui.dart';
import 'report_screen.dart';
import 'stream_catalog.dart';
import 'scan_history.dart';

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
  bool autoDeleteVideo = false;
  int downloadHeight = 480;
  String detectorProfile = 'gamin4hope';
  List<Map<String, dynamic>> jobs = [];
  int tab = 0;
  bool settingsLoaded = false;
  bool busy = false;
  bool refreshing = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadSettings();
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
    timer = Timer.periodic(const Duration(seconds: 2), (tick) {
      if (tick.tick % 5 == 0 ||
          jobs.any(
            (job) => job['status'] == 'running' || job['status'] == 'queued',
          )) {
        refresh();
      }
    });
  }

  Map<String, dynamic> get settings => {
    'interval': fastScan ? 5.0 : 2.0,
    'adaptive_scan': fastScan,
    'speech_fallback': speechFallback,
    'auto_delete_video': autoDeleteVideo,
    'download_height': downloadHeight,
    'detector_profile': detectorProfile,
  };

  void message(String text) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> loadSettings() async {
    try {
      final saved = await api.scanSettings();
      if (!mounted) return;
      setState(() {
        fastScan = saved['adaptive_scan'] != false;
        speechFallback = saved['speech_fallback'] != false;
        autoDeleteVideo = saved['auto_delete_video'] == true;
        downloadHeight = saved['download_height'] == 360 ? 360 : 480;
        detectorProfile = saved['detector_profile'] == 'full_frame'
            ? 'full_frame'
            : 'gamin4hope';
      });
    } catch (error) {
      message('Could not load scan settings: $error');
    } finally {
      if (mounted) setState(() => settingsLoaded = true);
    }
  }

  Future<void> saveSettings(VoidCallback change) async {
    setState(change);
    try {
      await api.saveScanSettings(settings);
    } catch (error) {
      message('Could not save scan settings: $error');
    }
  }

  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final result = await api.list();
      if (mounted) setState(() => jobs = result.cast<Map<String, dynamic>>());
    } catch (error) {
      message('Could not read phone analyses: $error');
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
        });
      }
    } catch (error) {
      message('$error');
    }
  }

  Future<void> start({double? probeSeconds}) async {
    final link = url.text.trim();
    if (video == null && link.isEmpty) {
      message('Enter a YouTube VOD URL or choose a local video.');
      return;
    }
    await enqueue({
      ...settings,
      'url': link,
      'probe_seconds': ?probeSeconds,
      if (video != null) 'video_uri': video!['uri'],
      'title': video?['name'] ?? 'YouTube VOD',
      if (transcript != null) 'transcript_uri': transcript!['uri'],
    }, showScans: true);
  }

  Future<void> enqueue(
    Map<String, dynamic> input, {
    bool showScans = false,
  }) async {
    if (busy || !settingsLoaded) return;
    setState(() => busy = true);
    try {
      await api.start(input);
      if (mounted && showScans) setState(() => tab = 2);
      await refresh();
    } catch (error) {
      message('$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> queueStream(String id, String title) => enqueue({
    ...settings,
    'url': 'https://www.youtube.com/watch?v=$id',
    'title': title,
  });

  Future<void> checkScreenshot() async {
    setState(() => busy = true);
    try {
      final image = await api.pick('image');
      if (image == null) return;
      final result = await api.diagnoseBanner(image['uri']!);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => BannerCheck(result: result)),
      );
    } catch (e) {
      message('$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> checkVodFrame() async {
    var timestamp = '';
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Check a VOD frame'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Uses the selected video or YouTube URL. Downloads the video if needed, then checks only this timestamp instead of scanning the full VOD.',
            ),
            TextFormField(
              onChanged: (value) => timestamp = value,
              decoration: const InputDecoration(
                labelText: 'Timestamp · H:MM:SS',
                hintText: '0:12:34',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, timestamp),
            child: const Text('Check frame'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    final parts = value.trim().split(':');
    if (!RegExp(r'^\d{1,3}:[0-5]\d:[0-5]\d$').hasMatch(value.trim())) {
      message('Enter a timestamp such as 0:12:34.');
      return;
    }
    final seconds =
        int.parse(parts[0]) * 3600 +
        int.parse(parts[1]) * 60 +
        int.parse(parts[2]);
    await start(probeSeconds: seconds.toDouble());
  }

  Future<void> openJob(String id) async {
    try {
      final details = await api.get(id);
      if (!mounted) return;
      if (details['diagnostic'] != null) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BannerCheck(
              result: details['diagnostic'] as Map<String, dynamic>,
            ),
          ),
        );
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReportScreen(
            initial: details['report'] as Map<String, dynamic>,
            api: api,
            jobId: id,
          ),
        ),
      );
      await refresh();
    } catch (e) {
      message('$e');
    }
  }

  Future<void> cancel(String id) async {
    try {
      await api.cancel(id);
      await refresh();
    } catch (e) {
      message('$e');
    }
  }

  Future<void> remove(String id) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete local analysis?'),
        content: const Text(
          'This removes the scan and any video used only by this scan. Published GitHub reports will remain.',
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
      message('$e');
    }
  }

  Future<void> mediaAction(String id, String action) async {
    try {
      switch (action) {
        case 'move_up':
          await api.moveUp(id);
        case 'retry':
          await retryFailed(id);
        case 'rescan':
          await api.rescan(id, settings);
          message('Rescan added to the queue.');
        case 'export':
          message('Exporting video…');
          final name = await api.exportVideo(id);
          if (name != null) message('Export complete: $name');
        case 'remove_video':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              scrollable: true,
              title: const Text('Delete downloaded video?'),
              content: const Text(
                'Your reports and edits will stay on this phone.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Keep'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Delete video'),
                ),
              ],
            ),
          );
          if (confirmed == true) await api.removeVideo(id);
        case 'delete':
          await remove(id);
      }
      await refresh();
    } catch (error) {
      message('$error');
    }
  }

  Future<void> retryFailed([String? id]) async {
    try {
      final count = await api.retryFailed(id);
      message(
        count == 0
            ? 'No failed scans can be retried.'
            : '$count added to the queue.',
      );
    } catch (error) {
      message('Could not retry scans: $error');
    } finally {
      await refresh();
    }
  }

  Future<void> clearVideos() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: const Text('Delete downloaded videos?'),
        content: const Text(
          'Reports and edits stay on your phone. Videos used by the queue will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete videos'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final count = await api.removeUnusedVideos();
      message('$count downloaded videos deleted.');
    } catch (error) {
      message('Could not delete videos: $error');
    } finally {
      await refresh();
    }
  }

  Future<void> resumeQueue() async {
    try {
      await api.resumeQueue();
      await refresh();
    } catch (error) {
      message('Could not resume the queue: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final completed = <String, String>{};
    final queued = <String>{};
    for (final job in jobs) {
      final videoId = job['completed_video_id'];
      if (videoId is String) {
        completed.putIfAbsent(videoId, () => job['id'] as String);
      }
      final queuedId = job['queued_video_id'];
      if (queuedId is String) queued.add(queuedId);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('GONE4HOPE', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'GitHub publishing settings',
            onPressed: () => showPublishingSettings(context),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'screenshot') {
                checkScreenshot();
              } else if (value == 'licenses') {
                showLicensePage(
                  context: context,
                  applicationName: 'BRB Tracker',
                  applicationVersion: '0.6.0',
                );
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'screenshot',
                enabled: !busy,
                child: const Text('Check saved screenshot'),
              ),
              const PopupMenuItem(
                value: 'licenses',
                child: Text('Open-source licenses'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: IndexedStack(
          index: tab,
          children: [
            StreamCatalog(
              api: api,
              completed: completed,
              queued: queued,
              openReport: openJob,
              queueStream: busy || !settingsLoaded ? null : queueStream,
            ),
            if (settingsLoaded)
              scanOptions()
            else
              const Center(child: CircularProgressIndicator()),
            ScanHistory(
              jobs: jobs,
              refresh: refresh,
              openJob: openJob,
              cancel: cancel,
              action: mediaAction,
              resumeQueue: resumeQueue,
              retryFailed: retryFailed,
              clearVideos: clearVideos,
              settingsLoaded: settingsLoaded,
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        maintainBottomViewPadding: true,
        selectedIndex: tab,
        onDestinationSelected: (index) => setState(() => tab = index),
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
    );
  }

  Widget scanOptions() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      DropdownButtonFormField<bool>(
        isExpanded: true,
        itemHeight: null,
        initialValue: fastScan,
        decoration: const InputDecoration(labelText: 'Scan mode'),
        items: const [
          DropdownMenuItem(value: true, child: Text('Fast (5s, 1s edges)')),
          DropdownMenuItem(value: false, child: Text('Detailed (2s)')),
        ],
        onChanged: !settingsLoaded
            ? null
            : (value) => saveSettings(() => fastScan = value!),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<int>(
        isExpanded: true,
        itemHeight: null,
        initialValue: downloadHeight,
        decoration: const InputDecoration(labelText: 'Download quality'),
        items: const [
          DropdownMenuItem(value: 480, child: Text('480p (clearer)')),
          DropdownMenuItem(value: 360, child: Text('360p (smaller)')),
        ],
        onChanged: !settingsLoaded
            ? null
            : (value) => saveSettings(() => downloadHeight = value!),
      ),
      const SizedBox(height: 12),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Transcribe speech when captions are missing'),
        subtitle: const Text(
          'Runs on this phone near detected breaks. First use downloads a 41 MB English model; YouTube VODs also need audio.',
        ),
        value: speechFallback,
        onChanged: !settingsLoaded
            ? null
            : (value) => saveSettings(() => speechFallback = value),
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Auto-delete new videos after successful scans'),
        subtitle: const Text(
          'Failed scans and videos reused for rescans stay on this phone.',
        ),
        value: autoDeleteVideo,
        onChanged: (value) => saveSettings(() => autoDeleteVideo = value),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: url,
        enabled: !busy,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: video == null
              ? 'YouTube VOD URL'
              : 'YouTube source URL (optional)',
        ),
      ),
      const SizedBox(height: 16),
      const SizedBox(height: 12),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Files & detection settings'),
        children: [
          OutlinedButton.icon(
            onPressed: busy ? null : () => pick('video'),
            icon: const Icon(Icons.video_file_outlined),
            label: Text(video?['name'] ?? 'Choose local video'),
          ),
          if (video != null)
            TextButton(
              onPressed: busy ? null : () => setState(() => video = null),
              child: const Text('Use YouTube instead'),
            ),
          OutlinedButton.icon(
            onPressed: busy ? null : () => pick('transcript'),
            icon: const Icon(Icons.subtitles_outlined),
            label: Text(transcript?['name'] ?? 'Choose transcript · optional'),
          ),
          if (transcript != null)
            TextButton(
              onPressed: busy ? null : () => setState(() => transcript = null),
              child: const Text('Clear transcript'),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            itemHeight: null,
            initialValue: detectorProfile,
            decoration: const InputDecoration(labelText: 'BRB banner'),
            items: const [
              DropdownMenuItem(
                value: 'gamin4hope',
                child: Text('Gamin4Hope banner'),
              ),
              DropdownMenuItem(value: 'full_frame', child: Text('Full frame')),
            ],
            onChanged: !settingsLoaded
                ? null
                : (value) => saveSettings(() => detectorProfile = value!),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : checkVodFrame,
            icon: const Icon(Icons.image_search),
            label: const Text('Check VOD frame at timestamp'),
          ),
          const SizedBox(height: 16),
        ],
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: busy ? null : start,
        icon: const Icon(Icons.play_arrow),
        label: const Text('Queue VOD scan'),
      ),
      const SizedBox(height: 16),
      TextButton.icon(
        onPressed: () => launchUrl(
          Uri.https('mactimit.github.io', '/brb-tracker/'),
          mode: LaunchMode.externalApplication,
        ),
        icon: const Icon(Icons.open_in_new),
        label: const Text('Open Dashboard'),
      ),
    ],
  );
}
