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
