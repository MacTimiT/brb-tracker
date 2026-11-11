import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const BrbApp());
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

class Api {
  Api(this.baseUrl, this.token, {http.Client? client})
    : client = client ?? http.Client();
  final String baseUrl;
  final String token;
  final http.Client client;
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'))
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 25)),
    );
    if (response.statusCode >= 400) {
      throw Exception(
        'Service returned ${response.statusCode}. Check the URL, token, and service logs.',
      );
    }
    return jsonDecode(response.body);
  }

  void close() => client.close();
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
  final server = TextEditingController(text: 'http://10.0.2.2:8000');
  final token = TextEditingController();
  final url = TextEditingController(
    text: 'https://www.youtube.com/live/IW2rEIuKGSs',
  );
  Api? api;
  Timer? timer;
  List<dynamic> jobs = [];
  String? error;
  bool busy = false;
  bool refreshing = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    api?.close();
    server.dispose();
    token.dispose();
    url.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    timer?.cancel();
    if (state == AppLifecycleState.resumed && api != null) {
      refresh();
      startPolling();
    }
  }

  void startPolling() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  Future<void> refresh() async {
    if (api == null || refreshing) return;
    refreshing = true;
    try {
      final result = await api!.request('/jobs');
      if (mounted) {
        setState(() {
          jobs = result as List<dynamic>;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      refreshing = false;
    }
  }

  Future<void> connect() async {
    setState(() {
      busy = true;
      error = null;
    });
    Api? candidate;
    try {
      final value = server.text.trim().replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse(value);
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw Exception(
          'Enter the service origin, for example https://brb.example.com',
        );
      }
      candidate = Api(value, token.text.trim());
      final result = await candidate.request('/jobs');
      if (!mounted) {
        candidate.close();
        return;
      }
      api?.close();
      api = candidate;
      setState(() => jobs = result as List<dynamic>);
      startPolling();
    } catch (e) {
      candidate?.close();
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api!.request(
        '/jobs',
        method: 'POST',
        body: {'url': url.text.trim()},
      );
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('BRB Tracker'),
      actions: [
        IconButton(
          onPressed: api == null ? null : refresh,
          tooltip: 'Refresh jobs',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Every break, accounted for.',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Find BRB screens, measure time away, and review the reason with transcript evidence.',
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: demo,
          icon: const Icon(Icons.insights),
          label: const Text('Explore sample report'),
        ),
        const SizedBox(height: 20),
        const Text(
          'CONNECT YOUR ANALYSIS SERVICE',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: server,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Service URL',
            helperText: 'HTTPS remotely. Android emulator: 10.0.2.2',
          ),
        ),
        TextField(
          controller: token,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'API token',
            helperText: 'Kept in memory for this session only.',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : connect,
          child: Text(api == null ? 'Connect' : 'Reconnect'),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (api != null) ...[
          const SizedBox(height: 24),
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'YouTube VOD URL'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy ? null : submit,
            icon: const Icon(Icons.add),
            label: const Text('Analyze VOD'),
          ),
          const SizedBox(height: 20),
          const Text('ANALYSES', style: TextStyle(fontWeight: FontWeight.bold)),
          if (jobs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No VODs yet. Submit one above.'),
            ),
          for (final job in jobs)
            Card(
              child: ListTile(
                title: Text(
                  job['url'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${job['status']} · ${((job['progress'] as num) * 100).round()}%${job['error'] == null ? '' : '\n${job['error']}'}',
                ),
                trailing: job['status'] == 'completed'
                    ? const Icon(Icons.chevron_right)
                    : null,
                onTap: job['status'] != 'completed'
                    ? null
                    : () async {
                        try {
                          final result = await api!.request(
                            '/jobs/${job['id']}',
                          );
                          if (!context.mounted) return;
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ReportScreen(
                                initial:
                                    result['report'] as Map<String, dynamic>,
                                api: api,
                                jobId: job['id'] as String,
                              ),
                            ),
                          );
                        } catch (e) {
                          if (mounted) setState(() => error = '$e');
                        }
                      },
              ),
            ),
        ],
        const SizedBox(height: 24),
        const Text(
          'VOD processing runs on your computer or server. GitHub Pages displays exported reports; it does not process video.',
          style: TextStyle(color: Colors.grey),
        ),
      ],
    ),
  );
}

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.initial, this.api, this.jobId});
  final Map<String, dynamic> initial;
  final Api? api;
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
      final updated = await widget.api!.request(
        '/jobs/${widget.jobId}/breaks/$index',
        method: 'PATCH',
        body: {'reason': reason},
      );
      if (mounted) setState(() => report = updated as Map<String, dynamic>);
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
            tooltip: 'Copy report JSON for dashboard import',
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
                      'Report JSON copied. Paste into the dashboard or save as .json.',
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
