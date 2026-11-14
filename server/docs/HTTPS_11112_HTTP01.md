# HTTPS 11112 con Let s Encrypt usando la porta pubblica 80

Profilo preparato localmente il 14 novembre 2026. Non ancora attivato nella VM.
Questa e la strada preferita se l inoltro HTTP sulla porta pubblica 80 e disponibile:
non richiede modifiche DNS, purche il nome sisagen-cardio.poliba.it continui a
risolvere all IP pubblico corretto e l uso del nome sia autorizzato.

## Due inoltri distinti

| Ingresso pubblico | Destinazione VM | Funzione |
|---|---|---|
| TCP 80 | 192.168.50.10:8000 -> gateway:80 | verifica HTTP-01 e rinnovi |
| TCP 11112 | 192.168.50.10:8443 -> gateway:443 | traffico HTTPS dell app |

Il percorso attraverso PC1 e la rete del PC2 deve essere confermato, non inventato.
Il 14 novembre sul PC2 (10.59.1.50 / 192.168.50.1) non risultano regole portproxy
v4tov4. La documentazione precedente riporta invece, sul PC1, un inoltro della 80
verso la VM 192.168.50.10:8000. Il transito fisico attraverso il PC2 non implica
che serva un secondo inoltro TCP sul PC2: occorre leggere le regole effettive.

Sul PC1 raccogliere, prima di modificare regole o firewall:

```powershell
netsh interface portproxy show all
Test-NetConnection 192.168.50.10 -Port 8000
Get-Service iphlpsvc
```

La nuova regola 11112 deve seguire il percorso effettivo gia usato dalla 80,
con destinazione finale VM:8443. Verificare che non esista gia un altro servizio
sulla 11112. Un eventuale inoltro del router/firewall pubblico verso PC1:11112
resta distinto dalla regola portproxy di Windows e deve essere gia presente o
configurato dal responsabile della rete. Il forwarding deve lasciare invariato
il traffico TLS fino al gateway, senza decifrarlo sul PC1 o sul PC2.

## Perche si puo ottenere il certificato senza accesso DNS

Let s Encrypt deve poter recuperare da Internet:

```text
http://sisagen-cardio.poliba.it/.well-known/acme-challenge/<token>
```

Questo usa la porta pubblica 80. Caddy serve automaticamente il token di verifica
e conserva chiave, account ACME e certificati nel volume certificates. Il profilo
disabilita TLS-ALPN-01, percio non richiede disponibilita della porta pubblica 443.
Il certificato e valido per il nome host e puo essere usato dal client su 11112.

Il DNS A osservato e 193.204.50.163. Dalla workstation health nella VM restituisce
200, mentre gli accessi tramite PC1 e IP pubblico vanno in timeout. Non si puo
considerare gia funzionante la validazione HTTP-01: prima occorre verificare la
80 anche da una rete esterna (per esempio dati mobili), tenendo conto di eventuali
limiti di rientro sull IP pubblico e delle regole firewall. Verificare anche che
record AAAA o restrizioni CAA eventualmente presenti non impediscano l emissione.

## Configurazione

Nella .env gia esistente della VM, mantenendo password/database/modelli:

```dotenv
TELEDERM_DOMAIN=sisagen-cardio.poliba.it
TELEDERM_PUBLIC_HTTPS_PORT=11112
HTTPS_BIND_IP=192.168.50.10
HTTP_VM_PORT=8000
HTTPS_VM_PORT=8443
ACME_EMAIL=indirizzo-del-responsabile@example.org
```

Sostituire l email di esempio con il contatto amministrativo reale. Per una prima
prova ACME senza consumare i limiti di produzione si puo aggiungere temporaneamente:

```dotenv
ACME_DIRECTORY=https://acme-staging-v02.api.letsencrypt.org/directory
```

I certificati staging non sono riconosciuti dai telefoni. Dopo aver verificato
l esito, impostare la directory di produzione per ottenere un certificato valido:

```dotenv
ACME_DIRECTORY=https://acme-v02.api.letsencrypt.org/directory
```

Usare solo questo profilo con compose.yaml, senza combinarlo con gli altri profili
HTTPS. Il gateway prende VM:8000 e VM:8443; l API e pubblicata soltanto sul loopback
127.0.0.1:8001. Le origini ammesse includono il numero 11112, i cookie sono Secure
e le eccezioni HTTP sono disattivate. Il sito HTTP conserva solo health e il
redirect esplicito alla porta 11112; la challenge ACME viene intercettata da Caddy.

Dopo verifica degli inoltri e backup previsto dalla procedura di aggiornamento:

```bash
sudo docker compose -f compose.yaml -f compose.https-11112-http01.yaml config --quiet
sudo docker compose -f compose.yaml -f compose.https-11112-http01.yaml up -d --no-build
sudo docker compose -f compose.yaml -f compose.https-11112-http01.yaml logs --tail 60 gateway
```

L avvio implica una richiesta di certificato al server ACME configurato. Questi
comandi non sono stati eseguiti nella VM. Non avviare con l email di esempio o
ripetere tentativi di produzione mentre il percorso HTTP non e funzionante.

## Verifica finale e rinnovi

Da una rete esterna, a certificato di produzione emesso:

```bash
curl https://sisagen-cardio.poliba.it:11112/health
```

Deve rispondere 200 con certificato riconosciuto, senza usare -k. L app usa lo
stesso URL tramite config/server.sisagen.example.json. La 80 va mantenuta instradata
al gateway per i rinnovi automatici, anche dopo la prima emissione. Il volume
certificates deve rimanere persistente; nessuna chiave o credenziale ACME entra in Git.

Il profilo con certificato esterno compose.https-11112.yaml rimane disponibile se
la 80 pubblica non puo essere usata e si deve scegliere certificato esterno o DNS-01.

Fonti ufficiali:
- https://letsencrypt.org/docs/challenge-types/
- https://caddyserver.com/docs/automatic-https#http-challenge
- https://caddyserver.com/docs/caddyfile/directives/tls#issuers

## Esito dei controlli del 14 novembre

PC1 ha confermato la regola 10.50.3.17:80 -> 192.168.50.10:8000 e l indirizzo
Ethernet 3 192.168.50.2/24, Preferred, SkipAsSource=False, con rotta privata on-link.
Il primo test PC1 -> VM:8000 fallisce. Dal PC2 invece /health e /ready della VM
restituiscono 200 e la connessione TCP usa il corretto sorgente 192.168.50.1.
L associazione fra Embedded NIC 2 e lo switch Hyper-V e attiva, la VLAN della
scheda fisica e 0; la VM viene rilevata con il suo MAC, il PC1 risulta Unreachable
senza MAC nella tabella vicini del PC2. Prima dell attivazione HTTPS va quindi
ripristinata/verificata la comunicazione privata fra PC1 e PC2/VM. Questi controlli
non autorizzano a concludere che il cavo sia sicuramente scollegato o che il
firewall sia la causa: manca ancora la conferma dei due lati del collegamento.

Il profilo e stato analizzato con Docker Compose 5.7.1 e Caddy 2.11.9. Verificate
mappature 8000->80 e 8443->443, origine completa di :11112, API solo loopback,
HTTP-01 abilitato e TLS-ALPN-01 disabilitato, directory ACME staging/produzione,
redirect esplicito alla 11112 e rifiuto della configurazione senza email ACME.
Non e stata fatta una richiesta di certificato e nessun servizio della VM e stato
modificato per questi controlli. Le modifiche restano locali finche non viene
ripristinato l accesso GitHub della workstation.
