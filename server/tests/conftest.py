from contextlib import ExitStack
from io import BytesIO

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from PIL import Image
import pytest

from app.config import get_settings
from app.db import db_session, get_engine
from app.main import app
from app.model_service import get_predictor
from model_integration.registry import get_mobile_predictor
from app.models import User
from app.security import hash_password


PASSWORD = "password-di-test-12345"


@pytest.fixture
def environment(monkeypatch, tmp_path):
    monkeypatch.setenv("DATABASE_URL", f"sqlite:///{(tmp_path / 'test.sqlite3').as_posix()}")
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("APP_ORIGINS", "http://testserver")
    monkeypatch.setenv("COOKIE_SECURE", "false")
    monkeypatch.setenv("HTTP_DEMO_ORIGINS", "")
    monkeypatch.setenv("MODEL_ADAPTER", "disabled")
    get_settings.cache_clear()
    get_engine.cache_clear()
    get_predictor.cache_clear()
    get_mobile_predictor.cache_clear()
    command.upgrade(Config("alembic.ini"), "head")
    encoded = hash_password(PASSWORD)
    with db_session() as db:
        for username, role in [("paziente.uno","patient"),("paziente.due","patient"),("medico.uno","doctor"),("admin.uno","admin")]:
            db.add(User(username=username, role=role, password_hash=encoded))
        db.commit()
    yield tmp_path
    get_engine().dispose()
    get_engine.cache_clear()
    get_settings.cache_clear()
    get_predictor.cache_clear()
    get_mobile_predictor.cache_clear()


@pytest.fixture
def clients(environment):
    with ExitStack() as stack:
        result = {}
        for name, username in [("patient","paziente.uno"),("other","paziente.due"),("doctor","medico.uno"),("admin","admin.uno")]:
            client = stack.enter_context(TestClient(app))
            client.headers.update({"X-Requested-With":"Telederm","Origin":"http://testserver"})
            response = client.post("/api/login",json={"username":username,"password":PASSWORD})
            assert response.status_code == 200, response.text
            client.headers["X-CSRF-Token"] = response.json()["csrf_token"]
            result[name] = client
        result["anonymous"] = stack.enter_context(TestClient(app))
        yield result


@pytest.fixture
def photo():
    output = BytesIO()
    image = Image.new("RGB", (120,80), (180,150,130))
    exif = Image.Exif()
    exif[0x010E] = "dato-di-prova-da-rimuovere"
    exif[0x0112] = 6
    image.save(output,format="JPEG",exif=exif)
    return output.getvalue()


def new_case(client, photo=None):
    response = client.post("/api/cases",json={"body_site":"Sede di prova","notes":"Nota sintetica","demo_confirmed":True})
    assert response.status_code == 201, response.text
    case = response.json()
    if photo:
        response = client.post(f"/api/cases/{case['id']}/images",data={"expected_version":case["version"]},files={"file":("prova.jpg",photo,"image/jpeg")})
        assert response.status_code == 201, response.text
        case = response.json()
    return case


def submit(client, case):
    response = client.post(f"/api/cases/{case['id']}/submit",json={"expected_version":case["version"]})
    assert response.status_code == 200, response.text
    return response.json()
