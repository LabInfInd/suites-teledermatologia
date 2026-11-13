"""Authenticated mobile contract: durable receipt, owner-scoped polling and artifacts."""
from http.cookies import SimpleCookie
from pathlib import Path
from typing import Literal
from uuid import UUID,uuid4
import hashlib,json,re
from fastapi import APIRouter,Depends,File,Form,HTTPException,Request,Response,UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import select,func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from app.config import get_settings
from app.db import get_db,now
from app.imaging import normalize_image,InvalidImage,storage_path
from app.models import MobileSubmission,LoginSession,User
from app.schemas import LoginInput
from app.security import digest
from model_integration.registry import resolve_model,available,public_catalog

router=APIRouter(prefix='/v1')
MAX_BYTES=40*1024*1024


def error(status,code,message):
    raise HTTPException(status,detail={'code':code,'message':message})


def mobile_user(request:Request,db:Session=Depends(get_db)):
    authorization=request.headers.get('authorization','')
    scheme,_,token=authorization.partition(' ')
    session=db.get(LoginSession,digest(token)) if scheme.lower()=='bearer' and token else None
    if not session or session.expires_at<=now():error(401,'unauthorized','Accesso scaduto o non valido.')
    user=db.get(User,session.user_id)
    if not user or not user.active:error(401,'unauthorized','Accesso scaduto o non valido.')
    if user.role!='doctor':error(403,'forbidden','È richiesto un account operatore medico.')
    return user


@router.post('/session')
def mobile_session(payload:LoginInput,request:Request,db:Session=Depends(get_db)):
    # Share the existing password hashing and account/IP login throttling.
    from app.main import login
    temporary=Response()
    data=login(payload,request,temporary,db)
    cookies=SimpleCookie();cookies.load(temporary.headers['set-cookie'])
    token=cookies['telederm_session'].value
    session=db.get(LoginSession,digest(token))
    if data['user']['role']!='doctor':
        db.delete(session);db.commit();error(403,'forbidden','È richiesto un account operatore medico.')
    return {'access_token':token,'token_type':'Bearer','expires_at':session.expires_at.isoformat()+'Z','user':data['user']}


@router.delete('/session',status_code=204)
def mobile_logout(request:Request,user:User=Depends(mobile_user),db:Session=Depends(get_db)):
    token=request.headers['authorization'].partition(' ')[2]
    db.delete(db.get(LoginSession,digest(token)));db.commit()
    return Response(status_code=204)


@router.get('/models')
def models(mode:Literal['clinical','dermoscopic']|None=None,user:User=Depends(mobile_user)):
    return {'schema_version':1,'models':public_catalog(mode)}


def receipt(row):
    return {'submission_id':row.id,'status':'received','mode':row.mode,'case_code':row.case_code,
        'model_id':row.model_id,'received_at':row.created_at.isoformat()+'Z',
        'server_reference':'SRV-'+row.id,'status_url':f'/v1/submissions/{row.id}'}


def owned(db,submission_id,user):
    row=db.get(MobileSubmission,submission_id)
    if row is None or row.owner_id!=user.id:error(404,'not_found','Invio non trovato.')
    return row


def existing_receipt(row,user,fingerprint,response):
    if row.owner_id!=user.id:error(404,'not_found','Invio non trovato.')
    if row.request_sha256!=fingerprint:error(409,'submission_conflict','Identificativo già usato per un invio diverso.')
    response.status_code=200
    return receipt(row)


@router.post('/submissions',status_code=201)
async def submit(request:Request,response:Response,submission_id:str=Form(),mode:Literal['clinical','dermoscopic']=Form(),
    case_code:str=Form(),source:Literal['camera','gallery','unknown']=Form(),image:UploadFile=File(),
    model_id:str|None=Form(default=None),explain:bool=Form(default=True),
    user:User=Depends(mobile_user),db:Session=Depends(get_db)):
    try:
        parsed=UUID(submission_id)
        if parsed.version!=4 or str(parsed)!=submission_id:raise ValueError()
    except ValueError:error(422,'invalid_request','Usare un identificativo UUID v4 valido.')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{2,39}',case_code) or re.fullmatch(r'[A-Za-z]{6}[0-9LMNPQRSTUV]{2}[A-Za-z][0-9LMNPQRSTUV]{2}[A-Za-z][0-9LMNPQRSTUV]{3}[A-Za-z]',case_code,re.I):
        error(422,'invalid_case_code','Usare un codice caso pseudonimo valido, senza dati personali.')
    form=await request.form()
    allowed={'submission_id','mode','case_code','source','image','model_id','explain'}
    if any(k not in allowed or len(form.getlist(k))!=1 for k in form.keys()):
        error(422,'invalid_request','Campi duplicati o non riconosciuti.')
    raw=await image.read(MAX_BYTES+1)
    if not raw or len(raw)>MAX_BYTES:error(413,'payload_too_large','La foto deve essere compresa entro 40 MiB.')
    fingerprint=hashlib.sha256(json.dumps({'mode':mode,'case_code':case_code,'source':source,'model_id':model_id,
        'explain':explain,'image_sha256':hashlib.sha256(raw).hexdigest()},sort_keys=True).encode()).hexdigest()
    previous=db.get(MobileSubmission,submission_id)
    if previous is not None:return existing_receipt(previous,user,fingerprint,response)
    try:spec=resolve_model(mode,model_id)
    except ValueError:error(422,'invalid_model','Modello sconosciuto o incompatibile con la modalità dichiarata.')
    if not available(spec):error(503,'model_unavailable','Il modello richiesto non è installato o è disabilitato.')
    pending=db.scalar(select(func.count()).select_from(MobileSubmission).where(MobileSubmission.state.in_(['queued','running'])))
    if pending>=100:raise HTTPException(429,detail={'code':'rate_limited','message':'Coda piena. Riprova tra poco.'},headers={'Retry-After':'30'})
    media=image.content_type or ''
    if media not in {'image/jpeg','image/png','image/webp','image/heic','image/heif'}:
        error(415,'unsupported_media_type','Formato ammesso: JPEG, PNG, WebP, HEIC o HEIF.')
    from PIL import Image
    from io import BytesIO
    from pillow_heif import register_heif_opener
    register_heif_opener(thumbnails=False)
    try:
        with Image.open(BytesIO(raw)) as check:
            expected={'JPEG':{'image/jpeg'},'PNG':{'image/png'},'WEBP':{'image/webp'},'HEIF':{'image/heic','image/heif'}}
            if media not in expected.get(check.format,set()):error(415,'unsupported_media_type','Il formato dichiarato non corrisponde al file.')
        clean=normalize_image(raw,max_upload_bytes=MAX_BYTES,max_image_pixels=80_000_000,formats={'JPEG','PNG','WEBP','HEIF'})
    except (InvalidImage,OSError,ValueError):error(422,'invalid_image','Immagine non valida: usare una singola foto da 32 px per lato fino a 80 megapixel.')
    key='mobile/'+str(uuid4())+'.png';path=storage_path(key);path.parent.mkdir(parents=True,exist_ok=True)
    try:
        with path.open('xb') as stream:
            stream.write(clean.data);stream.flush()
            import os
            os.fsync(stream.fileno())
        row=MobileSubmission(id=submission_id,owner_id=user.id,mode=mode,model_id=spec['id'],case_code=case_code,
            source=source,explain=explain,request_sha256=fingerprint,storage_key=key,image_sha256=clean.sha256,
            width=clean.width,height=clean.height)
        db.add(row);db.commit();db.refresh(row)
    except IntegrityError:
        db.rollback();path.unlink(missing_ok=True)
        previous=db.get(MobileSubmission,submission_id)
        if previous is None:raise
        return existing_receipt(previous,user,fingerprint,response)
    except BaseException:
        db.rollback();path.unlink(missing_ok=True);raise
    return receipt(row)


@router.get('/submissions/{submission_id}')
def status(submission_id:str,user:User=Depends(mobile_user),db:Session=Depends(get_db)):
    row=owned(db,submission_id,user)
    result=dict(row.result) if row.result else None
    if result:
        base=f'/v1/submissions/{row.id}/artifacts/'
        for name,value in list(result.get('artifacts',{}).items()):
            result['artifacts'][name]=base+name
    return {'submission_id':row.id,'mode':row.mode,'model_id':row.model_id,'state':row.state,
        'received_at':row.created_at.isoformat()+'Z','finished_at':row.finished_at.isoformat()+'Z' if row.finished_at else None,
        'failure_code':row.failure_code,'result':result,'intended_use':'research_only_external_validation_required'}


@router.get('/submissions/{submission_id}/artifacts/{kind}')
def artifact(submission_id:str,kind:str,user:User=Depends(mobile_user),db:Session=Depends(get_db)):
    row=owned(db,submission_id,user)
    artifacts=(row.result or {}).get('artifacts',{})
    if row.state!='completed' or kind not in {'normalized_image','heatmap','heatmap_overlay','segmentation_mask','segmentation_overlay'} or kind not in artifacts:
        error(404,'not_found','Mappa non disponibile.')
    path=storage_path(artifacts[kind])
    if not path.is_file():error(404,'not_found','Mappa non disponibile.')
    return FileResponse(path,media_type='image/png',headers={'Cache-Control':'no-store'})
