#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# backup_mlflow.sh - Respaldo de MLflow en S3: la base (PostgreSQL) y los
# artefactos en un solo .7z con la maxima compresion. Corre en la EC2, como
# root; lo lanza el workflow backup por SSM.
#
# Uso (busca el docker-compose.yml subiendo desde la carpeta del script; o
# fijalo con COMPOSE_DIR=/ruta):
#   /opt/mlflow/scripts/backup_mlflow.sh
#
# Resultado: s3://<bucket>/backup/backup_mlflow_AAAAMMDD-HHMMSS.7z (hora UTC)
#   db.sql         la base completa (pg_dump portable, sin owner ni privilegios)
#   manifest.txt   fecha, version de MLflow y conteos
#   artifacts/     copia de s3://<bucket>/artifacts
#
# Para no llenar el disco de la EC2:
#   1. pg_dump escribe directo en S3, en backup/backup_mlflow_<fecha>.tmp/.
#   2. El bucket se monta en solo lectura (mount-s3) mientras dura el respaldo
#      y 7-Zip lee de ahi la base y los artefactos, sin copiarlos al disco.
#   3. El .7z si se arma en el disco, porque 7-Zip necesita volver atras en el
#      archivo que escribe: ocupa lo comprimido. Se sube a backup/ y se borra
#      del disco, igual que la carpeta .tmp de S3.
#
# Con la base vacia (MLflow recien desplegado) no hace nada: ese respaldo
# seria el mas reciente y el restore lo tomaria antes que el ultimo con datos.
#
# Configuracion: backup.env junto al docker-compose.yml (lo escribe deploy.sh)
#   ARTIFACTS_DESTINATION  s3://<bucket>/artifacts
#   AWS_REGION             region de AWS
# Variables opcionales: PG_SERVICE, MLFLOW_SERVICE, WORK_DIR (donde se arma
# el .7z, /var/tmp) y MOUNT_DIR (punto de montaje del bucket, /mnt/mlflow-s3).
# ---------------------------------------------------------------------------
set -euo pipefail

PG_SVC="${PG_SERVICE:-postgres}"
ML_SVC="${MLFLOW_SERVICE:-mlflow}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "${SCRIPT_DIR}/common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        *)           die "opcion desconocida: $1 (usa --help)" ;;
    esac
done

# --- Comprobaciones previas -------------------------------------------------
command -v docker >/dev/null || die "docker no esta instalado"
find_compose_dir
read_conf backup.env
setup_s3
find_7z
take_lock
if ! err="$(dc config --quiet 2>&1)"; then
    die "el docker-compose.yml de $(pwd) no es valido o falta su .env. Detalle: ${err}"
fi
log "Proyecto compose: $(pwd)"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
NAME="backup_mlflow_${STAMP}"
STAGING="backup/${NAME}.tmp" # carpeta temporal en S3 (sin comprimir)
WORK_BASE="${WORK_DIR:-/var/tmp}"
WORK=""
STAGED=no
STARTED_PG=no

# --- Limpieza, pase lo que pase ------------------------------------------------
cleanup() {
    local status=$?
    unmount_bucket
    if [ "${STAGED}" = yes ]; then
        aws s3 rm "s3://${BUCKET}/${STAGING}/" --recursive --only-show-errors ||
            warn "no se pudo borrar s3://${BUCKET}/${STAGING}/"
    fi
    if [ -n "${WORK}" ] && [ -d "${WORK}" ]; then rm -rf "${WORK}"; fi
    if [ "${status}" -ne 0 ]; then
        echo "Respaldo FALLIDO: no se creo ningun respaldo nuevo en s3://${BUCKET}/backup/." >&2
    fi
    if [ "${STARTED_PG}" = yes ] && ! is_running "${ML_SVC}"; then
        log "Deteniendo ${PG_SVC} (estaba detenido antes del respaldo)"
        dc stop "${PG_SVC}" >/dev/null || true
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Restos de un respaldo cortado de golpe (apagado, kill -9). Con el candado
# tomado no hay otro en curso.
rm -rf "${WORK_BASE}"/mlflow-backup.*
aws s3 rm "s3://${BUCKET}/backup/" --recursive --exclude '*' --include '*.tmp/*' --only-show-errors

# --- Postgres arriba y algo que respaldar ----------------------------------------
if ! is_running "${PG_SVC}"; then
    log "${PG_SVC} detenido: arrancandolo temporalmente"
    dc up -d "${PG_SVC}" >/dev/null
    STARTED_PG=yes
fi
wait_postgres
RUNS="$(psql_q 'select count(*) from runs' 2>/dev/null)" ||
    die "la base '${PGDB}' no tiene el esquema de MLflow (no existe la tabla runs)"
if db_is_empty; then
    echo "La base esta vacia (MLflow recien desplegado): no se crea ningun respaldo."
    echo "Seria el mas reciente y el restore lo tomaria antes que el ultimo con datos."
    exit 0
fi
EXPERIMENTS="$(psql_q 'select count(*) from experiments')"
ALEMBIC="$(psql_q 'select version_num from alembic_version' 2>/dev/null || echo desconocida)"
DB_BYTES="$(psql_q 'select pg_database_size(current_database())')"
if is_running "${ML_SVC}"; then
    MLFLOW_VERSION="$(dc exec -T "${ML_SVC}" python -c \
        'import importlib.metadata as m; print(m.version("mlflow"))' 2>/dev/null || echo desconocida)"
else
    MLFLOW_VERSION="$(image_mlflow_version)"
fi

SUMMARY="$(s3_summary "s3://${BUCKET}/artifacts/")" || die "no se pudieron listar los artefactos de s3://${BUCKET}/artifacts/"
read -r ART_FILES ART_BYTES <<<"${SUMMARY}"

# El .7z se arma en el disco. Si nada se comprimiera (modelos binarios) ocuparia
# lo mismo que la base y los artefactos: se exige ese espacio y 512 MB de margen
# para no dejar sin disco a Postgres y MLflow.
need_space "${WORK_BASE}" $((ART_BYTES + DB_BYTES + 536870912)) "armar el .7z"

# 7-Zip con la maxima compresion (-mx=9). En 7-Zip 2x usa un diccionario de
# 256 MB y unos 2.2 GB de RAM; si no hay tanta memoria libre (t3.small), se
# baja a 64 MB: unos 0.7 GB y un .7z practicamente igual.
SZ_OPTS=(-t7z -mx=9 -bd)
if [ "$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)" -lt $((3 * 1024 * 1024)) ]; then
    SZ_OPTS+=(-md=64m)
fi

# --- Base y manifiesto, directo a S3 ---------------------------------------------
STAGED=yes
cat <<EOF | aws s3 cp - "s3://${BUCKET}/${STAGING}/manifest.txt" --only-show-errors
created_at=$(date -u -Iseconds)
host=$(uname -n)
mlflow_version=${MLFLOW_VERSION}
alembic_revision=${ALEMBIC}
pg_db=${PGDB}
experiments=${EXPERIMENTS}
runs=${RUNS}
artifact_files=${ART_FILES}
artifact_bytes=${ART_BYTES}
artifacts_source=s3://${BUCKET}/artifacts
EOF

log "Volcando la base '${PGDB}' (${EXPERIMENTS} experimentos, ${RUNS} corridas) en s3://${BUCKET}/${STAGING}/"
# -T es obligatorio: con TTY Docker mete caracteres de control en el volcado.
dc exec -T "${PG_SVC}" pg_dump -U "${PGUSER}" -d "${PGDB}" --no-owner --no-privileges |
    aws s3 cp - "s3://${BUCKET}/${STAGING}/db.sql" --only-show-errors

# --- Comprimir desde el bucket montado ----------------------------------------------
mount_bucket
# pg_dump escribe esta marca al final solo si termino bien.
DUMP_TAIL="$(tail -n 20 "${MNT}/${STAGING}/db.sql")"
grep -q "PostgreSQL database dump complete" <<<"${DUMP_TAIL}" || die "el volcado de la base esta incompleto"

WORK="$(mktemp -d "${WORK_BASE}/mlflow-backup.XXXXXX")"
ARCHIVE="${WORK}/${NAME}.7z"
log "Comprimiendo con 7-Zip (${SZ_OPTS[*]}): la base y ${ART_FILES} artefactos ($(mb "${ART_BYTES}") sin comprimir)"
# Primero lo pequeno y despues los artefactos: 7-Zip reescribe el .7z al
# agregar archivos, y asi solo copia la base y el manifiesto.
(cd "${MNT}/${STAGING}" && sz a "${SZ_OPTS[@]}" "${ARCHIVE}" db.sql manifest.txt) >/dev/null
if [ -d "${MNT}/artifacts" ]; then
    (cd "${MNT}" && sz a "${SZ_OPTS[@]}" "${ARCHIVE}" artifacts) >/dev/null
fi
log "Verificando el .7z"
sz t -bd "${ARCHIVE}" >/dev/null || die "el .7z quedo danado"
unmount_bucket

ARCHIVE_BYTES="$(stat -c %s "${ARCHIVE}")"
log "Subiendo ${NAME}.7z ($(mb "${ARCHIVE_BYTES}")) a s3://${BUCKET}/backup/"
aws s3 cp "${ARCHIVE}" "s3://${BUCKET}/backup/${NAME}.7z" --only-show-errors

# --- Ya esta en S3: se borra lo que no esta comprimido -----------------------------
aws s3 rm "s3://${BUCKET}/${STAGING}/" --recursive --only-show-errors
STAGED=no
rm -rf "${WORK}"
WORK=""

echo ""
echo "Respaldo completo: s3://${BUCKET}/backup/${NAME}.7z ($(mb "${ARCHIVE_BYTES}"))"
echo "  experimentos=${EXPERIMENTS} corridas=${RUNS} artefactos=${ART_FILES} archivos ($(mb "${ART_BYTES}") sin comprimir) mlflow=${MLFLOW_VERSION}"
echo "Para conservarlo despues de un destroy o un reinicio del lab, descargalo desde la consola de S3 (carpeta backup/)."
echo "RESPALDO=${NAME}.7z"
