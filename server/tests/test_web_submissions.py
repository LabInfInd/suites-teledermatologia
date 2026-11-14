from io import BytesIO
from datetime import timedelta
from uuid import uuid4

from PIL import Image
import pytest
from sqlalchemy import select

from app.db import db_session, now
from app.models import AuditEvent, MobileSubmission, User
from app.mobile_worker import process_mobile_one
from model_integration.registry import ModelOutput
from tests.test_mobile_api import data, send
from tests.test_mobile_cases import bearers


@pytest.fixture
def quick(bearers, monkeypatch, photo):
    monkeypatch.setattr("app.mobile_api.available", lambda spec: True)
    class Predictor:
        def predict(self, image, explain=True):
            return ModelOutput({"model_name": "test-only", "model_version": "fixture", "labels": [{"label": "MEL", "score": .9}, {"label": "NEV", "score": .1}]}, mask=Image.new("L", image.size, 255), heatmap=Image.new("L", image.size, 180), explanation={"method": "gradcam", "target_class": "MEL", "status": "available"})
    monkeypatch.setattr("app.mobile_worker.get_mobile_predictor", lambda model_id: Predictor())
    receipt = send(bearers["doctor"], photo).json()
    return receipt


def test_quick_history_owner_only_cookie_and_bearer(quick, bearers, clients):
    identifier = quick["submission_id"]; base = "/api/mobile-submissions"
    for doctor in [bearers["doctor"], clients["doctor"]]:
        response = doctor.get(base)
        assert response.status_code == 200
        page = response.json()
        assert page["total"] == 1 and page["limit"] == 50
        item = page["items"][0]
        assert item["submission_id"] == identifier and item["top_label"] is None
        assert set(["case_code", "mode", "model_id", "state", "received_at", "finished_at", "failure_code"]) <= item.keys()
    assert bearers["doctor2"].get(base).json()["items"] == []
    for suffix in ["/"+identifier, "/"+identifier+"/artifacts/normalized_image", "/missing"]:
        response = bearers["doctor2"].get(base+suffix)
        assert response.status_code == 404 and isinstance(response.json()["detail"], str)
    for client, status in [(bearers["patient"], 403), (clients["admin"], 403), (clients["anonymous"], 401)]:
        for suffix in ["", "/"+identifier, "/"+identifier+"/artifacts/heatmap"]:
            response = client.get(base+suffix)
            assert response.status_code == status and isinstance(response.json()["detail"], str)
    assert clients["doctor"].get(base+"/"+identifier).status_code == 200


def test_quick_results_urls_artifacts_and_audit(quick, bearers):
    doctor = bearers["doctor"]; identifier = quick["submission_id"]
    base = "/api/mobile-submissions/"+identifier
    assert doctor.get(base+"/artifacts/normalized_image").status_code == 404
    assert process_mobile_one()
    mobile_before = doctor.get(quick["status_url"]).json()
    web = doctor.get(base).json()
    assert web["state"] == "completed" and web["case_code"] == "CASO-001"
    assert web["result"]["classification"] == mobile_before["result"]["classification"]
    assert web["result"]["explanation"] == mobile_before["result"]["explanation"]
    assert web["result"]["segmentation"]["available"] is True
    assert web["intended_use"] == mobile_before["intended_use"]
    assert doctor.get("/api/mobile-submissions").json()["items"][0]["top_label"] == {"label": "MEL", "score": .9}
    for kind, url in web["result"]["artifacts"].items():
        assert url == base+"/artifacts/"+kind
        response = doctor.get(url)
        assert response.status_code == 200 and response.headers["content-type"] == "image/png"
        assert response.headers["cache-control"].endswith("no-store")
        with Image.open(BytesIO(response.content)) as image:
            assert image.size == (80, 120)
        assert bearers["doctor2"].get(url).status_code == 404
        assert bearers["patient"].get(url).status_code == 403
    assert doctor.get(base+"/artifacts/invalid").status_code == 404
    assert doctor.get(quick["status_url"]).json() == mobile_before
    with db_session() as db:
        row = db.get(MobileSubmission, identifier)
        assert all(not value.startswith("/") for value in row.result["artifacts"].values())
        actions = set(db.scalars(select(AuditEvent.action)))
        assert {"mobile_submissions_viewed", "mobile_submission_viewed", "mobile_artifact_viewed"} <= actions


@pytest.mark.parametrize("state", ["queued", "running", "failed"])
def test_quick_artifacts_unavailable_until_completed(quick, bearers, state):
    with db_session() as db:
        row = db.get(MobileSubmission, quick["submission_id"])
        row.state = state
        # Even stale/partial persisted results must never be exposed.
        row.result = {"artifacts": {"normalized_image": row.storage_key}}
        db.commit()
    base = "/api/mobile-submissions/"+quick["submission_id"]
    assert bearers["doctor"].get(base).json()["result"] is None
    assert bearers["doctor"].get(base+"/artifacts/normalized_image").status_code == 404


def test_quick_history_pagination_and_order(bearers):
    with db_session() as db:
        owner = db.scalar(select(User).where(User.username == "medico.uno"))
        for index in range(52):
            db.add(MobileSubmission(id=str(uuid4()), owner_id=owner.id, mode="clinical", model_id="clinical-dinov2-base", case_code=f"PAGE-{index:03}", source="camera", request_sha256="0"*64, storage_key=f"unused/{index}.png", image_sha256="0"*64, width=80, height=120, created_at=now()+timedelta(seconds=index)))
        db.commit()
    first = bearers["doctor"].get("/api/mobile-submissions?offset=0").json()
    second = bearers["doctor"].get("/api/mobile-submissions?offset=50").json()
    assert first["total"] == second["total"] == 52
    assert len(first["items"]) == 50 and len(second["items"]) == 2
    assert first["items"][0]["case_code"] == "PAGE-051"
    assert second["items"][-1]["case_code"] == "PAGE-000"
    assert bearers["doctor"].get("/api/mobile-submissions?offset=-1").status_code == 422
