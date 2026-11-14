from pathlib import Path
import os

import pytest
from PIL import Image

pytest.importorskip('torch')

from model_integration.adapter import build_predictor


@pytest.fixture(scope='module')
def real_predictor():
    directory = os.getenv('MODEL_TEST_DIR')
    if not directory:
        pytest.skip('Impostare MODEL_TEST_DIR per la prova con i pesi reali.')
    return build_predictor(Path(directory))


def test_real_model_prediction_matches_platform_contract(real_predictor):
    image = Image.new('RGB', (160, 96), (170, 130, 110))
    prediction = real_predictor.predict(image)
    labels = prediction.classification.labels
    assert [item.label for item in labels] == ['AK', 'BCC', 'BKL', 'DF', 'MEL', 'NV', 'VASC']
    assert sum(item.score for item in labels) == pytest.approx(1.0, abs=1e-5)
    assert all(0 <= item.score <= 1 for item in labels)
    assert prediction.classification.model_version == real_predictor.manifest['bundle_version']
    assert prediction.mask.mode == 'L' and prediction.mask.size == image.size
    assert set(prediction.mask.tobytes()).issubset({0, 255})


def test_changed_weights_are_rejected_before_inference(tmp_path):
    (tmp_path / 'CLASSIFICATION_5_auc.pth').write_bytes(b'pesi-alterati')
    with pytest.raises(ValueError, match='Impronta dei pesi'):
        build_predictor(tmp_path)
