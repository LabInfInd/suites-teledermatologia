"""Worker unico: coda persistente nel database, senza servizi esterni di messaggistica."""
import logging
import os
from pathlib import Path
import signal
import threading

from PIL import Image
from sqlalchemy import select, text

from app.config import get_settings
from app.db import db_session, get_engine, now
from app.imaging import save_mask, storage_path
from app.model_service import get_predictor, ModelUnavailable
from app.models import AnalysisRun, AuditEvent, Case, CaseImage, MobileSubmission
from app.mobile_worker import process_mobile_one, colored_overlay, save_artifact
from model_integration.registry import resolve_model, get_mobile_predictor
from app.schemas import ImagePrediction


log = logging.getLogger("telederm.worker")
stopping = threading.Event()


class AcquisitionModeRequired(ValueError):
    pass


def process_one() -> bool:
    with db_session() as db:
        run = db.scalar(select(AnalysisRun).where(AnalysisRun.state == "queued")
                        .order_by(AnalysisRun.created_at).with_for_update(skip_locked=True).limit(1))
        if run is None:
            return False
        run.state = "running"
        run_id, case_id, image_ids = run.id, run.case_id, list(run.image_ids)
        mode, model_id, target = run.mode, run.model_id, run.explanation_target
        db.commit()
    state, result, failure_code = "completed", None, None
    written_keys: list[str] = []
    try:
        if mode not in {"clinical", "dermoscopic"} or not model_id:
            raise AcquisitionModeRequired()
        spec = resolve_model(mode, model_id)
        predictor = get_mobile_predictor(spec["id"])
        with db_session() as db:
            images = [db.get(CaseImage, image_id) for image_id in image_ids]
            if not images or any(image is None or image.case_id != case_id for image in images):
                raise ValueError("Immagini della richiesta non disponibili.")
        outputs = []
        for image_record in images:
            with Image.open(storage_path(image_record.storage_key)) as source:
                photo = source.convert("RGB")
            prediction = predictor.predict(photo, explain=True, target_class=target)
            classification = ImagePrediction.model_validate({k:v for k,v in prediction.classification.items()
                if k in ImagePrediction.model_fields})
            classification.labels.sort(key=lambda item: item.score, reverse=True)
            item = {"image_id": image_record.id, "input_sha256": image_record.sha256,
                    "classification": classification.model_dump(), "explanation": prediction.explanation or {"status":"not_available"}}
            if prediction.mask is not None:
                if not spec["segmentation"]:
                    raise ValueError("Classifier returned an unexpected lesion mask")
                mask_key, overlay_key = save_mask(prediction.mask, photo.size, f"{run_id}-{image_record.id}")
                written_keys.extend([mask_key, overlay_key])
                item.update(mask_key=mask_key, overlay_key=overlay_key)
            if prediction.heatmap is not None:
                heatmap = prediction.heatmap
                if heatmap.mode != "L" or heatmap.size != photo.size:
                    raise ValueError("Grad-CAM alignment mismatch")
                explanation = item["explanation"]
                labels = {label.label for label in classification.labels}
                if explanation.get("method") != "gradcam" or explanation.get("target_class") not in labels or (target and explanation["target_class"] != target):
                    raise ValueError("Grad-CAM target mismatch")
                overlay = colored_overlay(heatmap)
                composite = Image.alpha_composite(photo.convert("RGBA"), overlay).convert("RGB")
                for kind, value in [("heatmap",heatmap), ("heatmap_overlay",overlay), ("heatmap_composite",composite)]:
                    key = f"artifacts/{run_id}-{image_record.id}-{kind}.png"
                    written_keys.append(key)
                    item[kind+"_key"] = save_artifact(value, key)
            outputs.append(item)
        result = {"mode":mode, "model_id":model_id, "images":outputs}
    except AcquisitionModeRequired:
        state, failure_code = "waiting_model", "acquisition_mode_required"
    except ModelUnavailable:
        state, failure_code = "waiting_model", "model_unavailable"
    except Exception as exc:
        state, failure_code = "failed", "inference_error"
        log.error("Analisi fallita (%s); controllare l'adattatore del modello.", type(exc).__name__)
    if state != "completed":
        for key in written_keys:
            storage_path(key).unlink(missing_ok=True)
    with db_session() as db:
        case = db.scalar(select(Case).where(Case.id == case_id).with_for_update())
        run = db.get(AnalysisRun, run_id)
        run.state, run.result, run.failure_code, run.finished_at = state, result, failure_code, now()
        case.state = {"completed":"awaiting_review", "waiting_model":"waiting_model", "failed":"analysis_failed"}[state]
        case.version += 1
        case.updated_at = now()
        db.add(AuditEvent(action=f"analysis_{state}", target_id=run_id))
        db.commit()
    return True


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    get_settings().data_dir.mkdir(parents=True, exist_ok=True)
    engine = get_engine()
    lock_connection = None
    ready_file = Path(os.environ['WORKER_READY_FILE']) if os.getenv('WORKER_READY_FILE') else None
    if ready_file:
        ready_file.unlink(missing_ok=True)
    try:
        # Un solo worker per progetto; lock di sessione mantenuto fino all'uscita.
        if engine.dialect.name == "postgresql":
            lock_connection = engine.connect()
            acquired = lock_connection.execute(text("SELECT pg_try_advisory_lock(734821905)")).scalar()
            lock_connection.commit()
            if not acquired:
                raise RuntimeError("È già attivo un worker per questo database.")
        if get_settings().model_adapter == "python":
            from model_integration.registry import catalog, available, get_mobile_predictor
            installed = [spec for spec in catalog() if available(spec)]
            if not installed:
                raise ModelUnavailable("Nessun modello configurato è installato.")
            for spec in installed:
                get_mobile_predictor(spec['id'])  # Integrity/architecture checks before readiness.
        with db_session() as db:
            for run in db.scalars(select(AnalysisRun).where(AnalysisRun.state == "running")):
                run.state = "queued"
            for submission in db.scalars(select(MobileSubmission).where(MobileSubmission.state == "running")):
                submission.state = "queued"
            db.commit()
        signal.signal(signal.SIGTERM, lambda *_: stopping.set())
        signal.signal(signal.SIGINT, lambda *_: stopping.set())
        log.info("Worker avviato; modello: %s.", get_settings().model_adapter)
        if ready_file:
            ready_file.write_text('ready', encoding='ascii')
        while not stopping.is_set():
            clinical_work = process_one()
            mobile_work = process_mobile_one()
            if not clinical_work and not mobile_work:
                stopping.wait(2)
    finally:
        if ready_file:
            ready_file.unlink(missing_ok=True)
        if lock_connection is not None:
            lock_connection.close()


if __name__ == "__main__":
    main()
