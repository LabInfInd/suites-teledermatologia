from datetime import timedelta
import hashlib
import hmac
import secrets

from fastapi import Depends, HTTPException, Request
from sqlalchemy.orm import Session

from app.db import get_db, now
from app.models import AuditEvent, LoginSession, User


COOKIE_NAME = "telederm_session"


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    key = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=16384, r=8, p=1, dklen=32)
    return f"scrypt${salt}${key.hex()}"


def check_password(password: str, encoded: str) -> bool:
    try:
        algorithm, salt, expected = encoded.split("$")
        if algorithm != "scrypt":
            return False
        key = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt), n=16384, r=8, p=1, dklen=32)
        return hmac.compare_digest(key.hex(), expected)
    except (ValueError, TypeError):
        return False


DUMMY_PASSWORD = hash_password(secrets.token_urlsafe(32))


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def audit(db: Session, actor: User | None, action: str, target_id: str | None = None):
    db.add(AuditEvent(actor_id=actor.id if actor else None, action=action, target_id=target_id))


def current_user(request: Request, db: Session = Depends(get_db)) -> User:
    raw_token = request.cookies.get(COOKIE_NAME)
    session = db.get(LoginSession, digest(raw_token)) if raw_token else None
    if not session or session.expires_at <= now():
        raise HTTPException(401, "Accedi per continuare.")
    user = db.get(User, session.user_id)
    if not user or not user.active:
        raise HTTPException(401, "Account non attivo.")
    if request.method not in {"GET", "HEAD", "OPTIONS"}:
        if not hmac.compare_digest(request.headers.get("X-CSRF-Token", ""), session.csrf_token):
            raise HTTPException(403, "Sessione non verificata. Ricarica la pagina.")
    request.state.login_session = session
    return user


def require_role(user: User, *roles: str):
    if user.role not in roles:
        raise HTTPException(403, "Operazione non consentita per questo account.")


def new_session(user: User, hours: int) -> tuple[str, LoginSession]:
    token = secrets.token_urlsafe(32)
    session = LoginSession(
        token_hash=digest(token), user_id=user.id, csrf_token=secrets.token_urlsafe(32),
        expires_at=now() + timedelta(hours=hours),
    )
    return token, session
