#!/usr/bin/env bash
set -euo pipefail

BACKEND_STORE_URI="${BACKEND_STORE_URI:?Falta BACKEND_STORE_URI}"
ARTIFACTS_DESTINATION="${ARTIFACTS_DESTINATION:-/mlflow/artifacts}"
MLFLOW_PORT="${MLFLOW_PORT:-8080}"
MLFLOW_PUBLIC_PORT="${MLFLOW_PUBLIC_PORT:-${MLFLOW_PORT}}"
MLFLOW_PUBLIC_HOST="${MLFLOW_PUBLIC_HOST:-}"
MLFLOW_WORKERS="${MLFLOW_WORKERS:-2}"

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

# Autenticacion: con MLFLOW_AUTH distinto de "off" (lo escribe deploy.sh), el
# usuario y la clave llegan en el secret de compose, como "usuario:clave".
MLFLOW_AUTH="${MLFLOW_AUTH:-off}"
AUTH_FILE=/run/secrets/mlflow_auth
if [ "${MLFLOW_AUTH}" != off ]; then
    [ -s "${AUTH_FILE}" ] || { echo "[entrypoint] ERROR: autenticacion activada pero ${AUTH_FILE} esta vacio" >&2; exit 1; }

    # Usuarios y permisos en la misma base de Postgres, en tablas propias
    # (con su alembic_version_auth): los respaldos de la base los incluyen.
    # configparser interpreta '%': se duplica.
    cat > /mlflow/basic_auth.ini <<INI
[mlflow]
default_permission = READ
database_uri = ${BACKEND_STORE_URI//%/%%}
authorization_function = mlflow.server.auth:authenticate_request_basic_auth
INI
    chmod 600 /mlflow/basic_auth.ini
    export MLFLOW_AUTH_CONFIG_PATH=/mlflow/basic_auth.ini

    # MLflow solo usa la clave configurada al crear el admin y despues la
    # ignora. Aqui se aplica en cada arranque: el usuario y la clave de los
    # secrets de GitHub son siempre los que valen, tambien tras un restore.
    # Es el unico admin: si cambias de usuario, el anterior se borra. Los
    # usuarios normales (creados desde la UI) no se tocan.
    MLFLOW_AUTH_ADMIN_USERNAME="$(python - "${AUTH_FILE}" <<'PY'
import os
import sys

from mlflow.server.auth.sqlalchemy_store import SqlAlchemyStore

user, sep, password = open(sys.argv[1], encoding="utf-8").read().rstrip("\r\n").partition(":")
if not sep or not user or len(password) < 12:
    sys.exit("[entrypoint] ERROR: el secret debe ser usuario:clave, con clave de 12 caracteres o mas")
store = SqlAlchemyStore()
store.init_db(os.environ["BACKEND_STORE_URI"])
if store.has_user(user):
    store.update_user(user, password=password, is_admin=True)
else:
    store.create_user(user, password, is_admin=True)
for other in store.list_users():
    if other.is_admin and other.username != user:
        store.delete_user(other.username)
        print(f"[entrypoint] admin anterior borrado: {other.username}", file=sys.stderr)
print(user)
PY
)"
    export MLFLOW_AUTH_ADMIN_USERNAME

    # basic-auth exige una clave de Flask comun a todos los workers. Nueva en
    # cada arranque: solo invalida las sesiones abiertas de la UI.
    MLFLOW_FLASK_SERVER_SECRET_KEY="${MLFLOW_FLASK_SERVER_SECRET_KEY:-$(python -c 'import secrets; print(secrets.token_hex(32))')}"
    export MLFLOW_FLASK_SERVER_SECRET_KEY
    SERVER_ARGS+=(--app-name basic-auth)
    echo "[entrypoint] auth=si usuario=${MLFLOW_AUTH_ADMIN_USERNAME}"
else
    echo "[entrypoint] auth=no"
fi

echo "[entrypoint] hosts=${ALLOWED_HOSTS}"
echo "[entrypoint] cors=${CORS_ORIGINS} artifacts=${ARTIFACTS_DESTINATION}"

exec mlflow "${SERVER_ARGS[@]}"
