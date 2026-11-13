import '../domain/submission.dart';

/// Fornisce il token di accesso al momento dell'invio, oppure `null` se il
/// server non richiede autenticazione.
///
/// Il token va ottenuto a runtime (accesso dell'operatore o registrazione del
/// dispositivo) e conservato in Keychain/Keystore: mai nel codice sorgente né
/// in `--dart-define`, che finisce nel binario dell'app.
typedef AccessTokenProvider = Future<String?> Function();

/// Invio delle foto al server, indipendente dall'interfaccia.
abstract interface class SubmissionApi {
  /// Vero se le conferme provengono dal server simulato di sviluppo.
  bool get isSimulated;

  /// Invia la foto e restituisce la conferma di ricezione.
  ///
  /// Lancia [SubmissionFailure] in caso di errore. Il completamento di
  /// [cancelSignal] interrompe l'invio con [SubmissionFailureKind.cancelled].
  Future<SubmissionReceipt> submit(
    SubmissionRequest request, {
    void Function(SubmissionProgress progress)? onProgress,
    Future<void>? cancelSignal,
  });
}
