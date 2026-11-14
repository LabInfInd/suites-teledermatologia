# SUI.T.E.S. — server di teledermatologia

Backend FastAPI, worker persistente, PostgreSQL e archivio immagini. Riceve le foto
Flutter tramite `/v1/submissions`, permette la scelta esplicita del modello e
restituisce classificazione, Grad-CAM e, dove disponibile, segmentazione separata.
La web-app con revisione medica esistente usa `/api/` e rimane disponibile.

**Istanza attiva dal 14 novembre 2026:** https://sisagen-cardio.poliba.it:11112 .
Certificato Let s Encrypt emesso tramite HTTP-01 sulla porta pubblica 80; richiesta, rinnovo e dettagli di rete sono descritti nel [profilo HTTP-01](docs/HTTPS_11112_HTTP01.md).

**Stato: prototipo di ricerca, non validato per uso clinico.** Nessuna accuracy,
heatmap o soglia autorizza una diagnosi automatica. Prima dei pazienti reali servono
HTTPS, gestione degli accessi/conservazione e validazione su una coorte indipendente
di pazienti, telefoni e condizioni di acquisizione del progetto.

## Modelli e modalita

| ID | Acquisizione | Classificazione | Segmentazione | Spiegazione |
|---|---|---|---|---|
| clinical-convnextv2-tiny | clinical, anche macro | 6 classi PAD-UFES-20 | no | Grad-CAM |
| clinical-dinov2-base | clinical, anche macro | 6 classi PAD-UFES-20 | no | Grad-CAM su patch ViT |
| dermoscopic-ftn | dermoscopic | 7 classi del checkpoint FTN | FTN separato | Grad-CAM delle 5 viste TTA |

PAD: **ACK, BCC, MEL, NEV, SCC, SEK**. FTN: **AK, BCC, BKL, DF, MEL, NV, VASC**.
Nessuna sostituzione fra clinical e dermoscopic o fra SEK e BKL. Il FTN disponibile
non contiene SCC: per integrare un diverso classificatore ISIC a otto classi servono
pesi, architettura e manifest effettivi. Smartphone con adattatore: dermoscopic.

ConvNeXt conserva il bundle storico calibrato. DINOv2 e un nuovo refit del modello
singolo a 224 px su 1.472 immagini di sviluppo, otto epoche fissate dalle CV e
calibrazione su 357 immagini separate. Non e l ensemble a tre seed e non ha una
nuova misura indipendente sul test. Il test storico non e stato riaperto.
PanDerm non e attivato nel server: la sua valutazione locale non implica diritti
di distribuzione o validazione clinica.

Questa versione e pubblicata nel ramo `server/multimodel-gradcam`; dopo il merge
in main si puo usare il clone predefinito.

## Prima installazione su Ubuntu con Docker

Richiesti: Docker Engine con Compose, Git, disco per immagini/modelli e backup.
L immagine usa Python 3.12 e PyTorch CPU: non serve una GPU nella VM. L installazione
esistente ha circa 62 GiB RAM; per nuove macchine misurare memoria e latenza con i
modelli richiesti prima di dimensionare il servizio. Un solo worker per database.

```bash
git clone --branch server/multimodel-gradcam https://github.com/LabInfInd/suites-teledermatologia.git
cd suites-teledermatologia/server
python3 scripts/configure_vm.py
# Installare i bundle e configurare .env come sotto.
sudo docker compose up -d --build
sudo docker compose ps -a
curl http://127.0.0.1:8001/health
```

`configure_vm.py` genera una password PostgreSQL casuale e non sovrascrive .env.
Non usare questa procedura per sovrascrivere un installazione gia esistente.
La migrazione aggiuntiva crea solo mobile_submissions e conserva casi, account,
revisioni e volumi preesistenti. `migrate` deve terminare con codice 0.

## Pesi e manifest (separati da Git)

Il repository contiene codice e configurazione, **non pesi, dataset, foto, database,
credenziali o backup**. Ottenere i pesi dai responsabili del progetto tramite un
canale protetto; non vengono scaricati automaticamente o inventati. Struttura:

```text
model_integration/weights/
  CLASSIFICATION_5_auc.pth
  Segm_model_Finale_ImageNet.pth
  clinical-pad-v1/
    manifest.json
    weights.pth
    ATTRIBUTION.md
  clinical-dinov2-base-224-refit-20261113/
    manifest.json
    weights.pth
    ATTRIBUTION.md
```

I due FTN devono corrispondere alle SHA-256 in model_integration/manifest.json.
Ogni bundle clinico verifica SHA-256, classi, modalita, architettura, input RGB,
EXIF, padding/resize e temperatura. Caricamento `weights_only=True` e strict sui
parametri. Nessun modello preaddestrato viene scaricato durante l inferenza.

PAD-UFES-20 v1: DOI 10.17632/zr7vgbcyr2.1, CC BY 4.0; conservare ATTRIBUTION.md.
ConvNeXt deriva da pesi CC BY-NC 4.0: uso non commerciale e revisione dei diritti
prima di distribuzione/prodotto. DINOv2 pretraining Apache-2.0; restano attribuzioni
del dataset e validazione. Provenienza e revisione del pretraining sono nei manifest.
Il profilo FTN di segmentazione e provvisorio (ImageNet, attenzione senza PSP):
normalizzazione e ricetta storica devono essere confermate con gli autori.

## Configurazione

Modificare `.env` nella cartella server; non pubblicarlo:

```dotenv
MODEL_ADAPTER=python
MODEL_THREADS=8
HOST_BIND=127.0.0.1
APP_PORT=8001
APP_ORIGINS=https://telederm.example.org
COOKIE_SECURE=true
HTTP_DEMO_ORIGINS=
SESSION_HOURS=8
```

MODEL_THREADS ammette 1-16. MODEL_DIR nel container e /models, montato in sola
lettura. Catalogo in model_integration/catalog.json: `enabled`, `default`, `bundle`.
Un solo default per modalita. Si possono disabilitare modelli non installati.
Opzionale MODEL_CATALOG_FILE=/models/catalog.json per una configurazione esterna.
Le architetture cliniche supportate sono esplicitamente autorizzate dal codice:
un nuovo ID non permette di eseguire classi Python o percorsi arbitrari.

APP_ORIGINS deve contenere l origine pubblica esatta, senza percorso. Il servizio
rifiuta Host/origini non configurati. Per prove HTTP di rete con sole immagini
sintetiche dichiarare esplicitamente la stessa origine in HTTP_DEMO_ORIGINS e
COOKIE_SECURE=false. Questa eccezione non rende HTTP adatto ai dati dei pazienti.

## HTTPS e account

Se la porta pubblica 80 arriva al gateway, usare il [profilo Let s Encrypt HTTP-01](docs/HTTPS_11112_HTTP01.md): richiesta e rinnovo automatici, HTTPS sulla 11112 e nessun uso dedicato della 443 pubblica. Il percorso pubblico e stato verificato il 14 novembre 2026, insieme ad accesso medico, tre modelli e mappe via HTTPS.

Per `https://sisagen-cardio.poliba.it:11112` e disponibile il [profilo dedicato](docs/HTTPS_11112.md), con certificato fornito dall amministratore o da un emettitore DNS-01. Il profilo e preparato ma non ancora attivo; rete e certificato restano da completare.

Configurare DNS, certificato e proxy HTTPS prima dell uso da telefoni reali.
Il profilo compose.https.yaml usa Caddy; configurare TELEDERM_DOMAIN e ACME_EMAIL e il routing delle
porte secondo ops/Caddyfile e il file Compose. Un indirizzo IP HTTP esistente non
soddisfa automaticamente TLS o le policy Android/iOS.

```bash
sudo docker compose exec api python -m app.manage create-user --username operatore --role doctor
sudo docker compose exec api python -m app.manage create-user --username referente --role admin
```

Inserire le password solo nel terminale. Nessun account predefinito viene creato.
Il login mobile restituisce un token temporaneo a runtime; le sessioni web rimangono
cookie+CSRF. Gli invii mobili sono visibili solo all operatore che li ha creati.
L amministratore gestisce account e registro, non acquisisce accesso ai dati clinici.

## Contratto con Flutter

Consultare [API_MOBILE.md](docs/API_MOBILE.md) per esempi, limiti e risposte:

1. POST /v1/session con username/password, acquisire Bearer a runtime;
2. GET /v1/models e scegliere un ID disponibile per la modalita;
3. POST /v1/submissions multipart con UUID, mode, case_code, source, image,
   model_id facoltativo ed explain=true;
4. conservare la ricevuta; GET status_url fino a completed/failed;
5. recuperare le PNG da result.artifacts usando lo stesso Bearer.

JPEG/PNG/WebP/HEIC, massimo 40 MiB, 80 MP, almeno 32 px per lato. EXIF applicato
prima della rimozione di tutti i metadati. Il salvataggio e persistente prima della
ricevuta. Ritentativi identici restituiscono 200; cambi di immagine/modalita/modello
con lo stesso UUID restituiscono 409. La ricezione non coincide con una diagnosi.

Grad-CAM e una spiegazione relativa alla classe scelta, normalizzata per immagine:
puo evidenziare sfondo o artefatti e non e una maschera della lesione. La maschera
esiste solo per il segmentatore separato. Le mappe mantengono dimensioni e orientamento
della foto normalizzata; un risultato nullo e dichiarato no_positive_signal.

## Operativita, aggiornamenti e ripristino

```bash
sudo docker compose logs --tail 80 api worker migrate
sudo docker compose ps -a
sudo bash scripts/backup.sh
```

Prima di aggiornare: backup verificato di PostgreSQL e immagini, copia protetta di
.env, versione del codice e tag dell immagine precedente. Compilare e provare la
nuova immagine con database/volumi di test separati, poi applicare la migrazione e
riavviare api/worker. Conservare gli hash dei bundle. Non usare `docker compose down -v`.
Per rollback ripristinare codice/configurazione e tag precedenti, mantenendo i volumi;
la tabella mobile aggiunta non richiede rimozione per eseguire la vecchia versione.
Non cancellare invii o database in uso con una migrazione downgrade automatica.

Backup e immagini sono dati riservati. Definire con il centro tempi di conservazione,
cancellazione, autorizzazioni e copia fuori dalla VM. Il codice non applica una
politica clinica di conservazione implicita e non elimina automaticamente immagini.

## Verifiche di sviluppo

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pip install torch==2.7.1 torchvision==0.22.1 --index-url https://download.pytorch.org/whl/cpu
pip install -r model_integration/requirements.txt
python -m pytest tests
# Facoltativo: integra i test con i pesi veri installati.
MODEL_TEST_DIR=model_integration/weights python -m pytest tests/test_real_models.py
```

Le dipendenze effettivamente provate in Linux sono registrate in
`model_integration/runtime-linux.lock.txt`.

I test coprono il flusso web, autorizzazioni, isolamento degli operatori, ricevute
persistenti/idempotenza, errore di modalita/modello, formati HEIF/WebP, allineamento
EXIF e mappe dipendenti dalla classe. I test con modelli reali usano foto sintetiche;
non certificano sensibilita, generalizzazione o utilita clinica.
