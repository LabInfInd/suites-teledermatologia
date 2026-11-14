from pathlib import Path
import hashlib
import json
import os

from app.model_service import Prediction, Predictor
from app.schemas import ImagePrediction, LabelScore


def build_predictor(model_dir: Path) -> Predictor:
    return FTNPredictor(model_dir)


class FTNPredictor:
    def __init__(self, model_dir: Path):
        # Impedire il controllo aggiornamenti di Albumentations nel servizio.
        os.environ['NO_ALBUMENTATIONS_UPDATE'] = '1'
        import albumentations as A
        import cv2
        import numpy as np
        import torch
        from model_integration.ftn import FTNClassification, FTNSegmentation

        self.torch, self.np, self.cv2 = torch, np, cv2
        self.manifest = json.loads(Path(__file__).with_name('manifest.json').read_text(encoding='utf-8'))
        if self.manifest['schema_version'] != 1:
            raise ValueError('Versione del manifest non supportata.')
        architecture_hash = hashlib.sha256(Path(__file__).with_name('ftn.py').read_bytes()).hexdigest()
        if architecture_hash != self.manifest['architecture_sha256']:
            raise ValueError('Il codice del modello non corrisponde al manifest.')
        if hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != self.manifest['adapter_sha256']:
            raise ValueError('L’adattatore non corrisponde al manifest.')
        threads = int(os.getenv('MODEL_THREADS', '4'))
        if not 1 <= threads <= 16:
            raise ValueError('MODEL_THREADS deve essere compreso fra 1 e 16.')
        torch.set_num_threads(threads)
        cv2.setNumThreads(1)
        self.classifier = FTNClassification()
        self.segmenter = FTNSegmentation()
        for name, model in [('classification', self.classifier), ('segmentation', self.segmenter)]:
            entry = self.manifest[name]
            path = (model_dir / entry['filename']).resolve()
            if not path.is_relative_to(model_dir.resolve()):
                raise ValueError('Percorso dei pesi non consentito.')
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            if digest.hexdigest() != entry['sha256']:
                raise ValueError('Impronta dei pesi non corrispondente: ' + name)
            state = torch.load(path, map_location='cpu', weights_only=True)
            model.load_state_dict(state, strict=True)
            model.eval()
            model.requires_grad_(False)
        self.labels = self.manifest['classification']['labels']
        self.classification_transform = A.Compose([
            A.Resize(224, 224), A.Normalize(**self.manifest['classification']['normalization'])])
        self.segmentation_transform = A.Compose([
            A.CLAHE(clip_limit=4.0, tile_grid_size=(8, 8), p=1.0),
            A.Resize(512, 512), A.Normalize(**self.manifest['segmentation']['normalization'])])

    def _tensor(self, pixels, transform):
        converted = transform(image=pixels)['image'].transpose(2, 0, 1).copy()
        return self.torch.from_numpy(converted).unsqueeze(0)

    def predict(self, image) -> Prediction:
        from PIL import Image

        torch, np = self.torch, self.np
        pixels = np.array(image.convert('RGB'))
        if min(image.size) < 32:
            raise ValueError('Immagine troppo piccola per il modello.')
        tensor = self._tensor(pixels, self.classification_transform)
        with torch.no_grad():
            probabilities = torch.zeros((1, len(self.labels)))
            for view in [tensor, tensor.flip(2), tensor.flip(3), tensor.flip(2).flip(3), tensor.transpose(2, 3)]:
                logits = self.classifier(view)
                if not torch.isfinite(logits).all():
                    raise ValueError('Il classificatore ha prodotto valori non finiti.')
                probabilities += logits.softmax(1)
            scores = (probabilities / 5).squeeze(0).tolist()
            logits = self.segmenter(self._tensor(pixels, self.segmentation_transform))
            if logits.shape != (1, 2, 512, 512) or not torch.isfinite(logits).all():
                raise ValueError('Uscita del segmentatore non valida.')
            mask = logits.argmax(dim=1).squeeze(0).numpy().astype(np.uint8) * 255
        restored = self.cv2.resize(mask, image.size, interpolation=self.cv2.INTER_NEAREST)
        return Prediction(
            classification=ImagePrediction(
                model_name=self.manifest['model_name'], model_version=self.manifest['bundle_version'],
                labels=[LabelScore(label=label, score=score) for label, score in zip(self.labels, scores, strict=True)]),
            mask=Image.fromarray(restored),
        )
