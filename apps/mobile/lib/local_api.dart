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
  Future<Map<String, dynamic>> get(String id) async =>
      jsonDecode((await channel.invokeMethod<String>('get', {'id': id}))!)
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> start(Map<String, dynamic> input) async =>
      jsonDecode((await channel.invokeMethod<String>('start', input))!)
          as Map<String, dynamic>;
  Future<Map<String, dynamic>> review(
    String id,
    int index,
    String reason,
  ) async => jsonDecode(
    (await channel.invokeMethod<String>('review', {
      'id': id,
      'index': index,
      'reason': reason,
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
