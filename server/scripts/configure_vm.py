"""Crea una configurazione locale di prova senza sovrascrivere file esistenti."""
from pathlib import Path
import os
import secrets


def main():
    root = Path(__file__).resolve().parent.parent
    target = root / ".env"
    content = (
        "# Prova tramite tunnel SSH: nessuna esposizione su Internet\n"
        f"POSTGRES_PASSWORD={secrets.token_hex(32)}\n"
        "HOST_BIND=127.0.0.1\nAPP_PORT=8001\n"
        "APP_ORIGINS=http://localhost:8080,http://127.0.0.1:8080\n"
        "COOKIE_SECURE=false\nSESSION_HOURS=8\nMODEL_ADAPTER=disabled\n"
    )
    try:
        descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        print("Il file .env esiste già: non è stato modificato.")
        return
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        output.write(content)
    print("Configurazione creata. Prossimo passo: sudo docker compose up -d --build")


if __name__ == "__main__":
    main()
