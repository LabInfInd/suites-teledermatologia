import os
from pathlib import Path
import pytest
from PIL import Image,ImageDraw

@pytest.fixture(scope='module')
def real_registry():
    if not os.getenv('MODEL_TEST_DIR'):pytest.skip('MODEL_TEST_DIR required')
    from app.config import get_settings
    from app.model_service import get_predictor
    from model_integration.registry import get_mobile_predictor
    patch=pytest.MonkeyPatch();patch.setenv('MODEL_ADAPTER','python');patch.setenv('MODEL_DIR',os.environ['MODEL_TEST_DIR']);patch.setenv('MODEL_THREADS','8')
    get_settings.cache_clear();get_mobile_predictor.cache_clear();get_predictor.cache_clear()
    yield get_mobile_predictor
    get_mobile_predictor.cache_clear();get_predictor.cache_clear();patch.undo();get_settings.cache_clear()

@pytest.mark.parametrize('model_id,segmentation',[('clinical-convnextv2-tiny',False),('clinical-dinov2-base',False),('dermoscopic-ftn',True)])
def test_real_registry_classification_and_aligned_explanation(real_registry,model_id,segmentation):
    image=Image.new('RGB',(192,128),(180,140,120));ImageDraw.Draw(image).ellipse((60,30,132,98),fill=(85,47,31))
    result=real_registry(model_id).predict(image)
    assert abs(sum(r['score'] for r in result.classification['labels'])-1)<1e-5
    assert (result.mask is not None)==segmentation
    assert result.heatmap.mode=='L' and result.heatmap.size==image.size
    assert result.explanation['method']=='gradcam'
    assert result.explanation['target_class']==max(result.classification['labels'],key=lambda r:r['score'])['label']
    assert result.explanation['status'] in {'available','no_positive_signal'}
