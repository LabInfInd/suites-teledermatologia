import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/api/cases_api.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/app.dart';
import 'package:teledermatologia/src/config/app_config.dart';
import 'package:teledermatologia/src/ui/case_widgets.dart';

import '../support/fake_platform_server.dart';
import '../support/fakes.dart';

const message = 'Messaggio di prova per il paziente.';

void main() {
  late FakePhotoPicker picker;
  late List<(Uint8List, String)> shared;

  setUp(() {
    picker = FakePhotoPicker();
    shared = [];
  });

  Future<FakePlatformServer> pumpAndLogin(
    WidgetTester tester, {
    required String role,
    int caseContract = 2,
    void Function(FakePlatformServer server)? setup,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 4000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakePlatformServer(role: role, caseContract: caseContract);
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
          shareImage: (bytes, name) async => shared.add((bytes, name)),
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

  bool enabled(WidgetTester tester, Finder button) =>
      tester.widget<ButtonStyleButton>(button).onPressed != null;

  Iterable<String> requestedPaths(FakePlatformServer server) =>
      server.requests.map((r) => r.url.path);

  /// Pubblica sul server una valutazione con Grad-CAM condivisa, come
  /// farebbe il medico dal web.
  void publishWithGradcam(Map<String, dynamic> data, {String label = 'NEV'}) {
    final run = (data['analyses'] as List).first as Map<String, dynamic>;
    data['state'] = 'released';
    data['version'] = (data['version'] as int) + 1;
    (data['reviews'] as List<Map<String, dynamic>>).add({
      'id': 'review-1',
      'decision': 'approved',
      'final_label': label,
      'patient_message': 'Nevo regolare, controllo fra un anno.',
      'share_segmentation': false,
      'share_explanation': true,
      'analysis_id': run['id'],
      'doctor': 'medico.uno',
      'created_at': '2026-11-14T11:00:00Z',
    });
  }

  group('paziente', () {
    testWidgets('server senza contratto 2: creazione bloccata', (tester) async {
      await pumpAndLogin(tester, role: 'patient', caseContract: 1);
      await tester.tap(find.text('Nuovo caso'));
      await tester.pumpAndSettle();
      expect(find.text('Server non aggiornato'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('demo-confirmed')));
      await tester.pump();
      final create = find.widgetWithText(
        FilledButton,
        'Crea il caso e aggiungi le foto',
      );
      expect(enabled(tester, create), isFalse);
    });

    testWidgets(
      'risposta con Grad-CAM: foto composta senza doppio overlay, nessun punteggio, download autenticato',
      (tester) async {
        late Map<String, dynamic> data;
        final server = await pumpAndLogin(
          tester,
          role: 'patient',
          setup: (server) =>
              publishWithGradcam(data = server.addAnalyzedCase()),
        );
        await openCase(tester, data);

        expect(find.text('Validato dal medico'), findsOneWidget);
        expect(
          find.text('Mappa Grad-CAM condivisa dal medico'),
          findsOneWidget,
        );
        expect(find.text('Classe spiegata: NEV'), findsOneWidget);
        expect(find.text(gradcamWarning), findsOneWidget);
        expect(find.textContaining('%'), findsNothing);
        expect(find.text('Analisi del modello'), findsNothing);

        final composite = find.byWidgetPredicate(
          (w) => w is CaseImageView && w.path.endsWith('/heatmap_composite'),
        );
        expect(composite, findsOneWidget);
        expect(tester.widget<CaseImageView>(composite).overlayPath, isNull);
        expect(
          find.descendant(of: composite, matching: find.byType(Image)),
          findsOneWidget,
        );
        final paths = requestedPaths(server);
        expect(paths.where((p) => p.endsWith('/heatmap_overlay')), isEmpty);
        expect(paths.where((p) => p.endsWith('/heatmap')), isEmpty);
        expect(
          paths.where((p) => p.startsWith('/v1/') && p != '/v1/session'),
          isEmpty,
        );
        expect(paths.where((p) => p == '/api/models'), isEmpty);

        await tester.tap(find.text('Scarica la foto con la mappa'));
        await tester.pumpAndSettle();
        expect(shared, hasLength(1));
        expect(shared.single.$1, pngBytes);
        expect(shared.single.$2, 'gradcam-${data['code']}-foto-1.png');
        final download = server.requests.lastWhere(
          (r) => r.url.path.endsWith('/heatmap_composite'),
        );
        expect(download.headers['authorization'], 'Bearer token-di-prova');
      },
    );

    testWidgets('mappa revocata: 404 la rimuove senza ritentare', (
      tester,
    ) async {
      late Map<String, dynamic> data;
      late String compositeUrl;
      await pumpAndLogin(
        tester,
        role: 'patient',
        setup: (server) {
          publishWithGradcam(data = server.addAnalyzedCase());
          final run = (data['analyses'] as List).first as Map<String, dynamic>;
          compositeUrl =
              ((run['images'] as List).first
                      as Map<String, dynamic>)['heatmap_composite_url']
                  as String;
          server.revoked.add(compositeUrl);
        },
      );
      await openCase(tester, data);
      expect(
        find.byKey(const ValueKey('case-image-unavailable')),
        findsOneWidget,
      );
      expect(find.text('La mappa non è più disponibile.'), findsOneWidget);
      expect(find.byTooltip('Immagine non disponibile: riprova'), findsNothing);
    });

    testWidgets('nuova valutazione senza consenso: la mappa sparisce', (
      tester,
    ) async {
      late Map<String, dynamic> data;
      final server = await pumpAndLogin(
        tester,
        role: 'patient',
        setup: (server) => publishWithGradcam(data = server.addAnalyzedCase()),
      );
      await openCase(tester, data);
      expect(find.text('Mappa Grad-CAM condivisa dal medico'), findsOneWidget);

      final reviews = data['reviews'] as List<Map<String, dynamic>>;
      reviews.add({
        ...reviews.last,
        'id': 'review-2',
        'share_explanation': false,
      });
      await tester.tap(find.byTooltip('Aggiorna'));
      await tester.pumpAndSettle();
      expect(find.text('Mappa Grad-CAM condivisa dal medico'), findsNothing);
      expect(server.requests.last.url.path, '/api/cases/${data['id']}');
    });

    testWidgets(
      'caso storico con nuove foto richieste: modalità da confermare prima dell’invio',
      (tester) async {
        late Map<String, dynamic> data;
        final server = await pumpAndLogin(
          tester,
          role: 'patient',
          setup: (server) =>
              data = server.addAnalyzedCase(mode: null, state: 'needs_images'),
        );
        await openCase(tester, data);
        expect(find.text('Modalità: Modalità non indicata'), findsOneWidget);
        expect(find.text('Modalità da confermare'), findsOneWidget);
        final submit = find.widgetWithText(
          FilledButton,
          'Invia di nuovo il caso',
        );
        expect(enabled(tester, submit), isFalse);

        await tester.tap(find.byKey(const ValueKey('mode-dermoscopic')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Conferma'));
        await tester.pumpAndSettle();
        final patch = server.requests.lastWhere((r) => r.method == 'PATCH');
        expect(jsonDecode(patch.body), {
          'expected_version': 3,
          'mode': 'dermoscopic',
        });
        expect(patch.headers['x-requested-with'], 'Telederm');
        expect(find.text('Modalità: Dermatoscopica'), findsOneWidget);
        expect(find.text('Modalità da confermare'), findsNothing);
        expect(enabled(tester, submit), isTrue);
      },
    );
  });

  group('medico', () {
    testWidgets(
      'classe corretta: ricalcolo Grad-CAM, bozza conservata durante l’attesa, consenso esplicito',
      (tester) async {
        late Map<String, dynamic> data;
        late FakePlatformServer server;
        server = await pumpAndLogin(
          tester,
          role: 'doctor',
          setup: (s) => data = s.addAnalyzedCase(images: 2),
        );
        await openCase(tester, data);
        expect(find.text('NEV: 80.0%'), findsNWidgets(2));

        await tester.tap(find.text('Correggi classificazione'));
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('final-label')),
          'MEL',
        );
        await tester.enterText(
          find.byKey(const ValueKey('patient-message')),
          message,
        );
        await tester.pump();

        final share = find.byKey(const ValueKey('share-explanation'));
        expect(tester.widget<CheckboxListTile>(share).onChanged, isNull);
        expect(
          find.textContaining('ricalcola Grad-CAM per «MEL»'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('recompute-gradcam')));
        await tester.pumpAndSettle();
        final reanalyze = server.requests.lastWhere(
          (r) => r.url.path.endsWith('/reanalyze'),
        );
        expect(jsonDecode(reanalyze.body), {
          'expected_version': 3,
          'model_id': 'clinical-convnextv2-tiny',
          'explanation_target': 'MEL',
        });
        expect(
          find.text('Analisi in corso: la pagina si aggiorna da sola.'),
          findsOneWidget,
        );

        // Il worker completa le mappe per MEL; la pagina si aggiorna da sola.
        server.completeAnalysis(server.cases[data['id']]!);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();

        expect(
          find.text('Grad-CAM per la classe «MEL» · available'),
          findsNWidgets(2),
        );
        // La classificazione del modello non cambia.
        expect(find.text('NEV: 80.0%'), findsNWidgets(2));
        // La bozza è rimasta.
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('patient-message')))
              .controller!
              .text,
          message,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('final-label')))
              .controller!
              .text,
          'MEL',
        );
        // Pronto, ma non condiviso finché il medico non lo sceglie.
        expect(tester.widget<CheckboxListTile>(share).value, isFalse);
        await tester.tap(share);
        await tester.pump();
        expect(tester.widget<CheckboxListTile>(share).value, isTrue);

        await tester.tap(
          find.widgetWithText(FilledButton, 'Pubblica la valutazione'),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Sarà condivisa la mappa Grad-CAM per «MEL».'),
          findsOneWidget,
        );
        await tester.tap(find.text('Pubblica per il paziente'));
        await tester.pumpAndSettle();
        final review = server.requests.lastWhere(
          (r) => r.url.path.endsWith('/reviews'),
        );
        expect(jsonDecode(review.body), {
          // L'ultima versione ricevuta dal server, prima della pubblicazione.
          'expected_version': (data['version'] as int) - 1,
          'decision': 'corrected',
          'final_label': 'MEL',
          'patient_message': message,
          'share_segmentation': false,
          'share_explanation': true,
        });
        expect(data['state'], 'released');
      },
    );

    testWidgets(
      'caso storico: modalità obbligatoria per la nuova analisi, pubblicazione bloccata',
      (tester) async {
        late Map<String, dynamic> data;
        late FakePlatformServer server;
        server = await pumpAndLogin(
          tester,
          role: 'doctor',
          setup: (s) => data = s.addAnalyzedCase(mode: null),
        );
        await openCase(tester, data);
        expect(
          find.text('Caso senza modalità di acquisizione'),
          findsOneWidget,
        );
        // Si può solo chiedere nuove foto; niente conferma o correzione.
        expect(find.text('Richiedi nuove foto'), findsOneWidget);
        expect(find.text('Conferma classificazione'), findsNothing);

        final submit = find.byKey(const ValueKey('reanalyze-submit'));
        expect(enabled(tester, submit), isFalse);
        await tester.tap(find.byKey(const ValueKey('mode-clinical')).first);
        await tester.pumpAndSettle();
        expect(
          server.requests.where((r) => r.url.path == '/api/models'),
          isNotEmpty,
        );
        expect(enabled(tester, submit), isTrue);
        await tester.tap(submit);
        await tester.pumpAndSettle();
        final reanalyze = server.requests.lastWhere(
          (r) => r.url.path.endsWith('/reanalyze'),
        );
        expect(jsonDecode(reanalyze.body), {
          'expected_version': 3,
          'mode': 'clinical',
          'model_id': 'clinical-convnextv2-tiny',
        });
        expect(data['mode'], 'clinical');
      },
    );

    testWidgets(
      'FTN: Grad-CAM composta e segmentazione separate, consensi indipendenti',
      (tester) async {
        late Map<String, dynamic> data;
        late FakePlatformServer server;
        server = await pumpAndLogin(
          tester,
          role: 'doctor',
          setup: (s) => data = s.addAnalyzedCase(mode: 'dermoscopic'),
        );
        await openCase(tester, data);

        // Vista Grad-CAM: solo la foto composta, nessun overlay sopra.
        final composite = find.byWidgetPredicate(
          (w) => w is CaseImageView && w.path.endsWith('/heatmap_composite'),
        );
        expect(composite, findsOneWidget);
        expect(tester.widget<CaseImageView>(composite).overlayPath, isNull);
        expect(
          requestedPaths(server).where((p) => p.endsWith('/heatmap_overlay')),
          isEmpty,
        );

        await tester.tap(find.text('Segmentazione'));
        await tester.pumpAndSettle();
        final segmentation = find.byWidgetPredicate(
          (w) =>
              w is CaseImageView &&
              (w.overlayPath?.endsWith('/overlay') ?? false),
        );
        expect(segmentation, findsOneWidget);
        expect(
          find.text('La segmentazione FTN è separata da Grad-CAM.'),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const ValueKey('patient-message')),
          message,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('share-segmentation')));
        await tester.pump();
        await tester.tap(
          find.widgetWithText(FilledButton, 'Pubblica la valutazione'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pubblica per il paziente'));
        await tester.pumpAndSettle();
        final review = jsonDecode(
          server.requests
              .lastWhere((r) => r.url.path.endsWith('/reviews'))
              .body,
        ) as Map<String, dynamic>;
        expect(review['final_label'], 'NV');
        expect(review['share_segmentation'], isTrue);
        expect(review['share_explanation'], isFalse);
      },
    );

    testWidgets('conflitto 409 sulla revisione: ricarica senza ritentare', (
      tester,
    ) async {
      late Map<String, dynamic> data;
      late FakePlatformServer server;
      server = await pumpAndLogin(
        tester,
        role: 'doctor',
        setup: (s) => data = s.addAnalyzedCase(),
      );
      await openCase(tester, data);
      await tester.enterText(
        find.byKey(const ValueKey('patient-message')),
        message,
      );
      await tester.pump();
      // Un altro medico aggiorna il caso nel frattempo.
      data['version'] = (data['version'] as int) + 1;
      await tester.tap(
        find.widgetWithText(FilledButton, 'Pubblica la valutazione'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pubblica per il paziente'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Il caso è stato aggiornato'), findsOneWidget);
      expect(
        server.requests.where((r) => r.url.path.endsWith('/reviews')),
        hasLength(1),
      );
      expect(server.requests.last.method, 'GET');
      expect(data['reviews'], isEmpty);
      // La bozza resta per riprovare con la nuova versione.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('patient-message')))
            .controller!
            .text,
        message,
      );
    });
  });
}
