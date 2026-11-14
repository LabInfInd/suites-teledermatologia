from io import BytesIO
from types import SimpleNamespace

from PIL import Image
import pytest
from sqlalchemy import select

from app.db import db_session
from app.main import app
from app.model_service import Prediction
from app.models import AnalysisRun
from app.schemas import ImagePrediction, LabelScore
from app.worker import process_one
from tests.conftest import new_case, submit


class SyntheticPredictor:
    """Solo test: mai esposto dall'applicazione o attivabile con una richiesta HTTP."""
    def predict(self,image):
        return Prediction(
            classification=ImagePrediction(model_name="fixture-sintetica",model_version="test",labels=[
                LabelScore(label="CLASSE_DI_TEST_A",score=0.8),LabelScore(label="CLASSE_DI_TEST_B",score=0.2)]),
            mask=Image.new("L",image.size,255),
        )


def complete_analysis(monkeypatch,client,photo):
    case = submit(client,new_case(client,photo))
    monkeypatch.setattr("app.worker.get_predictor",lambda: SyntheticPredictor())
    assert process_one()
    return client.get(f"/api/cases/{case['id']}").json()


def test_health_unchanged_and_no_patient_access(clients):
    client = clients["anonymous"]
    assert client.get("/health").json() == {"status":"ok"}
    assert client.get("/api/cases").status_code == 401
    assert client.get("/docs").status_code == 404


def test_patient_isolation_in_list_details_and_images(clients,photo):
    case = new_case(clients["patient"],photo)
    image = case["images"][0]
    assert clients["other"].get("/api/cases").json()["total"] == 0
    assert clients["other"].get(f"/api/cases/{case['id']}").status_code == 404
    assert clients["other"].get(image["url"]).status_code == 404
    assert clients["anonymous"].get(image["url"]).status_code == 401


def test_drafts_hidden_from_doctors_and_clinical_data_hidden_from_admin(clients,photo):
    case = new_case(clients["patient"],photo)
    assert clients["doctor"].get("/api/cases").json()["total"] == 0
    assert clients["doctor"].get(f"/api/cases/{case['id']}").status_code == 404
    assert clients["admin"].get("/api/cases").status_code == 403
    assert clients["patient"].get("/api/admin/users").status_code == 403
    assert clients["doctor"].get("/api/admin/audit").status_code == 403


def test_images_are_oriented_and_metadata_removed(clients,photo):
    case = new_case(clients["patient"],photo)
    response = clients["patient"].get(case["images"][0]["url"])
    assert response.headers["cache-control"].endswith("no-store")
    with Image.open(BytesIO(response.content)) as image:
        assert image.size == (80,120)
        assert image.format == "PNG"
        assert not image.getexif()
        assert not image.info
    assert b"dato-di-prova-da-rimuovere" not in response.content


def test_missing_model_never_generates_predictions(clients,photo):
    patient,doctor = clients["patient"],clients["doctor"]
    case = submit(patient,new_case(patient,photo))
    assert process_one()
    details = doctor.get(f"/api/cases/{case['id']}").json()
    assert details["state"] == "waiting_model"
    assert details["analyses"][0]["state"] == "waiting_model"
    assert details["analyses"][0]["images"] == []
    with db_session() as db:
        run = db.scalar(select(AnalysisRun).where(AnalysisRun.case_id == case["id"]))
        assert run.result is None
    attempt = doctor.post(f"/api/cases/{case['id']}/reviews",json={"expected_version":details["version"],"decision":"approved","final_label":"Inventata","patient_message":"Un messaggio di prova."})
    assert attempt.status_code == 409
    assert not process_one()


@pytest.mark.parametrize("share",[False,True])
def test_predictions_private_until_doctor_validation(clients,photo,monkeypatch,share):
    patient,doctor = clients["patient"],clients["doctor"]
    case = complete_analysis(monkeypatch,patient,photo)
    url = f"/api/cases/{case['id']}"
    private = doctor.get(url).json()
    output = private["analyses"][0]["images"][0]
    assert "CLASSE_DI_TEST_A" in str(private)
    patient_before = patient.get(url)
    assert "CLASSE_DI_TEST_A" not in patient_before.text
    assert "analyses" not in patient_before.json()
    assert patient.get(output["overlay_url"]).status_code == 404
    assert clients["other"].get(output["mask_url"]).status_code == 404
    assert doctor.get(output["overlay_url"]).status_code == 200
    response = doctor.post(url+"/reviews",json={"expected_version":case["version"],"decision":"approved","final_label":"CLASSE_DI_TEST_A","patient_message":"Messaggio di test approvato dal medico.","share_segmentation":share})
    assert response.status_code == 201,response.text
    public = patient.get(url).json()
    assert public["state"] == "released"
    assert public["reviews"][-1]["final_label"] == "CLASSE_DI_TEST_A"
    assert "analyses" not in public
    assert "classification" not in str(public)
    assert patient.get(output["mask_url"]).status_code == (200 if share else 404)
    assert len(public["published_segmentations"]) == (1 if share else 0)


def test_only_doctor_can_publish_and_wrong_approval_requires_correction(clients,photo,monkeypatch):
    patient,doctor = clients["patient"],clients["doctor"]
    case = complete_analysis(monkeypatch,patient,photo)
    payload = {"expected_version":case["version"],"decision":"approved","final_label":"CLASSE_CORRETTA","patient_message":"Messaggio di test del medico."}
    url = f"/api/cases/{case['id']}/reviews"
    assert patient.post(url,json=payload).status_code == 403
    assert clients["admin"].post(url,json=payload).status_code == 403
    assert doctor.post(url,json=payload).status_code == 400
    payload["decision"] = "corrected"
    assert doctor.post(url,json=payload).status_code == 201
    assert patient.get(f"/api/cases/{case['id']}").json()["reviews"][-1]["final_label"] == "CLASSE_CORRETTA"


def test_need_new_photos_requires_actual_new_upload(clients,photo):
    patient,doctor = clients["patient"],clients["doctor"]
    case = submit(patient,new_case(patient,photo)); process_one()
    url = f"/api/cases/{case['id']}"
    current = doctor.get(url).json()
    response = doctor.post(url+"/reviews",json={"expected_version":current["version"],"decision":"needs_images","patient_message":"Richiesta sintetica di una nuova foto."})
    assert response.status_code == 201,response.text
    current = response.json()
    assert patient.post(url+"/submit",json={"expected_version":current["version"]}).status_code == 400
    upload = patient.post(url+"/images",data={"expected_version":current["version"]},files={"file":("seconda.jpg",photo,"image/jpeg")})
    assert upload.status_code == 201
    assert submit(patient,upload.json())["state"] == "queued"


def test_stale_versions_and_duplicate_submissions_rejected(clients,photo):
    patient = clients["patient"]; case = new_case(patient,photo)
    url = f"/api/cases/{case['id']}/submit"
    assert patient.post(url,json={"expected_version":case["version"]-1}).status_code == 409
    assert patient.post(url,json={"expected_version":case["version"]}).status_code == 200
    assert patient.post(url,json={"expected_version":case["version"]}).status_code == 409
    current = patient.get(f"/api/cases/{case['id']}").json()
    assert patient.post(f"/api/cases/{case['id']}/images",data={"expected_version":current["version"]},files={"file":("foto.jpg",photo,"image/jpeg")}).status_code == 409


def test_corrupt_and_oversized_uploads_rejected(clients):
    patient = clients["patient"]; case = new_case(patient)
    url = f"/api/cases/{case['id']}/images"
    response = patient.post(url,data={"expected_version":case["version"]},files={"file":("falso.jpg",b"<script>invalid</script>","image/jpeg")})
    assert response.status_code == 400
    response = patient.post(url,headers={"Content-Length":str(13*1024*1024)},content=b"x")
    assert response.status_code == 413
    assert patient.get(f"/api/cases/{case['id']}").json()["image_count"] == 0


def test_invalid_model_output_fails_closed(clients,photo,monkeypatch):
    class BadModel:
        def predict(self,image):
            return Prediction(classification=ImagePrediction(model_name="test",model_version="1",labels=[LabelScore(label="TEST",score=1)]),mask=Image.new("L",(1,1)))
    patient = clients["patient"]; case = submit(patient,new_case(patient,photo))
    monkeypatch.setattr("app.worker.get_predictor",lambda: BadModel())
    assert process_one()
    private = clients["doctor"].get(f"/api/cases/{case['id']}").json()
    assert private["state"] == "analysis_failed"
    assert private["analyses"][0]["images"] == []
    assert "TEST" not in patient.get(f"/api/cases/{case['id']}").text
