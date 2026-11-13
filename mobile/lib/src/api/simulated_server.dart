import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Comportamenti disponibili per il server simulato.
enum SimulatedScenario {
  /// Ogni invio viene confermato.
  success('success'),

  /// Il primo tentativo di ogni invio riceve 503; il ritentativo riesce.
  flaky('flaky'),

  /// La rete non è raggiungibile.
  offline('offline'),

  /// Il server rifiuta l'immagine (422).
  rejected('rejected'),

  /// Il server risponde con un errore interno (500).
  serverError('server_error');

  const SimulatedScenario(this.configValue);

  /// Valore di `SUITES_SIMULATED_SCENARIO`.
  final String configValue;

  static SimulatedScenario? fromConfigValue(String value) {
    for (final scenario in values) {
      if (scenario.configValue == value) return scenario;
    }
    return null;
  }
}

/// SERVER SIMULATO, SOLO PER SVILUPPO.
///
/// Sostituisce la rete all'interno dell'app: le foto non lasciano il
/// telefono e le conferme sono fittizie. Riproduce il contratto proposto
/// (risposte, errori, idempotenza) per provare l'interfaccia senza server.
/// Ogni conferma riporta `"simulated": true`, l'intestazione
/// `x-suites-simulated` e un riferimento che inizia con `SIMULATO-`.
class SimulatedServerClient extends http.BaseClient {
  SimulatedServerClient({
    this.scenario = SimulatedScenario.success,
    this.bytesPerSecond = 2 * 1024 * 1024,
    this.responseDelay = const Duration(milliseconds: 700),
    Random? random,
  }) : _random = random ?? Random();

  final SimulatedScenario scenario;

  /// Velocità di caricamento simulata; 0 per nessun ritardo.
  final int bytesPerSecond;

  /// Attesa simulata tra la fine del caricamento e la risposta.
  final Duration responseDelay;

  final Random _random;
  final _receipts = <String, Map<String, Object?>>{};
  final _attempts = <String, int>{};

  // I campi di testo precedono la foto nel corpo multipart.
  static const _headLimit = 16 * 1024;
  static final _fieldPattern = RegExp(r'form-data; name="([^"]+)"\r\n(?:[^\r\n]+\r\n)*\r\n([^\r]*)\r\n');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var aborted = false;
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.then((_) => aborted = true));
    }
    void checkAborted() {
      if (aborted) throw http.RequestAbortedException(request.url);
    }

    if (scenario == SimulatedScenario.offline) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      checkAborted();
      throw http.ClientException('Server simulato: rete non raggiungibile', request.url);
    }

    final head = BytesBuilder(copy: false);
    await for (final chunk in request.finalize()) {
      checkAborted();
      if (head.length < _headLimit) head.add(chunk);
      if (bytesPerSecond > 0) {
        await Future<void>.delayed(Duration(microseconds: chunk.length * 1000000 ~/ bytesPerSecond));
      }
    }
    if (responseDelay > Duration.zero) await Future<void>.delayed(responseDelay);
    checkAborted();

    final fields = {
      for (final match in _fieldPattern.allMatches(latin1.decode(head.takeBytes())))
        match.group(1)!: match.group(2)!,
    };
    final submissionId = fields['submission_id'] ?? '';

    switch (scenario) {
      case SimulatedScenario.rejected:
        return _json(request, 422, _error('invalid_image', 'Server simulato: immagine rifiutata per prova.'));
      case SimulatedScenario.serverError:
        return _json(request, 500, _error('internal_error', 'Server simulato: errore interno di prova.'));
      case SimulatedScenario.flaky:
        final attempt = _attempts[submissionId] = (_attempts[submissionId] ?? 0) + 1;
        if (attempt == 1) {
          return _json(
            request,
            503,
            _error('server_unavailable', 'Server simulato: non disponibile al primo tentativo.'),
            headers: {'retry-after': '1'},
          );
        }
      case SimulatedScenario.success:
      case SimulatedScenario.offline:
        break;
    }

    final existing = _receipts[submissionId];
    if (existing != null) return _json(request, 200, existing);
    final receipt = _receipts[submissionId] = {
      'submission_id': submissionId,
      'status': 'received',
      'mode': fields['mode'],
      'case_code': fields['case_code'],
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'server_reference': 'SIMULATO-${_random.nextInt(1 << 24).toRadixString(16).padLeft(6, '0').toUpperCase()}',
      'simulated': true,
    };
    return _json(request, 201, receipt);
  }

  static Map<String, Object?> _error(String code, String message) => {
    'error': {'code': code, 'message': message},
  };

  static http.StreamedResponse _json(
    http.BaseRequest request,
    int status,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      contentLength: bytes.length,
      request: request,
      headers: {'content-type': 'application/json', 'x-suites-simulated': 'true', ...headers},
    );
  }
}
