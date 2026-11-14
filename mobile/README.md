# App Flutter SUI.T.E.S.

App Android e iPhone per pazienti e medici del caso studio di teledermatologia. Panoramica della piattaforma, flusso dei casi, privacy e stato delle verifiche: [README della repository](../README.md). Contratto con il server: [CASE_GRADCAM.md](../server/docs/CASE_GRADCAM.md) e [API_MOBILE.md](../server/docs/API_MOBILE.md).

## Avvio

```sh
flutter pub get
flutter run --dart-define-from-file=config/server.sisagen.example.json
```

Si accede con un account paziente o medico creato sulla VM; gli amministratori usano solo il web. Il certificato dell’istanza è pubblico e viene verificato normalmente. Configurazione e server simulato: vedi il README della repository.

## Cosa fa

- **Login unico:** il ruolo arriva da `POST /v1/session`. Il token resta in memoria. Ogni richiesta autenticata invia `Authorization: Bearer`, ogni richiesta non GET anche `X-Requested-With: Telederm`; mai cookie, Origin o CSRF. Dopo un 401 l’app torna al login; dopo un 409 ricarica il caso e mostra il messaggio del server.
- **Paziente:** «I miei casi».
  - **Creazione:** modalità di acquisizione obbligatoria e conferma dei dati di prova. La creazione è bloccata se `/api/status` non annuncia `case_contract_version: 2`.
  - **Foto:** fino a quattro, da fotocamera o galleria.
  - **Modalità:** correggibile in bozza (`PATCH /api/cases/{id}/acquisition`); nei casi storici con nuove foto richieste si può solo confermare quella mancante.
  - **Risposta:** il paziente vede solo `reviews`, `published_explanations` e `published_segmentations`. La Grad-CAM è mostrata come foto composta (`composite_url`), senza un secondo overlay sopra, con la classe spiegata e l’avvertenza del server, ed è scaricabile con il token tramite il foglio di condivisione.
  - **Mappe revocate:** un 404 rimuove la mappa senza riusare l’URL.
  - **Accessi esclusi:** il paziente non chiama mai `/api/models` né `/v1/models` o `/v1/submissions`.
- **Medico, «Casi ricevuti»:**
  - **Viste separate** Foto / Grad-CAM (composite) / Segmentazione (solo FTN), con modello, versione e classe spiegata.
  - **«Nuova analisi»:** modalità (obbligatoria per i casi storici), modello da `/api/models?mode=` e classe da spiegare.
  - **Valutazione:** consensi `share_segmentation` e `share_explanation` separati, entrambi falsi finché il medico non li sceglie. La condivisione della Grad-CAM resta disattivata finché tutte le foto non hanno la mappa per la classe finale; nel frattempo c’è «Ricalcola Grad-CAM per «X»». Durante l’attesa la pagina si aggiorna da sola e conserva la bozza.
  - **Classe fuori catalogo:** pubblicazione solo testuale.
- **Medico, «Analisi rapida»:** acquisizione di una foto con scelta del modello, ricevuta, «Visualizza analisi sperimentale» (classificazione, Grad-CAM, segmentazione FTN) e storico da `/api/mobile-submissions`. Separata dai casi.

## Struttura

- `lib/src/api/`:
  - `user_session.dart`: login e ruolo;
  - `cases_api.dart`: endpoint `/api` dei casi, catalogo, stato e immagini autenticate;
  - `http_submission_api.dart`: invii rapidi `/v1/submissions`;
  - `simulated_server.dart`: server simulato.
- `lib/src/domain/`:
  - `patient_case.dart`: casi, analisi, mappe pubblicate, catalogo e stato del server;
  - inoltre modalità di acquisizione, foto, codice caso e invio.
- `lib/src/capture/`: `image_picker`, controllo di formato e dimensione, rimozione del GPS (`photo_preparation.dart`, `location_metadata.dart`).
- `lib/src/ui/`:
  - login e struttura per ruolo (`app.dart`, `doctor_home_page.dart`);
  - elenco e dettaglio dei casi (`case_list_page.dart`, `case_detail_page.dart`);
  - sezioni paziente e medico (`patient_case_sections.dart`, `doctor_case_sections.dart`);
  - analisi rapida (`acquisition_page.dart`, `submission_result_page.dart`, `quick_history_page.dart`).
- `test/`: test unitari e di interfaccia. `test/support/fake_platform_server.dart` è un server in memoria con le regole del contratto 2: nessuna richiesta di rete reale nei test.
- `config/`: esempi di configurazione (`server.example.json`, `server.sisagen.example.json`); i file `*.local.json` restano locali.
- `branding/`, `assets/images/`, `tool/genera_icone.sh`: logo e icone.

Le dipendenze sono in `pubspec.yaml` e bloccate in `pubspec.lock`; `share_plus` serve al download delle mappe pubblicate. I percorsi locali degli SDK, i file generati e le credenziali di firma non fanno parte dei sorgenti.

## Verifiche

```sh
flutter analyze
flutter test
```

Esiti aggiornati e prove ancora necessarie su Android e iPhone: sezione «Verifiche» del [README della repository](../README.md).
