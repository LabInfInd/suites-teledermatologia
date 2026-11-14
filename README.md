# SUI.T.E.S. — app mobile

**SUI.T.E.S.** (SUstaInable and smarT mEdical Shelter) è la piattaforma del progetto e la teledermatologia è uno dei suoi casi studio. Questa app Flutter per Android e iPhone è dedicata al caso studio di teledermatologia: acquisisce immagini dermatologiche e le invia a un server di classificazione.

Il backend e ora incluso in **[server/](server/README.md)**: installazione Docker,
configurazione, scelta dei modelli e mappe sono documentati nel README del server.
Le modifiche del 13/11/2026 aggiungono accesso medico a runtime, scelta del modello
dal catalogo disponibile e consultazione delle analisi sperimentali con Grad-CAM.
Le maschere di segmentazione sono separate e disponibili soltanto per FTN.

## Struttura

- `mobile/`: applicazione Flutter, con i progetti nativi Android e iOS.
  - `lib/src/domain/`: modalità di acquisizione, codice caso, foto e invio.
  - `lib/src/capture/`: acquisizione con `image_picker`, lettura delle dimensioni, rimozione della posizione GPS.
  - `lib/src/api/`: interfaccia di invio, client HTTP e server simulato di sviluppo.
  - `lib/src/config/`: configurazione del collegamento al server.
  - `lib/src/ui/`: stato del flusso (`AcquisitionController`) e schermate.
  - `config/server.example.json`: esempio di configurazione del server.
  - `assets/images/`: simbolo del logo mostrato nell’app.
  - `branding/`: logo ricevuto e immagini di partenza delle icone; `tool/genera_icone.sh` rigenera le icone Android e iOS.
- `docs/api-contratto-proposta.md`: proposta di contratto API minimo per l’invio delle foto.
- `docs/workstation-prompt.txt`: contesto e indicazioni per addestrare il modello per foto cliniche sulla workstation.

La repository si trova in `SUITES/suites-mobile/`. La cartella `SUITES/suites-repo/` è una repository indipendente, esterna a questo progetto.

## Stato del progetto

Il primo flusso dell’app è implementato, con interfaccia in italiano:

1. scelta esplicita del tipo di acquisizione, foto clinica (`clinical`) o immagine dermatoscopica (`dermoscopic`);
2. scatto con la fotocamera di sistema oppure scelta dalla galleria;
3. anteprima ingrandibile, con dimensioni, peso e formato, e possibilità di sostituire o rimuovere la foto;
4. codice caso pseudonimo e invio di foto e modalità al server;
5. avanzamento, conferma di ricezione, errori e ritentativi.

Il server implementa ricevute persistenti e un estensione per accesso, catalogo e risultati: l’app implementa la [proposta di contratto API](docs/api-contratto-proposta.md), con un collegamento configurabile e separato dall’interfaccia. Senza server reale si può usare un server simulato interno all’app, sempre segnalato; non richiede accesso e non simula le nuove analisi cliniche.

L’app non esegue modelli sul telefono. La conferma di invio attesta soltanto la ricezione; il medico puo poi aprire l analisi sperimentale separata, che non costituisce una diagnosi clinica validata.

## Avvio

Ambiente verificato sul computer di sviluppo: Flutter 3.47.5, Dart 3.13.4 e Xcode 27.2. Il progetto richiede Dart 3.13.4 o successivo compatibile con il vincolo nel pubspec.

```sh
cd mobile
flutter pub get
flutter devices

# Server simulato (solo build debug e profile)
flutter run --dart-define=SUITES_SIMULATED_SERVER=true

# Server reale: copiare l’esempio e indicare l’indirizzo
cp config/server.example.json config/server.local.json
flutter run --dart-define-from-file=config/server.local.json
```

Senza configurazione l’app si avvia e consente di acquisire le foto, ma segnala “Server non configurato” e non permette l’invio.

Per iOS sono necessari Xcode e, per installare su un iPhone fisico, la configurazione della firma. Per Android sono necessari Android SDK e un dispositivo o emulatore. La configurazione completa delle due piattaforme va verificata con `flutter doctor`.

## Configurazione del server

La configurazione si passa in fase di build con `--dart-define` o `--dart-define-from-file` e contiene solo valori non segreti. I file `mobile/config/*.local.json` sono esclusi dal versionamento.

| Variabile | Valori | Note |
|---|---|---|
| `SUITES_API_BASE_URL` | URL `https://…` | Indirizzo base; l’invio usa `{base}/v1/submissions`. `http://` è accettato solo nelle build debug e profile, per server locali; l’eventuale traffico in chiaro va abilitato nella configurazione Android/iOS, oggi non modificata. Non sono ammessi credenziali, query o frammenti nell’indirizzo. |
| `SUITES_SIMULATED_SERVER` | `true` / `false` | Attiva il server simulato. Non può essere combinato con un indirizzo reale ed è rifiutato nelle build release. |
| `SUITES_SIMULATED_SCENARIO` | `success`, `flaky`, `offline`, `rejected`, `server_error` | Comportamento del server simulato per provare conferme ed errori; predefinito `success`. |

Il server simulato sostituisce la rete all’interno dell’app: le foto non lasciano il telefono. È riconoscibile da un banner giallo “SERVER SIMULATO” sempre visibile, da conferme intitolate “Ricezione confermata (SIMULATA)” e da riferimenti che iniziano con `SIMULATO-`.

Credenziali e token non vanno mai inseriti nel codice né passati con `--dart-define`, che finisce nel binario dell’app. Il server richiede un account medico: la schermata di accesso ottiene un Bearer temporaneo tramite `/v1/session`. Il token resta solo in memoria; Esci lo revoca. Il catalogo `/v1/models` abilita la scelta per modalita; cambiare modello genera un nuovo invio. Per il contratto completo consultare [API mobile](server/docs/API_MOBILE.md).

## Fotocamera e qualità delle immagini

- Scatto e galleria usano `image_picker`, che apre la fotocamera e la galleria di sistema. L’app **non controlla** obiettivo, messa a fuoco, esposizione, flash, zoom o modalità macro e non può verificarne l’uso: dipendono dall’app fotocamera del telefono. Per questo l’app dà solo indicazioni, senza promettere controlli macro.
- La modalità è dichiarata dall’operatore: una foto macro senza dermatoscopio resta una foto clinica; uno smartphone con adattatore dermatoscopico produce immagini dermatoscopiche.
- L’app non ridimensiona e non ricomprime le foto. Su Android le foto della fotocamera sono il JPEG prodotto dall’app fotocamera e quelle della galleria il file originale (anche HEIC o WebP). Su iOS `image_picker` riscrive l’immagine in JPEG alla qualità massima conservando i metadati.
- L’anteprima a schermo intero è ingrandibile per controllare la nitidezza (decodifica fino a 4096 px di lato, solo per la visualizzazione). Sotto i 1000 px di lato corto compare un avviso di risoluzione bassa, che non blocca l’invio e non rappresenta un requisito dei modelli.
- Il preprocessing specifico dei modelli, compresa l’applicazione dell’orientamento EXIF, spetta al server.
- Controlli reali su obiettivo macro o distanza di messa a fuoco richiederebbero una fotocamera integrata nell’app (plugin `camera` o codice nativo), da valutare dopo le prove sui telefoni effettivamente usati.

## Privacy, permessi e log

- La foto resta in memoria: la copia temporanea creata da `image_picker` viene eliminata dopo la lettura e l’app non salva immagini in galleria. Alcune app fotocamera Android potrebbero comunque conservarne una copia: va verificato sui telefoni in uso.
- Dai JPEG viene rimossa la posizione GPS (directory GPS dell’EXIF e pacchetti XMP con coordinate) senza ricompressione e lasciando invariato l’orientamento. Per HEIC, PNG e WebP la rimozione spetta al server.
- Il file viene inviato con un nome generico. Il codice caso deve essere un pseudonimo: l’app rifiuta valori con la struttura del codice fiscale.
- L’app non scrive log: fotografie e token non vengono registrati. In caso di errore l’interfaccia mostra solo lo stato HTTP, il codice e il messaggio di errore del server.
- Android: l’app dichiara solo il permesso `INTERNET`. Il permesso `CAMERA` non è dichiarato di proposito, perché l’app fotocamera di sistema non lo richiede alla nostra app; la galleria usa il selettore di sistema.
- iOS: `Info.plist` contiene le descrizioni in italiano per fotocamera e foto e dichiara l’italiano come lingua dell’app (`CFBundleLocalizations`), perché anche i pulsanti delle schermate di sistema aperte dall’app siano in italiano. La galleria usa il selettore di sistema senza chiedere l’accesso all’intera libreria.
- Se Android chiude l’app mentre la fotocamera è aperta, al riavvio la foto viene recuperata e l’operatore deve scegliere di nuovo il tipo di acquisizione.

## Invio, errori e ritentativi

- Ogni invio ha un identificativo UUID generato sul telefono e riusato nei ritentativi, così il server può evitare duplicati.
- Errori di rete, timeout, `429` e `502`–`504` vengono ritentati automaticamente fino a 3 tentativi complessivi; gli altri errori mostrano un messaggio specifico. “Riprova invio” riusa lo stesso identificativo finché foto, modalità e codice caso non cambiano.
- L’invio si può annullare; durante l’invio e dopo la conferma i dati non sono modificabili. Dopo la conferma si può acquisire una nuova foto per lo stesso caso oppure iniziare un nuovo caso.
- L’invio non prosegue in background: se il sistema sospende l’app, l’invio può interrompersi e va ripetuto.

## Logo e icona

- Sotto l’icona compare il nome “SUI.T.E.S.”. L’intestazione dell’app mostra il simbolo del logo con la dicitura “Teledermatologia · caso studio”, e il pulsante informazioni riporta il nome esteso della piattaforma. Il colore del tema deriva dal blu del logo (`#126393`).
- Il logo disponibile è un JPEG di 410×287 px (`mobile/branding/logo_sorgente.jpg`). Il simbolo è stato ripulito e ingrandito per ricavare icone e immagine dell’app: è una versione **provvisoria**, con bordi meno precisi dell’originale.
- Quando sarà disponibile il file originale del logo (SVG, PDF o PNG ad alta risoluzione), vanno sostituiti:
  - `mobile/branding/app_icon.png`: 1024×1024 px, simbolo su fondo bianco, senza trasparenza (icona iOS e icona Android tradizionale);
  - `mobile/branding/app_icon_foreground.png`: 1024×1024 px, fondo trasparente, simbolo largo circa metà dell’immagine e centrato, perché resti visibile in tutte le forme dell’icona adattiva Android;
  - `mobile/assets/images/suites_symbol.png`: simbolo su fondo trasparente, circa 600 px di larghezza.

  Poi si rigenerano le icone con `mobile/tool/genera_icone.sh` (richiede macOS).
- Gli identificativi tecnici non sono cambiati: pacchetto Dart `teledermatologia`, bundle identifier iOS e `applicationId` Android `it.teledermatologia.teledermatologia`. Vanno decisi prima della pubblicazione negli store: cambiarli dopo equivale a pubblicare un’app diversa.

## Verifiche

```sh
cd mobile
flutter analyze
flutter test
```

Verificato il 12/11/2026 su questo computer:

- `flutter analyze`: nessun problema.
- `flutter test`: 68 test superati. Coprono regole del codice caso, riconoscimento dei formati, configurazione, rimozione GPS su JPEG sintetici, client HTTP (campi multipart, token, conferme non valide, stati HTTP, ritentativi, `Retry-After`, annullamento, timeout, avanzamento), server simulato, controller del flusso e interfaccia (flusso completo, permesso negato, scatto annullato, errore del server, annullamento dell’invio, server non configurato, codice fiscale rifiutato, intestazione e informazioni sulla piattaforma).
- `flutter build ios --simulator --debug` riuscita; l’app si avvia sul simulatore iPhone SE (3ª generazione) e la schermata iniziale, con logo e banner del server simulato, si visualizza correttamente. Nella schermata Home compaiono la nuova icona e il nome “SUI.T.E.S.”.
- Android non compilato: l’Android SDK non è installato su questo computer.

### Da verificare su dispositivi fisici

- Scatto su iPhone e Android, richieste di permesso, permesso negato e poi riattivato dalle Impostazioni, annullamento dalla fotocamera, lingua delle schermate di sistema.
- Galleria: foto HEIC su Android (anteprima e invio) e selettore di sistema su iOS.
- Comportamento macro dei telefoni in uso e acquisizione con adattatore dermatoscopico.
- Recupero della foto dopo la chiusura dell’app da parte di Android ed eliminazione delle copie temporanee.
- Memoria e fluidità con foto da 48 MP o più.
- Rimozione GPS su foto reali, per esempio confrontando i file con `exiftool`.
- Rete reale: cambio tra Wi-Fi e rete cellulare, app sospesa durante l’invio.
- Build Android e firma release: `applicationId` e firma sono ancora quelli del template.
- Icona adattiva Android con le diverse forme dei launcher.

### Da verificare con il server reale

- Implementazione del contratto, idempotenza, limiti di formato e dimensione.
- Autenticazione, HTTPS e certificati.
- Applicazione dell’orientamento EXIF e rimozione dei metadati di posizione lato server.

## Modelli sul server

Le foto cliniche da smartphone, anche macro, useranno un nuovo modello addestrato su dati clinici come PAD-UFES-20. Le immagini dermatoscopiche useranno il modello già disponibile addestrato su ISIC 2019. Uno smartphone con adattatore dermatoscopico appartiene al secondo percorso. Nessun modello viene eseguito sul telefono.
