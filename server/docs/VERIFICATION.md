# Verifiche del rilascio multi-modello — 13 novembre 2026

- Flutter 3.47.5 / Dart 3.13.4: analisi senza segnalazioni, 75 test passati.
- Server Windows Python 3.12.14: 47 test passati, inclusi i pesi FTN reali.
- Immagine Linux Python 3.12.16: 50 test passati con tutti e tre i modelli reali.
- Prova locale sintetica: ConvNeXt, DINOv2 e FTN producono probabilita finite e
  mappe Grad-CAM allineate; solo FTN produce una maschera indipendente.
- Prove di autorizzazione, isolamento per operatore, idempotenza, formati WebP/HEIF,
  orientamento EXIF, errori di modello/modalita e limite del corpo multipart.
- DINOv2 refit su 1.472 immagini di sviluppo, 8 epoche; temperatura stimata su
  357 immagini di calibrazione. Nessuna riapertura del test storico.

I test software e le immagini sintetiche non costituiscono una validazione clinica.
Build/installazione e prestazioni su iPhone/Android fisici restano da verificare;
HTTPS e dominio devono essere configurati prima dell uso con immagini reali.

Nella VM e stato verificato il percorso HTTP locale API -> coda -> worker -> mappe
per tutti i tre modelli: classificazione completata, ritentativo HTTP 200 idempotente,
mappe PNG protette con Bearer e allineate a 288x192, revoca della sessione confermata.
Tempi osservati su una sola immagine sintetica: circa 2,3 s ConvNeXt, 2,3 s DINOv2,
5,4 s FTN, incluso polling; non sono un benchmark di carico o una garanzia di latenza.
Il backup prima dell aggiornamento e stato controllato con SHA-256 e i conteggi dei
record preesistenti sono rimasti invariati durante il passaggio. La prova live ha
creato un account tecnico poi sospeso e tre invii sintetici conservati per tracciabilita.

## Raggiungibilita osservata dalla workstation dopo il rilascio

Il controllo diretto della VM su 192.168.50.10:8000 restituisce HTTP 200 per /health
e HTTP 401 per /v1/models senza token. Gli indirizzi inoltrati 10.50.3.17 e
193.204.50.163 vanno invece in timeout da questa workstation. Questo non dimostra
che siano irraggiungibili da ogni rete: l inoltro del PC 1 e il percorso di rete
vanno verificati prima delle prove da telefoni. Non sono state modificate regole
di rete o firewall esterne alla VM. HTTPS resta da configurare separatamente.

## Aggiornamento HTTPS del 14 novembre 2026

La riabilitazione della scheda privata del PC1 ha ripristinato il percorso di rete.
L indirizzo corrente e https://sisagen-cardio.poliba.it:11112 . HTTP-01 staging e
produzione hanno avuto esito positivo; certificato pubblico Let s Encrypt e TLS
1.3 verificati dalla workstation attraverso VM, PC1 e nome pubblico. Sono riusciti
anche login medico, catalogo, invio, worker, classificazione e download delle mappe
per tutti i tre modelli usando il solo indirizzo HTTPS pubblico. Il precedente
resoconto dei timeout documenta lo stato prima del ripristino, non lo stato attuale.
Il profilo attivo e compose.https-11112-http01.yaml; la .env della VM lo seleziona
tramite COMPOSE_FILE. Nessun test finale dei modelli e stato riaperto.


## Pazienti mobile e Analisi rapide web — 14 novembre 2026

- Windows, Python 3.12.14, ambiente con requirements dei modelli: **69 passed**,
  168,92 s, **0 skipped**. Comando da `server/` (MODEL_TEST_DIR impostato alla
  cartella privata dei pesi):
  `python -m pytest tests -x -ra --tb=short -p no:cacheprovider --basetemp=<cartella-temporanea-nuova> -o addopts=''`.
- Immagine finale Linux costruita con il Dockerfile del server, Python 3.12.16,
  tutti e tre i modelli reali montati in sola lettura: **69 passed**, 60,34 s,
  **0 skipped**. Test in contenitore isolato, senza database o immagini del servizio:
  `MODEL_TEST_DIR=/models MODEL_THREADS=8 PYTHONPATH=/checks:/app:/tmp/checkdeps python -m pytest -ra -c /checks/pytest.ini -p no:cacheprovider --basetemp=/tmp/test-run -o addopts='' /checks/tests`.
- `node --check server/app/static/app.js`: superato. Browser locale con database
  e immagini sintetici separati: login unico e aree dei tre ruoli, Analisi rapide
  visibile solo al medico; elenco, dettaglio con punteggi e Grad-CAM, stato in coda,
  errore spiegato e nuovo limite/formati del modulo paziente verificati. Lo script
  statico ha un identificativo di versione per aggiornare anche i browser già aperti.
- I test Bearer non inviano cookie, Origin o CSRF; tutte le scritture inviano
  X-Requested-With. Verificati ciclo completo del paziente e revisione/segmentazioni
  pubblicate dal medico, logout/revoca, isolamento, admin escluso dal login mobile,
  token non valido insieme a cookie valido, CSRF/origine/middleware conservati.
- Upload reali nei test: JPEG, PNG, WebP, HEIC/HEIF, PNG oltre 12 MiB e sotto 40 MiB;
  immagini oltre 25 MP rifiutate per i casi. Gli invii rapidi conservano 80 MP.
- Storico rapido: proprietà, cookie e Bearer, pagine da 50, ordine, audit,
  serializzazione senza alterare il JSON salvato e PNG protette/no-store; mappe
  assenti, invii incompleti e tipi non ammessi rifiutati.

Verifica su `https://sisagen-cardio.poliba.it:11112`, con validazione normale di CA
ed hostname, usando gli account di prova già presenti e senza nuove password:

| Controllo | Risultato |
|---|---|
| health e ready | 200 |
| Login paziente /v1/session e GET /api/cases con Bearer | 200 / 200 |
| Paziente: catalogo, inferenza diretta e storico rapido | 403 |
| Logout paziente, poi riuso del token sui casi | 204 / 401 |
| Login mobile amministratore | 403, messaggio previsto |
| Login web, cookie Secure/HttpOnly/SameSite e logout per tutti i ruoli | 200 / 204 |
| Scrittura Bearer senza X-Requested-With | 403 |
| Invio rapido medico con immagine sintetica DINOv2 | 201, completed |
| Foto normalizzata, heatmap e sovrapposizione | PNG 200, no-store, dimensioni allineate |
| Stesso invio nello storico con cookie dello stesso medico | 200, etichetta principale presente |
| Storico anonimo | 401 |

Rilascio nel profilo HTTPS HTTP-01 esistente: backup database/immagini verificato
con SHA-256 e mantenuto sulla VM, versione precedente conservata per rollback,
API/worker ricostruiti e riavviati. Configurazione .env/HTTPS e record preesistenti
conservati. Nessun cambiamento di schema o migrazione aggiuntiva. Le prove live
aggiungono solo invii sintetici tracciabili. Nessuna credenziale o peso in Git.

Restano da verificare l’app aggiornata su telefoni reali e la validazione clinica
indipendente. Il flusso dei casi mantiene l’integrazione FTN preesistente; la scelta
di acquisizione clinical/dermoscopic e modello è disponibile negli invii rapidi del
medico, non nei casi. Una macro clinica non va sostituita con inferenza FTN.


## Contratto 2: Grad-CAM nei casi paziente — aggiornamento successivo del 14 novembre

Il limite del precedente paragrafo (casi sempre FTN) è superato per le nuove
analisi. I casi richiedono mode esplicito; gli storici restano senza modalità
finché il medico non la conferma. Specifica: CASE_GRADCAM.md. Prompt per il client:
PROMPT_APP_CASE_GRADCAM.md. Flutter non modificato da questo aggiornamento.

- Windows Python 3.12.14, dipendenze modelli e tutti i pesi reali: **87 passed**,
  202,91 secondi, **0 skipped**. Da server/:
  `python -m pytest tests -x -ra --tb=short -p no:cacheprovider --basetemp=<nuova-cartella-temporanea> -o addopts=''`,
  con MODEL_TEST_DIR impostato alla cartella privata dei pesi e MODEL_THREADS=8.
- Immagine Docker Linux Python 3.12.16 con tutti i modelli reali: **87 passed**,
  82,54 secondi, **0 skipped**, database e storage di test separati:
  `python -m pytest -ra -c /checks/pytest.ini -p no:cacheprovider --basetemp=/tmp/test-run -o addopts='' /checks/tests`,
  con MODEL_TEST_DIR=/models, MODEL_THREADS=8, PYTHONPATH=/checks:/app:/tmp/checkdeps.
- I nuovi test verificano modalità obbligatoria, conferma degli storici, nessun
  fallback clinico a FTN, modelli incompatibili, PNG L/RGBA/RGB allineate, pubblicazione
  esplicita, consensi indipendenti, assenza dei punteggi al paziente, revoca degli URL
  dopo una nuova revisione e corrispondenza della classe su tutte le foto. I test
  reali dei tre modelli verificano che cambiare target Grad-CAM non alteri i punteggi
  del classificatore. I file sigillati adapter.py/ftn.py sono rimasti identici.
- Migrazione provata anche in PostgreSQL 17 su database temporaneo con record
  sintetici: note, record e revisioni conservati; mode NULL e share_explanation false.
  Il database temporaneo è stato eliminato al termine, quello del servizio non è
  stato usato per questo test.
- `node --check app/static/app.js`: superato. Browser locale con soli dati sintetici:
  visibilità medico, correzione MEL→NEV, consenso disabilitato prima del ricalcolo,
  nuova Grad-CAM NEV, bozza del messaggio conservata, pubblicazione e vista paziente
  con foto/mappa caricate (288×192) e zero barre dei punteggi. Corretto lo stile
  hidden affinché i comandi nascosti non siano visualizzati come pulsanti.

Rilascio sulla VM: backup database/immagini verificato con SHA-256 e mantenuto
sulla VM; migrazione additiva 20261114_case_explanations; nessuna attribuzione
inferenziale della modalità ai casi storici. Conteggi dei record invariati durante
la migrazione, .env e profilo HTTPS HTTP-01 conservati, API/worker sani.
Il rollback conserva lo schema additivo e mantiene fermo il worker precedente,
per impedire che elabori nuovi job clinici con il vecchio percorso FTN.

Verifica HTTPS reale su sisagen-cardio.poliba.it:11112 con CA/hostname verificati,
account di prova esistenti e due casi aggiuntivi con sole foto sintetiche:

- Login paziente/medico 200; status case_contract_version=2; caso nuovo senza mode 422.
- clinical: creazione 201, upload EXIF 201 e normalizzazione a 192×288, submit 200,
  ConvNeXt completato senza segmentazione; medico legge Grad-CAM/overlay/composite 200,
  paziente prima della pubblicazione 404 e nessun output preliminare nel dettaglio.
- Condivisione per classe finale diversa dalla mappa: 409. Rianalisi DINOv2 per la
  classe corretta 200/completed; pubblicazione 201; paziente legge tutte le mappe 200,
  classe coerente con la revisione e nessun punteggio o analisi privata.
- dermoscopic: FTN completato, maschera separata e Grad-CAM; pubblicazione con entrambi
  i consensi 201 e mappe paziente 200. Nessuna conversione delle classi tra i percorsi.
- Stessi casi letti con cookie del medico e del paziente via login web, 200; logout
  204. Inferenza diretta paziente ancora 403, storico Analisi rapide medico 200.
  Sessioni tecniche revocate al termine. Le prove live non cancellano gli storici.

Restano la modifica del client Flutter e le prove su Android/iPhone reali, affidate
all’altro agente tramite il prompt. Queste verifiche software e le immagini
sintetiche non misurano accuratezza o validità clinica di mappe e classificazioni.
