import 'package:flutter_test/flutter_test.dart';
import 'package:teledermatologia/src/api/simulated_server.dart';
import 'package:teledermatologia/src/config/app_config.dart';

void main() {
  ServerConnection parse({
    String baseUrl = '',
    bool simulated = false,
    String scenario = '',
    bool releaseMode = false,
  }) => AppConfig.parseConnection(
    baseUrl: baseUrl,
    simulated: simulated,
    scenario: scenario,
    releaseMode: releaseMode,
  );

  ConfigurationIssue? issueOf(ServerConnection connection) =>
      connection is ServerNotConfigured ? connection.issue : null;

  test('senza configurazione l’invio non è disponibile', () {
    expect(issueOf(parse()), ConfigurationIssue.missingUrl);
    expect(issueOf(AppConfig.fromEnvironment().connection), ConfigurationIssue.missingUrl);
  });

  test('accetta un server HTTPS, anche con prefisso di percorso', () {
    final connection = parse(baseUrl: ' https://suites.example.org/api ', releaseMode: true);
    expect(connection, isA<RemoteServer>());
    expect((connection as RemoteServer).baseUrl.toString(), 'https://suites.example.org/api');
  });

  test('ammette HTTP solo nelle build di sviluppo', () {
    expect(parse(baseUrl: 'http://192.168.1.20:8000'), isA<RemoteServer>());
    expect(
      issueOf(parse(baseUrl: 'http://192.168.1.20:8000', releaseMode: true)),
      ConfigurationIssue.insecureUrl,
    );
  });

  test('rifiuta indirizzi non validi', () {
    for (final url in [
      'suites.example.org',
      'ftp://suites.example.org',
      'https://',
      'https://suites.example.org/api?token=x',
      'https://suites.example.org/#frammento',
      'non è un url',
    ]) {
      expect(issueOf(parse(baseUrl: url)), ConfigurationIssue.invalidUrl, reason: url);
    }
  });

  test('rifiuta credenziali nell’indirizzo', () {
    expect(
      issueOf(parse(baseUrl: 'https://utente:segreto@suites.example.org')),
      ConfigurationIssue.credentialsInUrl,
    );
  });

  test('il server simulato va richiesto esplicitamente e solo in sviluppo', () {
    final connection = parse(simulated: true);
    expect(connection, isA<SimulatedServer>());
    expect((connection as SimulatedServer).scenario, SimulatedScenario.success);
    expect(
      (parse(simulated: true, scenario: 'flaky') as SimulatedServer).scenario,
      SimulatedScenario.flaky,
    );
    expect(issueOf(parse(simulated: true, scenario: 'boh')), ConfigurationIssue.unknownScenario);
    expect(issueOf(parse(simulated: true, releaseMode: true)), ConfigurationIssue.simulatedInRelease);
    expect(
      issueOf(parse(simulated: true, baseUrl: 'https://suites.example.org')),
      ConfigurationIssue.ambiguous,
    );
  });
}
