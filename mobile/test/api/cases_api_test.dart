import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teledermatologia/src/api/cases_api.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/domain/acquisition_mode.dart';
import 'package:teledermatologia/src/domain/patient_case.dart';

import '../support/fake_platform_server.dart';
import '../support/fakes.dart';

void main() {
  late FakePlatformServer server;
  late UserSession session;
  late CasesApi api;

  Future<void> loginAs(String role) async {
    server = FakePlatformServer(role: role);
    session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: server.client,
    );
    api = CasesApi(session);
    await session.login(role, 'password-solo-test');
  }

  /// Ogni richiesta autenticata ha il Bearer; ogni scrittura anche
  /// `x-requested-with`; mai cookie, Origin o CSRF.
  void expectAppHeaders(Iterable<http.Request> requests) {
    for (final r in requests.where((r) => r.url.path != '/v1/session')) {
      final what = '${r.method} ${r.url}';
      expect(r.headers['authorization'], 'Bearer token-di-prova', reason: what);
      if (r.method != 'GET') {
        expect(r.headers['x-requested-with'], 'Telederm', reason: what);
      }
      for (final header in ['cookie', 'origin', 'x-csrf-token']) {
        expect(r.headers.containsKey(header), isFalse, reason: what);
      }
    }
  }

  const message = 'Messaggio di prova per il paziente.';

  group('paziente', () {
    setUp(() => loginAs('patient'));

    test('crea con modalità, carica, corregge la modalità e invia', () async {
      expect((await api.status()).supportsAcquisitionModes, isTrue);
      var data = await api.create(
        mode: AcquisitionMode.dermoscopic,
        bodySite: 'Avambraccio',
        notes: 'Nota',
      );
      expect(data.mode, AcquisitionMode.dermoscopic);
      expect(jsonDecode(server.requests.last.body), {
        'mode': 'dermoscopic',
        'body_site': 'Avambraccio',
        'notes': 'Nota',
        'demo_confirmed': true,
      });

      data = await api.uploadImage(data, capturedJpeg(size: 1024));
      final upload = server.requests.last;
      final body = latin1.decode(upload.bodyBytes);
      expect(upload.headers['content-type'], startsWith('multipart/form-data'));
      expect(body, contains('name="expected_version"\r\n\r\n1'));
      expect(body, contains('filename="foto.jpg"'));
      expect(body, contains('content-type: image/jpeg'));
      expect(data.version, 2);

      data = await api.setAcquisition(data, AcquisitionMode.clinical);
      final patch = server.requests.last;
      expect(patch.method, 'PATCH');
      expect(patch.url.path, '/api/cases/${data.id}/acquisition');
      expect(jsonDecode(patch.body), {
        'expected_version': 2,
        'mode': 'clinical',
      });
      expect(data.mode, AcquisitionMode.clinical);

      data = await api.submit(data);
      expect(data.state, CaseState.queued);
      expect(jsonDecode(server.requests.last.body), {'expected_version': 3});
      expectAppHeaders(server.requests);
    });

    test('versione superata: 409 con il messaggio del server', () async {
      final data = await api.create(
        mode: AcquisitionMode.clinical,
        bodySite: '',
        notes: '',
      );
      await api.uploadImage(data, capturedJpeg(size: 1024));
      await expectLater(
        api.submit(data),
        throwsA(
          isA<CasesFailure>()
              .having((f) => f.isConflict, 'isConflict', isTrue)
              .having((f) => f.message, 'message', contains('aggiornato')),
        ),
      );
    });

    test('validazione del server (422): mostra il suo messaggio', () async {
      final data = await api.create(
        mode: AcquisitionMode.clinical,
        bodySite: '',
        notes: '',
      );
      await expectLater(
        api.review(
          data,
          decision: ReviewDecision.approved,
          finalLabel: 'NEV',
          patientMessage: message,
          shareSegmentation: false,
          shareExplanation: false,
        ),
        throwsA(isA<CasesFailure>()),
      );
      final invalid = UserSession(
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
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'detail': 'Controlla i campi inseriti.',
                'errors': [
                  {'field': 'mode', 'message': 'Field required'},
                ],
              }),
            ),
            422,
          );
        }),
      );
      await invalid.login('paziente', 'test');
      await expectLater(
        CasesApi(invalid)
            .create(mode: AcquisitionMode.clinical, bodySite: '', notes: ''),
        throwsA(
          isA<CasesFailure>()
              .having((f) => f.statusCode, 'status', 422)
              .having(
                (f) => f.message,
                'message',
                'Controlla i campi inseriti.',
              ),
        ),
      );
    });

    test(
      'caso storico: conferma della modalità, poi non più modificabile',
      () async {
        final stored = server.addAnalyzedCase(
          mode: null,
          state: 'needs_images',
        );
        var data = await api.details(stored['id'] as String);
        expect(data.mode, isNull);
        data = await api.setAcquisition(data, AcquisitionMode.dermoscopic);
        expect(data.mode, AcquisitionMode.dermoscopic);
        await expectLater(
          api.setAcquisition(data, AcquisitionMode.clinical),
          throwsA(
            isA<CasesFailure>().having((f) => f.statusCode, 'status', 409),
          ),
        );
      },
    );

    test(
      'nessuna analisi né punteggio; catalogo dei modelli vietato',
      () async {
        final stored = server.addAnalyzedCase();
        final details = await api.details(stored['id'] as String);
        expect(details.patientCode, isNull);
        expect(details.analyses, isEmpty);
        expect(details.publishedExplanations, isEmpty);
        await expectLater(
          api.models(AcquisitionMode.clinical),
          throwsA(
            isA<CasesFailure>().having((f) => f.statusCode, 'status', 403),
          ),
        );
      },
    );

    test('mappa non pubblicata: 404 riconoscibile', () async {
      final stored = server.addAnalyzedCase();
      final run = (stored['analyses'] as List).first as Map<String, dynamic>;
      final item = (run['images'] as List).first as Map<String, dynamic>;
      await expectLater(
        api.image(item['heatmap_composite_url'] as String),
        throwsA(isA<CasesFailure>().having((f) => f.statusCode, 'status', 404)),
      );
    });
  });

  group('medico', () {
    setUp(() => loginAs('doctor'));

    test('catalogo, ricalcolo per classe e consensi separati', () async {
      final stored = server.addAnalyzedCase();
      final models = await api.models(AcquisitionMode.clinical);
      expect(server.requests.last.url.query, 'mode=clinical');
      expect(models.map((m) => m.id), contains('clinical-dinov2-base'));
      expect(models.first.classes, clinicalClasses);

      var data = await api.details(stored['id'] as String);
      expect(data.latestAnalysis!.explanationReadyFor('NEV'), isTrue);
      expect(data.latestAnalysis!.explanationReadyFor('MEL'), isFalse);

      // Correzione a MEL con Grad-CAM: rifiutata finché le mappe spiegano NEV.
      await expectLater(
        api.review(
          data,
          decision: ReviewDecision.corrected,
          finalLabel: 'MEL',
          patientMessage: message,
          shareSegmentation: false,
          shareExplanation: true,
        ),
        throwsA(isA<CasesFailure>().having((f) => f.statusCode, 'status', 409)),
      );
      data = await api.details(data.id);

      data = await api.reanalyze(
        data,
        modelId: 'clinical-convnextv2-tiny',
        explanationTarget: 'MEL',
      );
      expect(jsonDecode(server.requests.last.body), {
        'expected_version': data.version - 1,
        'model_id': 'clinical-convnextv2-tiny',
        'explanation_target': 'MEL',
      });
      expect(data.state, CaseState.queued);
      server.completeAnalysis(server.cases[data.id]!);
      data = await api.details(data.id);
      expect(data.latestAnalysis!.explanationTarget, 'MEL');
      // Il ricalcolo della mappa non cambia la classificazione.
      expect(data.latestAnalysis!.images.single.topLabel, 'NEV');
      expect(data.latestAnalysis!.explanationReadyFor('MEL'), isTrue);

      data = await api.review(
        data,
        decision: ReviewDecision.corrected,
        finalLabel: 'MEL',
        patientMessage: message,
        shareSegmentation: false,
        shareExplanation: true,
      );
      expect(jsonDecode(server.requests.last.body), {
        'expected_version': data.version - 1,
        'decision': 'corrected',
        'final_label': 'MEL',
        'patient_message': message,
        'share_segmentation': false,
        'share_explanation': true,
      });
      expect(data.state, CaseState.released);
      expect(data.latestReview!.shareExplanation, isTrue);
      expectAppHeaders(server.requests);
    });

    test('nuova analisi senza classe: explanation_target omesso', () async {
      final stored = server.addAnalyzedCase(mode: null, state: 'waiting_model');
      final data = await api.details(stored['id'] as String);
      await api.reanalyze(data, mode: AcquisitionMode.clinical);
      expect(jsonDecode(server.requests.last.body), {
        'expected_version': data.version,
        'mode': 'clinical',
      });
    });

    test('scarica mappe e segmentazione dei casi con il Bearer', () async {
      final stored = server.addAnalyzedCase(mode: 'dermoscopic');
      final data = await api.details(stored['id'] as String);
      final result = data.latestAnalysis!.images.single;
      expect(result.hasSegmentation, isTrue);
      for (final path in [
        result.heatmapUrl!,
        result.heatmapOverlayUrl!,
        result.heatmapCompositeUrl!,
        result.overlayUrl!,
        result.maskUrl!,
      ]) {
        expect(await api.image(path), pngBytes);
      }
      expectAppHeaders(server.requests);
    });
  });

  test('sessione scaduta (401): torna all’accesso', () async {
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

  test('server senza contratto 2: nessuna modalità di acquisizione', () async {
    server = FakePlatformServer(caseContract: 1);
    session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: server.client,
    );
    await session.login('paziente', 'test');
    expect(
      (await CasesApi(session).status()).supportsAcquisitionModes,
      isFalse,
    );
  });

  test('il token non viene inviato a indirizzi non riconosciuti', () async {
    await loginAs('patient');
    final before = server.requests.length;
    const id = '00000000-0000-4000-8000-00000000000';
    for (final path in [
      'https://external.example/api/cases/x/images/y',
      '/api/admin/users',
      '/api/cases/../admin',
      '/api/cases/${id}1/analyses/${id}2/images/${id}3/raw',
    ]) {
      await expectLater(api.image(path), throwsA(isA<CasesFailure>()));
    }
    expect(server.requests.length, before);
  });
}
