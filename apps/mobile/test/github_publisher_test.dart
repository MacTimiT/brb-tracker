import 'dart:convert';

import 'package:brb_tracker/github_publisher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> report(String id, {String? video, bool demo = false}) => {
  'schema_version': 1,
  'id': id,
  'title': id,
  'video_id': video,
  'is_demo': demo,
  'duration_seconds': 100,
  'sample_interval_seconds': 2,
  'warnings': <String>[],
  'breaks': [
    {
      'start_seconds': 10,
      'end_seconds': 20,
      'reason': 'Unknown',
      'evidence': '',
      'reviewed': false,
      'truncated': false,
    },
  ],
};
http.Response response(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);
Map<String, dynamic> remote(List<Map<String, dynamic>> reports, String sha) => {
  'encoding': 'base64',
  'sha': sha,
  'content': base64Encode(
    utf8.encode(jsonEncode({'schema_version': 1, 'reports': reports})),
  ),
};

void main() {
  test(
    'publishing preserves original stream date separately from analysis time',
    () {
      final historical = {
        ...report('old'),
        'vod_date': '2026-10-22',
        'vod_date_source': 'release_timestamp',
        'analyzed_at': '2026-11-12T12:00:00Z',
      };
      final merged = GitHubPublisher.merge([], historical).single;
      expect(merged['vod_date'], '2026-10-22');
      expect(merged['analyzed_at'], '2026-11-12T12:00:00Z');
      expect(
        () =>
            GitHubPublisher.validate({...historical, 'vod_date': '2026-02-30'}),
        throwsFormatException,
      );
    },
  );

  test(
    'Merging keeps other VODs, replaces same VOD and removes invented samples',
    () {
      final merged = GitHubPublisher.merge([
        report('demo', demo: true),
        report('older', video: 'IW2rEIuKGSs'),
        report('keep'),
      ], report('replacement', video: 'IW2rEIuKGSs'));
      expect(merged.map((r) => r['id']).toSet(), {'replacement', 'keep'});
      expect(
        () => GitHubPublisher.merge([], report('demo', demo: true)),
        throwsFormatException,
      );
    },
  );
  test('Invalid remote data is never silently overwritten', () async {
    var puts = 0;
    final publisher = GitHubPublisher(
      client: MockClient((request) async {
        if (request.method == 'PUT') {
          puts++;
          return response({});
        }
        if (!request.url.path.contains('/contents/')) {
          return response({'default_branch': 'main'});
        }
        return response({
          'encoding': 'base64',
          'sha': 'x',
          'content': base64Encode(utf8.encode('{"oops":true}')),
        });
      }),
    );
    await expectLater(
      publisher.publish(
        token: 'secret',
        owner: 'owner',
        repo: 'repo',
        report: report('new'),
      ),
      throwsFormatException,
    );
    expect(puts, 0);
    publisher.close();
  });
  test('GitHub conflicts re-read the latest dataset before retrying', () async {
    var reads = 0;
    var puts = 0;
    final publisher = GitHubPublisher(
      client: MockClient((request) async {
        expect(request.url.host, 'api.github.com');
        expect(request.headers['Authorization'], 'Bearer secret');
        if (!request.url.path.contains('/contents/')) {
          return response({'default_branch': 'main'});
        }
        if (request.method == 'GET') {
          reads++;
          return response(
            remote([
              report('keep'),
              if (reads > 1) report('concurrent'),
            ], 'sha-$reads'),
          );
        }
        puts++;
        if (puts == 1) return response({'message': 'Conflict'}, 409);
        final body = jsonDecode(request.body) as Map;
        expect(body['sha'], 'sha-2');
        final data = jsonDecode(
          utf8.decode(base64Decode(body['content'] as String)),
        ) as Map;
        expect((data['reports'] as List).map((r) => r['id']).toSet(), {
          'keep',
          'concurrent',
          'new',
        });
        return response({
          'commit': {'html_url': 'https://github.com/owner/repo/commit/test'},
        });
      }),
    );
    expect(
      await publisher.publish(
        token: 'secret',
        owner: 'owner',
        repo: 'repo',
        report: report('new'),
      ),
      contains('/commit/test'),
    );
    expect(puts, 2);
    publisher.close();
  });
  test('Token failures do not attempt a write', () async {
    var calls = 0;
    final publisher = GitHubPublisher(
      client: MockClient((request) async {
        calls++;
        expect(request.method, 'GET');
        return response({}, 403);
      }),
    );
    await expectLater(
      publisher.publish(
        token: 'bad',
        owner: 'owner',
        repo: 'repo',
        report: report('new'),
      ),
      throwsException,
    );
    expect(calls, 1);
    publisher.close();
  });
}
