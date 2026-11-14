# Prompt da consegnare a Claude — app Flutter, casi e Grad-CAM

Lavora sul tuo clone di `LabInfInd/suites-teledermatologia`, esclusivamente in
`mobile/`. Il server FastAPI e il web sono gestiti da un altro agente: non modificare
`server/`, migrazioni o contratto API. Leggi le istruzioni del repository prima di
intervenire. Aggiorna il tuo ramo da `origin/main` con rebase conservando il tuo
lavoro. Commit in inglese, autore e committer abrunetti, nessun coautore automatico.
Non inserire credenziali, token, foto o pesi nel repository.

Il server implementa ora il contratto 2 dei casi. Leggi prima la specifica
`server/docs/CASE_GRADCAM.md`, insieme a `server/docs/API_MOBILE.md` e
`docs/api-contratto-proposta.md`: sono l’autorità per gli schemi esatti. Mantieni
il login paziente/medico e gli invii rapidi del medico già implementati. Completa
il flusso paziente → caso → analisi privata → revisione del medico → pubblicazione
facoltativa Grad-CAM al paziente.

## Chiamate e autorizzazioni

- Base URL dell’istanza: `https://sisagen-cardio.poliba.it:11112`. Verifica normalmente
  certificato e hostname. Mantieni la configurazione dell’URL esistente.
- `POST /v1/session` accetta patient/doctor. Leggi role dalla risposta; admin 403,
  solo interfaccia web. `DELETE /v1/session` revoca anche il token del paziente.
- Ogni richiesta autenticata: `Authorization: Bearer <token>`. Ogni non GET:
  anche `X-Requested-With: Telederm`. Nessun cookie, Origin o CSRF. Valido anche
  per multipart, DELETE, PATCH e download PNG. Nessuna credenziale compilata nell’app.
- Errori `/api`: detail (e talvolta errors); `/v1`: error.code/message. Dopo 401
  chiudi la sessione; dopo 409 ricarica il caso e la nuova version prima di agire.
- `GET /api/status`: `case_contract_version:2`, acquisition_modes, max_images,
  max_upload_mb. Un server vecchio non autorizza un fallback dermatoscopico silenzioso.

## Paziente

- Richiedi esplicitamente la modalità di acquisizione prima di creare il caso:
  clinical = smartphone normale, anche macro; dermoscopic = dermatoscopio o
  smartphone con adattatore. Non dedurre la modalità dai pixel. Tutte le foto di
  un caso hanno la stessa modalità; acquisizioni diverse richiedono casi separati.
- `POST /api/cases` JSON `{mode,body_site,notes,demo_confirmed:true}` → 201 dettaglio.
  mode è obbligatorio, non inviare model_id qui. Il server sceglie il default corretto.
  La conferma demo resta esplicita: l’istanza è un prototipo con dati sintetici.
- GET `/api/cases?offset=`, GET `/api/cases/{id}`; upload multipart
  `/{id}/images` con `expected_version` e `file`; DELETE immagine JSON
  `{expected_version}` solo bozza; POST `/{id}/submit` JSON `{expected_version}`.
  Riutilizza sempre la nuova version ricevuta. Limiti casi: 40 MiB, 25 MP, quattro
  foto, JPEG/PNG/WebP/HEIC/HEIF, minimo 32 px/lato. Conserva l’originale per upload;
  il server applica EXIF/RGB e rimuove metadati. Non usare gli 80 MP degli invii rapidi.
- Correzione/conferma modalità bozza: PATCH `/api/cases/{id}/acquisition`
  `{expected_version,mode}`. In needs_images è ammessa la conferma di modalità
  storica mancante, non il cambio della modalità di immagini già inviate.
- Il paziente NON chiama `/v1/models`, `/v1/submissions*` o `/api/models` e non
  riceve analisi/punteggi preliminari. Mostra soltanto reviews e mappe pubblicate.
- Il dettaglio aggiunge `published_explanations`, array vuoto fino al consenso.
  Ogni elemento contiene image_id, analysis_id, review_id, method, target_class,
  status, heatmap_url, overlay_url, composite_url, warning. Collega la mappa alla
  foto tramite image_id e alla valutazione tramite review_id.
- Mostra foto con Grad-CAM e download soltanto dagli URL presenti nell’array.
  composite_url è già la foto RGB composta: non sovrapporre nuovamente overlay_url.
  In alternativa overlay_url è RGBA trasparente da allineare alla foto normalizzata,
  e heatmap_url è l’intensità L. Carica tutto con Bearer, anche Image.network e salvataggi.
  Non caricare una vecchia URL ricordata se non è più pubblicata; 404 rimuove la mappa.
- Mantieni separata published_segmentations. Grad-CAM non è segmentazione, contorno,
  confidenza per pixel o diagnosi. Mostra target_class e warning del server;
  no_positive_signal non significa assenza di lesione. Nessun punteggio non validato.

## Medico

- Mantieni sia i casi `/api/cases` sia gli invii rapidi `/v1/submissions` e il loro
  storico `/api/mobile-submissions`, con la separazione dei due flussi.
- Per i casi usa `GET /api/models?mode=...` (Bearer, solo medico): seleziona un ID
  del catalogo della modalità confermata, senza equivalenze SEK/BKL o NEV/NV.
- Il dettaglio dei casi include `analyses[]`, dal più recente: id/state/mode/model_id/
  explanation_target/failure_code e images[] con classification, segmentation_available,
  mask_url/overlay_url (nullable), explanation, heatmap_url, heatmap_overlay_url,
  heatmap_composite_url. Mostra target_class, versione del modello, originali e
  mappe; segmentazione solo se realmente disponibile. I classificatori clinici non segmentano.
- Reanalyze: POST `/api/cases/{id}/reanalyze`
  `{expected_version,mode?,model_id?,explanation_target?}` → 200 asincrono. Per gli
  storici mode:null il medico deve confermare la modalità prima di analizzare.
  Ometti explanation_target oppure invia null per spiegare la classe predetta;
  invia un’etichetta esatta del catalogo per spiegarla su tutte le foto.
- Se il medico corregge la classe, disabilita la condivisione finché tutte le foto
  non hanno Grad-CAM per la classe finale. Offri ricalcolo con explanation_target,
  conserva la bozza del messaggio durante polling, attendi completamento e fai
  esaminare le nuove mappe. Il ricalcolo non cambia la classificazione del modello.
- Pubblica con POST `/api/cases/{id}/reviews`
  `{expected_version,decision,final_label,patient_message,share_segmentation,share_explanation}`.
  share_explanation è facoltativo, default false e deve essere una scelta esplicita,
  indipendente dalla segmentazione. 409 se target/mappe non corrispondono alla classe
  finale su tutte le foto. Non aggirare il controllo ritentando con altri flag.
  Diagnosi fuori catalogo: pubblicazione testuale senza Grad-CAM.
  needs_images non ammette label o condivisione mappe.
- I nuovi URL PNG dei casi sono sotto
  `/api/cases/{id}/analyses/{run}/images/{image}/{mask|overlay|heatmap|heatmap_overlay|heatmap_composite}`.
  Protetti da Bearer e no-store. La segmentazione verde FTN non va chiamata Grad-CAM.

## Verifica e consegna

Aggiungi test Flutter significativi per scelta obbligatoria della modalità, campi
JSON/multipart e header su tutte le scritture/download, isolamento dei ruoli,
parsing nullable e casi storici, mappe assenti/prima e dopo pubblicazione, classe
corretta e ricalcolo, consensi separati, revoca con 404, errori 401/409/422,
allineamento delle immagini e nessun doppio overlay del composite. Esegui flutter
analyze e tutta la suite, riportando esiti reali e limiti delle prove sui dispositivi.
Non usare dati reali per prove automatiche e non modificare il server per far passare
un test client. Non effettuare richieste di mutazione o inferenza live durante la
build/test ordinaria: usa fixture locali; prova HTTPS solo come smoke test esplicito.
Consegna file modificati, comandi/esiti, eventuali incompatibilità e commit pubblicati.
