import 'package:material_ui/material_ui.dart';

import 'local_api.dart';

class StreamCatalog extends StatefulWidget {
  const StreamCatalog({
    super.key,
    required this.api,
    required this.completed,
    required this.openReport,
  });

  final LocalApi api;
  final Map<String, String> completed;
  final Future<void> Function(String jobId) openReport;

  @override
  State<StreamCatalog> createState() => _StreamCatalogState();
}

class _StreamCatalogState extends State<StreamCatalog> {
  final scroll = ScrollController();
  final streams = <String, String>{};
  int? next = 1;
  bool loading = false;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    scroll.addListener(loadNearEnd);
    loadPage();
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void loadNearEnd() {
    if (scroll.hasClients && !failed && scroll.position.extentAfter < 250) {
      loadPage();
    }
  }

  Future<void> loadPage() async {
    final start = next;
    if (loading || start == null) return;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final page = await widget.api.listStreams(start);
      if (!mounted) return;
      final more = page['next'] as int?;
      final entries = {
        for (final item in page['streams'] as List)
          item['id'] as String: item['title'] as String,
      };
      setState(() {
        streams.addAll(entries);
        next = more != null && more > start ? more : null;
        loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadNearEnd();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        failed = true;
      });
    }
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() {
      streams.clear();
      next = 1;
    });
    await loadPage();
  }

  @override
  Widget build(BuildContext context) {
    final entries = streams.entries.toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: const Text('Gamin4Hope streams')),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView.builder(
          controller: scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: entries.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Newest first · Checkmarks show scans saved on this phone.',
                ),
              );
            }
            if (index == entries.length + 1) {
              if (loading) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (failed) {
                return ListTile(
                  title: const Text('Could not load streams'),
                  trailing: TextButton(
                    onPressed: loadPage,
                    child: const Text('Retry'),
                  ),
                );
              }
              if (entries.isEmpty && next == null) {
                return const ListTile(title: Text('No past streams found.'));
              }
              return const SizedBox(height: 16);
            }
            final entry = entries[index - 1];
            final reportId = widget.completed[entry.key];
            return ListTile(
              key: ValueKey(entry.key),
              title: Text(entry.value),
              leading: reportId == null
                  ? const Icon(Icons.video_library_outlined)
                  : Icon(
                      Icons.check_circle,
                      semanticLabel: 'Scanned',
                      color: Theme.of(context).colorScheme.primary,
                    ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                if (reportId != null) {
                  widget.openReport(reportId);
                } else {
                  Navigator.pop(context, entry.key);
                }
              },
            );
          },
        ),
      ),
    );
  }
}
