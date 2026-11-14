import 'dart:async';
import 'dart:convert';
import 'dart:io' show TlsException;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:teledermatologia/src/api/http_submission_api.dart';
import 'package:teledermatologia/src/domain/submission.dart';

import '../support/fakes.dart';

typedef Handler = FutureOr<http.StreamedResponse> Function(
  RecordedRequest request,
);

class RecordedRequest {
  RecordedRequest(this.original, this.body);

  final http.BaseRequest original;
  final Uint8List body;

  Map<String, String> get headers => original.headers;

  Map<String, String> get fields => {
    for (final m in RegExp(
      r'form-data; name="([^"]+)"\r\n(?:[^\r\n]+\r\n)*\r\n([^\r]*)\r\n',
    ).allMatches(latin1.decode(body)))
      m.group(1)!: m.group(2)!,
  };

  String get text => latin1.decode(body);
}

/// Client di prova: legge l'intero corpo, poi delega la risposta all'handler.
class RecordingClient extends http.BaseClient {
  RecordingClient(this.handler);

  Handler handler;
  final requests = <RecordedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final recorded = RecordedRequest(request, body);
    requests.add(recorded);
    return handler(recorded);
  }
}

http.StreamedResponse jsonResponse(
  int status,
  Object body, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

Map<String, Object?> receiptJson(
  SubmissionRequest request, {
  Map<String, Object?> overrides = const {},
}) => {
  'submission_id': request.submissionId,
  'status': 'received',
  'mode': request.mode.apiValue,
  'case_code': request.caseCode,
  'received_at': '2026-11-12T10:15:30Z',
  'server_reference': 'SRV-2026-000123',
  ...overrides,
};

void main() {
  final request = sampleRequest();
  late RecordingClient client;
  late List<Duration> waits;

  HttpSubmissionApi api({
    String? token,
    int maxAttempts = 3,
    Duration inactivityTimeout = const Duration(seconds: 30),
    Future<void> Function(Duration)? wait,
  }) => HttpSubmissionApi(
    client: client,
    baseUrl: Uri.parse('https://suites.example.org/api/'),
    accessToken: token == null ? null : () async => token,
    maxAttempts: maxAttempts,
    inactivityTimeout: inactivityTimeout,
    wait: wait ?? (d) async => waits.add(d),
  );

  Future<SubmissionFailure> failureOf(Future<Object?> future) async {
    try {
      await future;
    } on SubmissionFailure catch (failure) {
      return failure;
    }
    fail('Era atteso un SubmissionFailure');
  }

  setUp(() {
    waits = [];
    client = RecordingClient((r) => jsonResponse(201, receiptJson(request)));
  });

  test('invia il modello scelto nel multipart', () async {
    final selected = SubmissionRequest(
      submissionId: request.submissionId,
      caseCode: request.caseCode,
      mode: request.mode,
      photo: request.photo,
      modelId: 'dermoscopic-ftn',
    );
    await api().submit(selected);
    expect(client.requests.single.fields['model_id'], 'dermoscopic-ftn');
  });

  test('l’endpoint conserva il prefisso dell’indirizzo base', () {
    expect(
      HttpSubmissionApi.endpointFor(
        Uri.parse('https://suites.example.org/api/'),
      ).toString(),
      'https://suites.example.org/api/v1/submissions',
    );
    expect(
      HttpSubmissionApi.endpointFor(Uri.parse('https://suites.example.org'))
          .toString(),
      'https://suites.example.org/v1/submissions',
    );
  });

  test(
    'invia foto, modalità e codice caso in multipart, senza alterare la foto',
    () async {
      await api().submit(request);

      final sent = client.requests.single;
      expect(sent.original.method, 'POST');
      expect(
        sent.original.url.toString(),
        'https://suites.example.org/api/v1/submissions',
      );
      expect(sent.headers['accept'], 'application/json');
      expect(sent.headers.containsKey('authorization'), isFalse);
      expect(sent.fields, {
        'submission_id': request.submissionId,
        'mode': 'dermoscopic',
        'case_code': 'CASO-001',
        'source': 'camera',
      });
      expect(sent.text, contains('content-type: image/jpeg'));
      expect(sent.text, contains('name="image"; filename="image.jpg"'));
      final photo = latin1.decode(request.photo.bytes);
      expect(
        sent.text.contains(photo),
        isTrue,
        reason: 'la foto deve arrivare byte per byte',
      );
    },
  );

  test('aggiunge il token di accesso se disponibile', () async {
    await api(token: 'token-di-prova').submit(request);
    expect(
      client.requests.single.headers['authorization'],
      'Bearer token-di-prova',
    );
  });

  test('restituisce la conferma di ricezione', () async {
    final receipt = await api().submit(request);
    expect(receipt.submissionId, request.submissionId);
    expect(receipt.mode, request.mode);
    expect(receipt.caseCode, 'CASO-001');
    expect(receipt.serverReference, 'SRV-2026-000123');
    expect(receipt.receivedAt, DateTime.utc(2026, 11, 12, 10, 15, 30));
    expect(receipt.simulated, isFalse);
  });

  test('una conferma che non corrisponde all’invio non è valida', () async {
    for (final overrides in [
      {'submission_id': 'altro'},
      {'mode': 'clinical'},
      {'case_code': 'CASO-999'},
      {'status': 'queued'},
    ]) {
      client.handler = (r) =>
          jsonResponse(201, receiptJson(request, overrides: overrides));
      final failure = await failureOf(api().submit(request));
      expect(
        failure.kind,
        SubmissionFailureKind.invalidResponse,
        reason: '$overrides',
      );
      expect(failure.canRetry, isTrue);
    }
    expect(
      client.requests,
      hasLength(4),
      reason: 'nessun ritentativo automatico',
    );
  });

  test(
    'una risposta 200 non JSON o troppo grande non conferma la ricezione',
    () async {
      client.handler = (r) => http.StreamedResponse(
        Stream.value(utf8.encode('<html>ok</html>')),
        200,
      );
      expect(
        (await failureOf(api().submit(request))).kind,
        SubmissionFailureKind.invalidResponse,
      );

      client.handler = (r) =>
          http.StreamedResponse(Stream.value(List.filled(70 * 1024, 32)), 200);
      expect(
        (await failureOf(api().submit(request))).kind,
        SubmissionFailureKind.invalidResponse,
      );
    },
  );

  test(
    'riporta codice e messaggio degli errori di validazione, senza ritentare',
    () async {
      client.handler = (r) => jsonResponse(422, {
        'error': {
          'code': 'invalid_case_code',
          'message': 'Codice caso sconosciuto.',
        },
      });
      final failure = await failureOf(api().submit(request));
      expect(failure.kind, SubmissionFailureKind.rejected);
      expect(failure.statusCode, 422);
      expect(failure.serverCode, 'invalid_case_code');
      expect(failure.serverMessage, 'Codice caso sconosciuto.');
      expect(failure.canRetry, isFalse);
      expect(client.requests, hasLength(1));
    },
  );

  test('associa gli stati HTTP ai tipi di errore', () async {
    const expected = {
      400: SubmissionFailureKind.rejected,
      401: SubmissionFailureKind.unauthorized,
      403: SubmissionFailureKind.forbidden,
      404: SubmissionFailureKind.notFound,
      409: SubmissionFailureKind.conflict,
      413: SubmissionFailureKind.payloadTooLarge,
      415: SubmissionFailureKind.unsupportedMediaType,
      500: SubmissionFailureKind.serverError,
      501: SubmissionFailureKind.serverError,
      302: SubmissionFailureKind.unexpectedStatus,
    };
    for (final MapEntry(key: status, value: kind) in expected.entries) {
      client.handler = (r) =>
          http.StreamedResponse(const Stream.empty(), status);
      final failure = await failureOf(api().submit(request));
      expect(failure.kind, kind, reason: 'HTTP $status');
    }
    expect(
      client.requests,
      hasLength(expected.length),
      reason: 'nessun ritentativo automatico',
    );
  });

  test('ritenta da solo un 503 con lo stesso identificativo', () async {
    var calls = 0;
    client.handler = (r) => ++calls == 1
        ? jsonResponse(503, {
            'error': {'code': 'server_unavailable', 'message': ''},
          })
        : jsonResponse(201, receiptJson(request));
    final progress = <SubmissionProgress>[];

    final receipt = await api().submit(request, onProgress: progress.add);

    expect(receipt.submissionId, request.submissionId);
    expect(client.requests.map((r) => r.fields['submission_id']).toSet(), {
      request.submissionId,
    });
    expect(waits, [const Duration(seconds: 2)]);
    final retry = progress.singleWhere(
      (p) => p.phase == SubmissionPhase.waitingToRetry,
    );
    expect(retry.attempt, 2);
    expect(retry.retryIn, const Duration(seconds: 2));
  });

  test('rispetta Retry-After entro il limite', () async {
    var calls = 0;
    client.handler = (r) => ++calls == 1
        ? http.StreamedResponse(
            const Stream.empty(),
            429,
            headers: {'retry-after': '7'},
          )
        : jsonResponse(201, receiptJson(request));
    await api().submit(request);
    expect(waits, [const Duration(seconds: 7)]);
  });

  test('non attende da solo un Retry-After troppo lungo', () async {
    client.handler = (r) => http.StreamedResponse(
      const Stream.empty(),
      503,
      headers: {'retry-after': '600'},
    );
    final failure = await failureOf(api().submit(request));
    expect(failure.kind, SubmissionFailureKind.serverUnavailable);
    expect(failure.retryAfter, const Duration(minutes: 10));
    expect(client.requests, hasLength(1));
    expect(waits, isEmpty);
  });

  test('dopo i tentativi previsti segnala l’errore di rete', () async {
    client.handler = (r) =>
        throw http.ClientException('Connection refused', r.original.url);
    final failure = await failureOf(api().submit(request));
    expect(failure.kind, SubmissionFailureKind.network);
    expect(failure.canRetry, isTrue);
    expect(client.requests, hasLength(3));
    expect(waits, [const Duration(seconds: 2), const Duration(seconds: 4)]);
  });

  test('segnala i problemi di certificato', () async {
    client.handler = (r) =>
        throw const TlsException('CERTIFICATE_VERIFY_FAILED');
    final failure = await failureOf(api().submit(request));
    expect(failure.kind, SubmissionFailureKind.insecureConnection);
    expect(client.requests, hasLength(1));
  });

  test('riporta l’avanzamento fino all’attesa della conferma', () async {
    final progress = <SubmissionProgress>[];
    await api().submit(request, onProgress: progress.add);

    final uploading = progress
        .where((p) => p.phase == SubmissionPhase.uploading)
        .toList();
    expect(uploading.length, greaterThan(2));
    expect(uploading.first.bytesSent, 0);
    for (var i = 1; i < uploading.length; i++) {
      expect(uploading[i].bytesSent, greaterThan(uploading[i - 1].bytesSent));
    }
    final last = progress.last;
    expect(last.phase, SubmissionPhase.awaitingResponse);
    expect(last.bytesSent, last.totalBytes);
    expect(last.totalBytes, greaterThan(request.photo.sizeInBytes));
  });

  test('l’annullamento interrompe l’invio in corso', () async {
    final never = Completer<http.StreamedResponse>();
    client.handler = (r) => never.future;
    final cancel = Completer<void>();

    final result = failureOf(
      api().submit(request, cancelSignal: cancel.future),
    );
    await Future<void>.delayed(Duration.zero);
    cancel.complete();

    expect((await result).kind, SubmissionFailureKind.cancelled);
    expect(client.requests, hasLength(1));
  });

  test(
    'l’annullamento interrompe anche l’attesa prima di un nuovo tentativo',
    () async {
      client.handler = (r) => http.StreamedResponse(const Stream.empty(), 503);
      final cancel = Completer<void>();
      final result = failureOf(
        api(wait: (_) => Completer<void>().future)
            .submit(request, cancelSignal: cancel.future),
      );
      await Future<void>.delayed(Duration.zero);
      cancel.complete();
      expect((await result).kind, SubmissionFailureKind.cancelled);
      expect(client.requests, hasLength(1));
    },
  );

  test('interrompe l’invio dopo un periodo di inattività', () async {
    client.handler = (r) => Completer<http.StreamedResponse>().future;
    final failure = await failureOf(
      api(
        maxAttempts: 1,
        inactivityTimeout: const Duration(milliseconds: 50),
      ).submit(request),
    );
    expect(failure.kind, SubmissionFailureKind.timeout);
    expect(failure.canRetry, isTrue);
  });
}
