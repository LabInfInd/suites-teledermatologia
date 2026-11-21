# Integrazione di ferite e ulcere nell'app Flutter

Lavora sull'app Flutter SUI.T.E.S. nel repository corrente. Integra il nuovo percorso
**Ferite e ulcere** per scopi di ricerca, conservando le funzionalità e i ruoli già
implementati. Completa codice e verifiche: non fermarti a una proposta. Il backend
è già aggiornato; questa richiesta riguarda il client, senza riaddestrare modelli.

## Prima di modificare

Leggi le istruzioni del repository, server/docs/WOUNDS.md,
server/docs/API_MOBILE.md e server/docs/CASE_GRADCAM.md. Ispeziona lo stato reale
dell'app e conserva le modifiche esistenti. Il client è in mobile/. I punti iniziali
sono lib/src/api/operator_session.dart, lib/src/api/http_submission_api.dart,
lib/src/ui/acquisition_controller.dart, acquisition_page.dart e
submission_result_page.dart; adatta anche le schermate paziente/medico già presenti.
Il server HTTPS del progetto è https://sisagen-cardio.poliba.it:11112; mantieni la
base URL configurabile e gli eventuali prefissi di percorso.

## Modalità e tipo di analisi

Mantieni due concetti distinti:

- mode=clinical: fotografia clinica da smartphone, anche macro.
- mode=dermoscopic: fotografia con dermatoscopio o adattatore.
- analysis_task=skin_lesion: lesioni cutanee in foto cliniche.
- analysis_task=wound_type: ferite e ulcere in foto cliniche.
- analysis_task=dermoscopic_lesion: lesioni cutanee in dermatoscopia.

Non aggiungere mode=wound o una conversione automatica basata sui pixel. Presenta
il tipo di analisi con nomi italiani; per dermoscopic rendi disponibile soltanto
il relativo task. Il percorso ferite deve essere scelto esplicitamente. Conserva
le corrispondenze delle classi PAD e FTN, inclusa la distinzione SEK/BKL e NEV/NV.

## Compatibilità e casi paziente

GET /api/status mantiene case_contract_version=2 e aggiunge
analysis_task_contract_version=1 e analysis_tasks con i tre valori sopra. Se il
server non espone questa estensione, conserva i flussi precedenti e non proporre
un percorso ferite che quel server non supporta.

POST /api/cases ora accetta, oltre ai campi già previsti, analysis_task facoltativo.
Esempio per la ricerca sulle ferite:
{"mode":"clinical","analysis_task":"wound_type","body_site":"Piede","notes":"Caso di ricerca","demo_confirmed":true}.
Senza il campo, clinical conserva skin_lesion e dermoscopic conserva
dermoscopic_lesion. Lista e dettaglio del caso restituiscono analysis_task.
Il paziente sceglie il percorso, non l'architettura del modello, e non chiama
/api/models o /v1/models, che sono riservati al medico.

PATCH /api/cases/{id}/acquisition accetta expected_version, mode e analysis_task.
In bozza consente un cambio esplicito; a parità di mode e con task omesso conserva
la scelta. Per needs_images non si cambia il percorso già confermato delle foto.
Upload e submit restano quelli esistenti: /api/cases/{id}/images e /submit,
sempre con expected_version aggiornato. Il submit di un caso wound_type seleziona
il modello ferite sul server. Non usare /v1/submissions per i casi paziente.

## Catalogo e analisi del medico

GET /api/models o /v1/models restituisce modelli con id, name, mode, task, scope,
classes, class_names_it, available, default, segmentation, explanation e intended_use.
Estendi il modello dati del client e gestisci i metadati facoltativi dei server
precedenti. Filtra per acquisizione e task; usa solo modelli available=true.
Per ferite il modello è clinical-wounds-azh, mode=clinical, task=wound_type,
default=false, scope=four_known_wound_types_only, segmentation=false,
explanation=gradcam. Non sostituirlo con il default PAD se manca o è disabilitato.

Le quattro etichette API sono diabetic, pressure, surgical, venous. Usa
class_names_it per visualizzare rispettivamente Ulcera diabetica, Lesione da
pressione, Ferita chirurgica, Ulcera venosa; conserva gli ID originali nelle richieste.
Le etichette e i punteggi possono arrivare ordinati per probabilità: associa per
label, senza assumere quattro/sei/sette posizioni fisse. Per etichette sconosciute
usa un fallback leggibile senza scartare il risultato.

Per il caso paziente il medico può richiedere:
POST /api/cases/{id}/reanalyze con
{"expected_version":5,"mode":"clinical","analysis_task":"wound_type","model_id":"clinical-wounds-azh","explanation_target":"pressure"}.
explanation_target omesso/null genera la mappa per la classe predetta.
Se model_id è esplicito e task è omesso il server ricava il task dal modello;
se entrambi sono forniti devono corrispondere. Cambiando modello o task azzera
un target Grad-CAM precedente incompatibile. Popola i target da model.classes.
Ogni analysis restituisce analysis_task. Gestisci queued/running/completed,
waiting_model e failed senza presentare una ricevuta come diagnosi completata.

## Invii rapidi e risultati

Per gli invii rapidi del medico conserva POST /v1/submissions multipart con
submission_id, mode, case_code, source, image, model_id ed explain. Per ferite
invia esplicitamente model_id=clinical-wounds-azh, mode=clinical, explain=true.
**Non aggiungere analysis_task a questo multipart**: il server rifiuta campi extra.
UUID invariato solo per ritentativi identici; nuovo modello/modalità/foto richiedono
un nuovo UUID. Polling dello status_url e gestione di 409/503 senza fallback.

result.classification contiene task, scope, class_names_it, labels, nome/versione
e calibrazione. Mostra punteggi sperimentali, senza trasformarli in rischio o certezza
diagnostica. Il task confronta quattro categorie note: non esclude tumori, non
riconosce tutte le ferite e non certifica l'assenza di infezione o ischemia.
Mostra un avviso breve: "Classificazione sperimentale per ricerca su quattro tipi
di ferita. Richiede valutazione medica." Non usare l'accuracy del dataset come
probabilità del singolo caso. Non aggiungere barriere o conferme ripetitive.

Mostra foto normalizzata e Grad-CAM allineate rispettando EXIF e proporzioni.
no_positive_signal significa assenza di contributo positivo visualizzabile, non
assenza di ferita. Per il modello ferite non mostrare maschere o misure di area:
segmentation.available=false. Mantieni la segmentazione FTN dove disponibile.

## Accessi e pubblicazione

Bearer su tutte le richieste e sul download dei PNG; X-Requested-With: Telederm
su ogni non GET, inclusi login e logout. Non aggiungere cookie/Origin/CSRF al client.
Accetta URL delle immagini solo dello stesso server e nei percorsi autorizzati;
non inviare token a URL assoluti esterni. Se necessario estendi la allowlist ai
percorsi /api/cases/{case}/analyses/{run}/images/{image}/{kind}, mantenendo controlli
stretti. heatmap_overlay è trasparente; heatmap_composite è già composto e non va
sovrapposto una seconda volta.

Il paziente vede solo reviews e published_explanations/published_segmentations
approvate. Non mostrare analyses, punteggi o mappe preliminari. La pubblicazione
resta una decisione del medico tramite reviews, final_label API e share_explanation;
share_segmentation=false per ferite. Non autorizzare inferenza diretta al paziente.
La correzione di etichetta con condivisione della mappa richiede prima reanalyze
per quella classe e attesa del risultato, secondo il contratto casi esistente.

## Verifiche e consegna

Aggiungi test mirati per parsing del catalogo, compatibilità con campi mancanti,
selezione ferite esplicita e assenza di fallback, combinazioni mode/task, payload
paziente e rapido distinti, target Grad-CAM, UUID nei ritentativi, classi ordinate,
assenza di segmentazione e visibilità dei risultati per ruolo. Conserva i test
delle lesioni PAD e FTN. Usa fixture sintetiche, senza immagini o credenziali reali.
Esegui flutter analyze e flutter test, correggi gli errori introdotti e riporta
file modificati, controlli svolti ed eventuali limiti osservati. Non modificare
backend, pesi, dataset, split, certificati o impostazioni della VM. Non inserire
credenziali nel repository e non fare commit di dati o artefatti locali.
