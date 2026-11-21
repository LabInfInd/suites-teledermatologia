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

Il modello per [ferite e ulcere](docs/WOUNDS.md) è abilitato nel catalogo per uso di
ricerca. Usa quattro classi AZH, scelta esplicita e Grad-CAM, senza segmentazione.
I casi paziente accettano `analysis_task=wound_type`; il default clinico esistente
rimane dedicato alle lesioni PAD. La baseline non è validata per impiego clinico.
La provenienza e i limiti d'uso dei dati rimangono nelle attribuzioni del bundle.

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

Il codice del server è in `server/` sul ramo `main` dello stesso repository dell’app.

## Prima installazione su Ubuntu con Docker

Richiesti: Docker Engine con Compose, Git, disco per immagini/modelli e backup.
L immagine usa Python 3.12 e PyTorch CPU: non serve una GPU nella VM. L installazione
esistente ha circa 62 GiB RAM; per nuove macchine misurare memoria e latenza con i
modelli richiesti prima di dimensionare il servizio. Un solo worker per database.

```bash
git clone https://github.com/LabInfInd/suites-teledermatologia.git
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

Per `https://sisagen-cardio.poliba.it:11112` e disponibile il [profilo dedicato](docs/HTTPS_11112.md), con certificato fornito dall amministratore o da un emettitore DNS-01. Questo profilo alternativo non è attivo: l’istanza usa il profilo HTTP-01 sopra.

Configurare DNS, certificato e proxy HTTPS prima dell uso da telefoni reali.
Il profilo compose.https.yaml usa Caddy; configurare TELEDERM_DOMAIN e ACME_EMAIL e il routing delle
porte secondo ops/Caddyfile e il file Compose. Un indirizzo IP HTTP esistente non
soddisfa automaticamente TLS o le policy Android/iOS.

```bash
sudo docker compose exec api python -m app.manage create-user --username paziente --role patient
sudo docker compose exec api python -m app.manage create-user --username operatore --role doctor
sudo docker compose exec api python -m app.manage create-user --username referente --role admin
```

Inserire le password solo nel terminale. Nessun account predefinito viene creato.
Il login mobile restituisce un token temporaneo a runtime; le sessioni web rimangono
cookie+CSRF. Gli invii mobili sono visibili solo all operatore che li ha creati.
L amministratore gestisce account e registro, non acquisisce accesso ai dati clinici.

## Grad-CAM nei casi dei pazienti

Il [contratto 2 dei casi](docs/CASE_GRADCAM.md) documenta modalità obbligatoria,
catalogo `/api/models`, scelta del modello da parte del medico, mappe Grad-CAM
nell’area web e pubblicazione esplicita al paziente con `share_explanation`.
La foto con sovrapposizione si può scaricare in PNG autenticata. La mappa deve
riferirsi alla classe finale: dopo una correzione si genera e verifica una nuova
Grad-CAM per quella classe prima di condividerla. La migrazione è additiva e non
assegna una modalità ai casi storici. Il [prompt per il client Flutter](docs/PROMPT_APP_CASE_GRADCAM.md)
è pronto per l’agente che sviluppa l’app.

## App: pazienti e medici con Bearer

Il login web resta unico per paziente, medico e amministratore, con un’area per
ruolo. Il login mobile accetta `patient` e `doctor` attivi; l’amministratore usa il
web: `/v1/session` restituisce 403 e cancella la sessione appena creata.

Ogni richiesta autenticata dell’app invia `Authorization: Bearer <token>`; ogni
richiesta non GET invia anche `X-Requested-With: Telederm` (login/logout inclusi).
Non servono cookie, Origin o X-CSRF-Token. Authorization è esclusivo: un token
non valido restituisce 401 anche con un cookie valido. Senza Authorization,
i controlli cookie, CSRF, origine e middleware del browser restano invariati.

| Ruolo | Endpoint e risposta |
|---|---|
| Paziente e medico | `POST /v1/session` JSON `{username,password}` → 200 `{access_token,token_type:"Bearer",expires_at,user:{id,username,role,active}}`; `DELETE /v1/session` → 204 e revoca; `GET /api/status` |
| Paziente | `GET /api/cases?offset=0`; `POST /api/cases` JSON `{mode,body_site,notes,demo_confirmed:true}` → 201, dettaglio del caso; `GET /api/cases/{id}` |
| Paziente | `POST /api/cases/{id}/images` multipart `expected_version`, `file` → 201; `DELETE /api/cases/{id}/images/{image_id}` JSON `{expected_version}` → 200 (bozza); `POST /api/cases/{id}/submit` JSON `{expected_version}` → 200 |
| Paziente | GET degli URL `images[].url` e `published_segmentations[].mask_url/overlay_url`, con lo stesso Bearer |
| Medico | `GET /api/cases?offset=0`, `GET /api/cases/{id}` (include `analyses`); le bozze sono invisibili |
| Medico | `POST /api/cases/{id}/reviews` JSON `{expected_version,decision,final_label,patient_message,share_segmentation,share_explanation}` → 201; decision: `approved`, `corrected`, `needs_images` (quest’ultima senza label/segmentazione) |
| Medico | `POST /api/cases/{id}/reanalyze` JSON `{expected_version,mode?,model_id?,explanation_target?}`; GET `/api/cases/{id}/analyses/{run}/images/{image}/{mask|overlay}` |
| Solo medico | `/v1/models`, `/v1/submissions` e relativi dettagli/artifacts: inferenza diretta |
| Solo medico | `GET /api/mobile-submissions?offset=0`, `GET /api/mobile-submissions/{id}` e relativi artifacts: storico degli invii rapidi propri |

Il paziente vede solo i propri casi (altri casi: 404), revisioni e segmentazioni
pubblicate dal medico, mai `analyses` o punteggi non validati. Paziente su
`/v1/models`, `/v1/submissions*`, `/api/mobile-submissions*`: 403. Dopo ogni modifica
usare la nuova `version` restituita; conflitti di `expected_version`: 409.

**Foto dei casi:** JPEG, PNG, WebP, HEIC/HEIF, fino a **40 MiB** per file, almeno
32 px per lato, massimo **25 megapixel** e quattro foto per caso. EXIF applicato,
RGB/sRGB, salvataggio PNG senza metadati. `/api/status.max_upload_mb` è in MiB.
Gli invii rapidi conservano il limite separato di **80 megapixel**. I nuovi casi
richiedono `mode`: clinical usa un classificatore clinico con Grad-CAM, dermoscopic
usa FTN con segmentazione separata e Grad-CAM. Nessun fallback tra acquisizioni.

Errori `/api`: `{"detail":"messaggio"}` (validazione: anche `errors`);
errori `/v1`: `{"error":{"code":"...","message":"..."}}`.
Admin su login mobile: 403
`{"error":{"code":"forbidden","message":"Gli account amministratore usano l'interfaccia web."}}`.

## Web medico: Analisi rapide

La navigazione del medico affianca “Analisi rapide” a “Casi ricevuti”: storico in
sola lettura dei propri invii dall’app. Pazienti e amministratori non accedono.
Lista dal più recente, pagine da 50: `items`, `total`, `offset`, `limit`. Elemento:
`submission_id`, `case_code`, `mode`, `model_id`, `state`, `received_at`,
`finished_at`, `failure_code`, `top_label` (`{label,score}` a completamento, altrimenti null).

Dettaglio: stesso schema di `/v1/submissions/{id}`, con result, explanation,
segmentation e intended_use; URL mappe sotto
`/api/mobile-submissions/{id}/artifacts/{kind}`. Tipi: `normalized_image`, `heatmap`,
`heatmap_overlay`, `segmentation_mask`, `segmentation_overlay`. PNG, `no-store`,
solo proprietario e invii completati. Invio altrui/inesistente o mappa assente: 404.
Anonimo: 401; paziente e admin: 403. Le consultazioni sono registrate nell’audit.

Il web mostra foto normalizzata, punteggi, Grad-CAM e sovrapposizione, segmentazione
solo se disponibile (FTN), stato in coda/elaborazione con Aggiorna e failure_code
spiegato in caso d’errore. Avviso sempre presente:
“Analisi sperimentale per ricerca: non è una diagnosi clinica validata e non viene
comunicata al paziente.” Nessun risultato rapido viene pubblicato al paziente.

## Invii rapidi da Flutter (solo medico)

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
MODEL_TEST_DIR=model_integration/weights python -m pytest -ra tests
```

Le dipendenze effettivamente provate in Linux sono registrate in
`model_integration/runtime-linux.lock.txt`.

I test coprono il flusso web, autorizzazioni, isolamento degli operatori, ricevute
persistenti/idempotenza, errore di modalita/modello, formati HEIF/WebP, allineamento
EXIF e mappe dipendenti dalla classe. I test con modelli reali usano foto sintetiche;
non certificano sensibilita, generalizzazione o utilita clinica.
