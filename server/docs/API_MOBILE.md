# API mobile SUI.T.E.S. v1

L invio resta compatibile con il client Flutter: `POST /v1/submissions` restituisce
una ricevuta persistente, non il risultato dell inferenza. HTTPS richiesto per dati
reali. Le prove HTTP esistenti sono limitate a foto sintetiche e account di prova.

## Sessione operatore

`POST /v1/session`, JSON `{"username":"operatore","password":"..."}`.
Restituisce `access_token`, `token_type: Bearer`, `expires_at` e `user`.
Solo account `doctor` attivi possono usare questa API: gli account paziente e
amministratore non ricevono immagini o predizioni attraverso questa interfaccia.
La sessione scade entro SESSION_HOURS (1-24, default 8); `DELETE /v1/session`
revoca il token corrente. Il blocco dopo otto tentativi falliti in 15 minuti e
condiviso con il login web. Password e token non entrano nei log. Nell app
conservarli soltanto a runtime o in Keychain/Keystore, mai nel repository/build.

Tutti gli endpoint seguenti richiedono `Authorization: Bearer <access_token>`.
I cookie e CSRF della piattaforma web `/api/` continuano a funzionare separatamente.

## Catalogo e scelta del modello

`GET /v1/models?mode=clinical` oppure `mode=dermoscopic` (filtro facoltativo).
Ogni voce contiene `id`, `name`, `mode`, `default`, `available`, `classes`,
`classification`, `segmentation`, `explanation`, `intended_use`.
`available` controlla la presenza dei file; integrita e caricamento sono verificati
all avvio del worker e prima dell inferenza. Nessun percorso o nome Python ricevuto
via HTTP viene eseguito. Un ID sconosciuto o incompatibile con la modalita e rifiutato.

| model_id | mode | Classi in ordine | Segmentazione |
|---|---|---|---|
| clinical-convnextv2-tiny | clinical | ACK,BCC,MEL,NEV,SCC,SEK | no |
| clinical-dinov2-base | clinical | ACK,BCC,MEL,NEV,SCC,SEK | no |
| dermoscopic-ftn | dermoscopic | AK,BCC,BKL,DF,MEL,NV,VASC | modello FTN separato |

I modelli clinici sono classificatori a sei classi. SEK non e l intera categoria
BKL e nessuna conversione fra classi viene applicata. Il contratto del FTN realmente
disponibile contiene sette classi e nessuna SCC: non viene rinominato come modello
ISIC a otto classi. Una macro rimane clinical; un adattatore dermatoscopico implica
dermoscopic. PanDerm non e incluso nel servizio: benchmark congelato e licenza
limitata alla ricerca accademica non commerciale, diritti di prodotto da chiarire.

## Invio persistente e idempotenza

`POST /v1/submissions`, multipart con una sola foto:

| Campo | Valore |
|---|---|
| submission_id | UUID v4 minuscolo canonico, riusato per i ritentativi |
| mode | clinical oppure dermoscopic |
| case_code | pseudonimo 3-40 lettere/cifre/trattini/underscore; no codice fiscale |
| source | camera, gallery oppure unknown |
| image | JPEG, PNG, WebP, HEIC/HEIF, massimo 40 MiB e 80 megapixel |
| model_id | facoltativo; omesso usa il default della modalita al primo invio |
| explain | facoltativo, default true; genera Grad-CAM |

Il server verifica contenuto/MIME, rifiuta animazioni e applica EXIF e conversione
RGB/sRGB prima di riscrivere una PNG senza metadati. Non memorizza il nome originale
o la foto originale con EXIF/GPS. Il limite di corpo e applicato prima del parser
multipart, anche con trasferimento chunked. Limite coda: 100 invii in attesa/esecuzione.

Risposta nuova: HTTP 201; identico ritentativo: HTTP 200 e stessa ricevuta:

```json
{"submission_id":"0b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b","status":"received","mode":"clinical","case_code":"CASO-001","model_id":"clinical-dinov2-base","received_at":"2026-11-13T12:00:00Z","server_reference":"SRV-...","status_url":"/v1/submissions/0b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b"}
```

La ricevuta viene emessa dopo scrittura del file, sincronizzazione e commit database.
Il confronto di idempotenza comprende i byte originali, mode, case_code, source,
model_id richiesto ed explain. Stesso ID con uno di questi campi diverso: HTTP 409.
Omettere model_id nei ritentativi preserva il default risolto al primo invio anche se
la configurazione cambia. Cambiare modello richiede un nuovo submission_id.
Gli invii e le mappe sono accessibili soltanto all account medico che li ha creati.
Un altro account riceve 404. La chiave e mantenuta fino alla cancellazione esplicita
secondo le regole di conservazione del centro; non viene eliminata automaticamente.

## Risultati e mappe

`GET /v1/submissions/{id}` restituisce `state` queued/running/completed/failed,
mode, model_id, tempi, failure_code e result (null finche non completato).

`result.classification` contiene nome/versione, lista ordinata `{label,score}`,
metodo di calibrazione e destinazione sperimentale. `result.segmentation.available`
indica se esiste una maschera indipendente. `result.explanation` specifica metodo,
classe spiegata, layer, score bersaglio, normalizzazione e stato.

`result.artifacts` contiene URL autenticati PNG, ove disponibili:

- normalized_image: PNG RGB senza metadati per allineare le sovrapposizioni;
- heatmap: Grad-CAM L, 0-255, stessa dimensione e orientamento della PNG normalizzata;
- heatmap_overlay: RGBA trasparente da sovrapporre alla foto normalizzata;
- segmentation_mask: solo FTN, L binaria 0/255;
- segmentation_overlay: solo FTN, RGBA trasparente.

Endpoint: `GET /v1/submissions/{id}/artifacts/{kind}`. Richiedono lo stesso Bearer,
non sono link pubblici e impostano Cache-Control: no-store. Il padding clinico viene
invertito prima del ripristino della mappa. La mappa e normalizzata per immagine e
non e una probabilita pixel per pixel. `no_positive_signal` significa mappa nulla,
non conferma di assenza di lesione. Non vengono inventate aree salienti o maschere.
Per FTN le cinque mappe TTA sono riallineate prima della media; la classe bersaglio
e quella della classificazione TTA. Per ViT si usa norm1 dell ultimo blocco prima
dell attenzione, eliminando CLS per ricostruire la griglia dei patch.

Grad-CAM puo evidenziare bordi, sfondo o artefatti e non certifica la correttezza
della previsione: https://arxiv.org/abs/1610.02391 . Nessuna heatmap viene trattata
come segmentazione. Il test finale storico non viene riutilizzato dal servizio.

## Errori

`{"error":{"code":"invalid_model","message":"Messaggio in italiano"}}`.
401 accesso, 403 ruolo/origine, 404 invio/mappa, 409 conflitto, 413 dimensione,
415 formato, 422 campi/immagine/modello, 429 coda piena (Retry-After: 30),
503 modello non installato. Le eccezioni di inferenza producono stato failed con
failure_code generico; immagini, token e note non vengono riportati nei log.

Il flusso web con validazione medica e pubblicazione al paziente rimane separato.
Gli esiti mobili sono riservati all operatore medico, non vengono pubblicati
automaticamente ai pazienti e non costituiscono un dispositivo clinico validato.
