from dataclasses import dataclass
from functools import lru_cache
from typing import Protocol

from PIL import Image

from app.config import get_settings
from app.schemas import ImagePrediction


class ModelUnavailable(RuntimeError):
    pass


@dataclass
class Prediction:
    classification: ImagePrediction
    # 0 = sfondo, 255 = lesione; dimensioni uguali all'immagine RGB in ingresso.
    mask: Image.Image


class Predictor(Protocol):
    def predict(self, image: Image.Image) -> Prediction: ...


@lru_cache
def get_predictor() -> Predictor:
    settings = get_settings()
    if settings.model_adapter == "disabled":
        raise ModelUnavailable("Il modello non è ancora disponibile.")
    from model_integration.adapter import build_predictor
    return build_predictor(settings.model_dir)
