L istanza del progetto e ora disponibile su `https://sisagen-cardio.poliba.it:11112`.
Per provarla, dalla cartella mobile usare:

```bash
flutter run --dart-define-from-file=config/server.sisagen.example.json
```

Accedere con un account paziente o medico gia creato nella VM (gli account
amministratore usano solo il web). Il certificato pubblico e
verificato normalmente; nessuna eccezione TLS e richiesta. Le prove su telefoni
fisici restano da eseguire e gli esiti rimangono sperimentali.

## Collegamento al server del progetto

Il server e in [../server/README.md](../server/README.md). Configurare soltanto
SUITES_API_BASE_URL a build time; username/password si inseriscono nella schermata
Accedi e il token resta in memoria. Il ruolo arriva dal server:

- Paziente: I miei casi. Crea un caso scegliendo obbligatoriamente la modalita
  di acquisizione (clinical: smartphone normale, anche macro; dermoscopic:
  dermatoscopio o adattatore), con sede e note facoltative e conferma dei dati di
  prova. La creazione e bloccata se `/api/status` non annuncia il contratto 2.
  Aggiunge fino a quattro foto (posizione GPS rimossa dai JPEG), puo correggere la
  modalita in bozza e confermare quella mancante dei casi storici, poi invia. Vede
  solo valutazioni e mappe pubblicate dal medico: la foto composta con Grad-CAM
  (`composite_url`, mai con un secondo overlay), la classe spiegata, l'avvertenza
  del server e il download autenticato tramite il foglio di condivisione; la
  segmentazione condivisa resta separata. Una mappa revocata (404) viene rimossa.
  Nessun punteggio o analisi preliminare.
- Medico: due sezioni. Casi ricevuti: elenco filtrabile, foto, analisi con viste
  separate Foto/Grad-CAM (composite)/Segmentazione (solo FTN), modello e versione;
  nuova analisi con modalita (obbligatoria per i casi storici), modello da
  `/api/models` e classe da spiegare; valutazione (conferma, correzione o richiesta
  di nuove foto) con consensi separati per segmentazione e Grad-CAM. Se la classe
  finale non ha mappe su tutte le foto la condivisione e disabilitata e si offre il
  ricalcolo per quella classe; la bozza resta durante l'aggiornamento automatico.
  Classi fuori catalogo: pubblicazione solo testuale. Analisi rapida: invariata,
  con scelta del modello, analisi sperimentale e storico (anche sul web).

Contratto di riferimento: `server/docs/CASE_GRADCAM.md` e `server/docs/API_MOBILE.md`.
Gli endpoint usati sono quelli del web (`/api/status`, `/api/cases`, `/api/models`, `/api/mobile-submissions`)
con `Authorization: Bearer` e `X-Requested-With: Telederm`, piu `/v1/session`,
`/v1/models` e `/v1/submissions`: richiedono la versione del server che accetta il
Bearer anche su `/api` e il contratto 2 dei casi.

HTTPS richiesto per dispositivi reali; la configurazione pubblica HTTP di prova
esistente non basta per le policy di rete Android/iOS. La build simulata mantiene
il flusso precedente e non finge di restituire analisi cliniche.

# Applicazione Flutter SUITES

Questa cartella contiene il progetto Android e iOS. Per lo stato del lavoro, l’avvio e le verifiche, consultare il [README della repository](../README.md).

Le dipendenze sono definite in `pubspec.yaml` e bloccate in `pubspec.lock`. I percorsi locali degli SDK, i file generati e le credenziali di firma non fanno parte dei sorgenti.
