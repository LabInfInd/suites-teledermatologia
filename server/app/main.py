from contextlib import asynccontextmanager
from datetime import timedelta
from pathlib import Path
import threading

from fastapi import Depends, FastAPI, File, Form, HTTPException, Query, Request, Response, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import delete, func, or_, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.case_analysis import ARTIFACT_KEYS, explanation_ready, publication_matches, published_maps, run_data
from model_integration.registry import resolve_model, public_catalog, CLINICAL_CLASSES, DERMOSCOPIC_CLASSES
from app.config import get_settings
from app.db import get_db, get_engine, new_id, now
from app.imaging import InvalidImage, normalize_image, storage_path
from app.middleware import SafetyMiddleware
from app.models import AnalysisRun, AuditEvent, Case, CaseImage, LoginAttempt, LoginSession, MedicalReview, User
from app.schemas import AcquisitionInput, ReanalyzeInput, CaseInput, CreateUserInput, LoginInput, PasswordInput, ReviewInput, UserActiveInput, VersionInput
from app.security import (
    audit, check_password, COOKIE_NAME, current_user, digest, DUMMY_PASSWORD,
    hash_password, new_session, require_role,
)


STATIC = Path(__file__).parent / "static"
login_lock = threading.Lock()


@asynccontextmanager
async def lifespan(_app):
    get_settings().data_dir.mkdir(parents=True, exist_ok=True)
    with get_engine().connect() as connection:
        connection.execute(text("SELECT 1"))
    yield


app = FastAPI(title="Teledermatologia", version="0.1.0", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(SafetyMiddleware)


@app.exception_handler(RequestValidationError)
async def invalid_request(_request, exc):
    if _request.url.path.startswith("/v1/"):
        return JSONResponse({"error":{"code":"invalid_request","message":"Controlla i campi della richiesta."}},status_code=422)
    # Non restituire il campo 'input': potrebbe contenere password o note.
    errors = [{"field": ".".join(map(str, error["loc"][1:])), "message": error["msg"]} for error in exc.errors()]
    return JSONResponse({"detail": "Controlla i campi inseriti.", "errors": errors}, status_code=422)


def iso(value):
    return value.isoformat(timespec="seconds") + "Z" if value else None


def user_data(user):
    return {"id": user.id, "username": user.username, "role": user.role, "active": user.active}


def case_code(case):
    return f"TD-{case.created_at:%Y}-{case.id[:8].upper()}"


def get_case(db, case_id, user, lock=False):
    require_role(user, "patient", "doctor")
    query = select(Case).where(Case.id == case_id)
    if lock:
        query = query.with_for_update()
    case = db.scalar(query)
    if case is None or (user.role == "patient" and case.patient_id != user.id) or (user.role == "doctor" and case.state == "draft"):
        raise HTTPException(404, "Caso non trovato.")
    return case


def check_version(case, expected):
    if case.version != expected:
        raise HTTPException(409, "Il caso è stato aggiornato. Ricarica i dettagli prima di continuare.")


def touch(case):
    case.version += 1
    case.updated_at = now()


def latest_run(db, case_id):
    return db.scalar(select(AnalysisRun).where(AnalysisRun.case_id == case_id).order_by(AnalysisRun.created_at.desc()).limit(1))


def review_data(db, review):
    doctor = db.get(User, review.doctor_id)
    return {"id": review.id, "decision": review.decision, "final_label": review.final_label,
            "patient_message": review.patient_message, "share_segmentation": review.share_segmentation,
            "share_explanation": review.share_explanation,
            "analysis_id": review.analysis_id, "doctor": doctor.username, "created_at": iso(review.created_at)}


def case_data(db, case, user, details=False):
    images = list(db.scalars(select(CaseImage).where(CaseImage.case_id == case.id).order_by(CaseImage.created_at)))
    data = {"id": case.id, "code": case_code(case), "mode": case.mode, "body_site": case.body_site, "state": case.state,
            "version": case.version, "image_count": len(images), "created_at": iso(case.created_at),
            "updated_at": iso(case.updated_at)}
    if user.role == "doctor":
        data["patient_code"] = db.get(User, case.patient_id).username
    if details:
        data["notes"] = case.notes
        data["images"] = [{"id": image.id, "width": image.width, "height": image.height,
                           "url": f"/api/cases/{case.id}/images/{image.id}"} for image in images]
        reviews = list(db.scalars(select(MedicalReview).where(MedicalReview.case_id == case.id).order_by(MedicalReview.created_at)))
        data["reviews"] = [review_data(db, review) for review in reviews]
        if user.role == "doctor":
            data["analyses"] = [run_data(run, case.id) for run in db.scalars(
                select(AnalysisRun).where(AnalysisRun.case_id == case.id).order_by(AnalysisRun.created_at.desc()))]
        else:
            data["published_segmentations"], data["published_explanations"] = published_maps(db, case, reviews)
    return data


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok"}


@app.post("/api/login")
def login(payload: LoginInput, request: Request, response: Response, db: Session = Depends(get_db)):
    username = payload.username.strip().lower()
    peer = request.client.host if request.client else "unknown"
    key = digest(username + ":" + peer)
    with login_lock:
        threshold = now() - timedelta(minutes=15)
        db.execute(delete(LoginAttempt).where(LoginAttempt.created_at < threshold))
        attempts = db.scalar(select(func.count()).select_from(LoginAttempt).where(LoginAttempt.key_hash == key))
        if attempts >= 8:
            db.commit()
            raise HTTPException(429, "Troppi tentativi. Riprova fra 15 minuti.", headers={"Retry-After": "900"})
        db.add(LoginAttempt(key_hash=key))
        db.commit()
        user = db.scalar(select(User).where(User.username == username))
        correct = check_password(payload.password, user.password_hash if user else DUMMY_PASSWORD)
        if not user or not correct or not user.active:
            audit(db, None, "login_failed")
            db.commit()
            raise HTTPException(401, "Credenziali non valide.")
        db.execute(delete(LoginAttempt).where(LoginAttempt.key_hash == key))
        db.execute(delete(LoginSession).where(LoginSession.expires_at < now()))
        # Sostituire un'eventuale sessione già presente nel browser.
        previous = request.cookies.get(COOKIE_NAME)
        if previous:
            db.execute(delete(LoginSession).where(LoginSession.token_hash == digest(previous)))
        token, session = new_session(user, get_settings().session_hours)
        db.add(session)
        audit(db, user, "login", user.id)
        db.commit()
    response.set_cookie(COOKIE_NAME, token, httponly=True, secure=get_settings().secure_cookies,
                        samesite="strict", max_age=get_settings().session_hours * 3600, path="/")
    return {"user": user_data(user), "csrf_token": session.csrf_token}


@app.get("/api/me")
def me(request: Request, user: User = Depends(current_user)):
    return {"user": user_data(user), "csrf_token": request.state.login_session.csrf_token}


@app.post("/api/logout", status_code=204)
def logout(request: Request, response: Response, user: User = Depends(current_user), db: Session = Depends(get_db)):
    db.delete(request.state.login_session)
    audit(db, user, "logout", user.id)
    db.commit()
    response.delete_cookie(COOKIE_NAME, path="/", secure=get_settings().secure_cookies, httponly=True, samesite="strict")


@app.post("/api/me/password", status_code=204)
def change_password(payload: PasswordInput, request: Request, user: User = Depends(current_user), db: Session = Depends(get_db)):
    if not check_password(payload.current_password, user.password_hash):
        raise HTTPException(400, "Password attuale non corretta.")
    user.password_hash = hash_password(payload.new_password)
    current = request.state.login_session.token_hash
    db.execute(delete(LoginSession).where(LoginSession.user_id == user.id, LoginSession.token_hash != current))
    audit(db, user, "password_changed", user.id)
    db.commit()


@app.get("/api/status")
def status(user: User = Depends(current_user)):
    settings = get_settings()
    return {"demo": True, "http_demo": bool(settings.http_demo_origins),
            "model": "not_installed" if settings.model_adapter == "disabled" else "configured",
            "max_images": settings.max_images, "max_upload_mb": settings.max_upload_bytes / (1024 * 1024),
            "case_contract_version": 2, "acquisition_modes": ["clinical", "dermoscopic"]}


@app.get("/api/cases")
def list_cases(search: str = Query(default="", max_length=80), offset: int = Query(default=0, ge=0, le=100000),
               user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "patient", "doctor")
    query = select(Case)
    if user.role == "patient":
        query = query.where(Case.patient_id == user.id)
    else:
        query = query.where(Case.state != "draft")
    base = query.subquery()
    counts = dict(db.execute(select(base.c.state, func.count()).group_by(base.c.state)).all())
    if search.strip():
        term = search.strip().removeprefix("TD-")
        query = query.where(or_(Case.id.contains(term, autoescape=True), Case.body_site.contains(search.strip(), autoescape=True)))
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    cases = db.scalars(query.order_by(Case.updated_at.desc()).offset(offset).limit(50))
    return {"items": [case_data(db, case, user) for case in cases], "total": total, "offset": offset, "limit": 50, "counts": counts}


@app.post("/api/cases", status_code=201)
def create_case(payload: CaseInput, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "patient")
    case = Case(patient_id=user.id, body_site=payload.body_site, notes=payload.notes, mode=payload.mode)
    db.add(case)
    db.flush()
    audit(db, user, "case_created", case.id)
    db.commit()
    return case_data(db, case, user, details=True)


@app.get("/api/cases/{case_id}")
def case_details(case_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    case = get_case(db, case_id, user)
    data = case_data(db, case, user, details=True)
    audit(db, user, "case_viewed", case.id)
    db.commit()
    return data


@app.post("/api/cases/{case_id}/images", status_code=201)
def upload_image(case_id: str, expected_version: int = Form(ge=1), file: UploadFile = File(),
                 user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "patient")
    case = get_case(db, case_id, user, lock=True)
    check_version(case, expected_version)
    if case.state not in {"draft", "needs_images"}:
        raise HTTPException(409, "Il caso è già stato inviato. Le immagini non sono modificabili.")
    count = db.scalar(select(func.count()).select_from(CaseImage).where(CaseImage.case_id == case.id))
    if count >= get_settings().max_images:
        raise HTTPException(400, "Sono consentite al massimo quattro immagini per caso.")
    try:
        raw = file.file.read(get_settings().max_upload_bytes + 1)
        image = normalize_image(raw)
    except InvalidImage as exc:
        raise HTTPException(400, str(exc)) from exc
    finally:
        file.file.close()
    image_id = new_id()
    key = f"uploads/{image_id}.png"
    path = storage_path(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(image.data)
    try:
        db.add(CaseImage(id=image_id, case_id=case.id, storage_key=key, sha256=image.sha256, width=image.width, height=image.height))
        touch(case)
        audit(db, user, "image_uploaded", image_id)
        db.commit()
    except Exception:
        path.unlink(missing_ok=True)
        raise
    return case_data(db, case, user, details=True)


@app.delete("/api/cases/{case_id}/images/{image_id}")
def remove_image(case_id: str, image_id: str, payload: VersionInput, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "patient")
    case = get_case(db, case_id, user, lock=True)
    check_version(case, payload.expected_version)
    if case.state != "draft":
        raise HTTPException(409, "Si possono rimuovere immagini soltanto dalle bozze.")
    image = db.get(CaseImage, image_id)
    if not image or image.case_id != case.id:
        raise HTTPException(404, "Immagine non trovata.")
    key = image.storage_key
    db.delete(image)
    touch(case)
    audit(db, user, "image_removed", image_id)
    db.commit()
    storage_path(key).unlink(missing_ok=True)
    return case_data(db, case, user, details=True)


@app.get("/api/cases/{case_id}/images/{image_id}")
def read_image(case_id: str, image_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    case = get_case(db, case_id, user)
    image = db.get(CaseImage, image_id)
    if not image or image.case_id != case.id:
        raise HTTPException(404, "Immagine non trovata.")
    path = storage_path(image.storage_key)
    if not path.is_file():
        raise HTTPException(404, "Immagine non disponibile nell'archivio.")
    audit(db, user, "image_viewed", image_id)
    db.commit()
    return FileResponse(path, media_type="image/png", headers={"Cache-Control": "no-store"})


@app.get("/api/models")
def case_models(mode: str | None = Query(default=None, pattern="^(clinical|dermoscopic)$"),
                user: User = Depends(current_user)):
    require_role(user, "doctor")
    return {"schema_version":1, "models":public_catalog(mode)}


@app.patch("/api/cases/{case_id}/acquisition")
def set_acquisition(case_id: str, payload: AcquisitionInput, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "patient")
    case = get_case(db, case_id, user, lock=True)
    check_version(case, payload.expected_version)
    if case.state not in {"draft", "needs_images"}:
        raise HTTPException(409, "La modalità può essere modificata dal paziente solo prima dell’invio.")
    if case.state == "needs_images" and case.mode and case.mode != payload.mode:
        raise HTTPException(409, "Le foto già inviate mantengono la modalità dichiarata. Per una modalità diversa apri un nuovo caso.")
    case.mode = payload.mode
    touch(case)
    audit(db, user, "acquisition_confirmed", case.id)
    db.commit()
    return case_data(db, case, user, details=True)


def queue_case_analysis(db, case, images, *, mode, model_id=None, target=None):
    if mode not in {"clinical", "dermoscopic"}:
        raise HTTPException(409, "Conferma la modalità clinical o dermoscopic prima dell’analisi.")
    try:
        spec = resolve_model(mode, model_id)
    except ValueError as exc:
        raise HTTPException(400, "Modello sconosciuto o incompatibile con la modalità.") from exc
    if target and target not in (CLINICAL_CLASSES if mode == "clinical" else DERMOSCOPIC_CLASSES):
        raise HTTPException(400, "La classe richiesta per Grad-CAM non è prevista dal modello selezionato.")
    db.add(AnalysisRun(case_id=case.id, image_ids=[image.id for image in images], mode=mode,
                       model_id=spec["id"], explanation_target=target))
    case.mode = mode


@app.post("/api/cases/{case_id}/submit")
def submit_case(case_id: str, payload: VersionInput, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "patient")
    case = get_case(db, case_id, user, lock=True)
    check_version(case, payload.expected_version)
    if case.state not in {"draft", "needs_images"}:
        raise HTTPException(409, "Il caso è già stato inviato.")
    images = list(db.scalars(select(CaseImage).where(CaseImage.case_id == case.id).order_by(CaseImage.created_at)))
    if not images:
        raise HTTPException(400, "Carica almeno una foto prima di inviare il caso.")
    if case.state == "needs_images":
        last_review = db.scalar(select(MedicalReview).where(MedicalReview.case_id == case.id).order_by(MedicalReview.created_at.desc()).limit(1))
        if not any(image.created_at > last_review.created_at for image in images):
            raise HTTPException(400, "Aggiungi almeno una nuova foto richiesta dal medico.")
    queue_case_analysis(db, case, images, mode=case.mode)
    case.state = "queued"
    touch(case)
    audit(db, user, "case_submitted", case.id)
    db.commit()
    return case_data(db, case, user, details=True)


@app.post("/api/cases/{case_id}/reanalyze")
def reanalyze(case_id: str, payload: ReanalyzeInput, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "doctor")
    case = get_case(db, case_id, user, lock=True)
    check_version(case, payload.expected_version)
    if case.state not in {"waiting_model", "analysis_failed", "awaiting_review", "released"}:
        raise HTTPException(409, "Il caso non può essere analizzato in questo stato.")
    images = list(db.scalars(select(CaseImage).where(CaseImage.case_id == case.id).order_by(CaseImage.created_at)))
    previous = latest_run(db, case.id)
    mode = payload.mode or case.mode
    model_id = payload.model_id or (previous.model_id if previous and previous.mode == mode else None)
    queue_case_analysis(db, case, images, mode=mode, model_id=model_id, target=payload.explanation_target)
    case.state = "queued"
    touch(case)
    audit(db, user, "analysis_requested", case.id)
    db.commit()
    return case_data(db, case, user, details=True)


@app.post("/api/cases/{case_id}/reviews", status_code=201)
def review_case(case_id: str, payload: ReviewInput, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "doctor")
    case = get_case(db, case_id, user, lock=True)
    check_version(case, payload.expected_version)
    run = latest_run(db, case.id)
    if payload.decision == "needs_images":
        if case.state not in {"awaiting_review", "waiting_model", "analysis_failed"}:
            raise HTTPException(409, "Non è possibile richiedere altre immagini in questo stato.")
        count = db.scalar(select(func.count()).select_from(CaseImage).where(CaseImage.case_id == case.id))
        if count >= get_settings().max_images:
            raise HTTPException(400, "Il caso contiene già quattro immagini. Per ulteriori foto aprire un nuovo caso di prova.")
        if payload.final_label or payload.share_segmentation or payload.share_explanation:
            raise HTTPException(400, "La richiesta di foto non deve includere classificazioni o mappe.")
        case.state = "needs_images"
    else:
        if case.state != "awaiting_review" or not run or run.state != "completed":
            raise HTTPException(409, "Per validare occorre prima un'analisi completata dal modello.")
        if not case.mode or run.mode != case.mode or not run.model_id:
            raise HTTPException(409, "Conferma la modalità di acquisizione e ripeti l’analisi prima di pubblicare.")
        if not payload.final_label:
            raise HTTPException(400, "Inserisci la classificazione da comunicare al paziente.")
        top_labels = {item["classification"]["labels"][0]["label"] for item in run.result["images"]}
        if payload.decision == "approved" and payload.final_label not in top_labels:
            raise HTTPException(400, "Per una classificazione diversa dalla predizione seleziona «Correggi».")
        items = run.result["images"]
        if payload.share_segmentation and not all(item.get("mask_key") and item.get("overlay_key") for item in items):
            raise HTTPException(400, "La segmentazione non è disponibile per questo modello.")
        if payload.share_explanation and not all(explanation_ready(item, payload.final_label) for item in items):
            raise HTTPException(409, "Genera e verifica Grad-CAM per la classe finale su tutte le immagini prima di condividerla.")
        if payload.share_explanation:
            for item in items:
                if not all(storage_path(item[key]).is_file() for key in ["heatmap_key","heatmap_overlay_key","heatmap_composite_key"]):
                    raise HTTPException(409, "Le mappe Grad-CAM non sono disponibili nell’archivio. Ripeti l’analisi.")
        case.state = "released"
    review = MedicalReview(
        case_id=case.id, doctor_id=user.id, analysis_id=run.id if run and run.state == "completed" else None,
        decision=payload.decision, final_label=payload.final_label, patient_message=payload.patient_message,
        share_segmentation=payload.share_segmentation, share_explanation=payload.share_explanation,
    )
    db.add(review)
    touch(case)
    audit(db, user, "review_published", case.id)
    db.commit()
    return case_data(db, case, user, details=True)


@app.get("/api/cases/{case_id}/analyses/{run_id}/images/{image_id}/{kind}")
def read_artifact(case_id: str, run_id: str, image_id: str, kind: str,
                  user: User = Depends(current_user), db: Session = Depends(get_db)):
    case = get_case(db, case_id, user)
    run = db.get(AnalysisRun, run_id)
    if not run or run.case_id != case.id or run.state != "completed" or kind not in ARTIFACT_KEYS:
        raise HTTPException(404, "Mappa non trovata.")
    result = next((item for item in (run.result or {}).get("images", []) if item["image_id"] == image_id), None)
    key = result.get(ARTIFACT_KEYS[kind]) if result else None
    if not key:
        raise HTTPException(404, "Mappa non disponibile.")
    if user.role == "patient":
        review = db.scalar(select(MedicalReview).where(MedicalReview.case_id == case.id).order_by(MedicalReview.created_at.desc()).limit(1))
        if not publication_matches(case, review, run):
            raise HTTPException(404, "Mappa non disponibile.")
        if kind in {"mask", "overlay"}:
            permitted = review.share_segmentation
        else:
            permitted = review.share_explanation and explanation_ready(result, review.final_label)
        if not permitted:
            raise HTTPException(404, "Mappa non disponibile.")
    path = storage_path(key)
    if not path.is_file():
        raise HTTPException(404, "Mappa non disponibile nell’archivio.")
    audit(db, user, "segmentation_viewed" if kind in {"mask","overlay"} else "explanation_viewed", run.id)
    db.commit()
    return FileResponse(path, media_type="image/png", headers={"Cache-Control":"no-store"},
                        filename=f"gradcam-{image_id}.png" if kind == "heatmap_composite" else None,
                        content_disposition_type="inline")



@app.get("/api/admin/users")
def list_users(user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "admin")
    return {"items": [user_data(item) for item in db.scalars(select(User).order_by(User.created_at).limit(500))]}


@app.post("/api/admin/users", status_code=201)
def create_user(payload: CreateUserInput, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "admin")
    record = User(username=payload.username, password_hash=hash_password(payload.password), role=payload.role)
    db.add(record)
    try:
        db.flush()
    except IntegrityError as exc:
        raise HTTPException(409, "Nome utente già in uso.") from exc
    audit(db, user, "user_created", record.id)
    db.commit()
    return user_data(record)


@app.patch("/api/admin/users/{user_id}")
def activate_user(user_id: str, payload: UserActiveInput, user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "admin")
    target = db.get(User, user_id)
    if target is None:
        raise HTTPException(404, "Account non trovato.")
    if target.id == user.id:
        raise HTTPException(400, "Non puoi disattivare il tuo account.")
    target.active = payload.active
    if not payload.active:
        db.execute(delete(LoginSession).where(LoginSession.user_id == target.id))
    audit(db, user, "user_activated" if payload.active else "user_deactivated", target.id)
    db.commit()
    return user_data(target)


@app.get("/api/admin/audit")
def read_audit(offset: int = Query(default=0, ge=0, le=100000), user: User = Depends(current_user), db: Session = Depends(get_db)):
    require_role(user, "admin")
    events = db.scalars(select(AuditEvent).order_by(AuditEvent.created_at.desc()).offset(offset).limit(100))
    return {"items": [{"id": event.id, "actor_id": event.actor_id, "action": event.action,
                       "target_id": event.target_id, "created_at": iso(event.created_at)} for event in events]}


@app.get("/")
def homepage():
    return FileResponse(STATIC / "index.html", media_type="text/html", headers={"Cache-Control": "no-store"})


app.mount("/static", StaticFiles(directory=STATIC, check_dir=False), name="static")


@app.exception_handler(HTTPException)
async def http_error(request,exc):
    if request.url.path.startswith('/v1/'):
        detail=exc.detail if isinstance(exc.detail,dict) else {'code':{401:'unauthorized',403:'forbidden',429:'rate_limited'}.get(exc.status_code,'invalid_request'),'message':str(exc.detail)}
        return JSONResponse({'error':detail},status_code=exc.status_code,headers=exc.headers)
    return JSONResponse({'detail':exc.detail},status_code=exc.status_code,headers=exc.headers)


from app.mobile_api import router as mobile_router
app.include_router(mobile_router)
from app.web_submissions import router as web_submissions_router
app.include_router(web_submissions_router)
