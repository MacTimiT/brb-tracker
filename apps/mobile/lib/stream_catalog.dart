import 'package:material_ui/material_ui.dart';

import 'local_api.dart';

enum StreamFilter { all, unscanned, scanned }

class StreamCatalog extends StatefulWidget {
  const StreamCatalog({
    super.key,
    required this.api,
    required this.completed,
    required this.openReport,
    required this.queued,
    required this.queueStream,
  });

  final LocalApi api;
  final Map<String, String> completed;
  final Set<String> queued;
  final Future<void> Function(String id, String title)? queueStream;
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
  StreamFilter filter = StreamFilter.all;

  @override
  void initState() {
    super.initState();
    scroll.addListener(loadNearEnd);
    loadCached();
  }

  Future<void> loadCached() async {
    try {
      final cached = await widget.api.cachedStreams();
      if (mounted && cached != null) {
        setState(() => streams.addAll(pageEntries(cached)));
      }
    } catch (_) {
      // A missing or expired cache falls back to the live archive.
    }
    if (mounted) await loadPage();
  }

  Map<String, String> pageEntries(Map<String, dynamic> page) => {
    for (final item in page['streams'] as List)
      item['id'] as String: item['title'] as String,
  };

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void loadNearEnd() {
    if (filter == StreamFilter.all &&
        scroll.hasClients &&
        !failed &&
        scroll.position.extentAfter < 250) {
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
      final entries = pageEntries(page);
      setState(() {
        if (start == 1) streams.clear();
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
    next = 1;
    await loadPage();
  }

  @override
  Widget build(BuildContext context) {
    final entries = streams.entries
        .where((entry) {
          final scanned = widget.completed.containsKey(entry.key);
          return switch (filter) {
            StreamFilter.all => true,
            StreamFilter.unscanned => !scanned,
            StreamFilter.scanned => scanned,
          };
        })
        .toList(growable: false);
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.builder(
        controller: scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: entries.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final (value, label) in const [
                    (StreamFilter.all, 'All VODs'),
                    (StreamFilter.unscanned, 'Unscanned'),
                    (StreamFilter.scanned, 'Scanned'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: filter == value,
                      onSelected: (_) {
                        if (filter == value) return;
                        if (scroll.hasClients) scroll.jumpTo(0);
                        setState(() => filter = value);
                      },
                    ),
                ],
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
                title: Text(
                  streams.isEmpty
                      ? 'Could not load streams'
                      : 'Could not refresh the archive',
                ),
                trailing: TextButton(
                  onPressed: loadPage,
                  child: const Text('Retry'),
                ),
              );
            }
            if (filter != StreamFilter.all && next != null) {
              return Column(
                children: [
                  if (entries.isEmpty)
                    const ListTile(
                      title: Text('No matches in loaded streams.'),
                    ),
                  TextButton(
                    onPressed: loadPage,
                    child: const Text('Load older streams'),
                  ),
                ],
              );
            }
            if (entries.isEmpty && next == null) {
              return const ListTile(title: Text('No matching streams found.'));
            }
            return const SizedBox(height: 16);
          }
          final entry = entries[index - 1];
          final reportId = widget.completed[entry.key];
          final queued = widget.queued.contains(entry.key);
          return ListTile(
            key: ValueKey(entry.key),
            title: Text(entry.value),
            subtitle: queued ? const Text('In scan queue') : null,
            leading: reportId == null
                ? Icon(queued ? Icons.schedule : Icons.video_library_outlined)
                : Icon(
                    Icons.check_circle,
                    semanticLabel: 'Scanned',
                    color: Theme.of(context).colorScheme.primary,
                  ),
            trailing: Icon(
              reportId == null && !queued ? Icons.add : Icons.chevron_right,
            ),
            onTap: reportId != null
                ? () => widget.openReport(reportId)
                : queued || widget.queueStream == null
                ? null
                : () => widget.queueStream!(entry.key, entry.value),
          );
        },
      ),
    );
  }
}
