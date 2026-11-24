import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'desktop_worker.dart';

enum ScanStatus { queued, running, completed, failed, cancelled }

String? youtubeVideoId(String link) {
  final uri = Uri.tryParse(link);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  final parts = uri.pathSegments;
  final String? id;
  if (uri.host == 'youtu.be' && parts.length == 1) {
    id = parts.single;
  } else if (const {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
  }.contains(uri.host)) {
    id = uri.path == '/watch'
        ? uri.queryParameters['v']
        : parts.length == 2 && const {'live', 'shorts'}.contains(parts.first)
        ? parts.last
        : null;
  } else {
    return null;
  }
  return id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null;
}

Uri? youtubeWatchAt(Map<String, dynamic> report, num seconds) {
  if (!seconds.isFinite || seconds < 0) return null;
  final value = report['video_id'];
  final source = report['source_url'];
  final id = value is String && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(value)
      ? value
      : source is String
      ? youtubeVideoId(source)
      : null;
  return id == null
      ? null
      : Uri.https('www.youtube.com', '/watch', {
          'v': id,
          't': '${seconds.floor()}s',
        });
}

class ScanJob {
  ScanJob({
    required this.folder,
    required this.title,
    required List<String> arguments,
    this.videoId,
    this.status = ScanStatus.queued,
    this.error,
  }) : arguments = List.unmodifiable(arguments);

  factory ScanJob.fromJson(Map<String, dynamic> json) => ScanJob(
    folder: json['folder'] as String,
    title: json['title'] as String,
    arguments: (json['arguments'] as List).cast<String>(),
    videoId: json['video_id'] as String?,
    status: ScanStatus.values.byName(json['status'] as String),
    error: json['error'] as String?,
  );

  final String folder;
  final List<String> arguments;
  final String? videoId;
  String title;
  ScanStatus status;
  String? error;
  String stage = 'Preparing scan';
  double? fraction;
  double? speed;
  int? bytes;

  String get reportPath => '$folder${Platform.pathSeparator}report.json';
  bool get pending =>
      status == ScanStatus.queued || status == ScanStatus.running;

  String? argument(String name) {
    final index = arguments.indexOf(name);
    return index >= 0 && index + 1 < arguments.length
        ? arguments[index + 1]
        : null;
  }

  List<File> get downloads {
    final media = Directory('$folder${Platform.pathSeparator}Video');
    if (FileSystemEntity.typeSync(media.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return [];
    }
    return [
      for (final extension in ['mp4', 'mkv', 'webm'])
        if (FileSystemEntity.typeSync(
              '${media.path}${Platform.pathSeparator}vod.$extension',
              followLinks: false,
            ) ==
            FileSystemEntityType.file)
          File('${media.path}${Platform.pathSeparator}vod.$extension'),
    ];
  }

  Map<String, dynamic> toJson() => {
    'folder': folder,
    'title': title,
    'arguments': arguments,
    'video_id': videoId,
    'status': status.name,
    'error': error,
  };
}

class ScanQueue extends ChangeNotifier {
  ScanQueue(this.file, this.startWorker);

  final File file;
  final Future<WorkerSession> Function(List<String>) startWorker;
  final _jobs = <ScanJob>[];
  List<ScanJob> get jobs => List.unmodifiable(_jobs);

  ScanJob? active;
  WorkerSession? _worker;
  Future<void>? _processing;
  bool _cancelling = false;
  bool _closing = false;
  bool _disposed = false;
  bool ready = false;
  String? storageError;

  void load() {
    try {
      if (file.existsSync()) {
        final data =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        if (data['version'] != 1) {
          throw const FormatException('Unsupported queue format.');
        }
        _jobs.addAll(
          (data['jobs'] as List)
              .map((item) => ScanJob.fromJson(item as Map<String, dynamic>))
              .toList(),
        );
        var recovered = false;
        for (final job in _jobs.where(
          (job) => job.status == ScanStatus.running,
        )) {
          // The worker renames a complete report into place before emitting success.
          if (File(job.reportPath).existsSync()) {
            job.status = ScanStatus.completed;
          } else {
            job.status = ScanStatus.failed;
            job.error = 'The previous scan was interrupted. Use Retry scan to continue.';
          }
          recovered = true;
        }
        if (recovered) _write();
      }
      ready = true;
      _pump();
    } on Exception catch (e) {
      storageError = 'The saved queue could not be loaded. $e';
    } on Error {
      storageError = 'The saved queue is invalid.';
    }
    _notify();
  }

  Map<String, String> get completed => {
    for (final job in _jobs)
      if (job.status == ScanStatus.completed && job.videoId != null)
        job.videoId!: job.folder,
  };

  Set<String> get queued => {
    for (final job in _jobs)
      if (job.pending && job.videoId != null) job.videoId!,
  };

  void add({
    required String title,
    required String output,
    required List<String> arguments,
    String? videoId,
  }) {
    _requireReady();
    if (videoId != null && queued.contains(videoId)) {
      throw StateError('This VOD is already in the queue.');
    }
    final root = Directory(output)..createSync(recursive: true);
    final folder = root.createTempSync('Scan-');
    final job = ScanJob(
      folder: folder.path,
      title: title,
      arguments: arguments,
      videoId: videoId,
    );
    _jobs.add(job);
    _persist();
    _pump();
  }

  void deleteDownload(ScanJob job) {
    _requireReady();
    if (job.pending) throw StateError('Wait for this scan to finish.');
    final downloads = job.downloads;
    final inputs = _jobs
        .where((item) => item.pending)
        .map((item) => item.argument('--video')?.toLowerCase())
        .toSet();
    if (downloads.any((file) => inputs.contains(file.path.toLowerCase()))) {
      throw StateError('A queued scan is using this download.');
    }
    try {
      for (final file in downloads) {
        file.deleteSync();
      }
    } finally {
      _notify();
    }
  }

  void moveUp(ScanJob job) {
    _requireReady();
    if (job.status != ScanStatus.queued) return;
    final index = _jobs.indexOf(job);
    final previous = _jobs
        .sublist(0, index)
        .lastIndexWhere((item) => item.status == ScanStatus.queued);
    if (previous < 0) return;
    _jobs[index] = _jobs[previous];
    _jobs[previous] = job;
    _persist();
  }

  void retry(ScanJob job) {
    _requireReady();
    if (job.pending || job.status == ScanStatus.completed) return;
    if (job.videoId != null && queued.contains(job.videoId)) {
      throw StateError('This VOD is already in the queue.');
    }
    job.status = ScanStatus.queued;
    job.error = null;
    _jobs.remove(job);
    _jobs.add(job);
    _persist();
    _pump();
  }

  void retryFailed() {
    _requireReady();
    final seen = <String>{...queued};
    final failed = _jobs.reversed
        .where((job) {
          return seen.add(job.videoId ?? job.folder) &&
              job.status == ScanStatus.failed;
        })
        .toList()
        .reversed;
    for (final job in failed) {
      job.status = ScanStatus.queued;
      job.error = null;
      _jobs.remove(job);
      _jobs.add(job);
    }
    _persist();
    _pump();
  }

  Future<void> cancel(ScanJob job) async {
    _requireReady();
    if (job == active && !_cancelling) {
      await _cancelActive();
    } else if (job.status == ScanStatus.queued) {
      job.status = ScanStatus.cancelled;
      _persist();
    }
  }

  Future<void> _cancelActive() async {
    _cancelling = true;
    active?.stage = 'Cancelling scan';
    _notify();
    await _worker?.cancel();
  }

  Future<void> close() async {
    _closing = true;
    if (active != null && !_cancelling) await _cancelActive();
    await _processing;
  }

  void _requireReady() {
    if (!ready || storageError != null || _closing) {
      throw StateError(storageError ?? 'The queue is unavailable.');
    }
  }

  void _pump() {
    if (!ready || storageError != null || _closing || active != null) return;
    final next = _jobs
        .where((job) => job.status == ScanStatus.queued)
        .firstOrNull;
    if (next != null) {
      _cancelling = false;
      active = next;
      _processing = _run(next);
    }
  }

  Future<void> _run(ScanJob job) async {
    // Let _pump store the future before any failure or completion schedules the next job.
    await Future<void>.value();
    try {
      job.status = ScanStatus.running;
      job.stage = 'Preparing scan';
      job.error = null;
      job.fraction = null;
      job.speed = null;
      job.bytes = null;
      _persist();
      if (_cancelling) return;
      final session = await startWorker([
        '--output',
        job.folder,
        ...job.arguments,
      ]);
      _worker = session;
      final events = session.events.forEach((event) {
        if (!_cancelling) _handleEvent(job, event);
      });
      if (_cancelling) await session.cancel();
      final result = await Future.wait<int>([
        session.exitCode,
        events.then((_) => 0),
      ]);
      if (!_cancelling && job.status != ScanStatus.completed) {
        job.error ??=
            'The scan did not produce a report (worker exit ${result.first}).';
      }
    } catch (e) {
      job.error ??= 'Could not run the scan. $e';
    } finally {
      _worker = null;
      if (_cancelling && job.status != ScanStatus.completed) {
        job.status = ScanStatus.cancelled;
        job.error = null;
      } else if (job.status != ScanStatus.completed) {
        job.status = ScanStatus.failed;
      }
      active = null;
      try {
        _persist();
      } on FileSystemException {
        // Persistence failures pause the queue and are displayed by the UI.
      }
      _pump();
    }
  }

  void _handleEvent(ScanJob job, WorkerEvent event) {
    switch (event['event']) {
      case 'progress':
        job.stage = event['phase'] as String? ?? 'Scanning';
        job.fraction = (event['fraction'] as num?)?.toDouble().clamp(0, 1);
        job.speed = (event['speed'] as num?)?.toDouble();
        job.bytes = (event['bytes'] as num?)?.toInt();
      case 'error':
        job.error = event['message'] as String?;
      case 'complete':
        if (File(job.reportPath).existsSync()) {
          final report = event['report'] as Map<String, dynamic>?;
          job.title = report?['title'] as String? ?? job.title;
          job.status = ScanStatus.completed;
        }
    }
    _notify();
  }

  void _persist() {
    try {
      _write();
    } on FileSystemException catch (e) {
      storageError = 'Could not save the scan queue. $e';
      rethrow;
    } finally {
      _notify();
    }
  }

  void _write() {
    file.parent.createSync(recursive: true);
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'jobs': _jobs.map((job) => job.toJson()).toList(),
      }),
      flush: true,
    );
    temp.renameSync(file.path);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
