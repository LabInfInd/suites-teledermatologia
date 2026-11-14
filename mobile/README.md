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

- Paziente: I miei casi. Crea un caso (sede e note facoltative, conferma dei dati
  di prova), aggiunge fino a quattro foto da fotocamera o galleria (posizione GPS
  rimossa dai JPEG) e lo invia. Segue lo stato e legge la risposta del medico; se
  il medico chiede altre foto, le aggiunge e reinvia. Non vede mai l'output del
  modello: solo classificazione, messaggio e segmentazione pubblicati dal medico.
- Medico: due sezioni. Casi ricevuti: elenco filtrabile, foto, analisi del modello
  con segmentazione, nuova analisi, valutazione (conferma, correzione o richiesta
  di nuove foto) con conferma prima della pubblicazione. Analisi rapida: il flusso
  di acquisizione con scelta del modello per clinical/dermoscopic; dopo la ricevuta,
  Visualizza analisi sperimentale recupera classificazione e mappe autenticate
  (solo FTN ha segmentazione). Lo storico degli invii rapidi e anche sul web.

Gli endpoint usati sono quelli del web (`/api/cases`, `/api/mobile-submissions`)
con `Authorization: Bearer` e `X-Requested-With: Telederm`, piu `/v1/session`,
`/v1/models` e `/v1/submissions`: richiedono la versione del server che accetta il
Bearer anche su `/api`. Con un server precedente il paziente non puo accedere e i
casi ricevuti del medico non si caricano.

HTTPS richiesto per dispositivi reali; la configurazione pubblica HTTP di prova
esistente non basta per le policy di rete Android/iOS. La build simulata mantiene
il flusso precedente e non finge di restituire analisi cliniche.

# Applicazione Flutter SUITES

Questa cartella contiene il progetto Android e iOS. Per lo stato del lavoro, l’avvio e le verifiche, consultare il [README della repository](../README.md).

Le dipendenze sono definite in `pubspec.yaml` e bloccate in `pubspec.lock`. I percorsi locali degli SDK, i file generati e le credenziali di firma non fanno parte dei sorgenti.
