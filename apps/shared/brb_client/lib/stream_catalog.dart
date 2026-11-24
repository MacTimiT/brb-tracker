import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'published_scans.dart';

abstract interface class StreamArchive {
  Future<Map<String, dynamic>?> cachedStreams();
  Future<Map<String, dynamic>> listStreams(int start);
}

enum StreamFilter { all, unpublished, unscanned, scanned }

class StreamCatalog extends StatefulWidget {
  const StreamCatalog({
    super.key,
    required this.api,
    required this.completed,
    required this.openReport,
    required this.queued,
    required this.queueStream,
    this.active = true,
    this.loadPublished = loadDashboardPublishedScans,
  });

  final StreamArchive api;
  final Map<String, String> completed;
  final Set<String> queued;
  final Future<void> Function(String id, String title)? queueStream;
  final Future<void> Function(String jobId) openReport;
  final bool active;
  final Future<Set<String>> Function() loadPublished;

  @override
  State<StreamCatalog> createState() => _StreamCatalogState();
}

class _StreamCatalogState extends State<StreamCatalog>
    with WidgetsBindingObserver {
  final scroll = ScrollController();
  final streams = <String, String>{};
  int? next = 1;
  bool loading = false;
  bool failed = false;
  StreamFilter filter = StreamFilter.all;
  Set<String>? published;
  final justPublished = <String>{};
  Future<void>? publicationRefresh;
  bool publicationFailed = false;

  @override
  void initState() {
    super.initState();
    scroll.addListener(loadNearEnd);
    WidgetsBinding.instance.addObserver(this);
    dashboardPublication.addListener(onPublished);
    if (widget.active) unawaited(syncPublication());
    loadCached();
  }

  @override
  void didUpdateWidget(StreamCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) unawaited(syncPublication());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.active && state == AppLifecycleState.resumed) {
      unawaited(syncPublication());
    }
  }

  void onPublished() {
    if (dashboardPublication.value case (final String id, _)) {
      setState(() => justPublished.add(id));
      if (widget.active) unawaited(syncPublication());
    }
  }

  Future<void> syncPublication() =>
      publicationRefresh ??= fetchPublication().whenComplete(() {
        if (mounted) setState(() => publicationRefresh = null);
      });

  Future<void> fetchPublication() async {
    try {
      final ids = await widget.loadPublished();
      if (!mounted) return;
      setState(() {
        published = ids;
        justPublished.removeAll(ids);
        publicationFailed = false;
      });
    } catch (_) {
      if (mounted) setState(() => publicationFailed = true);
    }
  }

  bool isPublished(String id) =>
      published?.contains(id) == true || justPublished.contains(id);

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
    dashboardPublication.removeListener(onPublished);
    WidgetsBinding.instance.removeObserver(this);
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
    final publication = syncPublication();
    if (mounted) setState(() {});
    if (loading) {
      await publication;
      return;
    }
    next = 1;
    await Future.wait([loadPage(), publication]);
  }

  @override
  Widget build(BuildContext context) {
    final entries = streams.entries
        .where((entry) {
          final scanned = widget.completed.containsKey(entry.key);
          return switch (filter) {
            StreamFilter.all => true,
            StreamFilter.unpublished =>
              published != null && !isPublished(entry.key),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: publicationRefresh != null ? null : refresh,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh VODs'),
                      ),
                      for (final (value, label) in const [
                        (StreamFilter.all, 'All VODs'),
                        (StreamFilter.unpublished, 'Unpublished'),
                        (StreamFilter.unscanned, 'Unscanned here'),
                        (StreamFilter.scanned, 'Scanned here'),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: filter == value,
                          onSelected:
                              value == StreamFilter.unpublished &&
                                  published == null
                              ? null
                              : (_) {
                                  if (filter == value) return;
                                  if (scroll.hasClients) scroll.jumpTo(0);
                                  setState(() => filter = value);
                                },
                        ),
                    ],
                  ),
                  if (publicationFailed)
                    Text(
                      published == null
                          ? 'Could not sync published scans. Use Refresh VODs to retry.'
                          : 'Could not sync published scans. Showing the last synced status.',
                    )
                  else if (publicationRefresh != null)
                    const Text('Syncing published scans…'),
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
          final uploaded = isPublished(entry.key);
          final statuses = [
            if (uploaded) 'Published',
            if (reportId != null) 'Scanned on this device',
            if (queued) 'In scan queue',
            if (!uploaded &&
                reportId == null &&
                !queued &&
                published != null &&
                !publicationFailed)
              'No report yet',
          ];
          return ListTile(
            key: ValueKey(entry.key),
            title: Text(entry.value),
            subtitle: statuses.isEmpty ? null : Text(statuses.join(' · ')),
            leading: Icon(
              uploaded
                  ? Icons.cloud_done_outlined
                  : reportId != null
                  ? Icons.check_circle
                  : queued
                  ? Icons.schedule
                  : Icons.video_library_outlined,
              color: uploaded || reportId != null
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            trailing: reportId != null
                ? const Icon(Icons.chevron_right)
                : uploaded && !queued && widget.queueStream != null
                ? PopupMenuButton<void>(
                    tooltip: 'Published VOD actions',
                    itemBuilder: (_) => [
                      PopupMenuItem<void>(
                        onTap: () =>
                            widget.queueStream!(entry.key, entry.value),
                        child: const Text('Scan on this device'),
                      ),
                    ],
                  )
                : !uploaded && !queued && widget.queueStream != null
                ? const Icon(Icons.add)
                : null,
            onTap: reportId != null
                ? () => widget.openReport(reportId)
                : uploaded || queued || widget.queueStream == null
                ? null
                : () => widget.queueStream!(entry.key, entry.value),
          );
        },
      ),
    );
  }
}
