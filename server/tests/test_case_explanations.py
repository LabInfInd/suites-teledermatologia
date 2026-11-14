from io import BytesIO
import json
from uuid import uuid4

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from PIL import Image
import pytest
from sqlalchemy import select, text, func

from app.db import db_session
from app.main import app
from app.models import AnalysisRun, Case, MedicalReview, User
from app.worker import process_one
from model_integration.registry import ModelOutput
from tests.conftest import new_case, submit, PASSWORD
from tests.test_mobile_cases import bearers


@pytest.fixture
def predictor(monkeypatch):
    calls = []
    class Classifier:
        def __init__(self, model_id):
            self.model_id = model_id
        def predict(self, image, explain=True, target_class=None):
            calls.append((self.model_id, target_class))
            clinical = self.model_id.startswith("clinical-")
            target = target_class or "MEL"
            heat = Image.new("L", image.size, 0)
            heat.paste(220, (0, 0, image.width//2, image.height) if target == "MEL" else (image.width//2, 0, image.width, image.height))
            return ModelOutput({"model_name":"synthetic-only", "model_version":"fixture", "labels":[{"label":"MEL","score":.8},{"label":"NEV" if clinical else "NV","score":.2}]},
                mask=None if clinical else Image.new("L",image.size,255), heatmap=heat,
                explanation={"method":"gradcam", "target_class":target, "status":"available"})
    monkeypatch.setattr("app.worker.get_mobile_predictor", lambda model_id: Classifier(model_id))
    return calls


def completed(patient, doctor, photo, mode="clinical"):
    case = submit(patient, new_case(patient, photo, mode=mode))
    assert process_one()
    detail = doctor.get(f"/api/cases/{case['id']}")
    assert detail.status_code == 200
    assert detail.json()["state"] == "awaiting_review", detail.text
    return detail.json()


def review_payload(case, **updates):
    return {"expected_version":case["version"], "decision":"approved", "final_label":"MEL",
            "patient_message":"Valutazione sintetica approvata dal medico.", **updates}


def test_mode_required_catalog_and_draft_confirmation(bearers):
    patient, doctor = bearers["patient"], bearers["doctor"]
    assert patient.post("/api/cases", json={"demo_confirmed":True}).status_code == 422
    assert patient.post("/api/cases", json={"demo_confirmed":True,"mode":"macro"}).status_code == 422
    case = new_case(patient, mode="clinical")
    assert case["mode"] == "clinical"
    url = f"/api/cases/{case['id']}/acquisition"
    response = patient.patch(url,json={"expected_version":case["version"],"mode":"dermoscopic"})
    assert response.status_code == 200 and response.json()["mode"] == "dermoscopic"
    assert patient.patch(url,json={"expected_version":case["version"],"mode":"clinical"}).status_code == 409
    assert patient.get("/api/models").status_code == 403
    catalog = doctor.get("/api/models?mode=clinical")
    assert catalog.status_code == 200 and len(catalog.json()["models"]) == 2
    assert all(model["mode"] == "clinical" for model in catalog.json()["models"])
    assert doctor.get("/api/models?mode=macro").status_code == 422


def test_clinical_routes_to_classifier_and_never_invents_segmentation(bearers, predictor, photo):
    patient, doctor = bearers["patient"], bearers["doctor"]
    case = completed(patient, doctor, photo)
    run = case["analyses"][0]; output = run["images"][0]
    assert case["mode"] == run["mode"] == "clinical"
    assert run["model_id"] == "clinical-convnextv2-tiny"
    assert predictor == [("clinical-convnextv2-tiny",None)]
    assert output["mask_url"] is None and output["overlay_url"] is None
    assert output["segmentation_available"] is False
    assert output["explanation"]["target_class"] == "MEL"
    for kind in ["heatmap_url","heatmap_overlay_url","heatmap_composite_url"]:
        response = doctor.get(output[kind]); assert response.status_code == 200
        assert response.headers["content-type"] == "image/png" and "no-store" in response.headers["cache-control"]
        with Image.open(BytesIO(response.content)) as image:
            assert image.size == (80,120)
            assert image.mode == {"heatmap_url":"L","heatmap_overlay_url":"RGBA","heatmap_composite_url":"RGB"}[kind]
        assert patient.get(output[kind]).status_code == 404
        assert bearers["other"].get(output[kind]).status_code == 404
    assert doctor.get(output["heatmap_url"].removesuffix("heatmap")+"mask").status_code == 404
    public = patient.get(f"/api/cases/{case['id']}").json()
    assert public["published_explanations"] == [] and "analyses" not in public and "classification" not in str(public)
    assert doctor.post(f"/api/cases/{case['id']}/reviews",json=review_payload(case,share_segmentation=True)).status_code == 400


@pytest.mark.parametrize("share",[False,True])
def test_patient_receives_only_explicitly_published_gradcam(bearers,predictor,photo,share):
    patient, doctor = bearers["patient"], bearers["doctor"]
    case = completed(patient,doctor,photo);url=f"/api/cases/{case['id']}"
    output = case["analyses"][0]["images"][0]
    response = doctor.post(url+"/reviews",json=review_payload(case,share_explanation=share))
    assert response.status_code == 201,response.text
    public = patient.get(url).json()
    assert "analyses" not in public and "classification" not in str(public) and "score" not in str(public)
    assert public["reviews"][-1]["share_explanation"] == share
    assert len(public["published_explanations"]) == int(share)
    assert public["published_segmentations"] == []
    for kind in ["heatmap_url","heatmap_overlay_url","heatmap_composite_url"]:
        assert patient.get(output[kind]).status_code == (200 if share else 404)
        assert bearers["other"].get(output[kind]).status_code == 404
    if share:
        explanation = public["published_explanations"][0]
        assert explanation["target_class"] == public["reviews"][-1]["final_label"] == "MEL"
        assert explanation["method"] == "gradcam" and explanation["warning"]
        assert patient.get(explanation["composite_url"]).headers["content-type"] == "image/png"


def test_corrected_class_requires_reviewed_maps_for_that_exact_class(bearers,predictor,photo):
    patient,doctor = bearers["patient"],bearers["doctor"]
    case = completed(patient,doctor,photo);url=f"/api/cases/{case['id']}"
    old_map = doctor.get(case["analyses"][0]["images"][0]["heatmap_url"]).content
    payload = review_payload(case,decision="corrected",final_label="NEV",share_explanation=True)
    assert doctor.post(url+"/reviews",json=payload).status_code == 409
    assert patient.get(url).json()["reviews"] == []
    response = doctor.post(url+"/reanalyze",json={"expected_version":case["version"],"explanation_target":"NEV","model_id":"clinical-dinov2-base"})
    assert response.status_code == 200,response.text
    assert process_one()
    case = doctor.get(url).json();run=case["analyses"][0]
    assert run["model_id"] == "clinical-dinov2-base" and run["explanation_target"] == "NEV"
    assert run["images"][0]["classification"]["labels"][0]["label"] == "MEL"
    assert run["images"][0]["explanation"]["target_class"] == "NEV"
    assert doctor.get(run["images"][0]["heatmap_url"]).content != old_map
    response = doctor.post(url+"/reviews",json=review_payload(case,decision="corrected",final_label="NEV",share_explanation=True))
    assert response.status_code == 201,response.text
    public=patient.get(url).json()
    assert public["published_explanations"][0]["target_class"] == "NEV"
    assert "MEL" not in str(public) and "classification" not in str(public)


@pytest.mark.parametrize("share_segmentation,share_explanation",[(False,False),(True,False),(False,True),(True,True)])
def test_ftn_maps_have_independent_publication_flags(bearers,predictor,photo,share_segmentation,share_explanation):
    patient,doctor=bearers["patient"],bearers["doctor"]
    case=completed(patient,doctor,photo,mode="dermoscopic");url=f"/api/cases/{case['id']}"
    assert predictor[0][0] == "dermoscopic-ftn"
    output=case["analyses"][0]["images"][0]
    response=doctor.post(url+"/reviews",json=review_payload(case,share_segmentation=share_segmentation,share_explanation=share_explanation))
    assert response.status_code == 201,response.text
    public=patient.get(url).json()
    assert len(public["published_segmentations"])==int(share_segmentation)
    assert len(public["published_explanations"])==int(share_explanation)
    assert patient.get(output["mask_url"]).status_code==(200 if share_segmentation else 404)
    assert patient.get(output["heatmap_url"]).status_code==(200 if share_explanation else 404)


def test_mismatched_models_classes_and_share_requests_are_rejected(bearers,predictor,photo):
    patient,doctor=bearers["patient"],bearers["doctor"]
    case=completed(patient,doctor,photo);url=f"/api/cases/{case['id']}"
    for fields in [{"model_id":"dermoscopic-ftn"},{"explanation_target":"BKL"},{"model_id":"../../weights"}]:
        assert doctor.post(url+"/reanalyze",json={"expected_version":case["version"],**fields}).status_code==400
    assert patient.post(url+"/reanalyze",json={"expected_version":case["version"]}).status_code==403
    assert patient.patch(url+"/acquisition",json={"expected_version":case["version"],"mode":"dermoscopic"}).status_code==409
    assert doctor.post(url+"/reviews",json=review_payload(case,decision="needs_images",final_label=None,share_explanation=True)).status_code==400


def test_new_review_revokes_previous_map_publication(bearers,predictor,photo):
    patient,doctor=bearers["patient"],bearers["doctor"]
    case=completed(patient,doctor,photo);url=f"/api/cases/{case['id']}"
    old_url=case["analyses"][0]["images"][0]["heatmap_composite_url"]
    response=doctor.post(url+"/reviews",json=review_payload(case,share_explanation=True));assert response.status_code==201
    assert patient.get(old_url).status_code==200
    assert doctor.post(url+"/reanalyze",json={"expected_version":response.json()["version"]}).status_code==200
    assert process_one();case=doctor.get(url).json()
    assert doctor.post(url+"/reviews",json=review_payload(case,share_explanation=False)).status_code==201
    assert patient.get(url).json()["published_explanations"]==[]
    assert patient.get(old_url).status_code==404


def test_legacy_migration_preserves_records_and_never_assumes_acquisition(environment,monkeypatch):
    config=Config("alembic.ini")
    command.downgrade(config,"20261113_mobile")
    case_id,run_id,review_id=str(uuid4()),str(uuid4()),str(uuid4())
    with db_session() as db:
        patient=db.scalar(select(User).where(User.role=="patient"));doctor=db.scalar(select(User).where(User.role=="doctor"))
        db.execute(text("INSERT INTO cases (id,patient_id,body_site,notes,state,version,created_at,updated_at) VALUES (:id,:user,'','legacy','queued',1,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)"),{"id":case_id,"user":patient.id})
        db.execute(text("INSERT INTO analysis_runs (id,case_id,state,image_ids,created_at) VALUES (:id,:case,'queued','[]',CURRENT_TIMESTAMP)"),{"id":run_id,"case":case_id})
        db.execute(text("INSERT INTO medical_reviews (id,case_id,doctor_id,decision,patient_message,share_segmentation,created_at) VALUES (:id,:case,:doctor,'needs_images','legacy message',0,CURRENT_TIMESTAMP)"),{"id":review_id,"case":case_id,"doctor":doctor.id})
        db.commit()
    command.upgrade(config,"head")
    with db_session() as db:
        assert db.get(Case,case_id).mode is None
        assert db.get(AnalysisRun,run_id).model_id is None
        assert db.get(MedicalReview,review_id).share_explanation is False
    monkeypatch.setattr("app.worker.get_mobile_predictor",lambda _:pytest.fail("Legacy input must not reach FTN"))
    assert process_one()
    with db_session() as db:
        run=db.get(AnalysisRun,run_id)
        assert run.state=="waiting_model" and run.failure_code=="acquisition_mode_required" and run.result is None
    with TestClient(app) as doctor:
        doctor.headers["X-Requested-With"]="Telederm"
        login=doctor.post("/v1/session",json={"username":"medico.uno","password":PASSWORD}).json()
        doctor.headers["Authorization"]="Bearer "+login["access_token"]
        detail=doctor.get(f"/api/cases/{case_id}").json()
        assert doctor.post(f"/api/cases/{case_id}/reanalyze",json={"expected_version":detail["version"]}).status_code==409


def test_doctor_must_confirm_mode_for_legacy_case_before_new_analysis(bearers,predictor,photo):
    patient,doctor=bearers["patient"],bearers["doctor"]
    case=completed(patient,doctor,photo);url=f"/api/cases/{case['id']}"
    with db_session() as db:
        db.get(Case,case["id"]).mode=None
        run=db.get(AnalysisRun,case["analyses"][0]["id"]);run.mode=None;run.model_id=None;db.commit()
    assert doctor.post(url+"/reviews",json=review_payload(case)).status_code==409
    assert doctor.post(url+"/reanalyze",json={"expected_version":case["version"]}).status_code==409
    response=doctor.post(url+"/reanalyze",json={"expected_version":case["version"],"mode":"clinical"})
    assert response.status_code==200,response.text
    assert process_one()
    assert predictor[-1][0]=="clinical-convnextv2-tiny"
    assert doctor.get(url).json()["mode"]=="clinical"


def test_unavailable_clinical_model_never_falls_back_to_dermoscopy(bearers,photo,monkeypatch):
    from app.model_service import ModelUnavailable
    calls=[]
    def unavailable(model_id):
        calls.append(model_id);raise ModelUnavailable()
    monkeypatch.setattr("app.worker.get_mobile_predictor",unavailable)
    patient,doctor=bearers["patient"],bearers["doctor"]
    case=submit(patient,new_case(patient,photo,mode="clinical"));assert process_one()
    detail=doctor.get(f"/api/cases/{case['id']}").json()
    assert calls==["clinical-convnextv2-tiny"]
    assert detail["state"]=="waiting_model" and detail["analyses"][0]["images"]==[]


def test_sharing_requires_matching_target_for_every_photo(bearers,photo,monkeypatch):
    class Mixed:
        def __init__(self):self.count=0
        def predict(self,image,explain=True,target_class=None):
            self.count+=1;top="MEL" if self.count%2 else "NEV";other="NEV" if top=="MEL" else "MEL"
            return ModelOutput({"model_name":"test","model_version":"fixture","labels":[{"label":top,"score":.8},{"label":other,"score":.2}]},heatmap=Image.new("L",image.size,180),explanation={"method":"gradcam","status":"available","target_class":target_class or top})
    model=Mixed();monkeypatch.setattr("app.worker.get_mobile_predictor",lambda _:model)
    patient,doctor=bearers["patient"],bearers["doctor"]
    case=new_case(patient,photo,mode="clinical");url=f"/api/cases/{case['id']}"
    response=patient.post(url+"/images",data={"expected_version":case["version"]},files={"file":("second.jpg",photo,"image/jpeg")});assert response.status_code==201
    submit(patient,response.json());assert process_one();case=doctor.get(url).json()
    assert doctor.post(url+"/reviews",json=review_payload(case,share_explanation=True)).status_code==409
    assert doctor.post(url+"/reanalyze",json={"expected_version":case["version"],"explanation_target":"MEL"}).status_code==200
    assert process_one();case=doctor.get(url).json()
    response=doctor.post(url+"/reviews",json=review_payload(case,share_explanation=True));assert response.status_code==201,response.text
    assert len(patient.get(url).json()["published_explanations"])==2
