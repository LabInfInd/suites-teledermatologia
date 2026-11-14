import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/api/cases_api.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/app.dart';
import 'package:teledermatologia/src/config/app_config.dart';

import '../support/fake_platform_server.dart';
import '../support/fakes.dart';

void main() {
  late FakePhotoPicker picker;

  setUp(() => picker = FakePhotoPicker());

  Future<FakePlatformServer> pumpAndLogin(
    WidgetTester tester, {
    required String role,
    void Function(FakePlatformServer server)? setup,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 3200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakePlatformServer(role: role);
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
    expect(
      find.text(
        'Pazienti e medici del progetto: usa le credenziali ricevute dal referente.',
      ),
      findsOneWidget,
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

  bool enabled(WidgetTester tester, String label) =>
      tester
          .widget<ButtonStyleButton>(
            find.ancestor(
              of: find.text(label),
              matching: find.bySubtype<ButtonStyleButton>(),
            ),
          )
          .onPressed !=
      null;

  testWidgets('paziente: nuovo caso, foto, invio e risposta del medico', (
    tester,
  ) async {
    final server = await pumpAndLogin(tester, role: 'patient');
    expect(find.text('Area paziente · I miei casi'), findsOneWidget);
    expect(find.textContaining('Non hai ancora casi'), findsOneWidget);
    expect(find.text('Analisi rapida'), findsNothing);

    await tester.tap(find.text('Nuovo caso'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('body-site')),
      'Avambraccio sinistro',
    );
    expect(enabled(tester, 'Crea il caso e aggiungi le foto'), isFalse);
    await tester.tap(find.byKey(const ValueKey('demo-confirmed')));
    await tester.pump();
    await tester.tap(find.text('Crea il caso e aggiungi le foto'));
    await tester.pumpAndSettle();

    expect(find.text('Il caso è in preparazione.'), findsOneWidget);
    expect(find.text('Sede: Avambraccio sinistro'), findsOneWidget);
    expect(enabled(tester, 'Invia il caso al medico'), isFalse);

    picker.enqueue(pickedPng());
    await tester.tap(find.text('Fotocamera'));
    await tester.pumpAndSettle();
    expect(find.text('Foto (1 di 4)'), findsOneWidget);
    expect(find.byTooltip('Rimuovi foto'), findsOneWidget);

    await tester.tap(find.text('Invia il caso al medico'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Invia'));
    await tester.pumpAndSettle();
    expect(find.text('Analisi in coda'), findsOneWidget);
    expect(find.text('Fotocamera'), findsNothing);
    expect(find.byTooltip('Rimuovi foto'), findsNothing);

    // Il medico pubblica la valutazione sul server.
    final data = server.cases.values.single;
    data['state'] = 'released';
    data['version'] = (data['version'] as int) + 1;
    (data['reviews'] as List<Map<String, dynamic>>).add({
      'decision': 'approved',
      'final_label': 'Nevo benigno',
      'patient_message': 'Lesione da controllare fra un anno.',
      'doctor': 'medico.uno',
      'created_at': '2026-11-14T11:00:00Z',
    });
    await tester.tap(find.byTooltip('Aggiorna'));
    await tester.pumpAndSettle();
    expect(find.text('Validato dal medico'), findsOneWidget);
    expect(find.text('Nevo benigno'), findsOneWidget);
    expect(find.text('Lesione da controllare fra un anno.'), findsWidgets);
    // Il paziente non vede mai l'analisi del modello.
    expect(find.text('Analisi del modello'), findsNothing);
  });

  testWidgets('paziente: il medico chiede altre foto', (tester) async {
    final server = await pumpAndLogin(tester, role: 'patient');
    final data = server.addAnalyzedCase()
      ..['state'] = 'needs_images'
      ..['reviews'] = [
        {
          'decision': 'needs_images',
          'final_label': null,
          'patient_message': 'Serve una foto più ravvicinata.',
          'doctor': 'medico.uno',
          'created_at': '2026-11-14T11:00:00Z',
        },
      ];
    await tester.tap(find.byTooltip('Esci'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Nome utente'),
      'patient.uno',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'password-solo-test',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Accedi'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(data['code'] as String));
    await tester.pumpAndSettle();
    expect(find.text('Il medico ha richiesto altre immagini.'), findsOneWidget);
    expect(
      find.textContaining('Serve una foto più ravvicinata.'),
      findsWidgets,
    );
    expect(find.text('Invia di nuovo il caso'), findsOneWidget);
    // Nelle richieste di nuove foto le immagini già inviate restano.
    expect(find.byTooltip('Rimuovi foto'), findsNothing);
  });

  testWidgets('medico: valida un caso ricevuto e passa all’analisi rapida', (
    tester,
  ) async {
    late Map<String, dynamic> data;
    await pumpAndLogin(
      tester,
      role: 'doctor',
      setup: (server) => data = server.addAnalyzedCase(),
    );

    expect(find.text('Area medico · Casi ricevuti'), findsOneWidget);
    expect(find.text('In valutazione medica'), findsOneWidget);
    await tester.tap(find.text(data['code'] as String));
    await tester.pumpAndSettle();

    expect(find.text('Analisi del modello'), findsOneWidget);
    expect(find.text('NEV: 80.0%'), findsOneWidget);
    expect(find.text('Paziente: paziente.uno'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('patient-message')),
      'Nevo regolare, controllo fra un anno.',
    );
    await tester.pump();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Pubblica la valutazione'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pubblica per il paziente'));
    await tester.pumpAndSettle();

    final review = (data['reviews'] as List).single as Map<String, dynamic>;
    expect(review['decision'], 'approved');
    expect(review['final_label'], 'NEV');
    expect(data['state'], 'released');
    expect(find.text('Valutazione pubblicata.'), findsWidgets);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analisi rapida'));
    await tester.pumpAndSettle();
    expect(find.text('1. Tipo di acquisizione'), findsOneWidget);
    expect(find.byTooltip('Analisi rapide inviate'), findsOneWidget);
  });

  testWidgets(
    'medico: un’etichetta diversa dalla predizione diventa una correzione',
    (tester) async {
      late Map<String, dynamic> data;
      await pumpAndLogin(
        tester,
        role: 'doctor',
        setup: (server) => data = server.addAnalyzedCase(),
      );
      await tester.tap(find.text(data['code'] as String));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('final-label')),
        'Cheratosi seborroica',
      );
      await tester.enterText(
        find.byKey(const ValueKey('patient-message')),
        'Lesione benigna, nessun trattamento.',
      );
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Pubblica la valutazione'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pubblica per il paziente'));
      await tester.pumpAndSettle();
      final review = (data['reviews'] as List).single as Map<String, dynamic>;
      expect(review['decision'], 'corrected');
      expect(review['final_label'], 'Cheratosi seborroica');
    },
  );
}
