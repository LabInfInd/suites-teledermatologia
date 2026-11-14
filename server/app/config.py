from dataclasses import dataclass
from functools import lru_cache
import os
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Settings:
    database_url: str
    data_dir: Path
    origins: tuple[str, ...]
    secure_cookies: bool
    session_hours: int
    model_adapter: str
    model_dir: Path
    http_demo_origins: tuple[str, ...] = ()
    max_images: int = 4
    max_upload_bytes: int = 12 * 1024 * 1024
    max_image_pixels: int = 25_000_000

    @property
    def hosts(self) -> list[str]:
        return list({urlsplit(origin).hostname for origin in self.origins})


@lru_cache
def get_settings() -> Settings:
    origins = tuple(origin.strip().rstrip("/") for origin in os.getenv(
        "APP_ORIGINS", "http://localhost:8001,http://127.0.0.1:8001,http://localhost:8080,http://127.0.0.1:8080"
    ).split(",") if origin.strip())
    http_demo_origins = tuple(origin.strip().rstrip("/") for origin in os.getenv(
        "HTTP_DEMO_ORIGINS", ""
    ).split(",") if origin.strip())
    secure = os.getenv("COOKIE_SECURE", "true").lower() == "true"
    if not origins:
        raise RuntimeError("Configurare APP_ORIGINS.")
    for origin in (*origins, *http_demo_origins):
        parsed = urlsplit(origin)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.path or parsed.query or parsed.fragment or parsed.username is not None:
            raise RuntimeError("APP_ORIGINS deve contenere origini complete, senza percorsi.")
    if any(urlsplit(origin).scheme != "http" for origin in http_demo_origins):
        raise RuntimeError("HTTP_DEMO_ORIGINS ammette soltanto indirizzi HTTP di prova.")
    if not set(http_demo_origins).issubset(origins):
        raise RuntimeError("Gli indirizzi HTTP di prova devono essere dichiarati anche in APP_ORIGINS.")
    if http_demo_origins and secure:
        raise RuntimeError("La prova HTTP richiede COOKIE_SECURE=false. Per HTTPS svuotare HTTP_DEMO_ORIGINS.")
    for origin in origins:
        parsed = urlsplit(origin)
        local = parsed.hostname in {"localhost", "127.0.0.1", "::1", "testserver"}
        explicit_http_demo = origin in http_demo_origins
        if parsed.scheme != "https" and not local and not explicit_http_demo:
            raise RuntimeError("HTTP di rete richiede un indirizzo esplicito in HTTP_DEMO_ORIGINS. Per dati reali configurare HTTPS.")
        if not secure and not local and not explicit_http_demo:
            raise RuntimeError("I cookie senza HTTPS sono consentiti soltanto per prove locali o HTTP esplicitamente autorizzato.")
    adapter = os.getenv("MODEL_ADAPTER", "disabled")
    if adapter not in {"disabled", "python"}:
        raise RuntimeError("MODEL_ADAPTER non riconosciuto.")
    hours = int(os.getenv("SESSION_HOURS", "8"))
    if not 1 <= hours <= 24:
        raise RuntimeError("SESSION_HOURS deve essere fra 1 e 24.")
    return Settings(
        database_url=os.getenv("DATABASE_URL", "sqlite:///.local/telederm.sqlite3"),
        data_dir=Path(os.getenv("DATA_DIR", ".local/data")).resolve(),
        origins=origins,
        secure_cookies=secure,
        session_hours=hours,
        model_adapter=adapter,
        model_dir=Path(os.getenv("MODEL_DIR", "model_integration/weights")).resolve(),
        http_demo_origins=http_demo_origins,
    )
