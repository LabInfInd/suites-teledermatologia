# SUITES — app mobile

Progetto Flutter per Android e iPhone dedicato all’acquisizione di immagini dermatologiche e all’invio a un server di classificazione.

## Struttura

- `mobile/`: applicazione Flutter, con i progetti nativi Android e iOS.
- `docs/workstation-prompt.txt`: contesto e indicazioni per addestrare il modello per foto cliniche sulla workstation.

La cartella `suites-repo/`, già presente sul computer, è una repository indipendente ed è esclusa dal versionamento di questo progetto.

## Stato del progetto

La base Flutter è inizializzata con le dipendenze `image_picker`, `http` e `http_parser`. L’interfaccia è ancora quella del template Flutter. Scatto, anteprima, scelta della modalità, invio autenticato e gestione della risposta del server sono da implementare.

L’app non include modelli di classificazione e non produce risultati diagnostici.

## Avvio

Ambiente verificato sul computer di sviluppo: Flutter 3.47.5, Dart 3.13.4 e Xcode 27.2. Il progetto richiede Dart 3.13.4 o successivo compatibile con il vincolo nel pubspec.

```sh
cd mobile
flutter pub get
flutter devices
flutter run
```

Per iOS sono necessari Xcode e, per installare su un iPhone fisico, la configurazione della firma. Per Android sono necessari Android SDK e un dispositivo o emulatore. La configurazione completa delle due piattaforme va verificata con `flutter doctor`.

## Verifiche

```sh
cd mobile
flutter analyze
flutter test
```

Il test incluso verifica il funzionamento del template iniziale; non verifica ancora il futuro flusso di acquisizione e invio.

## Flusso previsto

1. Selezione esplicita della modalità `clinical` oppure `dermoscopic`.
2. Acquisizione o selezione della foto e anteprima.
3. Invio al server con il tipo di acquisizione e i metadati concordati.
4. Conferma della ricezione e gestione dell’esito restituito dal server.

Le foto cliniche da smartphone, anche macro, useranno un nuovo modello addestrato su dati clinici come PAD-UFES-20. Le immagini dermatoscopiche useranno il modello già disponibile addestrato su ISIC 2019. Uno smartphone con adattatore dermatoscopico appartiene al secondo percorso. Endpoint, autenticazione e formato della risposta sono ancora da concordare.
