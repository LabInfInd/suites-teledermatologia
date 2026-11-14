from typing import Literal
import re

from pydantic import BaseModel, ConfigDict, Field, field_validator


Role = Literal["patient", "doctor", "admin"]


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class LoginInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: str = Field(min_length=3, max_length=64)
    password: str = Field(min_length=1, max_length=256)


def valid_username(value: str) -> str:
    value = value.strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{2,63}", value):
        raise ValueError("Usare 3–64 lettere, cifre, punti, trattini o underscore.")
    return value


def valid_password(value: str) -> str:
    if not 12 <= len(value) <= 256 or not value.strip():
        raise ValueError("La password deve contenere da 12 a 256 caratteri.")
    return value


class CreateUserInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: str
    password: str
    role: Role
    _username = field_validator("username")(valid_username)
    _password = field_validator("password")(valid_password)


class PasswordInput(BaseModel):
    model_config = ConfigDict(extra="forbid")
    current_password: str = Field(min_length=1, max_length=256)
    new_password: str
    _password = field_validator("new_password")(valid_password)


class UserActiveInput(Input):
    active: bool


class CaseInput(Input):
    body_site: str = Field(default="", max_length=80)
    notes: str = Field(default="", max_length=4000)
    demo_confirmed: Literal[True]


class VersionInput(Input):
    expected_version: int = Field(ge=1)


class ReviewInput(VersionInput):
    decision: Literal["approved", "corrected", "needs_images"]
    final_label: str | None = Field(default=None, max_length=160)
    patient_message: str = Field(min_length=10, max_length=5000)
    share_segmentation: bool = False


class LabelScore(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, revalidate_instances="always")
    label: str = Field(min_length=1, max_length=160)
    score: float = Field(ge=0, le=1)


class ImagePrediction(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, revalidate_instances="always")
    model_name: str = Field(min_length=1, max_length=120)
    model_version: str = Field(min_length=1, max_length=120)
    labels: list[LabelScore] = Field(min_length=1, max_length=100)
