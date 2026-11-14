#!/usr/bin/env bash
# Docker Engine + Compose dal repository ufficiale. Non rimuove pacchetti esistenti.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Eseguire nella VM con: sudo bash scripts/install-docker-ubuntu.sh"
    exit 1
fi
. /etc/os-release
if [ "${ID:-}" != ubuntu ]; then
    echo "Questa procedura e' riservata a Ubuntu. Nessuna modifica eseguita."
    exit 1
fi
case "${VERSION_ID:-}" in
    22.04|24.04|26.04|26.10) ;;
    *) echo "Versione Ubuntu da verificare nelle istruzioni ufficiali Docker: ${VERSION_ID:-sconosciuta}"; exit 1 ;;
esac
architecture=$(dpkg --print-architecture)
case "$architecture" in
    amd64|arm64) ;;
    *) echo "Architettura da verificare prima dell'installazione: $architecture"; exit 1 ;;
esac

conflict=0
for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    package_status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    if [ "$package_status" = installed ]; then
        echo "Pacchetto gia' presente da valutare prima di procedere: $package"
        conflict=1
    fi
done
if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
    echo "Docker Snap gia' presente: verificare prima di procedere."
    conflict=1
fi
if [ "$conflict" -ne 0 ]; then
    echo "Installazione interrotta. Nessun pacchetto e' stato rimosso."
    exit 1
fi

apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
    "${UBUNTU_CODENAME:-$VERSION_CODENAME}" "$architecture" > /etc/apt/sources.list.d/docker.sources
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker --version
docker compose version
docker run --rm hello-world
echo "Docker e Compose installati."
