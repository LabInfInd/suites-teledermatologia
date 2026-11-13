"""Mobile inference shares the single persistent worker, separate from medical cases."""
import logging
import numpy as np
from PIL import Image
from sqlalchemy import select
from app.db import db_session,now
from app.models import MobileSubmission
from app.imaging import storage_path
from app.model_service import ModelUnavailable
from model_integration.registry import get_mobile_predictor

log=logging.getLogger('telederm.mobile_worker')


def save_artifact(image,key):
    path=storage_path(key);path.parent.mkdir(parents=True,exist_ok=True)
    try:
        Image.frombytes(image.mode,image.size,image.tobytes()).save(path,format='PNG')
    except BaseException:
        path.unlink(missing_ok=True);raise
    return key


def colored_overlay(heatmap):
    x=np.asarray(heatmap,dtype=np.float32)/255
    # Continuous blue -> yellow -> red; transparent where attribution is zero.
    red=np.clip(1.5-abs(4*x-3),0,1);green=np.clip(1.5-abs(4*x-2),0,1);blue=np.clip(1.5-abs(4*x-1),0,1)
    rgba=np.stack([red,green,blue,.6*x],axis=-1)
    return Image.fromarray(np.rint(rgba*255).astype(np.uint8))


def process_mobile_one():
    with db_session() as db:
        row=db.scalar(select(MobileSubmission).where(MobileSubmission.state=='queued').order_by(MobileSubmission.created_at).with_for_update(skip_locked=True).limit(1))
        if row is None:return False
        row.state='running';db.commit()
        identifier,model_id,key,explain=row.id,row.model_id,row.storage_key,row.explain
    written=[];result=None;state='completed';failure=None
    try:
        predictor=get_mobile_predictor(model_id)
        with Image.open(storage_path(key)) as im:
            image=im.convert('RGB');output=predictor.predict(image,explain=explain)
        scores=output.classification['labels']
        if not scores or any(not np.isfinite(v['score']) or not 0<=v['score']<=1 for v in scores):raise ValueError('Invalid probabilities')
        output.classification['labels']=sorted(scores,key=lambda v:v['score'],reverse=True)
        artifacts={'normalized_image':key}
        def save(name,value):
            if value.size!=image.size:raise ValueError('Artifact alignment mismatch')
            name_key=f'mobile-artifacts/{identifier}-{name}.png'
            written.append(name_key);artifacts[name]=save_artifact(value,name_key)
        if output.mask is not None:
            if output.mask.mode!='L':raise ValueError('Invalid segmentation mask')
            save('segmentation_mask',output.mask)
            overlay=Image.new('RGBA',image.size,(18,157,139,0));overlay.putalpha(output.mask.point(lambda v:round(v*.45)))
            save('segmentation_overlay',overlay)
        if output.heatmap is not None:
            if output.heatmap.mode!='L':raise ValueError('Invalid explanation map')
            save('heatmap',output.heatmap);save('heatmap_overlay',colored_overlay(output.heatmap))
        result={'classification':output.classification,'segmentation':{'available':output.mask is not None,
            'meaning':'independent lesion segmentation; not a classification explanation' if output.mask is not None else 'this model is a classifier only'},
            'explanation':output.explanation or {'status':'not_requested'},'artifacts':artifacts,
            'image':{'width':image.width,'height':image.height,'orientation':'EXIF applied before metadata removal'},
            'warning':'Research output for an authenticated medical operator; not a validated clinical diagnosis.'}
    except ModelUnavailable:
        state='failed';failure='model_unavailable'
    except Exception as exc:
        state='failed';failure='inference_error';log.error('Mobile inference failed (%s).',type(exc).__name__)
    if state!='completed':
        for k in written:storage_path(k).unlink(missing_ok=True)
    with db_session() as db:
        row=db.get(MobileSubmission,identifier);row.state=state;row.failure_code=failure;row.result=result;row.finished_at=now();db.commit()
    return True
