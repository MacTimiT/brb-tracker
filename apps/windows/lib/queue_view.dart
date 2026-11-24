import 'dart:io';

import 'package:brb_client/published_scans.dart';
import 'package:material_ui/material_ui.dart';
import 'package:file_selector/file_selector.dart';

import 'scan_queue.dart';

class QueueView extends StatefulWidget {
  const QueueView({
    super.key,
    required this.queue,
    required this.publication,
    required this.openReport,
    required this.rescan,
    required this.showError,
  });

  final ScanQueue queue;
  final PublishedScanStatus publication;
  final Future<void> Function(String folder) openReport;
  final void Function(Object) showError;
  final void Function(ScanJob job, File? download) rescan;

  @override
  State<QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends State<QueueView> {
  bool downloadedOnly = false;
  ScanQueue get queue => widget.queue;

  Future<void> export(ScanJob job, File download) async {
    final suffix = download.path.split('.').last;
    final location = await getSaveLocation(
      initialDirectory:
          '${Platform.environment['USERPROFILE'] ?? Directory.current.path}${Platform.pathSeparator}Downloads',
      suggestedName: '${job.videoId ?? 'BRB-VOD'}.$suffix',
      acceptedTypeGroups: [
        XTypeGroup(label: 'Video', extensions: [suffix]),
      ],
    );
    if (location == null) return;
    if (File(location.path).existsSync() &&
        await FileSystemEntity.identical(download.path, location.path)) {
      return;
    }
    await download.copy(location.path);
  }

  Future<void> deleteDownload(BuildContext context, ScanJob job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete downloaded video?'),
        content: Text(
          job.status == ScanStatus.completed
              ? 'The report, reasons and checked status will still be available.'
              : 'The scan entry will stay in history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete video'),
          ),
        ],
      ),
    );
    if (confirmed == true) queue.deleteDownload(job);
  }

  Future<void> removeFromHistory(BuildContext context, ScanJob job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Remove this scan from history?'),
        content: const Text(
          'The scan folder and any saved video files will stay on disk.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Keep scan'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Remove scan'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) queue.removeFromHistory(job);
  }

  Future<void> act(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) widget.showError(error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.publication,
    builder: (context, _) => buildQueue(context),
  );

  Widget buildQueue(BuildContext context) {
    final jobs = queue.jobs;
    final waiting = jobs.where((job) => job.status == ScanStatus.queued);
    final history = [
      for (final job in jobs.reversed)
        if (!job.pending) (job, job.downloads.firstOrNull),
    ];
    final downloadCount = history.where((entry) => entry.$2 != null).length;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Scans', style: Theme.of(context).textTheme.headlineSmall),
        if (queue.storageError case final String error)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (jobs.isEmpty) const ListTile(title: Text('No scans yet')),
        if (queue.active case final ScanJob job)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    job.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(job.stage),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: job.fraction),
                  if (job.fraction != null ||
                      job.bytes != null ||
                      job.speed != null)
                    Text(
                      [
                        if (job.fraction case final double fraction)
                          '${(100 * fraction).floor()}%',
                        if (job.bytes case final int bytes)
                          '${(bytes / 1000000).toStringAsFixed(1)} MB',
                        if (job.speed case final double speed)
                          '${(speed * 8 / 1000000).toStringAsFixed(1)} Mbps',
                      ].join(' · '),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: job.stage == 'Cancelling scan'
                          ? null
                          : () => act(() => queue.cancel(job)),
                      child: const Text('Cancel scan'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (waiting.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Up next · ${waiting.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        for (final (index, job) in waiting.indexed)
          Card(
            child: ListTile(
              title: Text(job.title),
              subtitle: Text('Waiting · ${index + 1}'),
              trailing: PopupMenuButton<String>(
                tooltip: 'Queue actions',
                onSelected: (value) => act(() async {
                  if (value == 'up') {
                    queue.moveUp(job);
                  } else {
                    await queue.cancel(job);
                  }
                }),
                itemBuilder: (_) => [
                  if (index > 0)
                    const PopupMenuItem(value: 'up', child: Text('Move up')),
                  const PopupMenuItem(
                    value: 'cancel',
                    child: Text('Cancel scan'),
                  ),
                ],
              ),
            ),
          ),
        if (history.isNotEmpty || downloadedOnly)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Scan history',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                FilterChip(
                  label: Text('Downloaded only ($downloadCount)'),
                  selected: downloadedOnly,
                  onSelected: (selected) =>
                      setState(() => downloadedOnly = selected),
                ),
                if (history.any((entry) => entry.$1.videoId != null))
                  TextButton.icon(
                    onPressed: widget.publication.refreshing
                        ? null
                        : widget.publication.refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh published status'),
                  ),
                if (history.any(
                  (entry) => entry.$1.status == ScanStatus.failed,
                ))
                  TextButton(
                    onPressed: () => act(() async => queue.retryFailed()),
                    child: const Text('Retry failed scans'),
                  ),
              ],
            ),
          ),
        if (widget.publication.failed &&
            history.any((entry) => entry.$1.videoId != null))
          Text(
            widget.publication.hasSnapshot
                ? 'Showing last synced publication status.'
                : 'Publication status unavailable. Refresh to retry.',
          ),
        if (downloadedOnly && downloadCount == 0 && history.isNotEmpty)
          const ListTile(title: Text('No downloaded videos in scan history')),
        for (final (job, download) in history)
          if (!downloadedOnly || download != null)
            historyCard(context, job, download),
      ],
    );
  }

  Widget historyCard(BuildContext context, ScanJob job, File? download) {
    final status = switch (job.status) {
      ScanStatus.completed => 'Scan complete',
      ScanStatus.cancelled => 'Scan cancelled',
      _ => 'Scan failed',
    };
    final publication = widget.publication;
    final id = job.videoId;
    return Card(
      key: ValueKey(job.folder),
      child: ListTile(
        title: Text(job.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(status),
                Icon(
                  download == null ? Icons.cloud_outlined : Icons.download_done,
                  size: 16,
                  color: download == null
                      ? null
                      : Theme.of(context).colorScheme.primary,
                ),
                Text(
                  download == null ? 'No saved download' : 'Video downloaded',
                ),
                if (id != null && publication.contains(id)) ...[
                  Icon(
                    Icons.cloud_done_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const Text('Published'),
                ] else if (id != null &&
                    publication.hasSnapshot &&
                    !publication.failed)
                  const Text('Unpublished'),
              ],
            ),
            if (job.error case final String error) Text(error),
          ],
        ),
        onTap: job.status == ScanStatus.completed
            ? () => widget.openReport(job.folder)
            : null,
        trailing: PopupMenuButton<String>(
          tooltip: 'Scan actions',
          onSelected: (value) => act(() async {
            if (value == 'rescan') {
              widget.rescan(job, download);
            } else if (value == 'export' && download != null) {
              await export(job, download);
            } else if (value == 'delete' && download != null) {
              await deleteDownload(context, job);
            } else if (value == 'retry') {
              queue.retry(job);
            } else if (value == 'remove') {
              if (context.mounted) await removeFromHistory(context, job);
            } else {
              await Process.start('explorer.exe', [
                job.folder,
              ], mode: ProcessStartMode.detached);
            }
          }),
          itemBuilder: (_) => [
            if (job.canRemoveFromHistory)
              const PopupMenuItem(value: 'retry', child: Text('Retry scan')),
            if (job.status == ScanStatus.completed)
              PopupMenuItem(
                value: 'rescan',
                child: Text(
                  download != null ? 'Rescan saved download' : 'Rescan VOD',
                ),
              ),
            if (download != null) ...[
              const PopupMenuItem(value: 'export', child: Text('Export video')),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete downloaded video'),
              ),
            ],
            const PopupMenuItem(
              value: 'folder',
              child: Text('Open scan folder'),
            ),
            if (job.canRemoveFromHistory)
              const PopupMenuItem(
                value: 'remove',
                child: Text('Remove from history'),
              ),
          ],
        ),
      ),
    );
  }
}
