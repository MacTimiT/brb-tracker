import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'scan_queue.dart';

class QueueView extends StatelessWidget {
  const QueueView({
    super.key,
    required this.queue,
    required this.openReport,
    required this.showError,
  });

  final ScanQueue queue;
  final Future<void> Function(String folder) openReport;
  final void Function(Object) showError;

  Future<void> act(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobs = queue.jobs;
    final waiting = jobs.where((job) => job.status == ScanStatus.queued);
    final history = jobs.where((job) => !job.pending).toList().reversed;
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
        if (history.isNotEmpty)
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
                if (history.any((job) => job.status == ScanStatus.failed))
                  TextButton(
                    onPressed: () => act(() async => queue.retryFailed()),
                    child: const Text('Retry failed scans'),
                  ),
              ],
            ),
          ),
        for (final job in history)
          Card(
            child: ListTile(
              title: Text(job.title),
              subtitle: Text(
                job.error ??
                    switch (job.status) {
                      ScanStatus.completed => 'Scan complete',
                      ScanStatus.cancelled => 'Scan cancelled',
                      _ => 'Scan failed',
                    },
              ),
              onTap: job.status == ScanStatus.completed
                  ? () => openReport(job.folder)
                  : null,
              trailing: PopupMenuButton<String>(
                tooltip: 'Scan actions',
                onSelected: (value) => act(() async {
                  if (value == 'retry') {
                    queue.retry(job);
                  } else {
                    await Process.start('explorer.exe', [
                      job.folder,
                    ], mode: ProcessStartMode.detached);
                  }
                }),
                itemBuilder: (_) => [
                  if (job.status != ScanStatus.completed)
                    const PopupMenuItem(
                      value: 'retry',
                      child: Text('Retry scan'),
                    ),
                  const PopupMenuItem(
                    value: 'folder',
                    child: Text('Open scan folder'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
