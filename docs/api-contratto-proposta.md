# Contratto API minimo per l’invio delle foto — PROPOSTA

> **Stato: proposta da concordare** con chi sviluppa il server. Endpoint, autenticazione e formato della risposta non sono ancora stati definiti; questo documento descrive ciò che l’app implementa oggi (`mobile/lib/src/api/http_submission_api.dart`) e ciò che il server simulato di sviluppo riproduce (`mobile/lib/src/api/simulated_server.dart`). Ogni modifica concordata va riportata in entrambi i file e nei test.

## Principi

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

## Autenticazione (da definire)

L’app supporta già `Authorization: Bearer <token>` tramite un fornitore di token (`AccessTokenProvider`), oggi non configurato. Opzioni da valutare:

1. accesso dell’operatore con OpenID Connect / OAuth 2.0 (Authorization Code con PKCE) e token di breve durata;
2. token per dispositivo rilasciato a una registrazione iniziale e conservato in Keychain/Keystore.

Vincoli in ogni caso: nessuna credenziale nel codice o in `--dart-define` (finisce nel binario); token mai registrati nei log; dopo un `401` l’app dovrà richiedere un nuovo accesso (non ancora implementato).

## Privacy e log

- Il server non registra nei log il contenuto delle immagini né i token; registra al massimo `submission_id`, `mode`, stato e tempi.
- `case_code` è un pseudonimo: l’app rifiuta valori con la struttura del codice fiscale, ma la tabella di corrispondenza con il paziente resta fuori dall’app e dal server di inferenza.
- Conservazione dei dati, basi giuridiche e valutazione d’impatto (DPIA) vanno definite con il centro.

## Punti aperti

- Meccanismo di autenticazione e gestione della scadenza dei token.
- Regole del codice caso stabilite dal centro e verifica lato server della sua esistenza.
- Conferma di formati e limite di 40 MiB.
- Eventuale endpoint di stato (`GET /v1/submissions/{submission_id}`) e modalità di restituzione degli esiti, che non devono essere confusi con la conferma di ricezione.
- Eventuale controllo lato server della coerenza tra modalità dichiarata e immagine, senza sostituire la dichiarazione dell’operatore.
