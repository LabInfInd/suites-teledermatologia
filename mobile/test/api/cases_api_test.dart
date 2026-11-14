import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teledermatologia/src/api/cases_api.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/domain/patient_case.dart';

import '../support/fake_platform_server.dart';
import '../support/fakes.dart';

void main() {
  late FakePlatformServer server;
  late UserSession session;
  late CasesApi api;

  setUp(() async {
    server = FakePlatformServer();
    session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: server.client,
    );
    api = CasesApi(session);
    await session.login('paziente', 'password-solo-test');
  });

  test('crea un caso, carica una foto con nome generico e lo invia', () async {
    var data = await api.create(bodySite: 'Avambraccio', notes: 'Nota');
    expect(data.state, CaseState.draft);
    final create = server.requests.last;
    expect(jsonDecode(create.body), {
      'body_site': 'Avambraccio',
      'notes': 'Nota',
      'demo_confirmed': true,
    });
    expect(create.headers['authorization'], 'Bearer token-di-prova');
    expect(create.headers['x-requested-with'], 'Telederm');
    expect(create.headers.containsKey('cookie'), isFalse);

    data = await api.uploadImage(data, capturedJpeg(size: 1024));
    final upload = server.requests.last;
    final body = latin1.decode(upload.bodyBytes);
    expect(upload.url.path, '/api/cases/${data.id}/images');
    expect(upload.headers['content-type'], startsWith('multipart/form-data'));
    expect(body, contains('name="expected_version"\r\n\r\n1'));
    expect(body, contains('filename="foto.jpg"'));
    expect(body, contains('content-type: image/jpeg'));
    expect(data.images, hasLength(1));
    expect(data.version, 2);

    data = await api.submit(data);
    expect(data.state, CaseState.queued);
    expect(jsonDecode(server.requests.last.body), {'expected_version': 2});
  });

  test(
    'versione superata: errore di conflitto con il messaggio del server',
    () async {
      final data = await api.create(bodySite: '', notes: '');
      await api.uploadImage(data, capturedJpeg(size: 1024));
      await expectLater(
        api.submit(data),
        throwsA(
          isA<CasesFailure>()
              .having((f) => f.isConflict, 'isConflict', isTrue)
              .having((f) => f.message, 'message', contains('aggiornato')),
        ),
      );
    },
  );

  test('il paziente non riceve analisi né codice paziente', () async {
    server.addAnalyzedCase();
    final list = await api.list();
    final details = await api.details(list.items.single.id);
    expect(details.patientCode, isNull);
    expect(details.analyses, isEmpty);
  });

  test('sessione scaduta: torna all’accesso', () async {
    final expired = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async {
        if (r.url.path == '/v1/session') {
          return http.Response(
            jsonEncode({
              'access_token': 't',
              'token_type': 'Bearer',
              'user': {'role': 'patient'},
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'detail': 'Accedi per continuare.'}),
          401,
        );
      }),
    );
    await expired.login('paziente', 'test');
    await expectLater(CasesApi(expired).list(), throwsA(isA<CasesFailure>()));
    expect(expired.authenticated, isFalse);
  });

  test(
    'il token non viene inviato a indirizzi di immagini non riconosciuti',
    () async {
      final before = server.requests.length;
      for (final path in [
        'https://external.example/api/cases/x/images/y',
        '/api/admin/users',
        '/api/cases/../admin',
      ]) {
        await expectLater(api.image(path), throwsA(isA<CasesFailure>()));
      }
      expect(server.requests.length, before);
    },
  );

  test('scarica le immagini dei casi', () async {
    final data = server.addAnalyzedCase();
    final image = (data['images'] as List).single as Map<String, dynamic>;
    expect(await api.image(image['url'] as String), pngBytes);
  });
}
