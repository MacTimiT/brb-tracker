import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:brb_client/stream_catalog.dart';

typedef WorkerEvent = Map<String, dynamic>;

Iterable<WorkerEvent> workerEvents(String line) sync* {
  try {
    final event = jsonDecode(line);
    if (event is Map<String, dynamic>) yield event;
  } on FormatException {
    // The bundled tools can also print human-readable output.
  }
}

abstract interface class WorkerSession {
  Stream<WorkerEvent> get events;
  Future<int> get exitCode;
  Future<void> cancel();
}

class DesktopWorker {
  final app = File(Platform.resolvedExecutable).parent.path;

  String get executable => '$app\\worker\\brb-worker.exe';

  Future<WorkerSession> scan(List<String> arguments) async => _ProcessSession(
    await Process.start(executable, ['--runtime', '$app\\tools', ...arguments]),
  );

  Future<WorkerEvent> archive(int start) async {
    final process = await Process.start(executable, [
      '--catalog-start',
      '$start',
    ]);
    try {
      final output = await Future.wait([
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.drain<String>(''),
      ]).timeout(const Duration(seconds: 55));
      if (await process.exitCode == 0) {
        for (final line in const LineSplitter().convert(output.first)) {
          for (final event in workerEvents(line)) {
            if (event['event'] == 'catalog') {
              return event['page'] as WorkerEvent;
            }
          }
        }
      }
      throw StateError('Could not load the YouTube stream archive.');
    } on TimeoutException {
      await terminateTree(process);
      throw StateError('The archive request timed out.');
    }
  }
}

Future<void> terminateTree(Process process) async {
  try {
    final result = await Process.run('taskkill.exe', [
      '/PID',
      '${process.pid}',
      '/T',
      '/F',
    ]);
    if (result.exitCode != 0) process.kill();
  } on ProcessException {
    process.kill();
  }
}

class _ProcessSession implements WorkerSession {
  _ProcessSession(this.process) {
    // Drain errors to avoid blocking the worker's output pipe.
    process.stderr.drain<void>();
  }

  final Process process;

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  Stream<WorkerEvent> get events => process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .expand(workerEvents);

  @override
  Future<void> cancel() => terminateTree(process);
}

class DesktopArchive implements StreamArchive {
  DesktopArchive(this.cache, this.worker);

  final File cache;
  final DesktopWorker worker;

  @override
  Future<WorkerEvent?> cachedStreams() async {
    if (!await cache.exists()) return null;
    return jsonDecode(await cache.readAsString()) as WorkerEvent;
  }

  @override
  Future<WorkerEvent> listStreams(int start) async {
    final page = await worker.archive(start);
    if (start == 1) {
      try {
        await cache.parent.create(recursive: true);
        final temporary = await File('${cache.path}.tmp')
            .writeAsString(jsonEncode(page), flush: true);
        await temporary.rename(cache.path);
      } on FileSystemException {
        // A cache failure should still display the fresh page.
      }
    }
    return page;
  }
}
