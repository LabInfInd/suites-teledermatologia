import '../config/app_config.dart';
import '../domain/acquisition_mode.dart';
import '../domain/captured_photo.dart';
import '../domain/case_code.dart';
import '../domain/submission.dart';
import 'acquisition_controller.dart';

/// Testi dell'interfaccia (solo italiano).
extension AcquisitionModeText on AcquisitionMode {
  String get label => switch (this) {
    AcquisitionMode.clinical => 'Foto clinica',
    AcquisitionMode.dermoscopic => 'Immagine dermatoscopica',
  };

  String get description => switch (this) {
    AcquisitionMode.clinical =>
      'Fotografia della cute con la fotocamera del telefono, anche ravvicinata o in modalità macro.',
    AcquisitionMode.dermoscopic =>
      'Immagine acquisita attraverso un dermatoscopio collegato al telefono.',
  };

  String get guidance => switch (this) {
    AcquisitionMode.clinical =>
      'Usa la fotocamera posteriore con luce uniforme ed evita riflessi. '
          'Inquadra la lesione al centro e controlla la nitidezza nell’anteprima. '
          'Per le foto ravvicinate puoi usare la macro, se la fotocamera del telefono la offre: '
          'l’app apre la fotocamera di sistema e non può attivare né verificare la macro. '
          'Una foto macro senza dermatoscopio resta una foto clinica.',
    AcquisitionMode.dermoscopic =>
      'Collega il dermatoscopio al telefono e scatta attraverso la sua ottica. '
          'Usa questa modalità solo per immagini acquisite con il dermatoscopio.',
  };

  String get submitLabel => switch (this) {
    AcquisitionMode.clinical => 'Invia foto clinica',
    AcquisitionMode.dermoscopic => 'Invia immagine dermatoscopica',
  };
}

extension PhotoSourceText on PhotoSource {
  String get label => switch (this) {
    PhotoSource.camera => 'Fotocamera',
    PhotoSource.gallery => 'Galleria',
    PhotoSource.unknown => 'Recuperata',
  };
}

String caseCodeIssueText(CaseCodeIssue issue) => switch (issue) {
  CaseCodeIssue.empty => 'Inserisci il codice caso.',
  CaseCodeIssue.tooShort => 'Il codice caso deve avere almeno ${CaseCode.minLength} caratteri.',
  CaseCodeIssue.tooLong => 'Il codice caso può avere al massimo ${CaseCode.maxLength} caratteri.',
  CaseCodeIssue.invalidCharacters =>
    'Usa solo lettere senza accenti, cifre, “-” e “_”, iniziando con una lettera o una cifra.',
  CaseCodeIssue.looksLikeTaxCode =>
    'Sembra un codice fiscale: usa il codice pseudonimo del caso, non dati del paziente.',
};

bool isErrorNotice(PhotoNotice notice) => switch (notice) {
  PhotoNotice.cancelled || PhotoNotice.cancelledKeptPrevious || PhotoNotice.recovered => false,
  _ => true,
};

String photoNoticeText(PhotoNotice notice, {required int maxUploadBytes}) => switch (notice) {
  PhotoNotice.cancelled => 'Acquisizione annullata.',
  PhotoNotice.cancelledKeptPrevious => 'Acquisizione annullata: resta la foto precedente.',
  PhotoNotice.recovered =>
    'Foto recuperata dopo la chiusura dell’app durante lo scatto. '
        'Controlla l’anteprima e il tipo di acquisizione.',
  PhotoNotice.cameraPermissionDenied =>
    'Accesso alla fotocamera negato. Puoi consentirlo nelle Impostazioni del telefono '
        'oppure scegliere una foto dalla galleria.',
  PhotoNotice.photoPermissionDenied =>
    'Accesso alle foto negato. Puoi consentirlo nelle Impostazioni del telefono.',
  PhotoNotice.cameraUnavailable => 'Nessuna fotocamera disponibile su questo dispositivo.',
  PhotoNotice.alreadyActive => 'È già aperta una schermata di acquisizione.',
  PhotoNotice.unreadable => 'Impossibile leggere la foto selezionata.',
  PhotoNotice.unsupportedFormat =>
    'Formato non supportato. Sono accettati JPEG, PNG, HEIC/HEIF e WebP.',
  PhotoNotice.tooLarge => 'La foto supera il limite di ${formatBytes(maxUploadBytes)}.',
  PhotoNotice.failed => 'Acquisizione non riuscita. Riprova.',
};

String configurationIssueText(ConfigurationIssue issue) => switch (issue) {
  ConfigurationIssue.missingUrl =>
    'Indirizzo del server non configurato (${AppConfig.baseUrlKey}).',
  ConfigurationIssue.invalidUrl => 'L’indirizzo del server configurato non è valido.',
  ConfigurationIssue.insecureUrl =>
    'Le build release richiedono un indirizzo HTTPS per il server.',
  ConfigurationIssue.credentialsInUrl =>
    'L’indirizzo del server non deve contenere credenziali.',
  ConfigurationIssue.ambiguous =>
    'Configurati sia un server reale sia il server simulato: scegline uno.',
  ConfigurationIssue.simulatedInRelease =>
    'Il server simulato non è disponibile nelle build release.',
  ConfigurationIssue.unknownScenario => 'Scenario del server simulato non riconosciuto.',
};

class FailureText {
  const FailureText(this.title, this.message);

  final String title;
  final String message;
}

FailureText failureText(SubmissionFailure failure) => switch (failure.kind) {
  SubmissionFailureKind.notConfigured => const FailureText(
    'Server non configurato',
    'Non è possibile inviare finché il collegamento al server non è configurato.',
  ),
  SubmissionFailureKind.network => const FailureText(
    'Connessione non riuscita',
    'Impossibile raggiungere il server. Verifica la connessione e riprova.',
  ),
  SubmissionFailureKind.insecureConnection => const FailureText(
    'Connessione sicura non riuscita',
    'Il certificato del server non è valido o non è attendibile.',
  ),
  SubmissionFailureKind.timeout => const FailureText(
    'Tempo scaduto',
    'Il server non ha risposto in tempo. La foto potrebbe essere già arrivata: '
        'riprovando non verrà registrata due volte.',
  ),
  SubmissionFailureKind.cancelled => const FailureText(
    'Invio annullato',
    'Puoi riprovare quando vuoi. Se il server aveva già ricevuto la foto, '
        'non verrà registrata due volte.',
  ),
  SubmissionFailureKind.unauthorized => const FailureText(
    'Accesso non autorizzato',
    'Credenziali assenti, non valide o scadute. Contatta il referente del progetto.',
  ),
  SubmissionFailureKind.forbidden => const FailureText(
    'Invio non consentito',
    'Il server ha rifiutato l’invio per mancanza di permessi.',
  ),
  SubmissionFailureKind.notFound => const FailureText(
    'Servizio non trovato',
    'L’indirizzo configurato non espone il servizio di invio. Verifica la configurazione.',
  ),
  SubmissionFailureKind.rejected => FailureText(
    'Dati rifiutati dal server',
    switch (failure.serverCode) {
      'invalid_case_code' => 'Il server non accetta questo codice caso.',
      'invalid_mode' => 'Il server non accetta questo tipo di acquisizione.',
      'invalid_image' => 'Il server non è riuscito a leggere l’immagine. Prova a ripetere lo scatto.',
      _ => 'Il server ha rifiutato la richiesta. Controlla i dati e riprova.',
    },
  ),
  SubmissionFailureKind.conflict => const FailureText(
    'Invio in conflitto',
    'Il server ha già registrato dati diversi con lo stesso identificativo. '
        'Riprova: verrà usato un nuovo identificativo.',
  ),
  SubmissionFailureKind.payloadTooLarge => const FailureText(
    'Foto troppo grande',
    'Il server non accetta file di queste dimensioni.',
  ),
  SubmissionFailureKind.unsupportedMediaType => const FailureText(
    'Formato non accettato',
    'Il server non accetta questo formato di immagine.',
  ),
  SubmissionFailureKind.rateLimited => const FailureText(
    'Server occupato',
    'Il server ha ricevuto troppe richieste. Riprova tra poco.',
  ),
  SubmissionFailureKind.serverError => const FailureText(
    'Errore del server',
    'Il server non è riuscito a completare l’operazione. Riprova; '
        'se il problema persiste contatta il supporto.',
  ),
  SubmissionFailureKind.serverUnavailable => const FailureText(
    'Server non disponibile',
    'Il server è temporaneamente non disponibile. Riprova tra qualche minuto.',
  ),
  SubmissionFailureKind.invalidResponse => const FailureText(
    'Ricezione non confermata',
    'La risposta del server non è valida, quindi la ricezione non è confermata. '
        'Riprova: la foto non verrà registrata due volte.',
  ),
  SubmissionFailureKind.unexpectedStatus => const FailureText(
    'Risposta inattesa',
    'Il server ha risposto in modo inatteso. Riprova.',
  ),
  SubmissionFailureKind.unknown => const FailureText(
    'Invio non riuscito',
    'Si è verificato un errore imprevisto. Riprova.',
  ),
};

/// Riferimenti tecnici utili al supporto (mai token o dati della foto).
String? failureDetail(SubmissionFailure failure) {
  final parts = [
    if (failure.statusCode != null) 'HTTP ${failure.statusCode}',
    if (failure.serverCode != null) failure.serverCode!,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${_decimal(bytes / 1024)} KB';
  return '${_decimal(bytes / (1024 * 1024))} MB';
}

String formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String formatDimensions(ImageDimensions dimensions) =>
    '${dimensions.width} × ${dimensions.height} px (${_decimal(dimensions.megapixels)} MP)';

String _decimal(double value) => value.toStringAsFixed(1).replaceAll('.', ',');
