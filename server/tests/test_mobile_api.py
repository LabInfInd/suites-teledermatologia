from io import BytesIO
from uuid import uuid4
import json
from pathlib import Path
import pytest
from PIL import Image
from sqlalchemy import select
from app.db import db_session
from app.models import MobileSubmission,User
from app.mobile_worker import process_mobile_one
from app.imaging import storage_path
from model_integration.registry import ModelOutput
from tests.conftest import PASSWORD


@pytest.fixture
def operator(clients,monkeypatch):
    client=clients['anonymous']
    response=client.post('/v1/session',json={'username':'medico.uno','password':PASSWORD})
    assert response.status_code==200,response.text
    client.headers['Authorization']='Bearer '+response.json()['access_token']
    monkeypatch.setattr('app.mobile_api.available',lambda s:True)
    return client


def data(**kw):
    return dict(submission_id=str(uuid4()),mode='clinical',case_code='CASO-001',source='camera',**kw)


def send(operator,photo,fields=None,media='image/jpeg'):
    return operator.post('/v1/submissions',data=fields or data(),files={'image':('image.jpg',photo,media)})


def test_bearer_required_and_patient_login_forbidden(clients,photo):
    c=clients['anonymous']
    assert c.get('/v1/models').status_code==401
    assert c.post('/v1/session',json={'username':'paziente.uno','password':PASSWORD}).status_code==403
    assert send(c,photo).status_code==401
    wrong=c.post('/v1/session',json={'username':'medico.uno','password':'incorrect'})
    assert wrong.status_code==401 and 'error' in wrong.json()


def test_receipt_durable_idempotency_and_conflict(operator,photo):
    fields=data();first=send(operator,photo,fields)
    assert first.status_code==201,first.text
    receipt=first.json();assert receipt['status']=='received' and receipt['mode']=='clinical'
    assert receipt['model_id']=='clinical-convnextv2-tiny'
    with db_session() as db:
        row=db.get(MobileSubmission,fields['submission_id']);assert row.state=='queued'
        assert storage_path(row.storage_key).is_file()
        with Image.open(storage_path(row.storage_key)) as im:
            assert im.size==(80,120) and not im.getexif() and not im.info
    repeat=send(operator,photo,fields);assert repeat.status_code==200 and repeat.json()==receipt
    fields['model_id']='clinical-dinov2-base'
    assert send(operator,photo,fields).status_code==409
    with db_session() as db:assert len(list(db.scalars(select(MobileSubmission))))==1


@pytest.mark.parametrize('mode,model',[('clinical','dermoscopic-ftn'),('dermoscopic','clinical-dinov2-base'),('clinical','../../weights.pth')])
def test_mode_model_mismatch_rejected(operator,photo,mode,model):
    fields=data(model_id=model);fields['mode']=mode
    response=send(operator,photo,fields)
    assert response.status_code==422 and response.json()['error']['code']=='invalid_model'


def test_explicit_clinical_model_and_no_fake_segmentation(operator,photo,monkeypatch):
    class Classifier:
        def predict(self,image,explain=True):
            assert image.size==(80,120)
            return ModelOutput({'model_name':'test-only','model_version':'fixture','labels':[{'label':'MEL','score':.9},{'label':'NEV','score':.1}]},
                heatmap=Image.new('L',image.size,180),explanation={'method':'gradcam','target_class':'MEL','status':'available'})
    monkeypatch.setattr('app.mobile_worker.get_mobile_predictor',lambda _:Classifier())
    fields=data(model_id='clinical-dinov2-base');receipt=send(operator,photo,fields).json()
    assert operator.get(receipt['status_url']).json()['state']=='queued'
    assert process_mobile_one()
    response=operator.get(receipt['status_url']);result=response.json()['result']
    assert response.json()['state']=='completed'
    assert result['segmentation']['available'] is False
    assert 'segmentation_mask' not in result['artifacts']
    assert result['explanation']['target_class']=='MEL'
    for name,url in result['artifacts'].items():
        image=operator.get(url);assert image.status_code==200
        assert image.headers['cache-control'].endswith('no-store')
        with Image.open(BytesIO(image.content)) as im:assert im.size==(80,120)
    assert not process_mobile_one()


def test_owner_isolation_including_artifacts(operator,clients,photo,monkeypatch):
    receipt=send(operator,photo).json()
    with db_session() as db:
        first=db.get(MobileSubmission,receipt['submission_id']);owner=db.get(User,first.owner_id)
        other=User(username='medico.due',role='doctor',password_hash=owner.password_hash);db.add(other);db.commit()
    another=clients['doctor'];r=another.post('/v1/session',json={'username':'medico.due','password':PASSWORD})
    another.headers['Authorization']='Bearer '+r.json()['access_token']
    assert another.get(receipt['status_url']).status_code==404
    assert another.get(receipt['status_url']+'/artifacts/heatmap').status_code==404
    fields={'submission_id':receipt['submission_id'],'mode':'clinical','case_code':'CASO-001','source':'camera'}
    assert send(another,photo,fields).status_code==404


def test_failed_inference_is_explicit_without_partial_results(operator,photo,monkeypatch):
    class Broken:
        def predict(self,*args,**kwargs):raise RuntimeError('internal image content must not be exposed')
    monkeypatch.setattr('app.mobile_worker.get_mobile_predictor',lambda _:Broken())
    r=send(operator,photo).json();assert process_mobile_one()
    status=operator.get(r['status_url']).json()
    assert status['state']=='failed' and status['failure_code']=='inference_error' and status['result'] is None


@pytest.mark.parametrize('case',['RSSMRA80A01H501U','bad code','x','../secret'])
def test_invalid_or_personal_case_codes_rejected(operator,photo,case):
    fields=data();fields['case_code']=case
    assert send(operator,photo,fields).status_code==422


def test_webp_and_heif_supported_and_fake_media_type_rejected(operator):
    for fmt,media in [('WEBP','image/webp'),('HEIF','image/heic')]:
        from pillow_heif import register_heif_opener
        register_heif_opener(thumbnails=False)
        buffer=BytesIO();Image.new('RGB',(128,96),(180,140,120)).save(buffer,format=fmt)
        assert send(operator,buffer.getvalue(),media=media).status_code==201
        assert send(operator,buffer.getvalue(),media='image/jpeg').status_code==415


def test_request_size_limit_precedes_multipart_parser(operator):
    r=operator.post('/v1/submissions',content=b'x',headers={'Content-Length':str(41*1024*1024)})
    assert r.status_code==413 and r.json()['error']['code']=='payload_too_large'


def test_sign_out_revokes_token(operator):
    assert operator.delete('/v1/session').status_code==204
    assert operator.get('/v1/models').status_code==401
