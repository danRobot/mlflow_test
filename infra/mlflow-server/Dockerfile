# ---------------------------------------------------------------------------
# Servidor de tracking de MLflow. Backend PostgreSQL, artefactos por proxy a S3.
# La construye el workflow de deploy y la sube a ECR.
# ---------------------------------------------------------------------------
FROM python:3.11-slim

# uv: instalador de paquetes de Astral, bastante mas rapido que pip.
# Se copia el binario desde la imagen oficial; no hace falta instalarlo.
COPY --from=ghcr.io/astral-sh/uv:0.12.10 /uv /bin/uv

# Manten esta version alineada con la que instalas en Colab.
ARG MLFLOW_VERSION=3.17.0

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_SYSTEM_PYTHON=1 \
    UV_NO_CACHE=1 \
    MLFLOW_HOME=/mlflow \
    MLFLOW_PORT=8080

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl libpq5 \
    && rm -rf /var/lib/apt/lists/*

# psycopg2-binary para PostgreSQL. boto3 para guardar los artefactos en S3.
RUN uv pip install --system \
        "mlflow==${MLFLOW_VERSION}" \
        "psycopg2-binary==2.9.10" \
        "boto3==1.35.99"

# --- Alternativa con pyproject.toml -----------------------------------------
# El .toml debe estar en mlflow/, junto a este Dockerfile: el contexto de
# build es ./mlflow y COPY no puede salir de ahi. Sustituye el RUN de arriba:
#   COPY pyproject.toml ./
#   RUN uv pip install --system -r pyproject.toml
# ---------------------------------------------------------------------------

WORKDIR ${MLFLOW_HOME}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080

# Forma shell: ${MLFLOW_PORT} se expande al ejecutarse, asi el healthcheck
# sigue al puerto aunque lo cambies desde el compose.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD curl -fsS http://127.0.0.1:${MLFLOW_PORT}/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
