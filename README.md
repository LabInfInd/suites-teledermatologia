# SUI.T.E.S. — teledermatologia

**SUI.T.E.S.** (SUstaInable and smarT mEdical Shelter) è la piattaforma del progetto e la teledermatologia è uno dei suoi casi studio. Questa repository contiene il server con l’interfaccia web e l’app Flutter per Android e iPhone: i pazienti inviano foto dermatologiche, i modelli le analizzano in privato e il medico valuta e decide che cosa comunicare.

**Stato: prototipo di ricerca, non validato per uso clinico.** Nessun risultato del modello autorizza una diagnosi automatica e nessun esito viene pubblicato al paziente senza la revisione del medico. L’istanza di prova usa solo account e immagini di prova.

Istanza attiva: **https://sisagen-cardio.poliba.it:11112** (HTTPS con certificato pubblico).

## Componenti

| Cartella | Contenuto | Documentazione |
|---|---|---|
| `server/` | Backend FastAPI, worker delle analisi, PostgreSQL, archivio immagini, interfaccia web (`server/app/static/`), modelli e Grad-CAM | [server/README.md](server/README.md) |
| `mobile/` | App Flutter con i progetti nativi Android e iOS | [mobile/README.md](mobile/README.md) |
| `docs/` | Relazione tecnica finale, contratto API condiviso e indicazioni per l’addestramento del modello clinico | [docs/relazione-tecnica.md](docs/relazione-tecnica.md) |

Specifiche di riferimento: [contratto 2 dei casi e Grad-CAM](server/docs/CASE_GRADCAM.md), [API mobile](server/docs/API_MOBILE.md), [verifiche del server](server/docs/VERIFICATION.md).

## Ferite e ulcere

Il server di ricerca espone anche `clinical-wounds-azh`, con `mode=clinical` e
`analysis_task=wound_type` per i casi paziente. Il modello distingue quattro tipi
noti di ferita e produce Grad-CAM, senza segmentazione. L'integrazione di questo
nuovo percorso nell'app è descritta nelle specifiche del 20 novembre 2026:

- [Prompt completo per Claude per aggiornare l'app](server/docs/PROMPT_APP_WOUNDS.md).
- [Specifiche di ferite e ulcere](server/docs/WOUNDS.md).
- [API mobile aggiornate](server/docs/API_MOBILE.md).
- [Casi paziente e revisione medica](server/docs/CASE_GRADCAM.md).

I nuovi campi sono retrocompatibili; la scelta del percorso ferite è esplicita.
La classificazione resta sperimentale per ricerca e richiede valutazione medica.

Nell'app il percorso è integrato così:

- **Paziente**: dopo la modalità sceglie il tipo di analisi (*Lesioni cutanee* o
  *Ferite e ulcere* per le foto cliniche; con il dermatoscopio solo le lesioni). La
  scelta non ha un valore predefinito ed è modificabile in bozza; il paziente non
  vede catalogo, punteggi o mappe non approvate.
- **Medico, casi**: punteggi associati per etichetta con i nomi italiani del server,
  Grad-CAM senza segmentazione, nuova analisi con tipo di analisi, modello e classe
  da spiegare presi dal modello scelto.
- **Medico, analisi rapida**: per le ferite invia `model_id=clinical-wounds-azh`,
  `mode=clinical` ed `explain=true`, senza `analysis_task` nel multipart.
- Se il modello ferite non è disponibile l'app lo segnala e blocca l'invio, senza
  usare i modelli PAD o FTN. Con un server senza l'estensione il percorso ferite
  non compare.

## Ruoli e accesso

| Ruolo | Web | App |
|---|---|---|
| Paziente | I propri casi | I propri casi |
| Medico | Casi ricevuti e Analisi rapide | Casi ricevuti e Analisi rapida |
| Amministratore | Account e registro | Non ammesso (solo web) |

Il login è unico: il ruolo arriva dal server. Il web usa cookie e CSRF; l’app usa un token `Bearer` tenuto solo in memoria e invia `X-Requested-With: Telederm` su ogni richiesta che non sia GET, senza cookie. Gli account si creano sulla VM o dal web dell’amministratore: nessun account predefinito e nessuna credenziale nel codice.

## Flusso dei casi (contratto 2)

1. **Il paziente crea il caso** scegliendo la modalità di acquisizione, che vale per tutte le foto del caso:
   - `clinical`: smartphone normale, anche foto ravvicinate o macro;
   - `dermoscopic`: dermatoscopio oppure smartphone con adattatore dermatoscopico.

   La modalità è obbligatoria e non viene mai dedotta dalla foto.
2. **Aggiunge da una a quattro foto** (JPEG, PNG, WebP, HEIC/HEIF, fino a 40 MiB e 25 MP) e invia il caso. Il server sceglie il modello predefinito della modalità.
3. **Il modello analizza le foto in privato:** classificazione, Grad-CAM e, solo con il modello dermatoscopico FTN, segmentazione separata. Il paziente non vede mai punteggi o analisi preliminari.
4. **Il medico esamina** le foto e le mappe. Può ripetere l’analisi scegliendo modalità, modello del catalogo e classe da spiegare con Grad-CAM; nei casi storici senza modalità deve prima confermarla.
5. **Il medico pubblica la valutazione:** conferma, correzione o richiesta di nuove foto. La condivisione della Grad-CAM e quella della segmentazione sono due consensi espliciti e indipendenti. La Grad-CAM si può condividere solo se tutte le foto hanno la mappa per la classe finale: se la classe viene corretta, il medico ricalcola le mappe per quella classe e le esamina prima di pubblicare. Una classe fuori catalogo si pubblica solo come testo.
6. **Il paziente legge la risposta** e, se il medico l’ha condivisa, vede e può scaricare la foto composta con la Grad-CAM, insieme alla classe spiegata e all’avvertenza del server. Una nuova valutazione senza consenso revoca le mappe precedenti.

Il medico dispone inoltre dell’**analisi rapida** dall’app: una singola foto con scelta del modello e risultato sperimentale immediato. È separata dai casi, è visibile solo al medico che l’ha inviata, compare anche nel web in «Analisi rapide» e non viene mai comunicata ai pazienti.

Grad-CAM evidenzia le aree che influenzano la classificazione: non è il contorno della lesione, non è una probabilità per pixel e non è una segmentazione. Lo stato `no_positive_signal` non significa assenza di lesione.

## Avvio

**Server e web:** installazione con Docker, pesi dei modelli, HTTPS, account e aggiornamenti sono descritti in [server/README.md](server/README.md).

**App:** ambiente verificato con Flutter 3.47.5, Dart 3.13.4 e Xcode 27.2.

```sh
cd mobile
flutter pub get

# Istanza del progetto
flutter run --dart-define-from-file=config/server.sisagen.example.json

# Altro server: copiare l’esempio e indicare l’indirizzo
cp config/server.example.json config/server.local.json
flutter run --dart-define-from-file=config/server.local.json

# Server simulato interno all’app (solo build debug e profile, solo analisi rapida)
flutter run --dart-define=SUITES_SIMULATED_SERVER=true
```

Per installare su un iPhone fisico serve la firma in Xcode. Se il terminale non ha il permesso «Rete locale» di macOS, `flutter run` in debug non riesce a collegarsi al telefono. In quel caso si può usare una build profile: `flutter build ios --profile --dart-define-from-file=…`, poi `xcrun devicectl device install app`. Per Android servono l’Android SDK e un dispositivo o emulatore; verificare con `flutter doctor`.

## Configurazione dell’app

La configurazione si passa a build time e contiene solo valori non segreti. I file `mobile/config/*.local.json` sono esclusi dal versionamento.

| Variabile | Valori | Note |
|---|---|---|
| `SUITES_API_BASE_URL` | URL `https://…` | Indirizzo base del server. `http://` è accettato solo nelle build debug e profile, per server locali. Non sono ammessi credenziali, query o frammenti. |
| `SUITES_SIMULATED_SERVER` | `true` / `false` | Server simulato per l’analisi rapida, sempre segnalato da un banner giallo; non combinabile con un indirizzo reale e rifiutato nelle build release. |
| `SUITES_SIMULATED_SCENARIO` | `success`, `flaky`, `offline`, `rejected`, `server_error` | Comportamento del server simulato; predefinito `success`. |

Credenziali e token non vanno mai inseriti nel codice né passati con `--dart-define`, che finisce nel binario dell’app.

## Foto, privacy e permessi

- **Acquisizione:** fotocamera e galleria usano `image_picker`, cioè le schermate di sistema. L’app non controlla obiettivo, messa a fuoco, flash o macro e non può verificarne l’uso. La modalità è dichiarata da chi acquisisce: una macro senza dermatoscopio resta `clinical`.
- **Trattamento delle foto:** l’app non ridimensiona e non ricomprime. Dai JPEG rimuove la posizione GPS (EXIF e XMP) senza ricompressione; per gli altri formati la rimozione dei metadati spetta al server, che riscrive sempre una PNG senza metadati e applica l’orientamento EXIF.
- **Conservazione sul telefono:** le foto restano in memoria e la copia temporanea di `image_picker` viene eliminata. L’app salva un’immagine solo quando il paziente sceglie di scaricare la foto composta con la Grad-CAM, tramite il foglio di condivisione di sistema.
- **Codice caso e log:** nell’analisi rapida il codice caso deve essere un pseudonimo, e l’app rifiuta la struttura del codice fiscale. L’app non scrive log; in caso di errore mostra solo il messaggio del server.
- **Permessi Android:** dichiara solo `INTERNET`.
- **Permessi iOS:** `Info.plist` contiene le descrizioni in italiano per fotocamera, accesso alle foto e salvataggio in Foto, e dichiara l’italiano come lingua dell’app.
- **Login:** i campi supportano incolla, compilazione automatica delle credenziali e visualizzazione della password.

## Verifiche

```sh
cd mobile && flutter analyze && flutter test
```

Verificato il 14/11/2026 sul computer di sviluppo:

- `flutter analyze`: nessun problema.
- `flutter test`: 110 test superati, tutti con dati simulati locali. Coprono:
  - modalità obbligatoria e casi storici;
  - campi JSON e multipart; `Authorization` e `X-Requested-With` su scritture e download;
  - isolamento dei ruoli;
  - mappe prima e dopo la pubblicazione, revoca con 404, nessun doppio overlay della foto composta;
  - ricalcolo Grad-CAM per la classe corretta con bozza conservata e consensi separati;
  - errori 401, 409 e 422; incolla nel login;
  - flussi già esistenti dell’analisi rapida.
- `flutter build ios --profile`: riuscita. App installata su iPhone 14 Pro (iOS 27.2.1) e provata a mano sull’istanza del progetto, con esito positivo nei flussi principali di paziente e medico.
- Prova automatica dei client dell’app sull’istanza reale (account di prova, contratto 1): paziente → caso → analisi → valutazione del medico → risposta al paziente, più l’analisi rapida. Per il contratto 2 è stato eseguito uno smoke test HTTPS di sola lettura: contratto annunciato, catalogo per modalità, 403 al paziente sul catalogo, campi del dettaglio.
- Server: test e verifiche in [server/docs/VERIFICATION.md](server/docs/VERIFICATION.md).
- Percorso ferite e ulcere, 25/11/2026: `flutter analyze` senza problemi e 143 test superati (33 nuovi), con fixture sintetiche. I nuovi test coprono catalogo e campi mancanti, scelta esplicita senza ripiego su PAD o FTN, combinazioni modalità/task, payload distinti di casi e invii rapidi, UUID nei ritentativi, classi in ordine qualsiasi, target Grad-CAM, assenza di segmentazione e visibilità per ruolo. Non ancora provato sull’istanza reale né su un telefono.
- Android non compilato: l’Android SDK non è installato sul computer di sviluppo.

### Ancora da verificare

- **App su Android:** build, fotocamera e galleria (HEIC compreso), recupero della foto dopo la chiusura dell’app, icona adattiva, `applicationId` e firma release, che sono ancora quelli del template.
- **App sui telefoni:**
  - permessi negati e riattivati;
  - salvataggio della foto composta in Foto;
  - foto da 48 MP o più;
  - comportamento macro e adattatore dermatoscopico;
  - cambio di rete e app sospesa durante un invio.
- **Ferite e ulcere sull’istanza reale:** creazione del caso, invio rapido con `clinical-wounds-azh`, risultato e Grad-CAM, con un account di prova.
- **Rimozione dei metadati:** verifica su foto reali, per esempio con `exiftool`.
- **Validazione clinica:** dei modelli su una coorte indipendente di pazienti, telefoni e condizioni di acquisizione del progetto, prima di qualunque uso con pazienti reali.

## Logo e identificativi

- **Logo:** l’icona e l’intestazione usano il simbolo SUI.T.E.S. ricavato da un JPEG di 410×287 px (`mobile/branding/logo_sorgente.jpg`). È una versione provvisoria: con il file originale in alta risoluzione vanno sostituiti `mobile/branding/app_icon.png`, `mobile/branding/app_icon_foreground.png` e `mobile/assets/images/suites_symbol.png`. Poi si rigenerano le icone con `mobile/tool/genera_icone.sh` (richiede macOS).
- **Identificativi tecnici:** pacchetto Dart `teledermatologia`, bundle identifier iOS e `applicationId` Android `it.teledermatologia.teledermatologia`. Vanno decisi prima della pubblicazione negli store.

## Modelli

| Modalità | Modelli | Classi | Segmentazione |
|---|---|---|---|
| `clinical` | ConvNeXt V2 tiny (predefinito), DINOv2 base | ACK, BCC, MEL, NEV, SCC, SEK | No |
| `clinical`, task ferite | DINOv2 Base (`clinical-wounds-azh`, scelta esplicita) | diabetic, pressure, surgical, venous | No |
| `dermoscopic` | FTN | AK, BCC, BKL, DF, MEL, NV, VASC | Sì, separata da Grad-CAM |

Nessuna equivalenza tra classi dei due percorsi: SEK non è BKL e NEV non è NV. Nessun modello viene eseguito sul telefono. Dettagli, pesi e manifest sono in [server/README.md](server/README.md).
