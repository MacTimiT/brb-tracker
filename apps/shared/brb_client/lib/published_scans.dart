import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'github_publisher.dart';

const dashboardOwner = 'MacTimiT';
const dashboardRepository = 'brb-tracker';
const dashboardBranch = 'main';

final dashboardPublication = ValueNotifier<(String, Object)?>(null);
final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

String? publishedVideoId(Map<dynamic, dynamic> report) {
  final id = report['video_id'] ?? report['id'];
  return id is String && _videoId.hasMatch(id) ? id : null;
}

Future<Set<String>> loadDashboardPublishedScans() async {
  final client = http.Client();
  try {
    final response = await client
        .get(
          Uri.https(
            'raw.githubusercontent.com',
            '/$dashboardOwner/$dashboardRepository/$dashboardBranch/${GitHubPublisher.path}',
            {'refresh': '${DateTime.now().millisecondsSinceEpoch}'},
          ),
          headers: {'Cache-Control': 'no-cache'},
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw const FormatException('Could not read the dashboard reports.');
    }
    return compute(parseDashboardPublishedScans, response.bodyBytes);
  } finally {
    client.close();
  }
}

Set<String> parseDashboardPublishedScans(List<int> bytes) {
  final data = jsonDecode(utf8.decode(bytes));
  if (data is! Map || data['schema_version'] != 1 || data['reports'] is! List) {
    throw const FormatException('Unsupported dashboard report format.');
  }
  final ids = <String>{};
  for (final report in data['reports'] as List) {
    if (report is! Map || report['schema_version'] != 1) {
      throw const FormatException('Invalid dashboard report.');
    }
    if (report['is_demo'] == true) continue;
    if (publishedVideoId(report) case final String id) {
      ids.add(id);
    }
  }
  return ids;
}
