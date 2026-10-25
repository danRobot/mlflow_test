#!/usr/bin/env bash
set -euo pipefail

BACKEND_STORE_URI="${BACKEND_STORE_URI:?Falta BACKEND_STORE_URI}"
ARTIFACTS_DESTINATION="${ARTIFACTS_DESTINATION:-/mlflow/artifacts}"
MLFLOW_PORT="${MLFLOW_PORT:-8080}"
MLFLOW_PUBLIC_PORT="${MLFLOW_PUBLIC_PORT:-${MLFLOW_PORT}}"
MLFLOW_PUBLIC_HOST="${MLFLOW_PUBLIC_HOST:-}"
MLFLOW_WORKERS="${MLFLOW_WORKERS:-2}"
MLFLOW_AUTH_ENABLED="${MLFLOW_AUTH_ENABLED:-false}"

# No hay bucle de espera: el 'depends_on: condition: service_healthy' del
# compose garantiza que Postgres ya acepta conexiones.
# Esta linea si es necesaria: MLflow NO migra solo un esquema antiguo, lanza
# una excepcion pidiendo justamente este comando. Es idempotente.
mlflow db upgrade "${BACKEND_STORE_URI}"

# Validacion del header Host (MLflow >= 3.x): por defecto solo acepta
# localhost e IPs privadas. Sin declarar la IP publica, Colab recibe un 403.
ALLOWED_HOSTS="localhost,localhost:*,127.0.0.1,127.0.0.1:*"
[ -n "${MLFLOW_PUBLIC_HOST}" ] && \
    ALLOWED_HOSTS="${ALLOWED_HOSTS},${MLFLOW_PUBLIC_HOST},${MLFLOW_PUBLIC_HOST}:*"
ALLOWED_HOSTS="${MLFLOW_ALLOWED_HOSTS_OVERRIDE:-${ALLOWED_HOSTS}}"

# Validacion de Origin: el navegador lo manda incluso en POST del MISMO
# origen, y MLflow bloquea los que no sean localhost. Afecta solo a la UI,
# nunca a los clientes Python. Usa el OVERRIDE si sirves por HTTPS.
CORS_ORIGINS="http://localhost:${MLFLOW_PUBLIC_PORT},http://127.0.0.1:${MLFLOW_PUBLIC_PORT}"
[ -n "${MLFLOW_PUBLIC_HOST}" ] && \
    CORS_ORIGINS="${CORS_ORIGINS},http://${MLFLOW_PUBLIC_HOST}:${MLFLOW_PUBLIC_PORT},http://${MLFLOW_PUBLIC_HOST}"
CORS_ORIGINS="${MLFLOW_CORS_ORIGINS_OVERRIDE:-${CORS_ORIGINS}}"

SERVER_ARGS=(
    server
    --host 0.0.0.0
    --port "${MLFLOW_PORT}"
    --workers "${MLFLOW_WORKERS}"
    --backend-store-uri "${BACKEND_STORE_URI}"
    --serve-artifacts
    --artifacts-destination "${ARTIFACTS_DESTINATION}"
    --default-artifact-root "mlflow-artifacts:/"
    --allowed-hosts "${ALLOWED_HOSTS}"
    --cors-allowed-origins "${CORS_ORIGINS}"
)

if [ "${MLFLOW_AUTH_ENABLED,,}" = "true" ]; then
    : "${MLFLOW_AUTH_PASSWORD:?Falta MLFLOW_AUTH_PASSWORD}"

    # MLflow 3.x no arranca basic-auth sin una clave fija para CSRF, comun a
    # todos los workers. Se genera una vez y se guarda en el volumen de auth.
    SECRET_FILE=/mlflow/auth/flask_secret_key
    [ -s "${SECRET_FILE}" ] || python -c 'import secrets; print(secrets.token_hex(32))' > "${SECRET_FILE}"
    chmod 600 "${SECRET_FILE}"
    MLFLOW_FLASK_SERVER_SECRET_KEY="${MLFLOW_FLASK_SERVER_SECRET_KEY:-$(cat "${SECRET_FILE}")}"
    export MLFLOW_FLASK_SERVER_SECRET_KEY

    # El .ini se lee con configparser, que interpreta '%': se duplica.
    cat > /mlflow/auth/basic_auth.ini <<INI
[mlflow]
default_permission = READ
database_uri = sqlite:////mlflow/auth/basic_auth.db
admin_username = ${MLFLOW_AUTH_USERNAME:-admin}
admin_password = ${MLFLOW_AUTH_PASSWORD//%/%%}
authorization_function = mlflow.server.auth:authenticate_request_basic_auth
INI
    chmod 600 /mlflow/auth/basic_auth.ini
    export MLFLOW_AUTH_CONFIG_PATH=/mlflow/auth/basic_auth.ini
    SERVER_ARGS+=(--app-name basic-auth)
fi

echo "[entrypoint] auth=${MLFLOW_AUTH_ENABLED} hosts=${ALLOWED_HOSTS}"
echo "[entrypoint] cors=${CORS_ORIGINS} artifacts=${ARTIFACTS_DESTINATION}"

exec mlflow "${SERVER_ARGS[@]}"
