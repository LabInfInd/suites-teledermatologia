import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teledermatologia/src/api/user_session.dart';

http.Response loginResponse(String role) => http.Response(
  jsonEncode({
    'access_token': 'token-solo-test',
    'token_type': 'Bearer',
    'user': {
      'id': 'u1',
      'username': '$role.prova',
      'role': role,
      'active': true,
    },
  }),
  200,
);

void main() {
  test(
    'medico: login, catalogo disponibile e revoca senza perdere il prefisso',
    () async {
      final calls = <http.Request>[];
      final session = UserSession(
        baseUrl: Uri.parse('https://example.org/api'),
        client: MockClient((r) async {
          calls.add(r);
          if (r.method == 'POST') {
            expect(jsonDecode(r.body), {
              'username': 'medico',
              'password': 'password-solo-test',
            });
            return loginResponse('doctor');
          }
          expect(r.headers['authorization'], 'Bearer token-solo-test');
          if (r.method == 'DELETE') return http.Response('', 204);
          expect(r.headers['x-requested-with'], 'Telederm');
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
      expect(session.role, UserRole.doctor);
      expect(session.models.single.id, 'clinical-dinov2-base');
      expect(calls[0].url.path, '/api/v1/session');
      expect(calls[1].url.path, '/api/v1/models');
      await session.logout();
      expect(session.token, isNull);
      expect(session.role, isNull);
      expect(session.models, isEmpty);
      expect(calls.last.method, 'DELETE');
    },
  );
  test('paziente: login senza catalogo dei modelli', () async {
    final calls = <String>[];
    final session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls.add('${r.method} ${r.url.path}');
        return loginResponse('patient');
      }),
    );
    await session.login('paziente', 'password-solo-test');
    expect(session.role, UserRole.patient);
    expect(session.username, 'patient.prova');
    expect(session.models, isEmpty);
    expect(calls, ['POST /v1/session']);
  });
  test('amministratore rifiutato con il messaggio del server', () async {
    final session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient(
        (r) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'error': {
                'code': 'forbidden',
                'message':
                    'Gli account amministratore usano l’interfaccia web.',
              },
            }),
          ),
          403,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    await expectLater(
      session.login('admin', 'test'),
      throwsA(
        isA<SessionFailure>().having(
          (f) => f.message,
          'message',
          'Gli account amministratore usano l’interfaccia web.',
        ),
      ),
    );
    expect(session.authenticated, isFalse);
  });
  test('ruolo sconosciuto: il token appena creato viene revocato', () async {
    final calls = <String>[];
    final session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls.add(r.method);
        if (r.method == 'DELETE') return http.Response('', 204);
        return loginResponse('admin');
      }),
    );
    await expectLater(
      session.login('admin', 'test'),
      throwsA(isA<SessionFailure>()),
    );
    expect(session.authenticated, isFalse);
    expect(calls, ['POST', 'DELETE']);
  });
  test('non inoltra il token a URL esterni', () async {
    var calls = 0;
    final session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls++;
        return http.Response('', 500);
      }),
    );
    await expectLater(
      session.artifact('https://external.example/v1/secret'),
      throwsA(isA<SessionFailure>()),
    );
    expect(calls, 0);
  });
  test('un accesso rifiutato non crea una sessione', () async {
    final session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async => http.Response('{}', 401)),
    );
    await expectLater(
      session.login('medico', 'errata'),
      throwsA(isA<SessionFailure>()),
    );
    expect(session.authenticated, isFalse);
  });
  test('catalogo non disponibile revoca il token appena creato', () async {
    final calls = <String>[];
    final session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls.add(r.method);
        if (r.method == 'POST') return loginResponse('doctor');
        if (r.method == 'DELETE') return http.Response('', 204);
        return http.Response('{}', 503);
      }),
    );
    await expectLater(
      session.login('medico', 'test'),
      throwsA(isA<SessionFailure>()),
    );
    expect(session.token, isNull);
    expect(calls, ['POST', 'GET', 'DELETE']);
  });
}
