#!/usr/bin/env bash
# Backup coerente: sospende API e worker, salva database e archivio immagini.
set -euo pipefail
umask 077
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
backup_dir="backups/$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(3))')"
mkdir -p "$backup_dir"
touch "$backup_dir/INCOMPLETO"

api_running=$(docker compose ps --status running -q api)
worker_running=$(docker compose ps --status running -q worker)
restart_services() {
    if [ -n "$api_running" ]; then docker compose start api; fi
    if [ -n "$worker_running" ]; then docker compose start worker; fi
}
trap restart_services EXIT
docker compose stop api worker
docker compose exec -T db pg_dump -U telederm -d telederm --no-owner --no-acl -Fc > "$backup_dir/database.dump"
docker compose run --rm -T --no-deps --entrypoint tar api -C /data -czf - . > "$backup_dir/immagini.tar.gz"
(cd "$backup_dir" && sha256sum database.dump immagini.tar.gz > SHA256SUMS)
rm -- "$backup_dir/INCOMPLETO"
echo "Backup completato: $backup_dir"
echo "Conservare anche una copia protetta fuori dalla VM e verificare periodicamente il ripristino."
