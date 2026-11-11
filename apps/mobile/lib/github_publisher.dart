import 'dart:convert';

import 'package:http/http.dart' as http;

class GitHubPublisher {
  GitHubPublisher({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;
  static const path = 'docs/data/reports.json';
  static const reasons = {
    'Pee',
    'Snack',
    'Drink',
    'Stretch',
    'Technical',
    'Other',
    'Unknown',
  };

  static void validate(Map<String, dynamic> report) {
    if (report['schema_version'] != 1 ||
        report['id'] is! String ||
        (report['id'] as String).isEmpty ||
        report['title'] is! String ||
        report['breaks'] is! List ||
        report['duration_seconds'] is! num ||
        !(report['duration_seconds'] as num).isFinite ||
        (report['duration_seconds'] as num) < 0 ||
        report['sample_interval_seconds'] is! num ||
        !(report['sample_interval_seconds'] as num).isFinite ||
        (report['sample_interval_seconds'] as num) <= 0) {
      throw const FormatException(
        'Invalid version 1 report. Nothing was published.',
      );
    }
    final videoId = report['video_id'];
    if (videoId != null &&
        (videoId is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId))) {
      throw const FormatException('Invalid video ID.');
    }
    num end = 0;
    for (final raw in report['breaks'] as List) {
      if (raw is! Map ||
          raw['start_seconds'] is! num ||
          raw['end_seconds'] is! num ||
          !(raw['start_seconds'] as num).isFinite ||
          !(raw['end_seconds'] as num).isFinite ||
          (raw['start_seconds'] as num) < end ||
          (raw['end_seconds'] as num) < (raw['start_seconds'] as num) ||
          (raw['end_seconds'] as num) > (report['duration_seconds'] as num) ||
          !reasons.contains(raw['reason']) ||
          raw['evidence'] is! String) {
        throw const FormatException(
          'Invalid break timing or evidence. Nothing was published.',
        );
      }
      end = raw['end_seconds'] as num;
    }
  }

  static List<Map<String, dynamic>> merge(
    List<dynamic> existing,
    Map<String, dynamic> report,
  ) {
    validate(report);
    if (report['is_demo'] == true) {
      throw const FormatException(
        'Sample reports cannot be published as real observations.',
      );
    }
    final unique = <String, Map<String, dynamic>>{};
    for (final value in existing) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException(
          'The remote dataset is invalid. Nothing was overwritten.',
        );
      }
      validate(value);
      if (value['is_demo'] != true) {
        unique[(value['video_id'] ?? value['id']) as String] = value;
      }
    }
    unique[(report['video_id'] ?? report['id']) as String] = report;
    return unique.values.toList();
  }

  Future<Map<String, dynamic>> _request(
    Uri uri,
    String token, {
    Map<String, dynamic>? body,
    bool allowMissing = false,
  }) async {
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    };
    final response =
        await (body == null
                ? client.get(uri, headers: headers)
                : client.put(uri, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 40));
    if (allowMissing && response.statusCode == 404) return {};
    if (response.statusCode == 409) throw const PublishConflict();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'GitHub returned ${response.statusCode}. Check repository access and the token’s Contents read/write permission. Nothing was published.',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String> publish({
    required String token,
    required String owner,
    required String repo,
    required Map<String, dynamic> report,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(owner) ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(repo) ||
        token.trim().isEmpty) {
      throw const FormatException(
        'Enter a repository owner, name and GitHub token in publishing settings.',
      );
    }
    validate(report);
    if (report['is_demo'] == true) {
      throw const FormatException('Demo reports cannot be published.');
    }
    final repository = await _request(
      Uri.https('api.github.com', '/repos/$owner/$repo'),
      token,
    );
    final branch = repository['default_branch'] as String;
    for (var attempt = 0; attempt < 3; attempt++) {
      final uri = Uri.https(
        'api.github.com',
        '/repos/$owner/$repo/contents/$path',
        {'ref': branch},
      );
      final remote = await _request(uri, token, allowMissing: true);
      List<dynamic> existing = [];
      if (remote.isNotEmpty) {
        if (remote['encoding'] != 'base64' ||
            remote['content'] is! String ||
            remote['sha'] is! String) {
          throw const FormatException(
            'The remote file is not a readable JSON dataset. Nothing was overwritten.',
          );
        }
        final decoded = jsonDecode(
          utf8.decode(
            base64Decode(
              (remote['content'] as String).replaceAll(RegExp(r'\s'), ''),
            ),
          ),
        );
        if (decoded is! Map ||
            decoded['schema_version'] != 1 ||
            decoded['reports'] is! List) {
          throw const FormatException(
            'The remote dataset has an unsupported format. Nothing was overwritten.',
          );
        }
        existing = decoded['reports'] as List<dynamic>;
      }
      final merged = merge(existing, report);
      final content = const JsonEncoder.withIndent('  ')
          .convert({'schema_version': 1, 'reports': merged});
      try {
        final result = await _request(
          Uri.https('api.github.com', '/repos/$owner/$repo/contents/$path'),
          token,
          body: {
            'message':
                'Publish BRB report for ${report['video_id'] ?? report['id']}',
            'branch': branch,
            'content': base64Encode(utf8.encode('$content\n')),
            if (remote['sha'] != null) 'sha': remote['sha'],
          },
        );
        return (result['commit'] as Map<String, dynamic>)['html_url'] as String;
      } on PublishConflict {
        if (attempt == 2) rethrow;
      }
    }
    throw const PublishConflict();
  }

  void close() => client.close();
}

class PublishConflict implements Exception {
  const PublishConflict();
  @override
  String toString() =>
      'The dashboard dataset changed during publication. Try publishing again.';
}
