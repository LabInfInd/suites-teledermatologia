import argparse
from getpass import getpass
from pathlib import Path
import secrets

from alembic import command
from alembic.config import Config
from PIL import Image, ImageDraw
from sqlalchemy import delete, select

from app.config import get_settings
from app.db import db_session
from app.models import LoginSession, User
from app.schemas import valid_password, valid_username
from app.security import audit, hash_password


def migrate():
    command.upgrade(Config("alembic.ini"), "head")


def create_user(username, password, role):
    username, password = valid_username(username), valid_password(password)
    with db_session() as db:
        if db.scalar(select(User).where(User.username == username)):
            raise ValueError("Il nome utente esiste già.")
        user = User(username=username, password_hash=hash_password(password), role=role)
        db.add(user)
        db.flush()
        audit(db, None, "user_created_cli", user.id)
        db.commit()


def init_demo(credentials_file: Path):
    settings = get_settings()
    if not settings.database_url.startswith("sqlite:") or settings.secure_cookies:
        raise ValueError("Gli account demo sono consentiti solo nel database SQLite locale con cookie di prova.")
    migrate()
    records = [("demo.paziente", "patient"), ("demo.medico", "doctor"), ("demo.admin", "admin")]
    lines = ["ACCESSI DELLA DEMO LOCALE — non usare con dati reali", "Indirizzo: http://localhost:8080", ""]
    with db_session() as db:
        existing = {user.username for user in db.scalars(select(User))}
    if any(username in existing for username, _ in records):
        if not credentials_file.is_file():
            raise ValueError("Account demo già presenti; il file accessi manca. Usare reset-password per recuperare l'accesso.")
        print(f"Demo già inizializzata. Accessi in: {credentials_file.resolve()}")
        return
    for username, role in records:
        password = secrets.token_urlsafe(18)
        create_user(username, password, role)
        lines.extend([f"Ruolo: {role}", f"Utente: {username}", f"Password: {password}", ""])
    credentials_file.parent.mkdir(parents=True, exist_ok=True)
    with credentials_file.open("x", encoding="utf-8") as output:
        output.write("\n".join(lines))
    picture = Image.new("RGB", (800, 600), (224, 207, 181))
    draw = ImageDraw.Draw(picture)
    for x in range(0, 800, 40):
        draw.line((x, 0, x, 600), fill=(211, 192, 164), width=1)
    for y in range(0, 600, 40):
        draw.line((0, y, 800, y), fill=(211, 192, 164), width=1)
    draw.ellipse((255, 150, 545, 440), fill=(137, 103, 84), outline=(109, 80, 68), width=4)
    draw.ellipse((315, 210, 475, 385), fill=(120, 86, 70))
    draw.rectangle((0, 0, 800, 54), fill=(20, 55, 61))
    draw.text((24, 20), "IMMAGINE SINTETICA - SOLO PROVA TECNICA", fill="white")
    picture.save(credentials_file.parent / "foto-sintetica.png")
    print(f"Demo pronta. Accessi in: {credentials_file.resolve()}")


def main():
    parser = argparse.ArgumentParser(description="Gestione della piattaforma di teledermatologia")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("migrate")
    create = commands.add_parser("create-user")
    create.add_argument("--username", required=True)
    create.add_argument("--role", choices=["admin", "doctor", "patient"], required=True)
    reset = commands.add_parser("reset-password")
    reset.add_argument("--username", required=True)
    demo = commands.add_parser("init-demo")
    demo.add_argument("--credentials-file", type=Path, default=Path(".local/accessi-demo.txt"))
    args = parser.parse_args()
    try:
        if args.command == "migrate":
            migrate()
        elif args.command == "init-demo":
            init_demo(args.credentials_file)
        else:
            password = getpass("Nuova password (almeno 12 caratteri): ")
            if password != getpass("Ripeti la password: "):
                raise ValueError("Le password non coincidono.")
            valid_password(password)
            if args.command == "create-user":
                create_user(args.username, password, args.role)
            else:
                with db_session() as db:
                    user = db.scalar(select(User).where(User.username == valid_username(args.username)))
                    if user is None:
                        raise ValueError("Account non trovato.")
                    user.password_hash = hash_password(password)
                    db.execute(delete(LoginSession).where(LoginSession.user_id == user.id))
                    audit(db, None, "password_reset_cli", user.id)
                    db.commit()
            print("Operazione completata.")
    except ValueError as exc:
        parser.exit(1, f"{exc}\n")


if __name__ == "__main__":
    main()
