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
