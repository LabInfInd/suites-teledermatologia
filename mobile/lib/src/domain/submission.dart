import 'dart:math';

import 'acquisition_mode.dart';
import 'captured_photo.dart';

/// Dati di un invio. Lo stesso [submissionId] viene riusato nei ritentativi,
/// così il server può riconoscere i duplicati.
class SubmissionRequest {
  const SubmissionRequest({
    required this.submissionId,
    required this.caseCode,
    required this.mode,
    required this.photo,
  });

  final String submissionId;
  final String caseCode;
  final AcquisitionMode mode;
  final CapturedPhoto photo;
}

/// Conferma che il server ha ricevuto e registrato la foto.
///
/// Non contiene e non sostituisce un risultato diagnostico.
class SubmissionReceipt {
  const SubmissionReceipt({
    required this.submissionId,
    required this.caseCode,
    required this.mode,
    this.serverReference,
    this.receivedAt,
    this.simulated = false,
  });

  final String submissionId;
  final String caseCode;
  final AcquisitionMode mode;
  final String? serverReference;
  final DateTime? receivedAt;

  /// Vero se la conferma proviene dal server simulato di sviluppo.
  final bool simulated;
}

enum SubmissionPhase { uploading, awaitingResponse, waitingToRetry }

class SubmissionProgress {
  const SubmissionProgress({
    required this.phase,
    required this.attempt,
    required this.maxAttempts,
    this.bytesSent = 0,
    this.totalBytes = 0,
    this.retryIn,
  });

  final SubmissionPhase phase;
  final int attempt;
  final int maxAttempts;
  final int bytesSent;
  final int totalBytes;

  /// Attesa prima del prossimo tentativo, in [SubmissionPhase.waitingToRetry].
  final Duration? retryIn;

  double? get fraction => totalBytes > 0 ? bytesSent / totalBytes : null;
}

enum SubmissionFailureKind {
  notConfigured,
  network,
  insecureConnection,
  timeout,
  cancelled,
  unauthorized,
  forbidden,
  notFound,
  rejected,
  conflict,
  payloadTooLarge,
  unsupportedMediaType,
  rateLimited,
  serverError,
  serverUnavailable,
  invalidResponse,
  unexpectedStatus,
  unknown,
}

/// Errore di invio. Non contiene mai token, intestazioni o dati della foto.
class SubmissionFailure implements Exception {
  const SubmissionFailure(
    this.kind, {
    this.statusCode,
    this.serverCode,
    this.serverMessage,
    this.retryAfter,
  });

  final SubmissionFailureKind kind;
  final int? statusCode;

  /// Campo `error.code` della risposta, se presente.
  final String? serverCode;

  /// Campo `error.message` della risposta, se presente.
  final String? serverMessage;

  /// Valore di `Retry-After`, se indicato dal server.
  final Duration? retryAfter;

  /// Vero se ha senso riprovare senza modificare i dati.
  bool get canRetry => switch (kind) {
    SubmissionFailureKind.network ||
    SubmissionFailureKind.insecureConnection ||
    SubmissionFailureKind.timeout ||
    SubmissionFailureKind.cancelled ||
    SubmissionFailureKind.conflict ||
    SubmissionFailureKind.rateLimited ||
    SubmissionFailureKind.serverError ||
    SubmissionFailureKind.serverUnavailable ||
    SubmissionFailureKind.invalidResponse ||
    SubmissionFailureKind.unexpectedStatus ||
    SubmissionFailureKind.unknown => true,
    _ => false,
  };

  /// Vero per i problemi transitori che l'app ritenta da sola.
  bool get isTransient => switch (kind) {
    SubmissionFailureKind.network ||
    SubmissionFailureKind.timeout ||
    SubmissionFailureKind.rateLimited ||
    SubmissionFailureKind.serverUnavailable => true,
    _ => false,
  };

  @override
  String toString() =>
      'SubmissionFailure(${kind.name}, status: $statusCode, code: $serverCode)';
}

/// Identificativo UUID v4 generato sul telefono per ogni nuovo invio.
String generateSubmissionId([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
