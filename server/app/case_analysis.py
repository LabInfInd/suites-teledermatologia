"""Case analysis serialization and explicit, review-scoped map publication."""
from app.models import AnalysisRun

ARTIFACT_KEYS = {"mask":"mask_key", "overlay":"overlay_key", "heatmap":"heatmap_key",
                 "heatmap_overlay":"heatmap_overlay_key", "heatmap_composite":"heatmap_composite_key"}
EXPLANATION_WARNING = "Mappa sperimentale del modello per la classe indicata, condivisa dal medico. Non è il contorno della lesione né una misura del rischio."


def iso(value):
    return value.isoformat(timespec="seconds")+"Z" if value else None


def run_data(run, case_id):
    images = []
    for item in (run.result or {}).get("images", []) if run.state == "completed" else []:
        base = f"/api/cases/{case_id}/analyses/{run.id}/images/{item['image_id']}"
        images.append({"image_id":item["image_id"], "input_sha256":item["input_sha256"],
            "classification":item["classification"], "segmentation_available":bool(item.get("mask_key")),
            "mask_url":base+"/mask" if item.get("mask_key") else None,
            "overlay_url":base+"/overlay" if item.get("overlay_key") else None,
            "explanation":item.get("explanation", {"status":"not_available"}),
            "heatmap_url":base+"/heatmap" if item.get("heatmap_key") else None,
            "heatmap_overlay_url":base+"/heatmap_overlay" if item.get("heatmap_overlay_key") else None,
            "heatmap_composite_url":base+"/heatmap_composite" if item.get("heatmap_composite_key") else None})
    return {"id":run.id, "state":run.state, "mode":run.mode, "model_id":run.model_id,
            "explanation_target":run.explanation_target, "failure_code":run.failure_code,
            "created_at":iso(run.created_at), "finished_at":iso(run.finished_at), "images":images}


def explanation_ready(item, label):
    metadata = item.get("explanation", {})
    return bool(metadata.get("method") == "gradcam" and metadata.get("target_class") == label
        and metadata.get("status") in {"available", "no_positive_signal"}
        and all(item.get(key) for key in ["heatmap_key", "heatmap_overlay_key", "heatmap_composite_key"]))


def publication_matches(case, review, run):
    return bool(review and review.decision in {"approved", "corrected"} and run
        and review.analysis_id == run.id and run.case_id == case.id and run.state == "completed"
        and (case.mode is None or case.mode == run.mode))


def published_maps(db, case, reviews):
    segmentations, explanations = [], []
    review = reviews[-1] if reviews else None
    run = db.get(AnalysisRun, review.analysis_id) if review and review.analysis_id else None
    if not publication_matches(case, review, run):
        return segmentations, explanations
    for item in (run.result or {}).get("images", []):
        base = f"/api/cases/{case.id}/analyses/{run.id}/images/{item['image_id']}"
        if review.share_segmentation and item.get("mask_key") and item.get("overlay_key"):
            segmentations.append({"image_id":item["image_id"], "mask_url":base+"/mask", "overlay_url":base+"/overlay"})
        if review.share_explanation and explanation_ready(item, review.final_label):
            explanations.append({"image_id":item["image_id"], "analysis_id":run.id, "review_id":review.id,
                "method":"gradcam", "target_class":review.final_label, "status":item["explanation"]["status"],
                "heatmap_url":base+"/heatmap", "overlay_url":base+"/heatmap_overlay",
                "composite_url":base+"/heatmap_composite", "warning":EXPLANATION_WARNING})
    return segmentations, explanations
