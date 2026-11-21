# Contratto di ricezione foto — compatibilita e estensione server

> **Implementato nel server del repository.** Il contratto di ricevuta descritto sotto resta retrocompatibile; la specifica corrente aggiunge autenticazione medico, `model_id`, catalogo, stato, risultati e mappe: [server/docs/API_MOBILE.md](../server/docs/API_MOBILE.md). Le sezioni storiche sulla autenticazione da definire sono superate da `/v1/session`. La conferma di ricezione resta distinta dall analisi.

## Estensione per ferite e ulcere

Specifiche del server di ricerca: [Ferite e ulcere](../server/docs/WOUNDS.md).
Prompt per il client Flutter: [PROMPT_APP_WOUNDS](../server/docs/PROMPT_APP_WOUNDS.md).
L'estensione aggiunge `analysis_task` facoltativo ai casi paziente e i metadati del
modello `clinical-wounds-azh`, mantenendo `mode=clinical`. Negli invii rapidi
`/v1/submissions` il task si seleziona con `model_id`, senza aggiungere campi multipart.

## Aggiornamento casi paziente: contratto 2

Specifica implementata e prevalente: [Grad-CAM nei casi](../server/docs/CASE_GRADCAM.md).
`mode` è obbligatorio sui nuovi casi. Il medico può scegliere modello e classe da
spiegare, visionare Grad-CAM nel web e autorizzare la pubblicazione con
`share_explanation`. Il paziente riceve soltanto `published_explanations` approvate.
Prompt per il client: [PROMPT_APP_CASE_GRADCAM](../server/docs/PROMPT_APP_CASE_GRADCAM.md).

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

## Principi del contratto storico di ricevuta

- Una richiesta corrisponde a **una foto**, **una modalità dichiarata** e **un codice caso**.
- Il server sceglie il modello in base al campo `mode`: `clinical` (foto clinica da smartphone, anche macro) oppure `dermoscopic` (immagine acquisita con dermatoscopio). Una foto macro senza dermatoscopio è `clinical`. Il server non deve sostituire la modalità dichiarata con una dedotta dall’immagine.
- La risposta è una **conferma di ricezione**, non un risultato diagnostico. La restituzione di eventuali esiti dei modelli è fuori da questa proposta.
- In produzione la comunicazione avviene solo in HTTPS.

## Endpoint

```
POST {BASE_URL}/v1/submissions
Content-Type: multipart/form-data
Accept: application/json
Authorization: Bearer <token>        (solo quando l’autenticazione sarà definita)
```

`BASE_URL` è configurabile nell’app (`SUITES_API_BASE_URL`) e può contenere un prefisso di percorso, per esempio `https://suites.example.org/api` → `https://suites.example.org/api/v1/submissions`.

### Campi della richiesta

| Campo | Tipo | Obbligatorio | Note |
|---|---|---|---|
| `submission_id` | UUID v4 | sì | Generato dal telefono per ogni nuovo invio; è la chiave di idempotenza (vedi sotto). |
| `mode` | `clinical` \| `dermoscopic` | sì | Tipo di acquisizione dichiarato dall’operatore. |
| `case_code` | stringa | sì | Codice pseudonimo del caso, 3–40 caratteri `A–Z a–z 0–9 - _`, inizia con lettera o cifra. Mai nome, cognome o codice fiscale. |
| `source` | `camera` \| `gallery` \| `unknown` | sì | Provenienza: `unknown` indica una foto recuperata dopo che Android ha chiuso l’app durante lo scatto. |
| `image` | file | sì | Una sola immagine. |

Vincoli sul file `image`:

- Formati: JPEG, PNG, HEIC/HEIF, WebP. Il `Content-Type` della parte corrisponde al contenuto, riconosciuto dalla firma del file (`image/jpeg`, `image/png`, `image/heic`, `image/heif`, `image/webp`).
- Dimensione massima proposta: 40 MiB (verificata anche dall’app).
- Nome file generico (`image.jpg`, `image.heic`, …): il nome originale non viene inviato.
- L’immagine non è ridimensionata né ricompressa dall’app. Su iOS `image_picker` la riscrive in JPEG alla qualità massima conservando i metadati; su Android le foto della fotocamera sono il JPEG prodotto dall’app fotocamera e quelle della galleria il file originale.
- L’orientamento può essere indicato solo dall’EXIF: **il server deve applicarlo** prima del preprocessing.
- Il preprocessing specifico dei modelli (ritaglio, ridimensionamento, normalizzazione, conversione RGB) spetta al server, secondo il manifest di ciascun modello.
- L’app rimuove la posizione GPS dai JPEG senza ricomprimerli. Gli altri formati arrivano con i metadati originali: **il server deve rimuovere i metadati di posizione da tutti i file** al momento della ricezione.

Esempio:

```sh
curl -X POST "$BASE_URL/v1/submissions" \
  -H "Accept: application/json" \
  -F submission_id=0b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b \
  -F mode=clinical \
  -F case_code=CASO-001 \
  -F source=camera \
  -F "image=@foto.jpg;type=image/jpeg;filename=image.jpg"
```

## Risposta di conferma

`201 Created` per un nuovo invio, `200 OK` quando lo stesso `submission_id` viene ripresentato con lo stesso contenuto.

```json
{
  "submission_id": "0b6f4a2e-3c1d-4e5f-9a7b-1c2d3e4f5a6b",
  "status": "received",
  "mode": "clinical",
  "case_code": "CASO-001",
  "received_at": "2026-11-12T10:15:30Z",
  "server_reference": "SRV-2026-000123"
}
```

| Campo | Obbligatorio | Note |
|---|---|---|
| `submission_id`, `mode`, `case_code` | sì | Devono coincidere con quelli inviati: altrimenti l’app non considera confermata la ricezione. |
| `status` | sì | Sempre `received`. |
| `received_at` | no | ISO 8601 in UTC. |
| `server_reference` | no | Riferimento leggibile per il supporto, massimo 64 caratteri. |
| `simulated` | no | `true` solo nel server simulato di sviluppo. |

`received` significa che foto e metadati sono stati **salvati in modo persistente**, non solo letti in memoria. L’inferenza può avvenire in seguito e non deve essere eseguita all’interno di questa richiesta.

## Errori

Corpo JSON, con `message` in italiano e privo di dati personali (l’app lo mostra all’operatore):

```json
{ "error": { "code": "invalid_case_code", "message": "Codice caso non riconosciuto." } }
```

| Stato | `error.code` suggeriti | Comportamento dell’app |
|---|---|---|
| 400 / 422 | `invalid_request`, `invalid_mode`, `invalid_case_code`, `invalid_image` | Nessun ritentativo: messaggio specifico, l’operatore corregge i dati. |
| 401 | `unauthorized` | Nessun ritentativo: credenziali assenti, non valide o scadute. |
| 403 | `forbidden` | Nessun ritentativo. |
| 404 | — | Configurazione errata dell’indirizzo. |
| 409 | `submission_conflict` | Stesso `submission_id` con contenuto diverso: al nuovo tentativo l’app genera un nuovo identificativo. |
| 413 | `payload_too_large` | Nessun ritentativo. |
| 415 | `unsupported_media_type` | Nessun ritentativo. |
| 429 | `rate_limited` | Ritentativo automatico; `Retry-After` in secondi rispettato fino a 60 s. |
| 500 | `internal_error` | Nessun ritentativo automatico; l’operatore può riprovare. |
| 502 / 503 / 504 | `server_unavailable` | Ritentativo automatico; `Retry-After` rispettato fino a 60 s. |

Una risposta 2xx non JSON, incompleta, più grande di 64 KiB o non corrispondente all’invio viene trattata come “ricezione non confermata”: l’operatore può riprovare senza rischio di duplicati.

## Idempotenza e ritentativi

- Il server conserva il `submission_id` (proposta: almeno 24 ore). Se lo riceve di nuovo con gli stessi `mode`, `case_code` e immagine (per esempio confrontando un hash SHA-256), risponde `200` con la conferma originale; con contenuto diverso risponde `409`.
- L’app riusa lo stesso `submission_id` per i ritentativi automatici e per i “Riprova” dell’operatore, finché foto, modalità e codice caso non cambiano. Così una risposta persa (timeout, rete caduta dopo il salvataggio, annullamento tardivo) non genera duplicati.
- Ritentativi automatici: al massimo 3 tentativi complessivi per errori di rete, timeout, 429 e 502–504, con attese di 2 s e 4 s, oppure il `Retry-After` indicato se non supera 60 s.
- Timeout: l’app interrompe l’invio se per 30 s non trasmette né riceve dati. Il server dovrebbe rispondere subito dopo il salvataggio.

## Autenticazione (proposta storica superata dalla sessione sopra)

L’app supporta già `Authorization: Bearer <token>` tramite un fornitore di token (`AccessTokenProvider`), oggi non configurato. Opzioni da valutare:

1. accesso dell’operatore con OpenID Connect / OAuth 2.0 (Authorization Code con PKCE) e token di breve durata;
2. token per dispositivo rilasciato a una registrazione iniziale e conservato in Keychain/Keystore.

Vincoli in ogni caso: nessuna credenziale nel codice o in `--dart-define` (finisce nel binario); token mai registrati nei log; dopo un `401` l’app dovrà richiedere un nuovo accesso (non ancora implementato).

## Privacy e log

- Il server non registra nei log il contenuto delle immagini né i token; registra al massimo `submission_id`, `mode`, stato e tempi.
- `case_code` è un pseudonimo: l’app rifiuta valori con la struttura del codice fiscale, ma la tabella di corrispondenza con il paziente resta fuori dall’app e dal server di inferenza.
- Conservazione dei dati, basi giuridiche e valutazione d’impatto (DPIA) vanno definite con il centro.

## Punti aperti storici (stato corrente nel README server)

- Meccanismo di autenticazione e gestione della scadenza dei token.
- Regole del codice caso stabilite dal centro e verifica lato server della sua esistenza.
- Conferma di formati e limite di 40 MiB.
- Eventuale endpoint di stato (`GET /v1/submissions/{submission_id}`) e modalità di restituzione degli esiti, che non devono essere confusi con la conferma di ricezione.
- Eventuale controllo lato server della coerenza tra modalità dichiarata e immagine, senza sostituire la dichiarazione dell’operatore.
