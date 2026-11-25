import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/api/cases_api.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/app.dart';
import 'package:teledermatologia/src/config/app_config.dart';
import 'package:teledermatologia/src/domain/analysis_task.dart';

import '../support/fake_platform_server.dart';
import '../support/fakes.dart';

const message = 'Messaggio di prova per il paziente.';

/// Percorso «Ferite e ulcere» nei casi paziente e nella revisione medica.
void main() {
  late FakePhotoPicker picker;

  setUp(() => picker = FakePhotoPicker());

  Future<FakePlatformServer> pumpAndLogin(
    WidgetTester tester, {
    required String role,
    bool analysisTasks = true,
    void Function(FakePlatformServer server)? setup,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 4400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakePlatformServer(role: role, analysisTasks: analysisTasks);
    setup?.call(server);
    final baseUrl = Uri.parse('https://example.org');
    final session = UserSession(baseUrl: baseUrl, client: server.client);
    await tester.pumpWidget(
      SuitesApp(
        dependencies: AppDependencies(
          config: AppConfig(connection: RemoteServer(baseUrl)),
          picker: picker,
          inspector: FakeImageInspector(),
          api: null,
          session: session,
          cases: CasesApi(session),
        ),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Nome utente'),
      '$role.uno',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'password-solo-test',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Accedi'));
    await tester.pumpAndSettle();
    return server;
  }

  Future<void> openCase(WidgetTester tester, Map<String, dynamic> data) async {
    await tester.tap(find.text(data['code'] as String));
    await tester.pumpAndSettle();
  }

  Finder createButton() =>
      find.widgetWithText(FilledButton, 'Crea il caso e aggiungi le foto');

  bool enabled(WidgetTester tester, Finder button) =>
      tester.widget<ButtonStyleButton>(button).onPressed != null;

  Map<String, dynamic> lastBody(FakePlatformServer server, String suffix) =>
      jsonDecode(
            server.requests.lastWhere((r) => r.url.path.endsWith(suffix)).body,
          )
          as Map<String, dynamic>;

  Iterable<String> paths(FakePlatformServer server) =>
      server.requests.map((r) => r.url.path);

  group('paziente', () {
    testWidgets('nuovo caso: le ferite vanno scelte esplicitamente', (
      tester,
    ) async {
      final server = await pumpAndLogin(tester, role: 'patient');
      await tester.tap(find.text('Nuovo caso'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('demo-confirmed')));
      await tester.tap(find.byKey(const ValueKey('mode-clinical')));
      await tester.pump();
      expect(find.text('Cosa vuoi far valutare?'), findsOneWidget);
      expect(find.text('Scegli il tipo di analisi per continuare.'), findsOneWidget);
      // Nessun valore predefinito: niente creazione senza scelta.
      expect(enabled(tester, createButton()), isFalse);

      await tester.tap(find.byKey(const ValueKey('task-wound_type')));
      await tester.pump();
      expect(find.text('Dove si trova la ferita? (facoltativo)'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('body-site')), 'Piede');
      await tester.pump();
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(lastBody(server, '/api/cases'), {
        'mode': 'clinical',
        'analysis_task': 'wound_type',
        'body_site': 'Piede',
        'notes': '',
        'demo_confirmed': true,
      });
      expect(find.text('Tipo di analisi: Ferite e ulcere'), findsOneWidget);
      expect(paths(server).where((p) => p.contains('models')), isEmpty);
    });

    testWidgets('dermatoscopia: solo lesioni cutanee, senza scelta', (
      tester,
    ) async {
      final server = await pumpAndLogin(tester, role: 'patient');
      await tester.tap(find.text('Nuovo caso'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('demo-confirmed')));
      await tester.tap(find.byKey(const ValueKey('mode-dermoscopic')));
      await tester.pump();
      expect(find.byKey(const ValueKey('task-wound_type')), findsNothing);
      expect(find.text('Lesioni cutanee in dermatoscopia'), findsOneWidget);
      await tester.tap(createButton());
      await tester.pumpAndSettle();
      expect(
        lastBody(server, '/api/cases')['analysis_task'],
        'dermoscopic_lesion',
      );
    });

    testWidgets('server precedente: nessun percorso ferite proposto', (
      tester,
    ) async {
      final server = await pumpAndLogin(
        tester,
        role: 'patient',
        analysisTasks: false,
      );
      await tester.tap(find.text('Nuovo caso'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('demo-confirmed')));
      await tester.tap(find.byKey(const ValueKey('mode-clinical')));
      await tester.pump();
      expect(find.text('Cosa vuoi far valutare?'), findsNothing);
      expect(find.byKey(const ValueKey('task-wound_type')), findsNothing);
      await tester.tap(createButton());
      await tester.pumpAndSettle();
      expect(
        lastBody(server, '/api/cases').containsKey('analysis_task'),
        isFalse,
      );
      expect(find.textContaining('Tipo di analisi'), findsNothing);
    });

    testWidgets('bozza: cambio esplicito di percorso con PATCH', (
      tester,
    ) async {
      late Map<String, dynamic> data;
      final server = await pumpAndLogin(
        tester,
        role: 'patient',
        setup: (s) {
          data = s.addAnalyzedCase(state: 'draft');
          data['analyses'] = <Map<String, dynamic>>[];
        },
      );
      await openCase(tester, data);
      expect(find.text('Tipo di analisi: Lesioni cutanee'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('task-wound_type')));
      await tester.pumpAndSettle();
      expect(find.text('Foto clinica · Ferite e ulcere'), findsOneWidget);
      await tester.tap(find.text('Conferma'));
      await tester.pumpAndSettle();
      expect(lastBody(server, '/acquisition'), {
        'expected_version': 3,
        'mode': 'clinical',
        'analysis_task': 'wound_type',
      });
      expect(find.text('Tipo di analisi: Ferite e ulcere'), findsOneWidget);

      // Da dermatoscopia si torna a clinica: il task va riscelto prima di
      // salvare.
      await tester.tap(find.byKey(const ValueKey('mode-dermoscopic')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Conferma'));
      await tester.pumpAndSettle();
      expect(lastBody(server, '/acquisition')['analysis_task'], 'dermoscopic_lesion');
      final patches = server.requests
          .where((r) => r.url.path.endsWith('/acquisition'))
          .length;
      await tester.tap(find.byKey(const ValueKey('mode-clinical')));
      await tester.pumpAndSettle();
      expect(
        server.requests.where((r) => r.url.path.endsWith('/acquisition')),
        hasLength(patches),
      );
      expect(
        find.text('Scegli cosa vuoi far valutare per salvare il percorso.'),
        findsOneWidget,
      );
      expect(paths(server).where((p) => p.contains('models')), isEmpty);
    });

    testWidgets('risposta: etichetta in italiano, nessun punteggio o mappa non approvata', (
      tester,
    ) async {
      late Map<String, dynamic> data;
      final server = await pumpAndLogin(
        tester,
        role: 'patient',
        setup: (s) {
          data = s.addAnalyzedCase(task: 'wound_type', state: 'released');
          final run = (data['analyses'] as List).first as Map<String, dynamic>;
          (data['reviews'] as List<Map<String, dynamic>>).add({
            'id': 'review-1',
            'decision': 'approved',
            'final_label': 'pressure',
            'patient_message': 'Lesione da pressione, medicazione e controllo.',
            'share_segmentation': false,
            'share_explanation': false,
            'analysis_id': run['id'],
            'doctor': 'medico.uno',
            'created_at': '2026-11-20T11:00:00Z',
          });
        },
      );
      await openCase(tester, data);
      expect(find.text('Validato dal medico'), findsOneWidget);
      expect(find.text('Lesione da pressione'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      expect(find.text('Analisi del modello'), findsNothing);
      expect(find.text('Mappa Grad-CAM condivisa dal medico'), findsNothing);
      expect(find.text(woundResearchNotice), findsNothing);
      final requested = paths(server);
      expect(requested.where((p) => p.contains('/analyses/')), isEmpty);
      expect(requested.where((p) => p.contains('models')), isEmpty);
    });
  });

  group('medico', () {
    testWidgets(
      'analisi ferite: nomi italiani per punteggio, Grad-CAM senza segmentazione, pubblicazione con mappa',
      (tester) async {
        late Map<String, dynamic> data;
        final server = await pumpAndLogin(
          tester,
          role: 'doctor',
          setup: (s) => data = s.addAnalyzedCase(task: 'wound_type'),
        );
        await openCase(tester, data);

        expect(find.text(woundResearchNotice), findsOneWidget);
        expect(find.textContaining('Tipo di analisi: Ferite e ulcere'), findsWidgets);
        final scores = [
          'Lesione da pressione: 62.0%',
          'Ulcera diabetica: 18.0%',
          'Ulcera venosa: 15.0%',
          'Ferita chirurgica: 5.0%',
        ];
        final tops = [
          for (final text in scores) tester.getTopLeft(find.text(text)).dy,
        ];
        expect(tops, orderedEquals([...tops]..sort()));
        expect(
          find.text('Grad-CAM per la classe «Lesione da pressione» · available'),
          findsOneWidget,
        );
        expect(find.text('Segmentazione'), findsNothing);
        expect(find.byKey(const ValueKey('share-segmentation')), findsNothing);

        // La predizione è l'etichetta API; il paziente ne leggerà il nome.
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('final-label')))
              .controller!
              .text,
          'pressure',
        );
        expect(find.text('Il paziente leggerà: Lesione da pressione'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('patient-message')),
          message,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('share-explanation')));
        await tester.pump();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Pubblica la valutazione'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pubblica per il paziente'));
        await tester.pumpAndSettle();
        expect(lastBody(server, '/reviews'), {
          'expected_version': 3,
          'decision': 'approved',
          'final_label': 'pressure',
          'patient_message': message,
          'share_segmentation': false,
          'share_explanation': true,
        });

        // Il paziente riceve solo la valutazione e la mappa approvate.
        server.role = 'patient';
        final patient = UserSession(
          baseUrl: Uri.parse('https://example.org'),
          client: server.client,
        );
        final view = await tester.runAsync(() async {
          await patient.login('paziente.uno', 'password-solo-test');
          return CasesApi(patient).details(data['id'] as String);
        });
        expect(view!.analyses, isEmpty);
        expect(view.publishedSegmentations, isEmpty);
        expect(view.publishedExplanations.single.targetClass, 'pressure');
      },
    );

    testWidgets(
      'nuova analisi: target dalle classi del modello, azzerati cambiando tipo',
      (tester) async {
        late Map<String, dynamic> data;
        final server = await pumpAndLogin(
          tester,
          role: 'doctor',
          setup: (s) => data = s.addAnalyzedCase(task: 'wound_type'),
        );
        await openCase(tester, data);
        await tester.tap(find.text('Nuova analisi'));
        await tester.pumpAndSettle();

        // Percorso del caso preselezionato, con il solo modello ferite.
        expect(find.text('DINOv2 ferite (AZH)'), findsOneWidget);
        await tester.tap(find.text('Classe predetta di ogni foto'));
        await tester.pumpAndSettle();
        for (final name in woundNamesIt.values) {
          expect(find.text(name).hitTestable(), findsOneWidget);
        }
        expect(find.text('NEV').hitTestable(), findsNothing);
        await tester.tap(find.text('Ulcera venosa').hitTestable());
        await tester.pumpAndSettle();

        // Cambio di tipo: modello PAD e target azzerato.
        await tester.tap(find.byKey(const ValueKey('task-skin_lesion')));
        await tester.pumpAndSettle();
        expect(find.text('ConvNeXt V2 clinico'), findsOneWidget);
        expect(find.text('Ulcera venosa'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('task-wound_type')));
        await tester.pumpAndSettle();
        expect(find.text('Classe predetta di ogni foto'), findsOneWidget);
        await tester.tap(find.text('Classe predetta di ogni foto'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Lesione da pressione').hitTestable().last);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('reanalyze-submit')));
        await tester.pumpAndSettle();
        expect(lastBody(server, '/reanalyze'), {
          'expected_version': 3,
          'analysis_task': 'wound_type',
          'model_id': 'clinical-wounds-azh',
          'explanation_target': 'pressure',
        });
        expect(
          find.text('Analisi in corso: la pagina si aggiorna da sola.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('modello ferite non installato: nessun ripiego sul PAD', (
      tester,
    ) async {
      late Map<String, dynamic> data;
      final server = await pumpAndLogin(
        tester,
        role: 'doctor',
        setup: (s) {
          data = s.addAnalyzedCase(task: 'wound_type');
          s.woundAvailable = false;
        },
      );
      await openCase(tester, data);
      await tester.tap(find.text('Nuova analisi'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reanalyze-no-model')), findsOneWidget);
      expect(find.text('ConvNeXt V2 clinico'), findsNothing);
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.byKey(const ValueKey('reanalyze-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(paths(server).where((p) => p.endsWith('/reanalyze')), isEmpty);
    });
  });
}
