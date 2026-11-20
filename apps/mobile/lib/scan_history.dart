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
    required this.settingsLoaded,
  });

  final List<Map<String, dynamic>> jobs;
  final Future<void> Function() refresh;
  final Future<void> Function(String) openJob;
  final Future<void> Function(String) cancel;
  final Future<void> Function(String, String) action;
  final Future<void> Function() resumeQueue;
  final bool settingsLoaded;

  @override
  Widget build(BuildContext context) {
    final running = jobs.where((job) => job['status'] == 'running').toList();
    final queued = jobs.reversed
        .where((job) => job['status'] == 'queued')
        .toList();
    final saved = jobs.where(
      (job) => !['queued', 'running'].contains(job['status']),
    );
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Text('Scan queue', style: Theme.of(context).textTheme.titleLarge),
          if (running.isEmpty && queued.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No scans queued.'),
            ),
          for (final job in running) _job(job),
          for (var i = 0; i < queued.length; i++)
            _job(queued[i], position: i + 1),
          if (running.isEmpty && queued.isNotEmpty)
            TextButton(
              onPressed: resumeQueue,
              child: const Text('Resume queue'),
            ),
          const SizedBox(height: 20),
          Text('Saved scans', style: Theme.of(context).textTheme.titleLarge),
          if (saved.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No saved scans yet.'),
            ),
          for (final job in saved) _job(job),
        ],
      ),
    );
  }

  Widget _job(Map<String, dynamic> job, {int? position}) {
    final id = job['id'] as String;
    final running = job['status'] == 'running';
    final fraction = running ? jobFraction(job) : null;
    final hasVideo = job['has_video'] == true;
    final stage = position == null ? jobStage(job) : 'Queued · $position';
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text(job['title'] as String? ?? 'VOD'),
            subtitle: Text(
              [
                '$stage${fraction == null ? '' : ' · ${(fraction * 100).round()}%'}',
                if (hasVideo && !running && position == null)
                  'Video on this phone',
                if (job['error'] != null) '${job['error']}',
              ].join('\n'),
            ),
            onTap: job['status'] == 'completed' ? () => openJob(id) : null,
            trailing: running || position != null
                ? IconButton(
                    onPressed: stage == 'Cancelling' ? null : () => cancel(id),
                    icon: Icon(
                      running ? Icons.stop_circle_outlined : Icons.close,
                    ),
                    tooltip: running ? 'Cancel scan' : 'Remove from queue',
                  )
                : PopupMenuButton<String>(
                    tooltip: 'Scan actions',
                    onSelected: (value) => action(id, value),
                    itemBuilder: (_) => [
                      if (job['can_rescan'] == true && settingsLoaded)
                        PopupMenuItem(
                          value: 'rescan',
                          child: Text(
                            hasVideo ? 'Rescan saved video' : 'Rescan VOD',
                          ),
                        ),
                      if (hasVideo) ...[
                        const PopupMenuItem(
                          value: 'export',
                          child: Text('Export video to Downloads'),
                        ),
                        const PopupMenuItem(
                          value: 'remove_video',
                          child: Text('Delete downloaded video'),
                        ),
                      ],
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete scan'),
                      ),
                    ],
                  ),
          ),
          if (running) LinearProgressIndicator(value: fraction),
        ],
      ),
    );
  }
}
