FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    NO_ALBUMENTATIONS_UPDATE=1 \
    DATA_DIR=/data \
    MODEL_DIR=/models

WORKDIR /app
COPY requirements.txt ./
RUN python -m pip install --no-cache-dir -r requirements.txt
RUN python -m pip install --no-cache-dir torch==2.7.1 torchvision==0.22.1 --index-url https://download.pytorch.org/whl/cpu
COPY model_integration/requirements.txt ./model_integration/requirements.txt
RUN python -m pip install --no-cache-dir -r model_integration/requirements.txt
RUN groupadd --gid 10001 telederm && useradd --uid 10001 --gid telederm --no-create-home telederm \
    && mkdir -p /data /models && chown -R telederm:telederm /data /models

COPY --chown=telederm:telederm app ./app
COPY --chown=telederm:telederm model_integration ./model_integration
COPY --chown=telederm:telederm migrations ./migrations
COPY --chown=telederm:telederm alembic.ini ./

USER 10001:10001
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-proxy-headers", "--no-access-log"]
