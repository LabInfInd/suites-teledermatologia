import 'dart:async';
import 'dart:convert';
import 'dart:io' show TlsException;
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../domain/submission.dart';
import 'submission_api.dart';

/// Client HTTP per il contratto proposto in `docs/api-contratto-proposta.md`.
///
/// Gestisce avanzamento, annullamento, timeout per inattività e ritentativi
/// automatici dei soli errori transitori. Non registra nulla nei log.
class HttpSubmissionApi implements SubmissionApi {
  HttpSubmissionApi({
    required this._client,
    required Uri baseUrl,
    AccessTokenProvider? accessToken,
    this.maxAttempts = 3,
    this.inactivityTimeout = const Duration(seconds: 30),
    Future<void> Function(Duration delay)? wait,
    this.isSimulated = false,
  }) : endpoint = endpointFor(baseUrl),
       _accessToken = accessToken ?? _noAccessToken,
       _wait = wait ?? Future<void>.delayed;

  /// Dimensione dei blocchi con cui viene trasmessa la foto.
  static const chunkSize = 64 * 1024;

  /// Oltre questa attesa richiesta dal server l'app non ritenta da sola.
  static const maxRetryAfter = Duration(seconds: 60);

  static const _maxResponseBytes = 64 * 1024;

  final http.Client _client;
  final AccessTokenProvider _accessToken;
  final Future<void> Function(Duration delay) _wait;

  /// URL completo dell'endpoint di invio.
  final Uri endpoint;

  /// Tentativi totali per gli errori transitori, compreso il primo.
  final int maxAttempts;

  /// L'invio viene interrotto se per questo intervallo non vengono né
  /// trasmessi né ricevuti dati.
  final Duration inactivityTimeout;

  @override
  final bool isSimulated;

  static Uri endpointFor(Uri baseUrl) => baseUrl.replace(
    pathSegments: [...baseUrl.pathSegments.where((s) => s.isNotEmpty), 'v1', 'submissions'],
  );

  static Future<String?> _noAccessToken() async => null;

  @override
  Future<SubmissionReceipt> submit(
    SubmissionRequest request, {
    void Function(SubmissionProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await _attempt(request, attempt, onProgress, cancelSignal);
      } on SubmissionFailure catch (failure) {
        if (!failure.isTransient || attempt >= maxAttempts) rethrow;
        final delay = _retryDelay(failure, attempt);
        if (delay == null) rethrow;
        onProgress?.call(
          SubmissionProgress(
            phase: SubmissionPhase.waitingToRetry,
            attempt: attempt + 1,
            maxAttempts: maxAttempts,
            retryIn: delay,
          ),
        );
        try {
          await _orAbort(_wait(delay), cancelSignal);
        } on _Aborted {
          throw const SubmissionFailure(SubmissionFailureKind.cancelled);
        }
      }
    }
  }

  Duration? _retryDelay(SubmissionFailure failure, int attempt) {
    final retryAfter = failure.retryAfter;
    if (retryAfter != null) return retryAfter <= maxRetryAfter ? retryAfter : null;
    return Duration(seconds: 2 << (attempt - 1)); // 2 s, 4 s, 8 s...
  }

  Future<SubmissionReceipt> _attempt(
    SubmissionRequest request,
    int attempt,
    void Function(SubmissionProgress progress)? onProgress,
    Future<void>? cancelSignal,
  ) async {
    final abort = Completer<void>();
    var timedOut = false;
    Timer? watchdog;
    void kick() {
      watchdog?.cancel();
      watchdog = Timer(inactivityTimeout, () {
        timedOut = true;
        if (!abort.isCompleted) abort.complete();
      });
    }

    unawaited(
      cancelSignal?.then((_) {
        if (!abort.isCompleted) abort.complete();
      }),
    );

    void report(SubmissionPhase phase, int sent, int total) => onProgress?.call(
      SubmissionProgress(
        phase: phase,
        attempt: attempt,
        maxAttempts: maxAttempts,
        bytesSent: sent,
        totalBytes: total,
      ),
    );

    try {
      final token = await _orAbort(_accessToken(), abort.future);
      var lastReported = -1;
      final upload = _UploadRequest(
        endpoint,
        abortTrigger: abort.future,
        onBytesSent: (sent, total) {
          kick();
          if (sent >= total) {
            report(SubmissionPhase.awaitingResponse, sent, total);
          } else if (sent * 200 ~/ total > lastReported) {
            lastReported = sent * 200 ~/ total;
            report(SubmissionPhase.uploading, sent, total);
          }
        },
      );
      upload.headers['accept'] = 'application/json';
      if (token != null && token.isNotEmpty) {
        upload.headers['authorization'] = 'Bearer $token';
      }
      upload.fields.addAll({
        'submission_id': request.submissionId,
        'mode': request.mode.apiValue,
        'case_code': request.caseCode,
        'source': request.photo.source.apiValue,
      });
      final photo = request.photo;
      upload.files.add(
        http.MultipartFile(
          'image',
          _chunked(photo.bytes),
          photo.bytes.length,
          // Nome generico: il nome originale può contenere data o altri dati.
          filename: 'image.${photo.format.extension}',
          contentType: MediaType.parse(photo.format.mediaType),
        ),
      );

      report(SubmissionPhase.uploading, 0, upload.contentLength);
      kick();
      final response = await _orAbort(_client.send(upload), abort.future);
      kick();
      final body = await _orAbort(_readBody(response.stream, kick), abort.future);
      return _interpret(response.statusCode, response.headers, body, request);
    } on SubmissionFailure {
      rethrow;
    } on _Aborted {
      throw _abortFailure(timedOut);
    } on http.RequestAbortedException {
      throw _abortFailure(timedOut);
    } on http.ClientException {
      throw const SubmissionFailure(SubmissionFailureKind.network);
    } on TlsException {
      throw const SubmissionFailure(SubmissionFailureKind.insecureConnection);
    } on TimeoutException {
      throw const SubmissionFailure(SubmissionFailureKind.timeout);
    } on Exception {
      throw const SubmissionFailure(SubmissionFailureKind.unknown);
    } finally {
      watchdog?.cancel();
    }
  }

  static SubmissionFailure _abortFailure(bool timedOut) => SubmissionFailure(
    timedOut ? SubmissionFailureKind.timeout : SubmissionFailureKind.cancelled,
  );

  SubmissionReceipt _interpret(
    int status,
    Map<String, String> headers,
    _ResponseBody body,
    SubmissionRequest request,
  ) {
    if (status >= 200 && status < 300) {
      return _parseReceipt(status, body, request);
    }
    final error = body.truncated ? null : _decodeObject(body.bytes)?['error'];
    final code = error is Map<String, Object?> ? error['code'] : null;
    final message = error is Map<String, Object?> ? error['message'] : null;
    final kind = switch (status) {
      400 || 422 => SubmissionFailureKind.rejected,
      401 => SubmissionFailureKind.unauthorized,
      403 => SubmissionFailureKind.forbidden,
      404 => SubmissionFailureKind.notFound,
      409 => SubmissionFailureKind.conflict,
      413 => SubmissionFailureKind.payloadTooLarge,
      415 => SubmissionFailureKind.unsupportedMediaType,
      429 => SubmissionFailureKind.rateLimited,
      502 || 503 || 504 => SubmissionFailureKind.serverUnavailable,
      >= 500 => SubmissionFailureKind.serverError,
      _ => SubmissionFailureKind.unexpectedStatus,
    };
    throw SubmissionFailure(
      kind,
      statusCode: status,
      serverCode: code is String ? _clip(code, 64) : null,
      serverMessage: message is String ? _clip(message, 300) : null,
      retryAfter: _parseRetryAfter(headers['retry-after']),
    );
  }

  SubmissionReceipt _parseReceipt(int status, _ResponseBody body, SubmissionRequest request) {
    final json = body.truncated ? null : _decodeObject(body.bytes);
    // La conferma vale solo se si riferisce esattamente a questo invio.
    if (json == null ||
        json['status'] != 'received' ||
        json['submission_id'] != request.submissionId ||
        json['mode'] != request.mode.apiValue ||
        json['case_code'] != request.caseCode) {
      throw SubmissionFailure(SubmissionFailureKind.invalidResponse, statusCode: status);
    }
    final reference = json['server_reference'];
    final receivedAt = json['received_at'];
    return SubmissionReceipt(
      submissionId: request.submissionId,
      caseCode: request.caseCode,
      mode: request.mode,
      serverReference: reference is String && reference.isNotEmpty ? _clip(reference, 64) : null,
      receivedAt: receivedAt is String ? DateTime.tryParse(receivedAt) : null,
      simulated: isSimulated || json['simulated'] == true,
    );
  }

  static Map<String, Object?>? _decodeObject(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static Duration? _parseRetryAfter(String? value) {
    final seconds = int.tryParse(value?.trim() ?? '');
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  static String _clip(String value, int maxLength) =>
      value.length <= maxLength ? value : '${value.substring(0, maxLength)}…';

  static Stream<List<int>> _chunked(Uint8List bytes) async* {
    for (var start = 0; start < bytes.length; start += chunkSize) {
      yield Uint8List.sublistView(bytes, start, min(start + chunkSize, bytes.length));
    }
  }

  static Future<_ResponseBody> _readBody(Stream<List<int>> stream, void Function() onData) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      onData();
      builder.add(chunk);
      if (builder.length > _maxResponseBytes) {
        return _ResponseBody(builder.takeBytes(), truncated: true);
      }
    }
    return _ResponseBody(builder.takeBytes(), truncated: false);
  }
}

class _ResponseBody {
  const _ResponseBody(this.bytes, {required this.truncated});

  final Uint8List bytes;
  final bool truncated;
}

/// Richiesta multipart che segnala i byte consegnati alla connessione.
class _UploadRequest extends http.MultipartRequest with http.Abortable {
  _UploadRequest(Uri url, {required this.abortTrigger, required this.onBytesSent})
    : super('POST', url);

  @override
  final Future<void> abortTrigger;

  final void Function(int sent, int total) onBytesSent;

  @override
  http.ByteStream finalize() {
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(
      super.finalize().map((chunk) {
        sent += chunk.length;
        onBytesSent(sent, total);
        return chunk;
      }),
    );
  }
}

class _Aborted implements Exception {
  const _Aborted();
}

/// Completa con il risultato di [future], oppure con [_Aborted] se [abort]
/// completa prima. Serve anche con client che non supportano [http.Abortable].
Future<T> _orAbort<T>(Future<T> future, Future<void>? abort) {
  if (abort == null) return future;
  final completer = Completer<T>();
  future.then(
    (value) {
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
  );
  abort.then((_) {
    if (!completer.isCompleted) completer.completeError(const _Aborted());
  });
  return completer.future;
}
