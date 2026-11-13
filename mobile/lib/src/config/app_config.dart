import 'package:flutter/foundation.dart';

import '../api/simulated_server.dart';

/// Collegamento al server scelto in fase di build.
sealed class ServerConnection {
  const ServerConnection();
}

final class RemoteServer extends ServerConnection {
  const RemoteServer(this.baseUrl);

  final Uri baseUrl;
}

/// Server simulato interno all'app: disponibile solo nelle build di debug e
/// profile, sempre segnalato nell'interfaccia.
final class SimulatedServer extends ServerConnection {
  const SimulatedServer(this.scenario);

  final SimulatedScenario scenario;
}

enum ConfigurationIssue {
  missingUrl,
  invalidUrl,
  insecureUrl,
  credentialsInUrl,
  ambiguous,
  simulatedInRelease,
  unknownScenario,
}

/// Nessun server utilizzabile: l'acquisizione funziona, l'invio no.
final class ServerNotConfigured extends ServerConnection {
  const ServerNotConfigured(this.issue);

  final ConfigurationIssue issue;
}

/// Configurazione dell'app, letta dalle variabili di compilazione:
///
/// ```sh
/// flutter run --dart-define=SUITES_API_BASE_URL=https://server.example/api
/// flutter run --dart-define=SUITES_SIMULATED_SERVER=true
/// ```
///
/// Contiene solo valori non segreti: le credenziali non vanno mai passate
/// con `--dart-define`.
class AppConfig {
  const AppConfig({
    required this.connection,
    this.maxUploadBytes = defaultMaxUploadBytes,
    this.maxAttempts = 3,
    this.inactivityTimeout = const Duration(seconds: 30),
  });

  factory AppConfig.fromEnvironment() => AppConfig(
    connection: parseConnection(
      baseUrl: const String.fromEnvironment(baseUrlKey),
      simulated: const bool.fromEnvironment(simulatedKey),
      scenario: const String.fromEnvironment(scenarioKey),
      releaseMode: kReleaseMode,
    ),
  );

  static const baseUrlKey = 'SUITES_API_BASE_URL';
  static const simulatedKey = 'SUITES_SIMULATED_SERVER';
  static const scenarioKey = 'SUITES_SIMULATED_SCENARIO';

  /// Limite della foto, verificato anche dal server.
  static const defaultMaxUploadBytes = 40 * 1024 * 1024;

  final ServerConnection connection;
  final int maxUploadBytes;
  final int maxAttempts;
  final Duration inactivityTimeout;

  static ServerConnection parseConnection({
    required String baseUrl,
    required bool simulated,
    required String scenario,
    required bool releaseMode,
  }) {
    final url = baseUrl.trim();
    if (simulated) {
      if (releaseMode) return const ServerNotConfigured(ConfigurationIssue.simulatedInRelease);
      if (url.isNotEmpty) return const ServerNotConfigured(ConfigurationIssue.ambiguous);
      final parsed = scenario.isEmpty
          ? SimulatedScenario.success
          : SimulatedScenario.fromConfigValue(scenario);
      return parsed == null
          ? const ServerNotConfigured(ConfigurationIssue.unknownScenario)
          : SimulatedServer(parsed);
    }
    if (url.isEmpty) return const ServerNotConfigured(ConfigurationIssue.missingUrl);

    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return const ServerNotConfigured(ConfigurationIssue.invalidUrl);
    }
    if (uri.userInfo.isNotEmpty) {
      return const ServerNotConfigured(ConfigurationIssue.credentialsInUrl);
    }
    // HTTP in chiaro solo per server locali durante lo sviluppo.
    if (uri.scheme == 'http' && releaseMode) {
      return const ServerNotConfigured(ConfigurationIssue.insecureUrl);
    }
    return RemoteServer(uri);
  }
}
