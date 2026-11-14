import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teledermatologia/src/api/operator_session.dart';

void main() {
  test(
    'login runtime, catalogo disponibile e revoca senza perdere il prefisso',
    () async {
      final calls = <http.Request>[];
      final session = OperatorSession(
        baseUrl: Uri.parse('https://example.org/api'),
        client: MockClient((r) async {
          calls.add(r);
          if (r.method == 'POST') {
            expect(jsonDecode(r.body), {
              'username': 'medico',
              'password': 'password-solo-test',
            });
            return http.Response(
              jsonEncode({
                'access_token': 'token-solo-test',
                'token_type': 'Bearer',
              }),
              200,
            );
          }
          expect(r.headers['authorization'], 'Bearer token-solo-test');
          if (r.method == 'DELETE') return http.Response('', 204);
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'id': 'clinical-dinov2-base',
                  'name': 'DINOv2',
                  'mode': 'clinical',
                  'available': true,
                },
                {
                  'id': 'uninstalled',
                  'name': 'non installato',
                  'mode': 'clinical',
                  'available': false,
                },
              ],
            }),
            200,
          );
        }),
      );
      await session.login('medico', 'password-solo-test');
      expect(session.authenticated, isTrue);
      expect(session.models.single.id, 'clinical-dinov2-base');
      expect(calls[0].url.path, '/api/v1/session');
      expect(calls[1].url.path, '/api/v1/models');
      await session.logout();
      expect(session.token, isNull);
      expect(session.models, isEmpty);
      expect(calls.last.method, 'DELETE');
    },
  );
  test('non inoltra il token a URL esterni', () async {
    var calls = 0;
    final session = OperatorSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls++;
        return http.Response('', 500);
      }),
    );
    await expectLater(
      session.artifact('https://external.example/v1/secret'),
      throwsA(isA<OperatorFailure>()),
    );
    expect(calls, 0);
  });
  test('un accesso rifiutato non crea una sessione', () async {
    final session = OperatorSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async => http.Response('{}', 401)),
    );
    await expectLater(
      session.login('medico', 'errata'),
      throwsA(isA<OperatorFailure>()),
    );
    expect(session.authenticated, isFalse);
  });
  test('catalogo non disponibile revoca il token appena creato', () async {
    final calls = <String>[];
    final session = OperatorSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls.add(r.method);
        if (r.method == 'POST') {
          return http.Response(
            jsonEncode({'access_token': 'test', 'token_type': 'Bearer'}),
            200,
          );
        }
        if (r.method == 'DELETE') return http.Response('', 204);
        return http.Response('{}', 503);
      }),
    );
    await expectLater(
      session.login('medico', 'test'),
      throwsA(isA<OperatorFailure>()),
    );
    expect(session.token, isNull);
    expect(calls, ['POST', 'GET', 'DELETE']);
  });
}
