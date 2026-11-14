"""Allowlisted, mode-specific models; weights and catalog are never supplied by clients."""
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
import hashlib,json,os,threading
from PIL import Image,ImageOps
from app.config import get_settings
from app.model_service import ModelUnavailable,get_predictor

CLINICAL_CLASSES=['ACK','BCC','MEL','NEV','SCC','SEK']
DERMOSCOPIC_CLASSES=['AK','BCC','BKL','DF','MEL','NV','VASC']


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def catalog():
    path=Path(os.getenv('MODEL_CATALOG_FILE') or Path(__file__).with_name('catalog.json'))
    raw=json.loads(path.read_text(encoding='utf8'))
    if raw['schema_version']!=1:raise ValueError('Unsupported catalog schema')
    specs=raw['models'];ids=[s['id'] for s in specs]
    if len(ids)!=len(set(ids)):raise ValueError('Duplicate model id')
    for s in specs:
        if s['backend'] not in {'timm','ftn'} or s['mode'] not in {'clinical','dermoscopic'}:
            raise ValueError('Unsupported model backend or acquisition mode')
        if (s['backend']=='ftn') != (s['mode']=='dermoscopic'):
            raise ValueError('Acquisition/backend mismatch')
        bundle_path(s)
    return [s for s in specs if s.get('enabled',True)]


def bundle_path(spec):
    root=get_settings().model_dir
    path=(root/spec['bundle']).resolve()
    if not path.is_relative_to(root):raise ValueError('Invalid configured bundle path')
    return path


def available(spec):
    if get_settings().model_adapter!='python':return False
    root=bundle_path(spec)
    if spec['backend']=='ftn':
        return all((root/n).is_file() for n in ['CLASSIFICATION_5_auc.pth','Segm_model_Finale_ImageNet.pth'])
    return (root/'manifest.json').is_file() and (root/'weights.pth').is_file()


def resolve_model(mode,model_id=None):
    candidates=[s for s in catalog() if s['mode']==mode]
    if model_id is None:
        defaults=[s for s in candidates if s.get('default')]
        if len(defaults)!=1:raise ValueError('No unique default model for acquisition mode')
        return defaults[0]
    selected=next((s for s in candidates if s['id']==model_id),None)
    if selected is None:raise ValueError('Unknown model or incompatible acquisition mode')
    return selected


def public_catalog(mode=None):
    return [{'id':s['id'],'name':s['name'],'mode':s['mode'],'default':s.get('default',False),
        'available':available(s),'classes':CLINICAL_CLASSES if s['mode']=='clinical' else DERMOSCOPIC_CLASSES,
        'classification':True,'segmentation':bool(s['segmentation']),'explanation':'gradcam',
        'intended_use':'research_only_external_validation_required'} for s in catalog() if mode is None or s['mode']==mode]


@dataclass
class ModelOutput:
    classification:dict
    mask:Image.Image|None=None
    heatmap:Image.Image|None=None
    explanation:dict|None=None


class TimmClinical:
    def __init__(self,spec):
        import torch,timm
        from torchvision import transforms as T
        root=bundle_path(spec);m=json.loads((root/'manifest.json').read_text(encoding='utf8'))
        allowed={'convnextv2_tiny.fcmae_ft_in22k_in1k','vit_base_patch14_dinov2.lvd142m'}
        if m['model'] not in allowed or m['classes']!=CLINICAL_CLASSES or m['acquisition_mode']!='clinical':
            raise ValueError('Incompatible clinical bundle')
        inp=m['input']
        if inp['size']!=[224,224] or inp['color']!='RGB' or inp['mean']!=[.485,.456,.406] or inp['std']!=[.229,.224,.225] or m.get('tta',False):
            raise ValueError('Unsupported clinical preprocessing')
        weight=(root/m['weights']).resolve()
        if not weight.is_relative_to(root) or digest(weight)!=m['weights_sha256']:raise ValueError('Clinical weights integrity failure')
        temperature=float(m['calibration']['temperature'])
        if not 0<temperature<100:raise ValueError('Invalid calibration temperature')
        threads=int(os.getenv('MODEL_THREADS','4'))
        if not 1<=threads<=16:raise ValueError('MODEL_THREADS out of range')
        torch.set_num_threads(threads)
        kwargs={'img_size':224} if m['model'].startswith('vit_') else {}
        self.model=timm.create_model(m['model'],pretrained=False,num_classes=6,**kwargs).eval()
        self.model.load_state_dict(torch.load(weight,map_location='cpu',weights_only=True),strict=True)
        self.model.requires_grad_(False);self.manifest=m;self.temperature=temperature
        self.transform=T.Compose([T.Resize(224,interpolation=T.InterpolationMode.BICUBIC,antialias=True),T.ToTensor(),T.Normalize(inp['mean'],inp['std'])])
        self.target=self.model.blocks[-1].norm1 if m['model'].startswith('vit_') else self.model.stages[-1]

    def predict(self,image,explain=True):
        import torch
        from .explain import gradcam,restore_cam
        image=ImageOps.exif_transpose(image).convert('RGB');w,h=image.size;side=max(w,h)
        padded=Image.new('RGB',(side,side),(124,116,104));padded.paste(image,((side-w)//2,(side-h)//2))
        x=self.transform(padded).unsqueeze(0)
        with torch.inference_mode():
            logits=self.model(x)
            if not torch.isfinite(logits).all():raise ValueError('Non-finite clinical output')
            scores=(logits/self.temperature).softmax(1)[0].tolist()
        target=max(range(6),key=lambda i:scores[i]);heat=None;metadata=None
        if explain:
            heat,status=restore_cam(gradcam(self.model,self.target,x,target),image.size,padded=True)
            metadata={'method':'gradcam','target_class':CLINICAL_CLASSES[target],'target_score':'pre-temperature class logit',
                'layer':'blocks[-1].norm1; CLS excluded' if self.manifest['model'].startswith('vit_') else 'stages[-1]',
                'status':status,'normalization':'positive attribution / image maximum; uint8 0..255',
                'warning':'Class attribution only; not a lesion mask, diagnosis, or confidence map.'}
        result={'model_name':self.manifest['model'],'model_version':self.manifest['version'],
            'labels':[{'label':c,'score':s} for c,s in zip(CLINICAL_CLASSES,scores)],
            'calibration':{'method':'scalar temperature','temperature':self.temperature},
            'intended_use':'research_only_external_validation_required'}
        return ModelOutput(result,heatmap=heat,explanation=metadata)


class FTNMobile:
    def __init__(self,spec):
        if bundle_path(spec)!=get_settings().model_dir:raise ValueError('FTN uses the legacy weights root')
        self.predictor=get_predictor()

    def predict(self,image,explain=True):
        import numpy as np
        from .explain import gradcam,restore_cam
        p=self.predictor;output=p.predict(image);heat=None;metadata=None
        if explain:
            target=max(range(len(output.classification.labels)),key=lambda i:output.classification.labels[i].score)
            x=p._tensor(np.asarray(image.convert('RGB')),p.classification_transform)
            transforms=[(lambda t:t,lambda a:a),(lambda t:t.flip(2),lambda a:a[::-1,:]),
                (lambda t:t.flip(3),lambda a:a[:,::-1]),(lambda t:t.flip(2).flip(3),lambda a:a[::-1,::-1]),
                (lambda t:t.transpose(2,3),lambda a:a.T)]
            maps=[undo(gradcam(p.classifier,p.classifier.encoder.stem,apply(x),target,probability=True)) for apply,undo in transforms]
            heat,status=restore_cam(np.mean(maps,axis=0),image.size,padded=False)
            metadata={'method':'gradcam','target_class':p.labels[target],'target_score':'mean of five TTA class probabilities',
                'layer':'encoder.stem','tta':'inverse-align five raw attribution maps, mean, positive normalization',
                'status':status,'normalization':'positive attribution / image maximum; uint8 0..255',
                'warning':'Class attribution only; distinct from the independently predicted segmentation mask.'}
        classification=output.classification.model_dump();classification['intended_use']='research_only_external_validation_required'
        classification['calibration']={'method':'none; TTA softmax scores'}
        return ModelOutput(classification,mask=output.mask,heatmap=heat,explanation=metadata)


@lru_cache(maxsize=4)
def get_mobile_predictor(model_id):
    spec=next((s for s in catalog() if s['id']==model_id),None)
    if spec is None or not available(spec):raise ModelUnavailable('Model not installed')
    return FTNMobile(spec) if spec['backend']=='ftn' else TimmClinical(spec)
