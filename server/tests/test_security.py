from datetime import timedelta

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.db import db_session, now
from app.main import app
from app.models import LoginSession, User
from tests.conftest import new_case, PASSWORD


def test_csrf_and_cross_origin_requests_rejected(clients):
    patient = clients["patient"]
    payload = {"demo_confirmed":True}
    assert patient.post("/api/cases",json=payload,headers={"X-CSRF-Token":"wrong"}).status_code == 403
    assert patient.post("/api/cases",json=payload,headers={"Origin":"https://untrusted.invalid"}).status_code == 403
    assert patient.post("/api/cases",json=payload,headers={"X-Requested-With":""}).status_code == 403
    assert patient.post("/api/cases",json=payload,headers={"Sec-Fetch-Site":"cross-site"}).status_code == 403
    assert patient.get("/api/cases",headers={"Host":"untrusted.invalid"}).status_code == 400


def test_login_cookie_hash_expiration_and_logout(clients):
    patient = clients["patient"]
    token = patient.cookies.get("telederm_session")
    with db_session() as db:
        sessions = list(db.scalars(select(LoginSession)))
        assert all(session.token_hash != token for session in sessions)
        user = db.scalar(select(User).where(User.username == "paziente.uno"))
        session = db.scalar(select(LoginSession).where(LoginSession.user_id == user.id))
        session.expires_at = now()-timedelta(seconds=1)
        db.commit()
    assert patient.get("/api/me").status_code == 401
    response = patient.post("/api/login",json={"username":"paziente.uno","password":PASSWORD})
    cookie = response.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=strict" in cookie
    patient.headers["X-CSRF-Token"] = response.json()["csrf_token"]
    assert patient.post("/api/logout").status_code == 204
    assert patient.get("/api/me").status_code == 401


def test_deactivation_revokes_sessions(clients):
    patient,admin = clients["patient"],clients["admin"]
    user_id = patient.get("/api/me").json()["user"]["id"]
    assert admin.patch(f"/api/admin/users/{user_id}",json={"active":False}).status_code == 200
    assert patient.get("/api/me").status_code == 401
    assert patient.post("/api/login",json={"username":"paziente.uno","password":PASSWORD}).status_code == 401


def test_rate_limit_persists_and_validation_never_echoes_password(clients):
    anonymous = clients["anonymous"]
    headers = {"X-Requested-With":"Telederm","Origin":"http://testserver"}
    for _ in range(8):
        assert anonymous.post("/api/login",headers=headers,json={"username":"nessuno","password":"sbagliata"}).status_code == 401
    assert anonymous.post("/api/login",headers=headers,json={"username":"nessuno","password":"sbagliata"}).status_code == 429
    secret = "valore-riservato-di-prova"
    response = clients["admin"].post("/api/admin/users",json={"username":"Utente non valido","role":"patient","password":secret})
    assert response.status_code == 422
    assert secret not in response.text


def test_audit_excludes_notes_and_predictions(clients,photo):
    case = new_case(clients["patient"],photo)
    clients["patient"].get(f"/api/cases/{case['id']}")
    response = clients["admin"].get("/api/admin/audit")
    assert response.status_code == 200
    assert "case_created" in response.text and "image_uploaded" in response.text
    assert "Nota sintetica" not in response.text
    assert "Sede di prova" not in response.text


def test_password_change_revokes_other_browser_sessions(clients):
    patient = clients["patient"]
    with TestClient(app) as other:
        other.headers.update({"X-Requested-With":"Telederm","Origin":"http://testserver"})
        assert other.post("/api/login",json={"username":"paziente.uno","password":PASSWORD}).status_code == 200
        response = patient.post("/api/me/password",json={"current_password":PASSWORD,"new_password":"nuova-password-di-test-987"})
        assert response.status_code == 204
        assert other.get("/api/me").status_code == 401
        assert patient.get("/api/me").status_code == 200
