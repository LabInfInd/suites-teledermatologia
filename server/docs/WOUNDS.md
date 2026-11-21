# Classificazione di ferite e ulcere per ricerca

Il modello `clinical-wounds-azh` è abilitato nel catalogo per la sperimentazione del
progetto. L'acquisizione resta `clinical`; il task è `wound_type`. La selezione è
esplicita, tramite tipo di analisi del caso o modello negli invii rapidi. I default
PAD e FTN e le relative classi restano invariati.

## Classi e risultati

| Etichetta API | Nome italiano |
| --- | --- |
| diabetic | Ulcera diabetica |
| pressure | Lesione da pressione |
| surgical | Ferita chirurgica |
| venous | Ulcera venosa |

Il catalogo medico `/api/models` o `/v1/models` restituisce `task`, `scope`,
`class_names_it`, `classes`, `available`, `default`, `segmentation` ed `explanation`.
Per il nuovo modello: `scope=four_known_wound_types_only`, `default=false`,
`segmentation=false`, `explanation=gradcam`. Un modello non installato non va
sostituito da PAD o FTN. La classificazione include task, scope e nomi italiani;
i punteggi restano associati alle etichette API originali, indipendentemente dall'ordine.
Grad-CAM spiega la classe richiesta: non è segmentazione, misura fisica o rischio.

## Casi paziente

`GET /api/status` aggiunge `analysis_task_contract_version: 1` e l'elenco
`analysis_tasks: ["skin_lesion","wound_type","dermoscopic_lesion"]`. Il contratto
casi mantiene versione 2: i nuovi campi sono facoltativi e retrocompatibili.

Creazione paziente `POST /api/cases`:

```json
{"mode":"clinical","analysis_task":"wound_type","body_site":"Piede","notes":"Caso sintetico di ricerca","demo_confirmed":true}
```

Con `clinical` sono ammessi skin_lesion e wound_type; con `dermoscopic` soltanto
dermoscopic_lesion. Task omesso in creazione: percorso delle lesioni già previsto
per la modalità. La scelta non viene dedotta dall'immagine. Liste e dettaglio
restituiscono `analysis_task`; i dettagli medici includono il task di ciascun run.
Il paziente non sceglie architetture e non vede inferenze non validate.

In bozza `PATCH /api/cases/{id}/acquisition` accetta expected_version, mode e
analysis_task. Stessa modalità e task omesso: conserva la scelta. Per needs_images
non si cambia il percorso già confermato delle foto. Alla submit la richiesta
wound_type viene associata a clinical-wounds-azh; se i pesi mancano resta in attesa.

Il medico usa `POST /api/cases/{id}/reanalyze`:

```json
{"expected_version":5,"mode":"clinical","analysis_task":"wound_type","model_id":"clinical-wounds-azh","explanation_target":"pressure"}
```

explanation_target è facoltativo: omesso genera la mappa per la classe predetta.
Un model_id esplicito senza task determina il task; con entrambi presenti devono
corrispondere. Se cambia soltanto task il server risolve il relativo modello.
Le classi della spiegazione sono quelle del modello scelto. Le revisioni e le
mappe al paziente seguono il consenso del medico già previsto dal contratto casi.
Le mappe di un task diverso da quello corrente non sono pubblicabili.

## Invii rapidi del medico

`POST /v1/submissions` conserva il multipart esistente. Per ferite usare
`mode=clinical`, `model_id=clinical-wounds-azh`, explain=true e gli altri campi
obbligatori. Non inviare analysis_task in questo multipart. UUID invariato per
ritentativi identici; nuova foto/modalità/modello richiedono un nuovo invio.
Il task si legge dal catalogo e dalla classificazione del risultato.

Bearer per richieste e PNG; X-Requested-With: Telederm per ogni richiesta non GET.
Le mappe sono disponibili soltanto tramite URL autenticati. Nessuna pubblicazione
automatica ai pazienti. Errori e limiti fotografici sono in [API_MOBILE.md](API_MOBILE.md).

## Modello e installazione

Bundle DINOv2 Base a 224 pixel: `wounds-azh-v1-20261120`. SHA-256 dei pesi:
`d4288fd0586841b19cd0a40155549f14d60327c37e4259ec1c6858146d1dee03`.

Da una sorgente locale verificata usare `scripts/install_wound_bundle.py --source
PERCORSO_BUNDLE --model-dir PERCORSO_MODELLI`. Lo script verifica il bundle, installa
pesi/manifest/attribuzioni e rifiuta sovrascritture differenti. Dataset, credenziali,
pesi e immagini restano fuori da Git. Migrazione incrementale: `alembic upgrade head`.
Prima del rilascio conservare backup verificato e immagine precedente.

## Ambito di ricerca

La classificazione distingue quattro tipi noti in foto centrate sulla ferita. Non
è addestrata per cute sana, altri tipi di ferita, ustioni o immagini non valutabili;
non produce stadio, infezione, ischemia o segmentazione. Una lesione ulcerata può
richiedere anche valutazione oncologica. La baseline AZH non dimostra indipendenza
per paziente e non misura le prestazioni sulle foto complete dell'app.

L'uso richiesto è ricerca; la validazione clinica esterna non è completata.
Il repository AZH non specifica una licenza esplicita: mantenere la provenienza e
le attribuzioni, senza dichiarare diritti di distribuzione commerciale verificati.
Risultati e protocollo della workstation: `training/wounds`, `reports/wounds/RISULTATI.md`.
Prompt per il client: [PROMPT_APP_WOUNDS.md](PROMPT_APP_WOUNDS.md).
