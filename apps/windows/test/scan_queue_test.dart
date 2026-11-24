import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:brb_tracker_windows/desktop_worker.dart';
import 'package:brb_tracker_windows/scan_queue.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeWorker implements WorkerSession {
  final stream = StreamController<WorkerEvent>();
  final result = Completer<int>();

  @override
  Stream<WorkerEvent> get events => stream.stream;

  @override
  Future<int> get exitCode => result.future;

  @override
  Future<void> cancel() => finish(1);

  Future<void> finish(int exitCode) async {
    result.complete(exitCode);
    await stream.close();
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('makes a canonical watch link from a VOD ID or older source URL', () {
    expect(
      youtubeWatchAt({
        'source_url': 'https://www.youtube.com/live/9YP_ljMuDQM',
      }, 6235.8).toString(),
      'https://www.youtube.com/watch?v=9YP_ljMuDQM&t=6235s',
    );
    expect(
      youtubeWatchAt({'video_id': 'rHgIE7SB3kI'}, 0)?.queryParameters['t'],
      '0s',
    );
    expect(youtubeWatchAt({'video_id': 'rHgIE7SB3kI'}, -1), isNull);
    expect(
      youtubeWatchAt({
        'source_url': 'https://example.com/watch?v=rHgIE7SB3kI',
      }, 6),
      isNull,
    );
  });

  test(
    'deletes only a saved download and preserves the report and VOD checkmark',
    () {
      final folder = Directory.systemTemp.createTempSync('brb-download-test');
      addTearDown(() => folder.deleteSync(recursive: true));
      final queueFile = File('${folder.path}/queue.json');
      final job = ScanJob(
        folder: folder.path,
        title: 'VOD',
        videoId: 'rHgIE7SB3kI',
        arguments: [],
        status: ScanStatus.completed,
      );
      queueFile.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'jobs': [job.toJson()],
        }),
      );
      final media = Directory('${folder.path}/Video')..createSync();
      File('${media.path}/vod.mp4').writeAsStringSync('video');
      final captions = File('${media.path}/vod.en.vtt')
        ..writeAsStringSync('captions');
      final report = File(job.reportPath)..writeAsStringSync('report');
      final queue = ScanQueue(
        queueFile,
        (_) async => throw StateError('Unexpected scan'),
      )..load();
      addTearDown(queue.dispose);

      queue.deleteDownload(queue.jobs.single);

      expect(job.downloads, isEmpty);
      expect(queue.completed[job.videoId], folder.path);
      expect(report.existsSync(), isTrue);
      expect(captions.existsSync(), isTrue);
    },
  );
  test('processes one scan at a time and keeps each job’s speed cap', () async {
    final folder = Directory.systemTemp.createTempSync('brb-queue-test');
    final file = File('${folder.path}/queue.json');
    final sessions = <FakeWorker>[];
    final arguments = <List<String>>[];
    final queue = ScanQueue(file, (args) async {
      arguments.add(args);
      final worker = FakeWorker();
      sessions.add(worker);
      return worker;
    })..load();
    addTearDown(() {
      queue.dispose();
      folder.deleteSync(recursive: true);
    });

    for (final (id, cap) in [
      ('abcdefghijk', '2'),
      ('abcdefghijl', '5'),
      ('abcdefghijm', '1'),
    ]) {
      queue.add(
        title: id,
        output: folder.path,
        videoId: id,
        arguments: ['--limit-mbps', cap],
      );
    }
    final first = queue.jobs.first;
    final third = queue.jobs.last;
    queue.moveUp(third);
    await settle();
    expect(sessions.length, 1);
    expect(arguments.single.last, '2');
    expect(queue.queued.length, 3);
    expect(
      () => queue.add(
        title: 'duplicate',
        output: folder.path,
        videoId: first.videoId,
        arguments: [],
      ),
      throwsStateError,
    );

    File(first.reportPath).writeAsStringSync('{}');
    sessions.first.stream.add({
      'event': 'complete',
      'report': {'title': 'First report'},
    });
    await sessions.first.finish(0);
    await settle();
    expect(queue.completed[first.videoId], first.folder);
    expect(queue.active, third);
    expect(arguments.map((args) => args.last), ['2', '1']);

    await queue.close();
    final stored = jsonDecode(file.readAsStringSync()) as Map;
    expect((stored['jobs'] as List).map((job) => job['status']), [
      'completed',
      'cancelled',
      'queued',
    ]);
  });

  test(
    'reopens waiting scans and records previously interrupted work',
    () async {
      final folder = Directory.systemTemp.createTempSync('brb-recovery-test');
      final file = File('${folder.path}/queue.json');
      final saved = [
        ScanJob(
          folder: '${folder.path}/one',
          title: 'Interrupted',
          status: ScanStatus.running,
          arguments: [],
        ),
        ScanJob(
          folder: '${folder.path}/two',
          title: 'Waiting',
          arguments: ['--limit-mbps', '3'],
        ),
      ];
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'jobs': saved.map((job) => job.toJson()).toList(),
        }),
      );
      final worker = FakeWorker();
      final queue = ScanQueue(file, (args) async {
        expect(args.last, '3');
        return worker;
      })..load();
      addTearDown(() {
        queue.dispose();
        folder.deleteSync(recursive: true);
      });

      await settle();
      expect(queue.jobs.first.status, ScanStatus.failed);
      expect(queue.jobs.first.error, contains('interrupted'));
      expect(queue.active?.title, 'Waiting');
      await queue.close();
    },
  );
}
