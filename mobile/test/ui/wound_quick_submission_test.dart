import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/api/cases_api.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/app.dart';
import 'package:teledermatologia/src/config/app_config.dart';
import 'package:teledermatologia/src/domain/acquisition_mode.dart';
import 'package:teledermatologia/src/domain/analysis_task.dart';
import 'package:teledermatologia/src/domain/captured_photo.dart';
import 'package:teledermatologia/src/domain/model_catalog.dart';
import 'package:teledermatologia/src/domain/submission.dart';
import 'package:teledermatologia/src/ui/acquisition_controller.dart';

import '../support/fake_platform_server.dart';
import '../support/fakes.dart';

/// Invii rapidi del medico con il percorso ferite: scelta esplicita, modello
/// ferite senza ripiego sul PAD, UUID solo per ritentativi identici.
void main() {
  late FakePhotoPicker picker;
  late FakeSubmissionApi api;
  var idCounter = 0;

  List<CatalogModel> catalog({bool woundAvailable = true}) =>
      CatalogModel.parseList([
        ...(FakePlatformServer(analysisTasks: true)
              ..woundAvailable = woundAvailable)
            .catalog('clinical'),
        ...FakePlatformServer(analysisTasks: true).catalog('dermoscopic'),
      ]);

  AcquisitionController create(List<CatalogModel> models) =>
      AcquisitionController(
        picker: picker,
        inspector: FakeImageInspector(),
        api: api,
        newSubmissionId: () => 'id-${++idCounter}',
        catalog: () => models,
      );

  Future<AcquisitionController> ready(List<CatalogModel> models) async {
    final c = create(models)..selectMode(AcquisitionMode.clinical);
    addTearDown(c.dispose);
    picker.enqueue(pickedPng());
    await c.acquire(PhotoSource.camera);
    c.updateCaseCode('CASO-001');
    return c;
  }

  setUp(() {
    idCounter = 0;
    picker = FakePhotoPicker();
    api = FakeSubmissionApi();
  });

  group('controller', () {
    test('foto clinica: il tipo di analisi va scelto esplicitamente', () async {
      final c = await ready(catalog());
      expect(c.availableTasks, [
        AnalysisTask.skinLesion,
        AnalysisTask.woundType,
      ]);
      expect(c.needsTaskChoice, isTrue);
      expect(c.canSubmit, isFalse);

      c.selectTask(AnalysisTask.woundType);
      expect(c.modelId, 'clinical-wounds-azh');
      expect(c.availableModels.map((m) => m.id), ['clinical-wounds-azh']);
      expect(c.canSubmit, isTrue);
      await c.submit();
      final sent = api.requests.single;
      expect(sent.mode, AcquisitionMode.clinical);
      expect(sent.modelId, 'clinical-wounds-azh');
      expect(sent.explain, isTrue);
    });

    test('lesioni cutanee: predefinito del server e solo modelli PAD', () async {
      final c = await ready(catalog());
      c.selectTask(AnalysisTask.skinLesion);
      expect(c.modelId, isNull);
      expect(
        c.availableModels.map((m) => m.id),
        isNot(contains('clinical-wounds-azh')),
      );
      // Un modello ferite non è selezionabile fuori dal suo percorso, e
      // viceversa.
      c.selectTask(AnalysisTask.woundType);
      c.selectModel('clinical-convnextv2-tiny');
      expect(c.modelId, 'clinical-wounds-azh');
      c.selectModel(null);
      expect(c.modelId, 'clinical-wounds-azh');
    });

    test('modello ferite non disponibile: invio bloccato, nessun PAD', () async {
      final c = await ready(catalog(woundAvailable: false));
      expect(c.availableTasks, contains(AnalysisTask.woundType));
      c.selectTask(AnalysisTask.woundType);
      expect(c.woundModelUnavailable, isTrue);
      expect(c.modelId, isNull);
      expect(c.canSubmit, isFalse);
      await c.submit();
      expect(api.requests, isEmpty);
    });

    test('dermatoscopia o catalogo precedente: nessuna scelta di task', () async {
      final c = create(catalog())..selectMode(AcquisitionMode.dermoscopic);
      addTearDown(c.dispose);
      expect(c.availableTasks, isEmpty);
      expect(c.needsTaskChoice, isFalse);

      final old = create(
        CatalogModel.parseList(FakePlatformServer().catalog('clinical')),
      )..selectMode(AcquisitionMode.clinical);
      addTearDown(old.dispose);
      expect(old.availableTasks, isEmpty);
      expect(old.needsTaskChoice, isFalse);
    });

    test('stesso UUID solo per ritentativi identici', () async {
      final c = await ready(catalog());
      c.selectTask(AnalysisTask.woundType);
      api.handler = (_, _, _) async =>
          throw const SubmissionFailure(SubmissionFailureKind.serverUnavailable);
      await c.submit();
      await c.submit();
      // Cambio di percorso e modello: nuovo invio.
      c.selectTask(AnalysisTask.skinLesion);
      await c.submit();
      c.selectTask(AnalysisTask.woundType);
      await c.submit();
      // Cambio di modalità: si riparte dalla scelta del percorso.
      c.selectMode(AcquisitionMode.dermoscopic);
      expect(c.task, isNull);
      await c.submit();
      expect(api.requests.map((r) => r.submissionId), [
        'id-1',
        'id-1',
        'id-2',
        'id-3',
        'id-4',
      ]);
      expect(api.requests.map((r) => r.modelId), [
        'clinical-wounds-azh',
        'clinical-wounds-azh',
        null,
        'clinical-wounds-azh',
        null,
      ]);
      expect(api.requests.last.explain, isNull);
    });
  });

  group('schermata', () {
    Future<FakePlatformServer> openQuickAnalysis(
      WidgetTester tester, {
      bool woundAvailable = true,
    }) async {
      tester.view
        ..physicalSize = const Size(900, 3600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = FakePlatformServer(role: 'doctor', analysisTasks: true)
        ..woundAvailable = woundAvailable;
      final baseUrl = Uri.parse('https://example.org');
      final session = UserSession(baseUrl: baseUrl, client: server.client);
      await tester.pumpWidget(
        SuitesApp(
          dependencies: AppDependencies(
            config: AppConfig(connection: RemoteServer(baseUrl)),
            picker: picker,
            inspector: FakeImageInspector(),
            api: api,
            session: session,
            cases: CasesApi(session),
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Nome utente'),
        'doctor.uno',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'password-solo-test',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Accedi'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Analisi rapida'));
      await tester.pumpAndSettle();
      return server;
    }

    bool submitEnabled(WidgetTester tester) =>
        tester
            .widget<ButtonStyleButton>(find.byKey(const ValueKey('submit')))
            .onPressed !=
        null;

    testWidgets('ferite: modello esplicito e invio del medico', (tester) async {
      await openQuickAnalysis(tester);
      await tester.tap(find.byKey(const ValueKey('mode-clinical')));
      await tester.pump();
      expect(find.text('Tipo di analisi'), findsOneWidget);
      expect(find.text('• Seleziona il tipo di analisi'), findsOneWidget);
      picker.enqueue(pickedPng());
      await tester.tap(find.byKey(const ValueKey('acquire-camera')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('case-code')), 'CASO-001');
      await tester.pump();
      expect(submitEnabled(tester), isFalse);

      await tester.tap(find.byKey(const ValueKey('task-wound_type')));
      await tester.pumpAndSettle();
      expect(find.text('DINOv2 ferite (AZH)'), findsOneWidget);
      // Nessun «Predefinito del server» (PAD) nel percorso ferite.
      expect(find.text('Predefinito del server'), findsNothing);
      expect(submitEnabled(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey('submit')));
      await tester.pumpAndSettle();
      expect(api.requests.single.modelId, 'clinical-wounds-azh');
      expect(api.requests.single.mode, AcquisitionMode.clinical);
    });

    testWidgets('ferite: modello assente mostra lo stato senza sostituirlo', (
      tester,
    ) async {
      await openQuickAnalysis(tester, woundAvailable: false);
      await tester.tap(find.byKey(const ValueKey('mode-clinical')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('task-wound_type')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('wound-model-unavailable')),
        findsOneWidget,
      );
      expect(find.text('Predefinito del server'), findsNothing);
      expect(find.text('ConvNeXt V2 clinico'), findsNothing);
      expect(
        find.text('• Attendi il modello per ferite e ulcere'),
        findsOneWidget,
      );
      expect(submitEnabled(tester), isFalse);
    });
  });
}
