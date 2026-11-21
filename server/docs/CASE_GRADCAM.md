# Casi paziente: acquisizione, modelli e pubblicazione Grad-CAM (contratto 2)

Backend in `server/`, client Flutter in `mobile/`. Il login resta unico nel web;
app: pazienti e medici usano Bearer, admin solo web. Gli invii rapidi `/v1` restano
riservati ai medici e separati dai casi. Nessun risultato è pubblicato automaticamente.

## Autenticazione e compatibilità

Ogni richiesta autenticata dell’app invia `Authorization: Bearer <token>`; ogni
richiesta non GET aggiunge `X-Requested-With: Telederm`. Nessun cookie, Origin o
CSRF. Browser: cookie+CSRF e controlli d’origine invariati. Errori `/api`:
`{"detail":"..."}` (validazione può aggiungere `errors`); `/v1`: `error.code/message`.
`GET /api/status` restituisce `case_contract_version: 2`, `acquisition_modes`,
`max_images: 4`, `max_upload_mb: 40`. Login/logout invariati.

**Cambiamento del contratto:** la creazione di nuovi casi richiede `mode`.
Richieste senza `mode`: 422, senza inferenza automatica o default dermatoscopico.

## Tipo di analisi per ferite e ulcere

Estensione retrocompatibile: `GET /api/status` mantiene `case_contract_version: 2`
e aggiunge `analysis_task_contract_version: 1` e
`analysis_tasks: ["skin_lesion", "wound_type", "dermoscopic_lesion"]`.
`POST /api/cases`, `PATCH /api/cases/{id}/acquisition` e reanalyze accettano
`analysis_task` facoltativo. Senza il nuovo campo i nuovi casi conservano il
percorso precedente: clinical → skin_lesion, dermoscopic → dermoscopic_lesion.

Per un caso di ferita usare `mode=clinical, analysis_task=wound_type`. Il submit
congela `clinical-wounds-azh`; non viene eseguito un riconoscimento del tipo di foto.
Il dettaglio e le liste del caso restituiscono `analysis_task`; anche ogni analisi
medica conserva il task. Il paziente non accede al catalogo medico o ai punteggi.
Combinazioni incompatibili in creazione/acquisition: 422. In reanalyze: 400.
Il campo è ammesso solo per i casi; `/v1/submissions` conserva i campi multipart
esistenti e identifica il task dal `model_id` esplicito.

La patch con stessa modalità e senza task conserva la scelta già effettuata. In
bozza il task può essere cambiato esplicitamente; dopo l'invio lo cambia solo il
medico tramite reanalyze. Il modello esplicito del medico determina il task se
questo è omesso; se forniti entrambi devono corrispondere. Cambiando solo task il
server sceglie il modello previsto per il task e non conserva un modello incompatibile.
Le mappe pubblicate devono corrispondere anche al tipo di analisi corrente.
Migrazione additiva `20261120_wound_task`: valorizza il task delle modalità storiche
esplicite, lasciando NULL i casi e le analisi con acquisizione non confermata.

Specifiche complete: [WOUNDS.md](WOUNDS.md). Prompt app: [PROMPT_APP_WOUNDS.md](PROMPT_APP_WOUNDS.md).

## Creazione e invio paziente

`POST /api/cases` → 201, dettaglio completo:

```json
{"mode":"clinical","body_site":"Sede di prova","notes":"Nota sintetica","demo_confirmed":true}
```

`mode` obbligatorio: `clinical` per smartphone normale o macro; `dermoscopic` per
dermatoscopio/adattatore. Tutte le foto del caso hanno la stessa acquisizione.
SEK non viene convertito in BKL; nessuna modalità viene dedotta dai pixel.
Il paziente sceglie acquisizione e tipo di analisi, non l’architettura: al submit
il server congela nell’AnalysisRun il modello previsto per quel percorso. Una mancanza del modello lascia waiting_model, senza
fallback all’altro percorso.

`PATCH /api/cases/{id}/acquisition`, JSON `{expected_version,mode}`, solo paziente
proprietario: ammesso in bozza; per `needs_images` si può confermare una modalità
storica mancante, ma non cambiare quella delle immagini già inviate. → 200 dettaglio
aggiornato; versione obsoleta/stato non consentito: 409. Nei casi già inviati la
conferma/correzione è del medico tramite reanalyze.

Upload/rimozione/submit invariati: POST `/{id}/images` multipart `expected_version`
e `file` → 201; DELETE `/{id}/images/{image_id}` JSON `{expected_version}` → 200
(solo bozza); POST `/{id}/submit` JSON `{expected_version}` → 200. Usare sempre la
nuova `version` restituita. JPEG/PNG/WebP/HEIC/HEIF, 40 MiB, 25 MP, minimo 32 px/lato,
quattro foto; EXIF applicato, PNG RGB/sRGB senza metadati. `/v1/submissions` mantiene
il limite separato di 80 MP.

## Analisi e scelta del medico

`GET /api/models?mode=clinical|dermoscopic`: solo medico, cookie o Bearer. Stesso
catalogo di `/v1/models`: id/name/mode/default/available/classes/segmentation ecc.
Paziente/admin 403, anonimo 401. Nessun percorso arbitrario o modello fuori catalogo.

`GET /api/cases/{id}` del medico include `mode` e `analyses`, dal più recente.
Ogni analisi contiene id/state/mode/model_id/explanation_target/failure_code/tempi.
Ogni `images[]` contiene:

- image_id, input_sha256, classification (model_name/model_version/labels `{label,score}`);
- segmentation_available, mask_url, overlay_url (null se non disponibili);
- explanation (method/target_class/status e metadati di normalizzazione);
- heatmap_url (PNG L), heatmap_overlay_url (PNG RGBA trasparente),
  heatmap_composite_url (PNG RGB: foto originale normalizzata + Grad-CAM).

Mappe allineate alla foto normalizzata, stessa larghezza/altezza. L’overlay RGBA va
sovrapposto alla foto una sola volta; il composite è già composto, utile per vista
semplice e download. Grad-CAM non è una maschera di lesione o probabilità per pixel.
`no_positive_signal` non significa assenza di lesione. Solo FTN fornisce segmentazione.

`POST /api/cases/{id}/reanalyze` → 200, asincrono:

```json
{"expected_version":5,"mode":"clinical","model_id":"clinical-dinov2-base","explanation_target":"NEV"}
```

`mode` facoltativo se già confermato; obbligatorio per uno storico senza modalità.
`model_id` facoltativo: conserva il modello precedente se compatibile con modalità
e task richiesti; altrimenti risolve il modello del percorso selezionato. `explanation_target` omesso/null:
mappa per la classe predetta su ogni foto; classe specificata: stessa classe su tutte
le foto. Etichette esatte del catalogo; nessuna equivalenza NEV/NV o SEK/BKL.
Modello/classe incompatibili: 400. Stati ammessi: waiting_model, analysis_failed,
awaiting_review, released; queued o versione obsoleta: 409. Poll GET del dettaglio.

## Revisione e condivisione

`POST /api/cases/{id}/reviews` → 201, solo medico:

```json
{"expected_version":7,"decision":"corrected","final_label":"NEV","patient_message":"Messaggio del medico.","share_segmentation":false,"share_explanation":true}
```

`share_explanation` è nuovo, default false, indipendente da `share_segmentation`.
La pubblicazione richiede analisi completata con modalità confermata e modello
registrato. Per condividere Grad-CAM tutte le foto devono avere mappe presenti e
`explanation.target_class == final_label`; altrimenti 409, nessuna pubblicazione.
Se il medico corregge la classe, deve richiedere reanalyze con explanation_target,
attendere, visionare le nuove mappe, poi pubblicare. La classificazione del modello
non viene cambiata dal ricalcolo della mappa. Una diagnosi testuale fuori catalogo
può essere comunicata senza condividere Grad-CAM. Segmentazione richiesta a un
classificatore clinico: 400. `needs_images` non ammette label o condivisione mappe.

## Risposta e immagini del paziente

`GET /api/cases/{id}` del paziente non contiene analyses, classificazioni/punteggi
preliminari o metadati interni. Contiene immagini proprie, reviews (con
share_explanation), published_segmentations e il nuovo `published_explanations`:

```json
{"image_id":"...","analysis_id":"...","review_id":"...","method":"gradcam","target_class":"NEV","status":"available","heatmap_url":"/api/cases/.../heatmap","overlay_url":"/api/cases/.../heatmap_overlay","composite_url":"/api/cases/.../heatmap_composite","warning":"Mappa sperimentale del modello per la classe indicata, condivisa dal medico. Non è il contorno della lesione né una misura del rischio."}
```

Array vuoto finché non condiviso. Le mappe esposte sono quelle dell’ultima revisione
del caso, se approvata/corretta e coerente con modalità e tipo di analisi correnti. Una nuova revisione
senza consenso revoca l’accesso alle precedenti mappe, anche usando URL già noti.
La revisione `needs_images` non pubblica mappe. Le valutazioni testuali storiche
rimangono in reviews. Prima della successiva revisione restano solo le mappe già
pubblicate dalla precedente, mai quelle dell’analisi nuova.

GET autenticati `/api/cases/{id}/analyses/{run}/images/{image}/{kind}`:
`mask`, `overlay`, `heatmap`, `heatmap_overlay`, `heatmap_composite`. image/png,
Cache-Control no-store, medico autorizzato o paziente proprietario con consenso
appropriato sull’ultima revisione. Invio/caso/immagine altrui o mappa non condivisa,
non presente, tipo invalido: 404; anonimo: 401; admin: 403. Le consultazioni sono
auditate. Il composite è una foto PNG scaricabile tramite richiesta autenticata.

## Storico e migrazione

Migrazione additiva `20261114_case_explanations`: casi e analisi storici hanno mode
NULL, nessuna attribuzione automatica a dermoscopic. Nessun peso, immagine o referto
viene cancellato. share_explanation storico è false. Job storici senza modalità
si fermano con waiting_model/acquisition_mode_required e non raggiungono FTN.
Il medico conferma modalità/modello e richiede una nuova analisi prima di pubblicare
una nuova valutazione. Le segmentazioni già pubblicate restano storiche; cambiare
modalità o pubblicare una nuova revisione rende non accessibili quelle non coerenti.

Validazione clinica indipendente e prove su telefoni reali ancora necessarie.
