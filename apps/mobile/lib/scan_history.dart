import 'package:material_ui/material_ui.dart';

import 'job_progress.dart';

class ScanHistory extends StatelessWidget {
  const ScanHistory({
    super.key,
    required this.jobs,
    required this.refresh,
    required this.openJob,
    required this.cancel,
    required this.action,
    required this.resumeQueue,
    required this.retryFailed,
    required this.clearVideos,
    required this.settingsLoaded,
  });

  final List<Map<String, dynamic>> jobs;
  final Future<void> Function() refresh;
  final Future<void> Function(String) openJob;
  final Future<void> Function(String) cancel;
  final Future<void> Function(String, String) action;
  final Future<void> Function() resumeQueue;
  final Future<void> Function() retryFailed;
  final Future<void> Function() clearVideos;
  final bool settingsLoaded;

  @override
  Widget build(BuildContext context) {
    final running = jobs.where((job) => job['status'] == 'running');
    final waiting = jobs.reversed
        .where((job) => job['status'] == 'queued')
        .toList();
    waiting.sort(
      (a, b) => ((a['queue_position'] as int?) ?? 0).compareTo(
        (b['queue_position'] as int?) ?? 0,
      ),
    );
    final saved = jobs.where((job) => job['status'] == 'completed');
    final stopped = jobs.where(
      (job) => ['failed', 'cancelled'].contains(job['status']),
    );
    final retained = <String, int>{
      for (final job in jobs)
        if (job['media_key'] is String)
          job['media_key'] as String: (job['retained_bytes'] as num).toInt(),
    };
    final total = retained.values.fold<int>(0, (sum, bytes) => sum + bytes);
    final canClear = jobs.any(
      (job) => job['has_video'] == true && job['media_in_use'] != true,
    );
    final header = Theme.of(context).textTheme.titleLarge;
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Text('In progress', style: header),
          if (running.isEmpty) const ListTile(title: Text('No scan running.')),
          for (final job in running) _active(job, waiting.length),
          const SizedBox(height: 16),
          Text('Up next', style: header),
          if (waiting.isEmpty) const ListTile(title: Text('No scans waiting.')),
          for (var index = 0; index < waiting.length; index++)
            _waiting(waiting[index], index + 1),
          if (running.isEmpty && waiting.isNotEmpty)
            TextButton(
              onPressed: resumeQueue,
              child: const Text('Resume queue'),
            ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Downloads on this phone',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text('${retained.length} VODs · ${storageLabel(total)}'),
                  if (canClear)
                    TextButton(
                      onPressed: clearVideos,
                      child: const Text('Delete videos'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Saved reports', style: header),
          if (saved.isEmpty)
            const ListTile(title: Text('No saved reports yet.')),
          for (final job in saved) _history(job),
          if (stopped.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Failed or cancelled', style: header),
            if (stopped.any(
              (job) => job['status'] == 'failed' && job['can_rescan'] == true,
            ))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: retryFailed,
                  child: const Text('Retry failed scans'),
                ),
              ),
            for (final job in stopped) _history(job),
          ],
        ],
      ),
    );
  }

  Widget _active(Map<String, dynamic> job, int waiting) {
    final id = job['id'] as String;
    final stage = jobStage(job);
    final fraction = jobFraction(job);
    final percent = fraction == null ? '' : ' · ${(fraction * 100).round()}%';
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text(job['title'] as String? ?? 'VOD'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text('$stage$percent'), Text('$waiting waiting')],
              ),
              trailing: IconButton(
                onPressed: stage == 'Cancelling' ? null : () => cancel(id),
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: 'Cancel scan',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(value: fraction),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waiting(Map<String, dynamic> job, int position) {
    final id = job['id'] as String;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.schedule),
        title: Text(job['title'] as String? ?? 'VOD'),
        subtitle: Text('Queued · $position'),
        trailing: PopupMenuButton<String>(
          tooltip: 'Queue actions',
          onSelected: (value) =>
              value == 'move_up' ? action(id, value) : cancel(id),
          itemBuilder: (_) => [
            if (position > 1)
              const PopupMenuItem(value: 'move_up', child: Text('Move up')),
            const PopupMenuItem(
              value: 'cancel',
              child: Text('Remove from queue'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _history(Map<String, dynamic> job) {
    final id = job['id'] as String;
    final complete = job['status'] == 'completed';
    final failed = job['status'] == 'failed';
    final hasVideo = job['has_video'] == true;
    return Card(
      child: ListTile(
        title: Text(job['title'] as String? ?? 'VOD'),
        subtitle: Text(
          [
            jobStage(job),
            if (hasVideo)
              'Video · ${storageLabel((job['video_bytes'] as num?)?.toInt() ?? 0)}',
            if (job['error'] != null) '${job['error']}',
          ].join('\n'),
        ),
        onTap: complete ? () => openJob(id) : null,
        trailing: PopupMenuButton<String>(
          tooltip: 'Scan actions',
          onSelected: (value) => action(id, value),
          itemBuilder: (_) => [
            if (job['can_rescan'] == true)
              if (failed)
                const PopupMenuItem(value: 'retry', child: Text('Retry scan'))
              else if (settingsLoaded)
                PopupMenuItem(
                  value: 'rescan',
                  child: Text(hasVideo ? 'Rescan saved video' : 'Rescan VOD'),
                ),
            if (hasVideo) ...[
              const PopupMenuItem(
                value: 'export',
                child: Text('Export video to Downloads'),
              ),
              if (job['media_in_use'] != true)
                const PopupMenuItem(
                  value: 'remove_video',
                  child: Text('Delete downloaded video'),
                ),
            ],
            const PopupMenuItem(value: 'delete', child: Text('Delete scan')),
          ],
        ),
      ),
    );
  }
}

String storageLabel(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(1)} KB';
  return '$bytes B';
}
