"""App contract: Bearer only, no cookies/Origin/CSRF; browser protections unchanged."""
from contextlib import ExitStack
from io import BytesIO

from fastapi.testclient import TestClient
from PIL import Image
import numpy as np
import pytest
from sqlalchemy import func, select

from app.db import db_session
from app.main import app
from app.models import LoginSession, User
from app.worker import process_one
from tests.conftest import PASSWORD, new_case, submit
from tests.test_workflow import SyntheticPredictor


@pytest.fixture
def bearers(environment):
    with db_session() as db:
        original = db.scalar(select(User).where(User.username == "medico.uno"))
        db.add(User(username="medico.due", role="doctor", password_hash=original.password_hash))
        db.commit()
    with ExitStack() as stack:
        result = {}
        for name, username in [("patient", "paziente.uno"), ("other", "paziente.due"), ("doctor", "medico.uno"), ("doctor2", "medico.due")]:
            client = stack.enter_context(TestClient(app))
            client.headers["X-Requested-With"] = "Telederm"
            response = client.post("/v1/session", json={"username": username, "password": PASSWORD})
            assert response.status_code == 200, response.text
            data = response.json()
            assert data["token_type"] == "Bearer" and data["expires_at"].endswith("Z")
            assert set(data["user"]) == {"id", "username", "role", "active"}
            assert data["user"]["role"] == ("patient" if name in {"patient", "other"} else "doctor")
            assert not client.cookies and "set-cookie" not in response.headers
            client.headers["Authorization"] = "Bearer " + data["access_token"]
            result[name] = client
        yield result


def test_admin_mobile_login_revokes_new_session_and_preserves_web(clients):
    admin = clients["admin"]
    with db_session() as db:
        before = set(db.scalars(select(LoginSession.token_hash)))
    response = clients["anonymous"].post("/v1/session", json={"username": "admin.uno", "password": PASSWORD}, headers={"X-Requested-With": "Telederm"})
    assert response.status_code == 403
    assert response.json() == {"error": {"code": "forbidden", "message": "Gli account amministratore usano l'interfaccia web."}}
    with db_session() as db:
        assert set(db.scalars(select(LoginSession.token_hash))) == before
    for role in ["patient", "doctor", "admin"]:
        assert clients[role].get("/api/me").json()["user"]["role"] == role


def test_patient_case_lifecycle_and_doctor_validation_with_bearer(bearers, photo, monkeypatch):
    patient, other, doctor = (bearers[name] for name in ["patient", "other", "doctor"])
    assert patient.get("/api/status").json()["max_upload_mb"] == 40
    assert patient.get("/api/cases?offset=0").json()["items"] == []
    case = new_case(patient, photo)
    url = f"/api/cases/{case['id']}"
    assert doctor.get(url).status_code == 404
    assert other.get(url).status_code == 404
    image_url = case["images"][0]["url"]
    response = patient.request("DELETE", image_url, json={"expected_version": case["version"]})
    assert response.status_code == 200, response.text
    assert patient.get(image_url).status_code == 404
    case = response.json()
    uploaded = patient.post(url+"/images", data={"expected_version": case["version"]}, files={"file": ("again.jpg", photo, "image/jpeg")})
    assert uploaded.status_code == 201, uploaded.text
    case = submit(patient, uploaded.json())
    assert doctor.get("/api/cases").json()["items"][0]["id"] == case["id"]
    assert other.get(url).status_code == 404
    assert patient.get(case["images"][0]["url"]).status_code == 200
    monkeypatch.setattr("app.worker.get_predictor", lambda: SyntheticPredictor())
    assert process_one()
    private = doctor.get(url).json()
    # Reanalysis also uses Bearer without CSRF.
    repeated = doctor.post(url+"/reanalyze", json={"expected_version": private["version"]})
    assert repeated.status_code == 200, repeated.text
    assert process_one()
    private = doctor.get(url).json()
    output = private["analyses"][0]["images"][0]
    for kind in ["mask_url", "overlay_url"]:
        assert doctor.get(output[kind]).status_code == 200
        assert patient.get(output[kind]).status_code == 404
    public = patient.get(url).json()
    assert "analyses" not in public and public["reviews"] == [] and public["published_segmentations"] == []
    assert "CLASSE_DI_TEST_A" not in str(public)
    response = doctor.post(url+"/reviews", json={"expected_version": private["version"], "decision": "approved", "final_label": "CLASSE_DI_TEST_A", "patient_message": "Valutazione sintetica di prova.", "share_segmentation": True})
    assert response.status_code == 201, response.text
    public = patient.get(url).json()
    assert public["reviews"][-1]["final_label"] == "CLASSE_DI_TEST_A"
    assert "analyses" not in public and "classification" not in str(public)
    assert len(public["published_segmentations"]) == 1
    for kind in ["mask_url", "overlay_url"]:
        assert patient.get(public["published_segmentations"][0][kind]).status_code == 200
        assert other.get(output[kind]).status_code == 404
    assert not patient.cookies
    assert patient.delete("/v1/session").status_code == 204
    response = patient.get("/api/cases")
    assert response.status_code == 401 and isinstance(response.json()["detail"], str)


def test_patient_cannot_use_direct_inference(bearers, photo):
    patient = bearers["patient"]
    for response in [patient.get("/v1/models"), patient.post("/v1/submissions", files={"image": ("image.jpg", photo, "image/jpeg")}), patient.get("/v1/submissions/missing"), patient.get("/v1/submissions/missing/artifacts/heatmap")]:
        assert response.status_code == 403
        assert response.json() == {"error": {"code": "forbidden", "message": "È richiesto un account medico."}}


@pytest.mark.parametrize("authorization", ["Bearer invalid-token", "Basic invalid", "Bearer", ""])
def test_authorization_never_falls_back_to_valid_cookie(clients, authorization):
    response = clients["patient"].get("/api/cases", headers={"Authorization": authorization})
    assert response.status_code == 401
    assert isinstance(response.json()["detail"], str)


def test_bearer_still_requires_requested_with_and_checks_origins(bearers, clients):
    patient = bearers["patient"]
    assert patient.post("/api/cases", json={"demo_confirmed": True}, headers={"X-Requested-With": ""}).status_code == 403
    assert patient.post("/api/cases", json={"demo_confirmed": True}, headers={"Origin": "https://evil.invalid"}).status_code == 403
    assert patient.post("/api/cases", json={"demo_confirmed": True}, headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403
    browser = clients["patient"]
    del browser.headers["X-CSRF-Token"]
    assert browser.post("/api/cases", json={"demo_confirmed": True}).status_code == 403


@pytest.mark.parametrize("fmt,media", [("WEBP", "image/webp"), ("HEIF", "image/heic"), ("HEIF", "image/heif")])
def test_case_accepts_phone_formats(bearers, fmt, media):
    buffer = BytesIO()
    Image.new("RGB", (128, 96), (180, 140, 120)).save(buffer, format=fmt)
    patient = bearers["patient"]; case = new_case(patient)
    response = patient.post(f"/api/cases/{case['id']}/images", data={"expected_version": case["version"]}, files={"file": ("phone", buffer.getvalue(), media)})
    assert response.status_code == 201, response.text
    image = patient.get(response.json()["images"][0]["url"])
    assert image.headers["content-type"] == "image/png"


def test_case_accepts_actual_photo_between_12_and_40_mib(bearers):
    pixels = np.random.default_rng(42).integers(0, 256, (2000, 2300, 3), dtype=np.uint8)
    buffer = BytesIO(); Image.fromarray(pixels).save(buffer, format="PNG", compress_level=0)
    raw = buffer.getvalue()
    assert 12*1024*1024 < len(raw) < 40*1024*1024
    patient = bearers["patient"]; case = new_case(patient)
    response = patient.post(f"/api/cases/{case['id']}/images", data={"expected_version": case["version"]}, files={"file": ("large.png", raw, "image/png")})
    assert response.status_code == 201, response.text
    assert response.json()["images"][0]["width"] == 2300


def test_case_pixel_limit_unchanged_and_dynamic_errors(bearers):
    from app.imaging import InvalidImage, normalize_image
    buffer = BytesIO(); Image.new("RGB", (5001, 5000)).save(buffer, format="PNG")
    patient = bearers["patient"]; case = new_case(patient)
    response = patient.post(f"/api/cases/{case['id']}/images", data={"expected_version": case["version"]}, files={"file": ("pixels.png", buffer.getvalue(), "image/png")})
    assert response.status_code == 400 and "25 megapixel" in response.json()["detail"]
    with pytest.raises(InvalidImage, match="2 MiB"):
        normalize_image(b"x"*(2*1024*1024+1), max_upload_bytes=2*1024*1024)
    buffer = BytesIO(); Image.new("RGB", (64, 64)).save(buffer, format="GIF")
    with pytest.raises(InvalidImage, match="HEIC/HEIF, JPEG, PNG, WebP"):
        normalize_image(buffer.getvalue())
