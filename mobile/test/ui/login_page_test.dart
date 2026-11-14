import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/api/user_session.dart';
import 'package:teledermatologia/src/ui/login_page.dart';

import '../support/fake_platform_server.dart';

void main() {
  testWidgets('incolla nome utente e password dagli appunti', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      // Con gli appunti vuoti la piattaforma risponde null.
      (call) async => call.method == 'Clipboard.getData' && clipboard != null
          ? {'text': clipboard}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final server = FakePlatformServer();
    final session = UserSession(
      baseUrl: Uri.parse('https://example.org'),
      client: server.client,
    );
    await tester.pumpWidget(MaterialApp(home: LoginPage(session: session)));

    clipboard = ' paziente.uno ';
    await tester.tap(find.byTooltip('Incolla nome utente'));
    await tester.pump();
    clipboard = 'password-copiata\n';
    await tester.tap(find.byTooltip('Incolla password'));
    await tester.pump();

    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields[0].controller!.text, 'paziente.uno');
    expect(fields[1].controller!.text, 'password-copiata');
    expect(fields[1].obscureText, isTrue);
    expect(fields[0].autofillHints, [AutofillHints.username]);
    expect(fields[1].autofillHints, [AutofillHints.password]);

    await tester.tap(find.byTooltip('Mostra password'));
    await tester.pump();
    expect(
      tester.widgetList<TextField>(find.byType(TextField)).last.obscureText,
      isFalse,
    );

    clipboard = null;
    await tester.tap(find.byTooltip('Incolla password'));
    await tester.pump();
    expect(find.text('Gli appunti non contengono testo.'), findsOneWidget);
    expect(fields[1].controller!.text, 'password-copiata');

    await tester.tap(find.widgetWithText(FilledButton, 'Accedi'));
    await tester.pumpAndSettle();
    expect(session.authenticated, isTrue);
    expect(
      server.requests.first.body,
      contains('"password":"password-copiata"'),
    );
  });
}
