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
