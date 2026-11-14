"""Read-only web history of a doctor's own quick mobile analyses."""
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.mobile_api import artifact_response, owned, submission_data
from app.models import MobileSubmission, User
from app.security import audit, current_user, require_role

router = APIRouter(prefix="/api/mobile-submissions")


def doctor_user(user: User = Depends(current_user)):
    require_role(user, "doctor")
    return user


def web_error(status, code, message):
    raise HTTPException(status, message)


@router.get("")
def list_submissions(offset: int = Query(default=0, ge=0, le=100000),
                     user: User = Depends(doctor_user), db: Session = Depends(get_db)):
    query = select(MobileSubmission).where(MobileSubmission.owner_id == user.id)
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = db.scalars(query.order_by(MobileSubmission.created_at.desc(), MobileSubmission.id.desc()).offset(offset).limit(50))
    items = []
    for row in rows:
        data = submission_data(row, base="/api/mobile-submissions")
        result = data.pop("result")
        labels = (result or {}).get("classification", {}).get("labels", [])
        data["top_label"] = max(labels, key=lambda item: item["score"]) if labels else None
        items.append(data)
    audit(db, user, "mobile_submissions_viewed")
    db.commit()
    return {"items": items, "total": total, "offset": offset, "limit": 50}


@router.get("/{submission_id}")
def detail(submission_id: str, user: User = Depends(doctor_user), db: Session = Depends(get_db)):
    row = owned(db, submission_id, user, on_error=web_error)
    data = submission_data(row, base="/api/mobile-submissions")
    audit(db, user, "mobile_submission_viewed", row.id)
    db.commit()
    return data


@router.get("/{submission_id}/artifacts/{kind}")
def artifact(submission_id: str, kind: str, user: User = Depends(doctor_user), db: Session = Depends(get_db)):
    row = owned(db, submission_id, user, on_error=web_error)
    response = artifact_response(row, kind, on_error=web_error)
    audit(db, user, "mobile_artifact_viewed", row.id)
    db.commit()
    return response
