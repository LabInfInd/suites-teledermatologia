from contextlib import contextmanager
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
import uuid

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session

from app.config import get_settings


def now() -> datetime:
    # UTC senza fuso nel database, serializzato sempre con suffisso Z nell'API.
    return datetime.now(timezone.utc).replace(tzinfo=None)


def new_id() -> str:
    return str(uuid.uuid4())


class Base(DeclarativeBase):
    pass


@lru_cache
def get_engine():
    url = get_settings().database_url
    args = {}
    if url.startswith("sqlite:"):
        args["connect_args"] = {"check_same_thread": False, "timeout": 30}
        if url.startswith("sqlite:///") and ":memory:" not in url:
            Path(url.removeprefix("sqlite:///")).resolve().parent.mkdir(parents=True, exist_ok=True)
    engine = create_engine(url, pool_pre_ping=True, **args)
    if url.startswith("sqlite:"):
        @event.listens_for(engine, "connect")
        def sqlite_setup(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA journal_mode=WAL")
    return engine


@contextmanager
def db_session():
    with Session(get_engine(), expire_on_commit=False) as session:
        try:
            yield session
        except BaseException:
            session.rollback()
            raise


def get_db():
    with db_session() as session:
        yield session
