#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# backup_mlflow.sh - Respaldo de MLflow en Google Drive: metadatos
# (PostgreSQL) y artefactos (S3). Corre en la EC2, como root.
#
# Uso (busca el docker-compose.yml subiendo desde la carpeta del script; o
# fijalo con COMPOSE_DIR=/ruta):
#   /opt/mlflow/scripts/backup_mlflow.sh
#   /opt/mlflow/scripts/backup_mlflow.sh --stop-server   respaldo consistente
#   /opt/mlflow/scripts/backup_mlflow.sh --force         aunque no haya cambios
#
# Normalmente no hace falta lanzarlo a mano: lo ejecutan el timer
# mlflow-backup (cada hora con la EC2 encendida), el servicio
# mlflow-backup-shutdown (al apagarse la EC2, con --shutdown) y los workflows
# backup y destroy (por SSM).
#
# Resultado en Google Drive, carpeta GDRIVE_FOLDER (por defecto mlflow-backups):
#   mlflow-backup-AAAAMMDD-HHMMSS/   hora UTC
#     manifest.txt     fecha, version, conteos (restore los usa para verificar)
#     db.sql.gz        pg_dump portable (sin owner ni privilegios)
#     auth.tar.gz      usuarios de basic-auth, si el servidor los usa
#   artifacts/         copia de s3://<bucket>/artifacts, comun a todos
#
# Los artefactos no se empaquetan en cada respaldo: rclone copia a artifacts/
# solo los archivos nuevos (MLflow no modifica un artefacto ya subido) y ahi
# nunca borra nada, asi que cada respaldo encuentra los suyos. Sale de AWS
# solo lo nuevo, que es lo que se cobra como transferencia.
#
# Configuracion: backup.env junto al docker-compose.yml (lo escribe deploy.sh)
#   GDRIVE_PARAMETER       parametro de Parameter Store con la config de rclone
#   GDRIVE_FOLDER          carpeta en Drive (por defecto mlflow-backups)
#   ARTIFACTS_DESTINATION  s3://<bucket>/artifacts
#   AWS_REGION             region de AWS
#   KEEP                   respaldos a conservar en Drive (24; 0 = todos)
# Variables opcionales: PG_SERVICE, MLFLOW_SERVICE, HELPER_IMAGE (para leer el
# volumen de basic-auth, alpine:3.20) y WORK_DIR (volcado temporal, /var/tmp).
#
# Notas:
#   - Si la base no cambio desde el ultimo respaldo, solo copia los artefactos
#     nuevos y no crea otra carpeta (salvo --force): asi la retencion guarda
#     estados distintos y no 24 copias iguales.
#   - Con la base vacia (MLflow recien creado) no respalda nada (salvo
#     --force): un respaldo vacio seria el mas reciente y el deploy lo
#     restauraria en lugar de tus datos.
#   - Se sube a una carpeta .partial que solo se renombra al terminar bien:
#     nunca queda en Drive un respaldo a medias con aspecto de completo.
#   - Sin --stop-server el respaldo es "en caliente": pg_dump toma una foto
#     consistente de la base y los artefactos se copian despues, asi que
#     estan todos los que la base referencia.
# ---------------------------------------------------------------------------
set -euo pipefail

PG_SVC="${PG_SERVICE:-postgres}"
ML_SVC="${MLFLOW_SERVICE:-mlflow}"
HELPER_IMG="${HELPER_IMAGE:-alpine:3.20}"
STOP_SERVER=no
FORCE=no
SHUTDOWN=no
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=drive_common.sh
. "${SCRIPT_DIR}/drive_common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --stop-server) STOP_SERVER=yes ;;
        --force)       FORCE=yes ;;
        --shutdown)    SHUTDOWN=yes ;; # lo usa el servicio de apagado
        -h | --help)   usage; exit 0 ;;
        *)             die "opcion desconocida: $1 (usa --help)" ;;
    esac
    shift
done

# --- Comprobaciones previas -------------------------------------------------
command -v docker >/dev/null || die "docker no esta instalado"
find_compose_dir
read_conf backup.env
KEEP="${KEEP:-24}"
if [ "${SHUTDOWN}" = yes ] && [ -z "${GDRIVE_PARAMETER:-}" ]; then
    echo "Google Drive no esta configurado: no hay respaldo al apagar."
    exit 0
fi
# Al apagar la EC2 hay poco tiempo: no se espera mucho a otro respaldo.
if [ "${SHUTDOWN}" = yes ]; then take_lock 120; else take_lock 900; fi
if ! err="$(dc config --quiet 2>&1)"; then
    die "el docker-compose.yml de $(pwd) no es valido o falta su .env. Detalle: ${err}"
fi
log "Proyecto compose: $(pwd)"

# --- Limpieza y restauracion del estado previo, pase lo que pase ------------
STARTED_PG=no
STOPPED_ML=no
WORK=""
PARTIAL=""

cleanup() {
    local status=$?
    if [ -n "${PARTIAL}" ]; then
        timeout 120 rclone purge "${PARTIAL}" >/dev/null 2>&1 || true
    fi
    if [ -n "${WORK}" ] && [ -d "${WORK}" ]; then
        rm -rf "${WORK}"
    fi
    if [ "${status}" -ne 0 ]; then
        echo "Respaldo FALLIDO: no se creo ningun respaldo nuevo en Drive." >&2
    fi
    if [ "${STOPPED_ML}" = yes ]; then
        log "Reanudando ${ML_SVC}"
        dc start "${ML_SVC}" >/dev/null || warn "no se pudo reanudar ${ML_SVC}"
    fi
    if [ "${STARTED_PG}" = yes ] && ! is_running "${ML_SVC}"; then
        log "Deteniendo ${PG_SVC} (estaba detenido antes del respaldo)"
        dc stop "${PG_SVC}" >/dev/null || true
    fi
    cleanup_rclone
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

setup_rclone
log "Destino: ${DRIVE}"

# --- Postgres arriba (pg_dump corre dentro del contenedor) ------------------
if ! is_running "${PG_SVC}"; then
    if [ "${SHUTDOWN}" = yes ]; then
        echo "${PG_SVC} esta detenido: nada que respaldar al apagar."
        exit 0
    fi
    log "${PG_SVC} detenido: arrancandolo temporalmente"
    dc up -d "${PG_SVC}" >/dev/null
    STARTED_PG=yes
fi
for _ in $(seq 1 30); do
    dc exec -T "${PG_SVC}" pg_isready -q >/dev/null 2>&1 && break
    sleep 2
done
dc exec -T "${PG_SVC}" pg_isready -q >/dev/null 2>&1 || die "${PG_SVC} no acepta conexiones"

PGUSER="$(dc exec -T "${PG_SVC}" printenv POSTGRES_USER 2>/dev/null || true)"
PGUSER="${PGUSER:-postgres}"
PGDB="$(dc exec -T "${PG_SVC}" printenv POSTGRES_DB 2>/dev/null || true)"
PGDB="${PGDB:-${PGUSER}}"
psql_q() { dc exec -T "${PG_SVC}" psql -U "${PGUSER}" -d "${PGDB}" -tAc "$1"; }

RUNS="$(psql_q 'select count(*) from runs' 2>/dev/null)" ||
    die "la base '${PGDB}' no tiene el esquema de MLflow (no existe la tabla runs)"
if db_is_empty && [ "${FORCE}" = no ]; then
    echo "La base esta vacia (MLflow recien creado): no se respalda."
    echo "Un respaldo vacio taparia al ultimo con datos; usa --force si de verdad lo quieres."
    exit 0
fi
EXPERIMENTS="$(psql_q 'select count(*) from experiments')"
RUNNING_RUNS="$(psql_q "select count(*) from runs where status = 'RUNNING'")"
ALEMBIC="$(psql_q 'select version_num from alembic_version' 2>/dev/null || echo desconocida)"

# --- Version de MLflow y volumen de basic-auth (si lo hay) ------------------
ML_CID="$(dc ps -a -q "${ML_SVC}" 2>/dev/null || true)"
PY_VERSION='import importlib.metadata as m; print(m.version("mlflow"))'
MLFLOW_VERSION=desconocida
if is_running "${ML_SVC}"; then
    MLFLOW_VERSION="$(dc exec -T "${ML_SVC}" python -c "${PY_VERSION}" 2>/dev/null || echo desconocida)"
elif [ -n "${ML_CID}" ] && [ "${SHUTDOWN}" = no ]; then
    MLFLOW_VERSION="$(docker run --rm --entrypoint python "$(docker inspect -f '{{.Image}}' "${ML_CID}")" \
        -c "${PY_VERSION}" 2>/dev/null || echo desconocida)"
fi
AUTH_VOL=""
if [ -n "${ML_CID}" ]; then
    AUTH_VOL="$(docker inspect "${ML_CID}" --format \
        '{{range .Mounts}}{{if eq .Destination "/mlflow/auth"}}{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}')"
fi

# --- Espacio para el volcado temporal ---------------------------------------
WORK_BASE="${WORK_DIR:-/var/tmp}"
DB_KB=$(($(psql_q 'select pg_database_size(current_database())') / 1024))
FREE_KB="$(df -Pk "${WORK_BASE}" | awk 'NR == 2 { print $4 }')"
if [ "${FREE_KB}" -lt "$((DB_KB + 102400))" ]; then
    die "espacio insuficiente en ${WORK_BASE}: libres $((FREE_KB / 1024)) MB, la base ocupa $((DB_KB / 1024)) MB. Usa WORK_DIR=/otra/ruta."
fi

if [ "${RUNNING_RUNS}" -gt 0 ]; then
    warn "${RUNNING_RUNS} corrida(s) en estado RUNNING. Si nadie esta entrenando son huerfanas"
    warn "y apareceran asi al restaurar (restore_mlflow.sh --close-running las cierra)."
fi

HOT=no
if is_running "${ML_SVC}"; then
    if [ "${STOP_SERVER}" = yes ]; then
        log "Deteniendo ${ML_SVC} durante el volcado"
        dc stop "${ML_SVC}" >/dev/null
        STOPPED_ML=yes
    else
        HOT=yes
    fi
fi

# --- Volcado de la base -------------------------------------------------------
STAMP="$(date -u +%Y%m%d-%H%M%S)"
NAME="mlflow-backup-${STAMP}"
WORK="$(mktemp -d "${WORK_BASE}/${NAME}.XXXXXX")"

log "Volcando la base '${PGDB}' (${EXPERIMENTS} experimentos, ${RUNS} corridas)"
# -T es obligatorio: con TTY Docker mete caracteres de control en el volcado.
dc exec -T "${PG_SVC}" pg_dump -U "${PGUSER}" -d "${PGDB}" --no-owner --no-privileges |
    gzip >"${WORK}/db.sql.gz"
# pg_dump escribe esta marca al final solo si termino bien.
DUMP_TAIL="$(gunzip -c "${WORK}/db.sql.gz" | tail -n 20)"
grep -q "PostgreSQL database dump complete" <<<"${DUMP_TAIL}" ||
    die "el volcado SQL esta incompleto"

# Huella del contenido, para no repetir respaldos iguales. Sin las lineas
# \restrict y \unrestrict: pg_dump (16.10+) les pone una clave aleatoria
# distinta en cada volcado.
DB_SHA="$(gunzip -c "${WORK}/db.sql.gz" | grep -v -E '^\\(un)?restrict ' | sha256sum | cut -d' ' -f1)"
AUTH_SHA=none
if [ -n "${AUTH_VOL}" ]; then
    log "Guardando usuarios de basic-auth (${AUTH_VOL})"
    docker run --rm -v "${AUTH_VOL}":/data:ro -v "${WORK}":/backup "${HELPER_IMG}" \
        tar czf /backup/auth.tar.gz -C /data .
    AUTH_SHA="$(docker run --rm -v "${AUTH_VOL}":/data:ro "${HELPER_IMG}" sh -c \
        'cd /data && find . -type f | sort | xargs -r sha256sum' | sha256sum | cut -d' ' -f1)"
fi
FINGERPRINT="$(printf '%s\n%s\n' "${DB_SHA}" "${AUTH_SHA}" | sha256sum | cut -d' ' -f1)"

# Reanudar el servidor cuanto antes: los artefactos se copian con el en marcha.
if [ "${STOPPED_ML}" = yes ]; then
    log "Reanudando ${ML_SVC}"
    dc start "${ML_SVC}" >/dev/null
    STOPPED_ML=no
fi

# --- Artefactos: copia incremental de S3 a Drive ----------------------------
# Despues del volcado: asi estan en Drive todos los que la base referencia.
ART_FILES=0
ART_KB=0
if has_files "${S3_ART}"; then
    log "Copiando a Drive los artefactos nuevos de ${ARTIFACTS_DESTINATION}"
    rclone copy "${S3_ART}" "${DRIVE}/artifacts" --fast-list --transfers 4 --checkers 8 \
        "${RCLONE_PROGRESS[@]}"
    ART_JSON="$(rclone size --json --fast-list "${S3_ART}")"
    ART_FILES="$(sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<<"${ART_JSON}")"
    ART_KB=$(($(sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' <<<"${ART_JSON}") / 1024))
else
    log "No hay artefactos en ${ARTIFACTS_DESTINATION}"
fi

# --- ¿Cambio algo desde el ultimo respaldo? ---------------------------------
LAST="$(backup_names | sed -n '1p')"
if [ -n "${LAST}" ] && [ "${FORCE}" = no ]; then
    LAST_FP="$(rclone cat "${DRIVE}/${LAST}/manifest.txt" 2>/dev/null | sed -n 's/^fingerprint=//p' | sed -n '1p')" || LAST_FP=""
    if [ "${LAST_FP}" = "${FINGERPRINT}" ]; then
        echo ""
        echo "Sin cambios en la base desde ${LAST}: no se crea otro respaldo (artefactos al dia)."
        echo "RESPALDO=${LAST}"
        exit 0
    fi
fi

cat >"${WORK}/manifest.txt" <<EOF
created_at=$(date -u -Iseconds)
host=$(hostname)
mlflow_version=${MLFLOW_VERSION}
alembic_revision=${ALEMBIC}
pg_db=${PGDB}
experiments=${EXPERIMENTS}
runs=${RUNS}
running_runs=${RUNNING_RUNS}
artifact_files=${ART_FILES}
artifacts_kb=${ART_KB}
artifacts_source=${ARTIFACTS_DESTINATION}
hot_backup=${HOT}
fingerprint=${FINGERPRINT}
EOF

# --- Subida: a .partial y renombrado al final ---------------------------------
log "Subiendo ${NAME} a Google Drive"
PARTIAL="${DRIVE}/${NAME}.partial"
rclone copy "${WORK}" "${PARTIAL}"
rclone moveto "${PARTIAL}" "${DRIVE}/${NAME}"
PARTIAL=""
rm -rf "${WORK}"
WORK=""

# --- Retencion ---------------------------------------------------------------
# Lo que se borra va a la papelera de Drive, que se vacia sola a los 30 dias.
# La carpeta artifacts/ no se toca: puede tener artefactos de cualquier respaldo.
# Si falla, el respaldo ya esta completo en Drive: solo se avisa.
if [ "${KEEP}" -gt 0 ]; then
    backup_names | sed -n "$((KEEP + 1)),\$p" | while IFS= read -r old; do
        log "Eliminando respaldo antiguo ${old}"
        rclone purge "${DRIVE}/${old}" || warn "no se pudo eliminar ${old}"
    done || warn "no se pudo aplicar la retencion (KEEP=${KEEP})"
fi
# Restos de respaldos interrumpidos (por ejemplo, un apagado a mitad de subida).
rclone lsf --dirs-only "${DRIVE}" | sed -n 's#^\(mlflow-backup-.*\.partial\)/$#\1#p' |
    while IFS= read -r old; do
        rclone purge "${DRIVE}/${old}" || warn "no se pudo eliminar ${old}"
    done || warn "no se pudieron limpiar los respaldos interrumpidos"

echo ""
echo "Respaldo completo: ${NAME} en ${DRIVE}"
echo "  experimentos=${EXPERIMENTS} corridas=${RUNS} artefactos=${ART_FILES} archivos ($((ART_KB / 1024)) MB) mlflow=${MLFLOW_VERSION}"
if [ "${HOT}" = yes ]; then echo "  (en caliente: MLflow siguio atendiendo durante el respaldo)"; fi
echo "Para restaurar: ${SCRIPT_DIR}/restore_mlflow.sh ${NAME}  (o el workflow restore)"
echo "RESPALDO=${NAME}"
