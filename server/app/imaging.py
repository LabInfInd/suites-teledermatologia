from dataclasses import dataclass
from io import BytesIO
import hashlib
from pathlib import Path
import warnings

from PIL import Image, ImageCms, ImageOps, UnidentifiedImageError

from app.config import get_settings


class InvalidImage(ValueError):
    pass


@dataclass(frozen=True)
class StoredImage:
    data: bytes
    width: int
    height: int
    sha256: str


def normalize_image(raw: bytes, *, max_upload_bytes=None, max_image_pixels=None, formats=None) -> StoredImage:
    settings = get_settings()
    byte_limit = max_upload_bytes or settings.max_upload_bytes
    pixel_limit = max_image_pixels or settings.max_image_pixels
    allowed_formats = formats or {"JPEG", "PNG"}
    if not raw or len(raw) > byte_limit:
        raise InvalidImage("La foto deve essere più piccola di 12 MB.")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(BytesIO(raw)) as check:
                if check.format not in allowed_formats or getattr(check, "n_frames", 1) != 1:
                    raise InvalidImage("Carica una singola immagine JPEG o PNG.")
                if check.width * check.height > pixel_limit or min(check.size) < 32:
                    raise InvalidImage("Dimensioni consentite: almeno 32 px per lato, massimo 25 megapixel.")
                check.verify()
            with Image.open(BytesIO(raw)) as original:
                image = ImageOps.exif_transpose(original)
                if original.info.get("icc_profile"):
                    image = ImageCms.profileToProfile(
                        image, ImageCms.ImageCmsProfile(BytesIO(original.info["icc_profile"])),
                        ImageCms.createProfile("sRGB"), outputMode="RGB",
                    )
                elif image.mode in {"RGBA", "LA"} or "transparency" in original.info:
                    rgba = image.convert("RGBA")
                    background = Image.new("RGBA", image.size, "white")
                    background.alpha_composite(rgba)
                    image = background.convert("RGB")
                else:
                    image = image.convert("RGB")
                # Ricreare dai pixel evita di propagare EXIF, GPS, commenti e nomi originali.
                clean = Image.frombytes("RGB", image.size, image.tobytes())
                output = BytesIO()
                clean.save(output, format="PNG")
                data = output.getvalue()
                return StoredImage(data, clean.width, clean.height, hashlib.sha256(data).hexdigest())
    except InvalidImage:
        raise
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError, ImageCms.PyCMSError, Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
        raise InvalidImage("Immagine non valida o profilo colore non supportato.") from exc


def storage_path(key: str) -> Path:
    root = get_settings().data_dir
    path = (root / key).resolve()
    if not path.is_relative_to(root):
        raise ValueError("Percorso di archivio non valido.")
    return path


def save_mask(mask: Image.Image, size: tuple[int, int], key: str) -> tuple[str, str]:
    if mask.mode != "L" or mask.size != size:
        raise ValueError("La maschera deve essere L a 8 bit con le stesse dimensioni dell'immagine normalizzata.")
    raw_path = storage_path(f"artifacts/{key}-mask.png")
    overlay_path = storage_path(f"artifacts/{key}-overlay.png")
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    clean = Image.frombytes("L", size, mask.tobytes())
    try:
        clean.save(raw_path, format="PNG")
        overlay = Image.new("RGBA", size, (18, 157, 139, 0))
        overlay.putalpha(clean.point(lambda value: round(value * 0.45)))
        overlay.save(overlay_path, format="PNG")
    except Exception:
        raw_path.unlink(missing_ok=True)
        overlay_path.unlink(missing_ok=True)
        raise
    return str(raw_path.relative_to(get_settings().data_dir)).replace("\\", "/"), str(overlay_path.relative_to(get_settings().data_dir)).replace("\\", "/")
