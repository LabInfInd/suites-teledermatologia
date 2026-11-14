L istanza del progetto e ora disponibile su `https://sisagen-cardio.poliba.it:11112`.
Per provarla, dalla cartella mobile usare:

```bash
flutter run --dart-define-from-file=config/server.sisagen.example.json
```

Accedere con un account medico gia creato nella VM. Il certificato pubblico e
verificato normalmente; nessuna eccezione TLS e richiesta. Le prove su telefoni
fisici restano da eseguire e gli esiti rimangono sperimentali.

## Collegamento al server del progetto

Il server e in [../server/README.md](../server/README.md). Configurare soltanto
SUITES_API_BASE_URL a build time; username/password si inseriscono nella schermata
Accesso operatore medico e il token resta in memoria. Dopo il login si puo scegliere
un modello disponibile per clinical/dermoscopic. Dopo la ricevuta, Visualizza analisi
sperimentale recupera classificazione e mappe autenticate. Solo FTN ha segmentazione.
HTTPS richiesto per dispositivi reali; la configurazione pubblica HTTP di prova
esistente non basta per le policy di rete Android/iOS. La build simulata mantiene
il flusso precedente e non finge di restituire analisi cliniche.

# Applicazione Flutter SUITES

Questa cartella contiene il progetto Android e iOS. Per lo stato del lavoro, l’avvio e le verifiche, consultare il [README della repository](../README.md).

Le dipendenze sono definite in `pubspec.yaml` e bloccate in `pubspec.lock`. I percorsi locali degli SDK, i file generati e le credenziali di firma non fanno parte dei sorgenti.
