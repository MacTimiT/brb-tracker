import 'dart:convert';

import 'package:flutter/services.dart';

/// All processing calls cross into Android, never an HTTP analysis service.
class LocalApi {
  LocalApi({MethodChannel? channel})
    : channel =
          channel ?? const MethodChannel('dev.mactimit.brb_tracker/local');
  final MethodChannel channel;
  Future<List<dynamic>> list() async =>
      jsonDecode(await channel.invokeMethod<String>('list') ?? '[]')
          as List<dynamic>;
  Future<Map<String, dynamic>?> cachedStreams() async {
    final cached = await channel.invokeMethod<String>('cached_streams');
    return cached == null ? null : jsonDecode(cached) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> listStreams(int start) async => jsonDecode(
    (await channel.invokeMethod<String>('list_streams', {'start': start}))!,
  ) as Map<String, dynamic>;
  Future<Map<String, dynamic>> get(String id) async =>
      jsonDecode((await channel.invokeMethod<String>('get', {'id': id}))!)
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> start(Map<String, dynamic> input) async =>
      jsonDecode((await channel.invokeMethod<String>('start', input))!)
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> scanSettings() async =>
      jsonDecode(await channel.invokeMethod<String>('scan_settings') ?? '{}')
          as Map<String, dynamic>;
  Future<void> saveScanSettings(Map<String, dynamic> options) =>
      channel.invokeMethod<void>('save_scan_settings', options);
  Future<void> resumeQueue() => channel.invokeMethod<void>('resume_queue');
  Future<void> rescan(String id, Map<String, dynamic> settings) =>
      channel.invokeMethod<void>('rescan', {'id': id, 'settings': settings});
  Future<void> moveUp(String id) =>
      channel.invokeMethod<void>('move_up', {'id': id});
  Future<int> retryFailed([String? id]) async =>
      await channel.invokeMethod<int>('retry_failed', {'id': ?id}) ?? 0;
  Future<int> removeUnusedVideos() async =>
      await channel.invokeMethod<int>('remove_unused_videos') ?? 0;
  Future<void> removeVideo(String id) =>
      channel.invokeMethod<void>('remove_video', {'id': id});
  Future<String?> exportVideo(String id) =>
      channel.invokeMethod<String>('export_video', {'id': id});
  Future<Map<String, dynamic>> review(
    String id,
    int index,
    String reason, [
    List<String> additionalReasons = const [],
  ]) async => jsonDecode(
    (await channel.invokeMethod<String>('review', {
      'id': id,
      'index': index,
      'reason': reason,
      'additional_reasons': additionalReasons,
    }))!,
  ) as Map<String, dynamic>;
  Future<Map<String, String>?> pick(String kind) async =>
      (await channel.invokeMapMethod<String, String>('pick', {'kind': kind}));
  Future<void> cancel(String id) =>
      channel.invokeMethod<void>('cancel', {'id': id});
  Future<void> delete(String id) =>
      channel.invokeMethod<void>('delete', {'id': id});
  Future<Map<String, dynamic>> diagnoseBanner(String uri) async => jsonDecode(
    (await channel.invokeMethod<String>('diagnose_banner', {'uri': uri}))!,
  ) as Map<String, dynamic>;
}
