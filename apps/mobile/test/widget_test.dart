import 'package:brb_tracker/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('Entry screen and offline report', (tester) async {
    await tester.pumpWidget(const BrbApp());
    expect(find.text('BRB Tracker'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    await tester.tap(find.text('Explore sample report'));
    await tester.pumpAndSettle();
    expect(find.text('Break report'), findsOneWidget);
    expect(find.textContaining('Invented for demonstration'), findsOneWidget);
    expect(find.textContaining('6 breaks'), findsOneWidget);
  });
  test('API sends token and surfaces authentication errors', () async {
    final api = Api(
      'https://example.com',
      'secret',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer secret');
        expect(request.url.path, '/jobs');
        return http.Response('{"detail":"Unauthorized"}', 401);
      }),
    );
    await expectLater(api.request('/jobs'), throwsException);
    api.close();
  });
  test('Duration formatting supports multi-hour VODs', () {
    expect(timeLabel(3661), '1:01:01');
    expect(timeLabel(0), '0:00:00');
  });
}
