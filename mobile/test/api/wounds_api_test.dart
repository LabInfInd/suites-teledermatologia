import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teledermatologia/src/api/cases_api.dart';
import 'package:teledermatologia/src/api/http_submission_api.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/domain/acquisition_mode.dart';
import 'package:teledermatologia/src/domain/analysis_task.dart';
import 'package:teledermatologia/src/domain/submission.dart';

import '../support/fake_platform_server.dart';
import '../support/fakes.dart';
import 'http_submission_api_test.dart' show RecordingClient, jsonResponse;

/// Estensione ferite e ulcere (`server/docs/WOUNDS.md`) dal lato client:
/// payload dei casi distinti da quelli degli invii rapidi.
void main() {
  late FakePlatformServer server;
  late UserSession session;
  late CasesApi api;

  Future<void> loginAs(String role, {bool analysisTasks = true}) async {
    server = FakePlatformServer(role: role, analysisTasks: analysisTasks);
    session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: server.client,
    );
    api = CasesApi(session);
    await session.login(role, 'password-solo-test');
  }

  Map<String, dynamic> lastBody(String method, String suffix) =>
      jsonDecode(
            server.requests
                .lastWhere(
                  (r) => r.method == method && r.url.path.endsWith(suffix),
                )
                .body,
          )
          as Map<String, dynamic>;

  group('casi paziente', () {
    test('crea un caso ferite con mode=clinical e analysis_task', () async {
      await loginAs('patient');
      final status = await api.status();
      expect(status.tasksFor(AcquisitionMode.clinical), [
        AnalysisTask.skinLesion,
        AnalysisTask.woundType,
      ]);
      final created = await api.create(
        mode: AcquisitionMode.clinical,
        task: AnalysisTask.woundType,
        bodySite: 'Piede',
        notes: 'Caso sintetico di ricerca',
      );
      expect(lastBody('POST', '/api/cases'), {
        'mode': 'clinical',
        'analysis_task': 'wound_type',
        'body_site': 'Piede',
        'notes': 'Caso sintetico di ricerca',
        'demo_confirmed': true,
      });
      expect(created.mode, AcquisitionMode.clinical);
      expect(created.analysisTask, AnalysisTask.woundType);

      // Upload e submit restano quelli dei casi, con expected_version.
      var data = await api.uploadImage(created, capturedJpeg());
      expect(data.version, created.version + 1);
      data = await api.submit(data);
      expect(lastBody('POST', '/submit'), {'expected_version': 2});
      final run = server.cases[data.id]!['analyses'].first as Map;
      expect(run['model_id'], 'clinical-wounds-azh');
      expect(run['analysis_task'], 'wound_type');
      // Il paziente non vede il catalogo né le inferenze, e non usa /v1.
      final paths = server.requests.map((r) => r.url.path);
      expect(paths.where((p) => p.contains('/models')), isEmpty);
      expect(paths.where((p) => p.startsWith('/v1/submissions')), isEmpty);
      expect(data.analyses, isEmpty);
    });

    test('in bozza cambia percorso esplicitamente; task omesso lo conserva', () async {
      await loginAs('patient');
      var data = await api.create(
        mode: AcquisitionMode.clinical,
        task: AnalysisTask.skinLesion,
        bodySite: '',
        notes: '',
      );
      final stale = data;
      data = await api.setAcquisition(
        data,
        AcquisitionMode.clinical,
        task: AnalysisTask.woundType,
      );
      expect(lastBody('PATCH', '/acquisition'), {
        'expected_version': 1,
        'mode': 'clinical',
        'analysis_task': 'wound_type',
      });
      expect(data.analysisTask, AnalysisTask.woundType);
      data = await api.setAcquisition(data, AcquisitionMode.clinical);
      expect(lastBody('PATCH', '/acquisition'), {
        'expected_version': 2,
        'mode': 'clinical',
      });
      expect(data.analysisTask, AnalysisTask.woundType);
      // Versione superata: 409 senza ritentare.
      await expectLater(
        api.setAcquisition(
          stale,
          AcquisitionMode.dermoscopic,
          task: AnalysisTask.dermoscopicLesion,
        ),
        throwsA(isA<CasesFailure>().having((e) => e.isConflict, 'conflict', isTrue)),
      );
    });

    test('server precedente: nessun analysis_task nelle richieste', () async {
      await loginAs('patient', analysisTasks: false);
      final status = await api.status();
      expect(status.supportsAnalysisTasks, isFalse);
      final data = await api.create(
        mode: AcquisitionMode.clinical,
        bodySite: '',
        notes: '',
      );
      expect(lastBody('POST', '/api/cases').containsKey('analysis_task'), isFalse);
      expect(data.analysisTask, isNull);
      await api.setAcquisition(data, AcquisitionMode.dermoscopic);
      expect(
        lastBody('PATCH', '/acquisition').containsKey('analysis_task'),
        isFalse,
      );
    });
  });

  group('medico', () {
    test('catalogo con task, nomi italiani e modello ferite non predefinito', () async {
      await loginAs('doctor');
      final clinical = await api.models(AcquisitionMode.clinical);
      final wounds = clinical.singleWhere((m) => m.id == 'clinical-wounds-azh');
      expect(wounds.task, AnalysisTask.woundType);
      expect(wounds.isDefault, isFalse);
      expect(wounds.segmentation, isFalse);
      expect(wounds.scope, 'four_known_wound_types_only');
      expect(wounds.classes, woundClasses);
      expect(wounds.nameOf('surgical'), 'Ferita chirurgica');
      expect(clinical.singleWhere((m) => m.isDefault).task, AnalysisTask.skinLesion);
      // Anche il catalogo della sessione (invii rapidi) li espone.
      expect(session.models.map((m) => m.id), contains('clinical-wounds-azh'));
    });

    test('modello ferite non disponibile: resta nel catalogo, non tra i selezionabili', () async {
      server = FakePlatformServer(role: 'doctor', analysisTasks: true)
        ..woundAvailable = false;
      session = UserSession(
        baseUrl: Uri.parse('https://example.org'),
        client: server.client,
      );
      await session.login('doctor', 'password-solo-test');
      expect(session.catalog.map((m) => m.id), contains('clinical-wounds-azh'));
      expect(session.models.map((m) => m.id), isNot(contains('clinical-wounds-azh')));
    });

    test('reanalyze con task, modello e target Grad-CAM delle ferite', () async {
      await loginAs('doctor');
      final data = server.addAnalyzedCase();
      final current = await api.details(data['id'] as String);
      final updated = await api.reanalyze(
        current,
        task: AnalysisTask.woundType,
        modelId: 'clinical-wounds-azh',
        explanationTarget: 'pressure',
      );
      expect(lastBody('POST', '/reanalyze'), {
        'expected_version': current.version,
        'analysis_task': 'wound_type',
        'model_id': 'clinical-wounds-azh',
        'explanation_target': 'pressure',
      });
      expect(updated.latestAnalysis!.analysisTask, AnalysisTask.woundType);
      expect(updated.analysisTask, AnalysisTask.woundType);

      server.completeAnalysis(data);
      final done = await api.details(data['id'] as String);
      final image = done.latestAnalysis!.images.single;
      expect(image.topLabel, 'pressure');
      expect(image.labels.first.score, 0.62);
      expect(image.classification.isWound, isTrue);
      expect(image.explanation.targetClass, 'pressure');
      // Nessuna segmentazione per le ferite.
      expect(image.hasSegmentation, isFalse);
      // Le mappe si scaricano dal percorso autorizzato con il Bearer.
      await api.image(image.heatmapCompositeUrl!);
      final png = server.requests.last;
      expect(png.headers['authorization'], 'Bearer token-di-prova');

      // Un target di un altro modello è rifiutato dal server (400).
      await expectLater(
        api.reanalyze(
          done,
          modelId: 'clinical-wounds-azh',
          explanationTarget: 'NEV',
        ),
        throwsA(isA<CasesFailure>()),
      );
    });

    test('le mappe di un URL non autorizzato non ricevono il token', () async {
      await loginAs('doctor');
      final before = server.requests.length;
      for (final path in [
        'https://altro.example/api/cases/x/images/y',
        '/api/cases/00000000-0000-4000-8000-000000000001/analyses/00000000-0000-4000-8000-000000000002/images/00000000-0000-4000-8000-000000000003/area',
        '/api/cases/../v1/session',
      ]) {
        await expectLater(api.image(path), throwsA(isA<CasesFailure>()));
      }
      expect(server.requests.length, before);
    });
  });

  group('invio rapido ferite', () {
    test('multipart con model_id, mode=clinical ed explain, senza analysis_task', () async {
      final base = sampleRequest();
      final request = SubmissionRequest(
        submissionId: base.submissionId,
        caseCode: base.caseCode,
        mode: AcquisitionMode.clinical,
        photo: base.photo,
        modelId: woundModelId,
        explain: true,
      );
      final client = RecordingClient(
        (r) => jsonResponse(201, {
          'submission_id': request.submissionId,
          'status': 'received',
          'mode': 'clinical',
          'case_code': request.caseCode,
          'model_id': woundModelId,
        }),
      );
      await HttpSubmissionApi(
        client: client,
        baseUrl: Uri.parse('https://sisagen-cardio.poliba.it:11112'),
        accessToken: () async => 'token-solo-test',
      ).submit(request);
      final sent = client.requests.single;
      expect(sent.original.url.path, '/v1/submissions');
      expect(sent.headers['authorization'], 'Bearer token-solo-test');
      expect(sent.fields, {
        'submission_id': request.submissionId,
        'mode': 'clinical',
        'case_code': request.caseCode,
        'source': 'camera',
        'model_id': 'clinical-wounds-azh',
        'explain': 'true',
      });
      expect(sent.text.contains('analysis_task'), isFalse);
    });
  });

  test('artefatti rapidi: solo percorsi /v1 riconosciuti', () async {
    var calls = 0;
    final quick = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: MockClient((r) async {
        calls++;
        return http.Response.bytes(
          pngBytes,
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
    );
    const id = '0b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b';
    await quick.artifact('/v1/submissions/$id/artifacts/heatmap_composite');
    expect(calls, 1);
    await expectLater(
      quick.artifact('/v1/submissions/$id/artifacts/wound_area'),
      throwsA(isA<SessionFailure>()),
    );
    expect(calls, 1);
  });
}
