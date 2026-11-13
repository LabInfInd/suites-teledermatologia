import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:teledermatologia/src/api/http_submission_api.dart';
import 'package:teledermatologia/src/api/simulated_server.dart';
import 'package:teledermatologia/src/app.dart';
import 'package:teledermatologia/src/capture/photo_picker.dart';
import 'package:teledermatologia/src/config/app_config.dart';

import '../support/fakes.dart';

/// Server che riceve la foto ma non risponde mai.
class SilentClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    return Completer<http.StreamedResponse>().future;
  }
}

void main() {
  late FakePhotoPicker picker;

  setUp(() => picker = FakePhotoPicker());

  Future<void> pumpApp(
    WidgetTester tester, {
    ServerConnection connection = const SimulatedServer(SimulatedScenario.success),
    http.Client? client,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 3200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final simulated = connection is SimulatedServer;
    final api = connection is ServerNotConfigured
        ? null
        : HttpSubmissionApi(
            client:
                client ??
                SimulatedServerClient(
                  scenario: simulated ? connection.scenario : SimulatedScenario.success,
                  bytesPerSecond: 0,
                  responseDelay: Duration.zero,
                ),
            baseUrl: Uri.parse('https://server-simulato.invalid'),
            isSimulated: simulated,
          );
    await tester.pumpWidget(
      SuitesApp(
        dependencies: AppDependencies(
          config: AppConfig(connection: connection),
          picker: picker,
          inspector: FakeImageInspector(),
          api: api,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsOneWidget);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
  }

  bool isEnabled(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed != null;

  Future<void> fillForm(WidgetTester tester) async {
    await tapKey(tester, 'mode-clinical');
    picker.enqueue(pickedPng());
    await tapKey(tester, 'acquire-camera');
    await tester.enterText(find.byKey(const ValueKey('case-code')), 'CASO-001');
    await tester.pump();
  }

  testWidgets('flusso completo con il server simulato', (tester) async {
    await pumpApp(tester);

    expect(find.byKey(const ValueKey('simulated-banner')), findsOneWidget);
    expect(find.text('SERVER SIMULATO'), findsOneWidget);
    expect(isEnabled(tester, 'acquire-camera'), isFalse);
    expect(isEnabled(tester, 'submit'), isFalse);

    await tapKey(tester, 'mode-clinical');
    expect(find.textContaining('non può attivare né verificare la macro'), findsOneWidget);
    expect(isEnabled(tester, 'acquire-camera'), isTrue);

    picker.enqueue(pickedPng());
    await tapKey(tester, 'acquire-camera');
    expect(find.byKey(const ValueKey('photo-preview')), findsOneWidget);
    expect(find.textContaining('4032 × 3024 px'), findsOneWidget);
    expect(find.text('Scatta di nuovo'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('case-code')), 'CASO-001');
    await tester.pump();
    expect(find.text('Invia foto clinica'), findsOneWidget);
    expect(isEnabled(tester, 'submit'), isTrue);

    await tapKey(tester, 'submit');
    await pumpUntil(tester, find.byKey(const ValueKey('receipt')));

    expect(find.text('Ricezione confermata (SIMULATA)'), findsOneWidget);
    expect(find.textContaining('SIMULATO-'), findsOneWidget);
    expect(find.textContaining('Non è un risultato diagnostico.'), findsOneWidget);
    expect(find.byKey(const ValueKey('submit')), findsNothing);

    await tapKey(tester, 'new-photo');
    expect(find.byKey(const ValueKey('photo-preview')), findsNothing);
    expect(find.text('CASO-001'), findsOneWidget);
    expect(isEnabled(tester, 'acquire-camera'), isTrue, reason: 'resta la modalità scelta');

    picker.enqueue(pickedPng());
    await tapKey(tester, 'acquire-camera');
    await tapKey(tester, 'submit');
    await pumpUntil(tester, find.byKey(const ValueKey('receipt')));
    await tapKey(tester, 'new-case');
    expect(find.text('CASO-001'), findsNothing);
    expect(isEnabled(tester, 'acquire-camera'), isFalse, reason: 'nuovo caso: modalità da scegliere');
  });

  testWidgets('permesso fotocamera negato e scatto annullato', (tester) async {
    await pumpApp(tester);
    await tapKey(tester, 'mode-dermoscopic');

    picker.enqueue(const PhotoPickException(PhotoPickFailureKind.cameraPermissionDenied));
    await tapKey(tester, 'acquire-camera');
    expect(find.textContaining('Accesso alla fotocamera negato'), findsOneWidget);

    picker.enqueue(null);
    await tapKey(tester, 'acquire-camera');
    expect(find.text('Acquisizione annullata.'), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-preview')), findsNothing);
  });

  testWidgets('errore del server con possibilità di riprovare', (tester) async {
    await pumpApp(tester, connection: const SimulatedServer(SimulatedScenario.serverError));
    await fillForm(tester);

    await tapKey(tester, 'submit');
    await pumpUntil(tester, find.byKey(const ValueKey('upload-failure')));

    expect(find.text('Errore del server'), findsOneWidget);
    expect(find.textContaining('HTTP 500'), findsOneWidget);
    expect(find.text('Riprova invio'), findsOneWidget);
    expect(isEnabled(tester, 'submit'), isTrue);
    expect(find.byKey(const ValueKey('receipt')), findsNothing);
  });

  testWidgets('l’invio in corso mostra l’attesa e si può annullare', (tester) async {
    await pumpApp(
      tester,
      connection: RemoteServer(Uri.parse('https://suites.example.org')),
      client: SilentClient(),
    );
    expect(find.byKey(const ValueKey('simulated-banner')), findsNothing);
    await fillForm(tester);

    await tapKey(tester, 'submit');
    await pumpUntil(tester, find.text('In attesa della conferma del server…'));
    expect(find.byKey(const ValueKey('cancel-upload')), findsOneWidget);
    expect(isEnabled(tester, 'acquire-camera'), isFalse);

    await tapKey(tester, 'cancel-upload');
    await pumpUntil(tester, find.byKey(const ValueKey('upload-failure')));
    expect(find.text('Invio annullato'), findsOneWidget);
    expect(find.text('Riprova invio'), findsOneWidget);
  });

  testWidgets('senza server configurato si acquisisce ma non si invia', (tester) async {
    await pumpApp(tester, connection: const ServerNotConfigured(ConfigurationIssue.missingUrl));
    expect(find.text('Server non configurato'), findsOneWidget);
    expect(find.byKey(const ValueKey('simulated-banner')), findsNothing);

    await fillForm(tester);
    expect(find.byKey(const ValueKey('photo-preview')), findsOneWidget);
    expect(find.text('• Configura il collegamento al server'), findsOneWidget);
    expect(isEnabled(tester, 'submit'), isFalse);
  });

  testWidgets('intestazione con il nome della piattaforma e informazioni', (tester) async {
    await pumpApp(tester);
    expect(find.text('SUI.T.E.S.'), findsOneWidget);
    expect(find.text('Teledermatologia · caso studio'), findsOneWidget);

    await tester.tap(find.byTooltip('Informazioni'));
    await tester.pumpAndSettle();
    expect(find.text('Sustainable and Smart Medical Shelter'), findsOneWidget);
    expect(find.textContaining('non fornisce risultati diagnostici'), findsOneWidget);
  });

  testWidgets('il codice caso non accetta un codice fiscale', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(const ValueKey('case-code')), 'RSSMRA85T10A562S');
    await tester.pump();
    expect(find.textContaining('Sembra un codice fiscale'), findsOneWidget);
  });
}
