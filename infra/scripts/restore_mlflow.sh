#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore_mlflow.sh - Restaura en la EC2 un respaldo de backup_mlflow.sh
# (backup_mlflow_AAAAMMDD-HHMMSS.7z) que este en s3://<bucket>/backup/ y, si
# todo sale bien, borra ese .7z de S3.
#
# DESTRUCTIVO: reemplaza la base actual por la del respaldo. Los artefactos
# del respaldo se suben a s3://<bucket>/artifacts; los que ya estaban se quedan.
#
# El workflow restore copia antes a backup/ el respaldo mas reciente de Google
# Drive y llama a este script con --file. Sin --file toma el de nombre mas
# reciente de backup/ (por ejemplo, uno que subiste a mano a esa carpeta), y
# si no hay ninguno falla.
#
# Uso (misma deteccion del docker-compose.yml que backup_mlflow.sh):
#   /opt/mlflow/scripts/restore_mlflow.sh                 pide confirmacion
#   /opt/mlflow/scripts/restore_mlflow.sh --yes           sin confirmacion (SSM)
#   /opt/mlflow/scripts/restore_mlflow.sh --file NOMBRE   ese .7z de backup/, no
#                                                         el mas reciente
#
# Disco: el .7z se lee del bucket montado en solo lectura (mount-s3) y se
# descomprime en el disco de la EC2, que necesita espacio para todo su
# contenido sin comprimir. Se borra al terminar.
#
# Si el respaldo viene de una version anterior de MLflow, el entrypoint
# ejecuta 'mlflow db upgrade' al arrancar y migra el esquema solo. Funciona
# aunque el bucket se llame distinto (otra cuenta o region): la base guarda los
# artefactos como mlflow-artifacts:/..., no con el nombre del bucket.
#
# Configuracion y variables: las mismas que backup_mlflow.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

PG_SVC="${PG_SERVICE:-postgres}"
ML_SVC="${MLFLOW_SERVICE:-mlflow}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=no
FILE=""
# shellcheck source-path=SCRIPTDIR source=common.sh
. "${SCRIPT_DIR}/common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --yes | -y)  ASSUME_YES=yes ;;
        --file)      [ $# -ge 2 ] || die "--file necesita el nombre del .7z"; FILE="$2"; shift ;;
        --file=*)    FILE="${1#--file=}" ;;
        -h | --help) usage; exit 0 ;;
        *)           die "opcion desconocida: $1 (usa --help)" ;;
    esac
    shift
done
if [ -n "${FILE}" ] && ! [[ "${FILE}" =~ ^backup_mlflow_[A-Za-z0-9._-]+\.7z$ ]]; then
    die "--file '${FILE}': tiene que ser un nombre backup_mlflow_<fecha>.7z, sin carpeta"
fi

# --- Proyecto compose, configuracion y herramientas -----------------------------
command -v docker >/dev/null || die "docker no esta instalado"
find_compose_dir
read_conf backup.env
setup_s3
find_7z
take_lock
if ! err="$(dc config --quiet 2>&1)"; then
    die "el docker-compose.yml de $(pwd) no es valido o falta su .env. Detalle: ${err}"
fi

WORK_BASE="${WORK_DIR:-/var/tmp}"
WORK=""
STOPPED_ML=no
# shellcheck disable=SC2317 # la llama el trap
cleanup() {
    local status=$?
    unmount_bucket
    if [ -n "${WORK}" ] && [ -d "${WORK}" ]; then rm -rf "${WORK}"; fi
    # Si algo fallo con MLflow detenido, se vuelve a levantar: con la base
    # vacia arranca como recien creado. El respaldo no se toca.
    if [ "${STOPPED_ML}" = yes ] && ! is_running "${ML_SVC}"; then
        log "Levantando de nuevo ${ML_SVC}"
        dc up -d "${ML_SVC}" >/dev/null || warn "no se pudo levantar ${ML_SVC}"
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Restos de una restauracion cortada de golpe.
rm -rf "${WORK_BASE}"/mlflow-restore.*

# --- Que respaldo -----------------------------------------------------------------
BACKUPS="$(backup_names)" || die "no se pudo listar s3://${BUCKET}/backup/"
if [ -n "${FILE}" ]; then
    grep -qxF "${FILE}" <<<"${BACKUPS}" || die "no existe s3://${BUCKET}/backup/${FILE}"
    SRC="${FILE}"
    log "Respaldo a restaurar: ${SRC}"
else
    SRC="$(sed -n '1p' <<<"${BACKUPS}")"
    if [ -z "${SRC}" ]; then
        die "no hay respaldos en s3://${BUCKET}/backup/: el workflow restore los trae de Google Drive. Para usar este script a mano, sube antes a esa carpeta el .7z (backup_mlflow_AAAAMMDD-HHMMSS.7z)."
    fi
    log "Respaldo a restaurar: ${SRC} (el mas reciente de $(grep -c . <<<"${BACKUPS}") en s3://${BUCKET}/backup/)"
fi

# --- Descomprimir desde el bucket montado y validar ANTES de tocar nada ----------
OLDER="para restaurar el anterior, saca este .7z de la carpeta de Drive (o de backup/, si lo subiste ahi a mano)"
mount_bucket
ARCHIVE="${MNT}/backup/${SRC}"
[ -f "${ARCHIVE}" ] || die "no se encuentra ${SRC} en el bucket montado"
LISTING="$(sz l -slt "${ARCHIVE}")" ||
    die "${SRC} no es un .7z valido o esta danado: ${OLDER}"
grep -qx 'Path = db.sql' <<<"${LISTING}" || die "${SRC} no tiene db.sql, no es un respaldo de backup_mlflow.sh: ${OLDER}"
TOTAL="$(awk -F ' = ' '$1 == "Size" { s += $2 } END { print s + 0 }' <<<"${LISTING}")"
need_space "${WORK_BASE}" $((TOTAL + 536870912)) "descomprimir ${SRC}"

WORK="$(mktemp -d "${WORK_BASE}/mlflow-restore.XXXXXX")"
log "Descomprimiendo ${SRC} ($(mb "${TOTAL}") sin comprimir)"
sz x -bd -o"${WORK}" "${ARCHIVE}" >/dev/null ||
    die "no se pudo descomprimir ${SRC} (danado o incompleto): ${OLDER}"
unmount_bucket

DB_FILE="${WORK}/db.sql"
MANIFEST="${WORK}/manifest.txt"
[ -f "${DB_FILE}" ] || die "falta db.sql al descomprimir ${SRC}"
HEAD="$(head -c 4096 "${DB_FILE}" | tr -d '\0')"
grep -q "PostgreSQL database dump" <<<"${HEAD}" || die "db.sql no es un volcado SQL de pg_dump"
TAIL="$(tail -n 20 "${DB_FILE}")"
grep -q "PostgreSQL database dump complete" <<<"${TAIL}" || die "db.sql esta truncado: pg_dump no llego a terminar"
ART_FILES=0
if [ -d "${WORK}/artifacts" ]; then
    ART_FILES="$(find "${WORK}/artifacts" -type f | wc -l)"
fi

# --- Postgres y contenedor de MLflow ------------------------------------------------
dc up -d "${PG_SVC}" >/dev/null
wait_postgres
if [ -z "$(dc ps -a -q "${ML_SVC}" 2>/dev/null)" ]; then
    log "No existe el contenedor ${ML_SVC}: creandolo sin arrancarlo"
    dc up --no-start "${ML_SVC}"
fi
IMAGE_VERSION="$(image_mlflow_version)"
BACKUP_VERSION="$(mf mlflow_version "${MANIFEST}")"
BACKUP_VERSION="${BACKUP_VERSION:-desconocida}"

# --- Resumen y confirmacion ---------------------------------------------------------
echo ""
echo "  Respaldo     : s3://${BUCKET}/backup/${SRC}"
echo "  Creado       : $(mf created_at "${MANIFEST}") en $(mf host "${MANIFEST}")"
echo "  Contenido    : $(mf experiments "${MANIFEST}") experimentos, $(mf runs "${MANIFEST}") corridas, ${ART_FILES} artefactos"
echo "  MLflow       : respaldo ${BACKUP_VERSION}, imagen actual ${IMAGE_VERSION}"
echo ""
if [ "${BACKUP_VERSION}" != desconocida ] && [ "${IMAGE_VERSION}" != desconocida ] &&
    [ "${BACKUP_VERSION}" != "${IMAGE_VERSION}" ] &&
    [ "$(printf '%s\n%s\n' "${BACKUP_VERSION}" "${IMAGE_VERSION}" | sort -V | tail -n 1)" = "${BACKUP_VERSION}" ]; then
    die "el respaldo viene de un MLflow MAS NUEVO (${BACKUP_VERSION}) que la imagen (${IMAGE_VERSION}): el servidor rechazaria ese esquema. Sube MLFLOW_VERSION en el Dockerfile y lanza deploy."
fi
if is_running "${ML_SVC}"; then
    warn "MLflow esta en marcha: se detendra y quien este entrenando perdera la conexion."
fi
echo "Todo lo que hay ahora en la base de MLflow se REEMPLAZARA por este respaldo."
if [ "${ASSUME_YES}" != yes ]; then
    [ -t 0 ] || die "sin terminal interactiva: usa --yes para confirmar"
    read -r -p "Escribe 'restaurar' para continuar: " answer
    [ "${answer}" = restaurar ] || { echo "Cancelado, no se toco nada."; exit 1; }
fi

# --- Artefactos a S3 (con MLflow aun en marcha) ---------------------------------------
if [ "${ART_FILES}" -gt 0 ]; then
    log "Subiendo ${ART_FILES} artefactos a s3://${BUCKET}/artifacts/ (los que ya estaban se quedan)"
    aws s3 sync "${WORK}/artifacts" "s3://${BUCKET}/artifacts" --only-show-errors
else
    log "El respaldo no tiene artefactos"
fi

# --- A partir de aqui se modifican datos -------------------------------------------
log "Deteniendo ${ML_SVC}"
dc stop "${ML_SVC}" >/dev/null
STOPPED_ML=yes

log "Recreando la base '${PGDB}' vacia"
# Se conecta a la base de mantenimiento 'postgres', que siempre existe.
dc exec -T "${PG_SVC}" psql -U "${PGUSER}" -d postgres -v ON_ERROR_STOP=1 -q >/dev/null <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = '${PGDB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${PGDB}";
CREATE DATABASE "${PGDB}" OWNER "${PGUSER}";
SQL

log "Cargando la base del respaldo"
# --single-transaction: o entra todo o no entra nada.
dc exec -T "${PG_SVC}" psql -U "${PGUSER}" -d "${PGDB}" -v ON_ERROR_STOP=1 \
    --single-transaction -q >/dev/null <"${DB_FILE}" ||
    die "fallo la carga de la base. Quedo VACIA: vuelve a lanzar restore (el respaldo no se toco)"

# --- Levantar MLflow (up, no start: asi recoge el .env actual) ----------------------
log "Levantando ${ML_SVC}"
dc up -d "${ML_SVC}" >/dev/null
STOPPED_ML=no
HEALTHY=no
for _ in $(seq 1 40); do
    # shellcheck disable=SC2016 # MLFLOW_PORT se expande dentro del contenedor
    if dc exec -T "${ML_SVC}" sh -c 'curl -fsS "http://127.0.0.1:${MLFLOW_PORT:-8080}/health"' >/dev/null 2>&1; then
        HEALTHY=yes
        break
    fi
    sleep 3
done
if [ "${HEALTHY}" != yes ]; then
    dc logs --tail 40 "${ML_SVC}" >&2
    die "MLflow no responde tras restaurar (logs arriba). Los datos estan cargados; el respaldo no se toco."
fi

# --- Hecho: se borra el .7z de S3 --------------------------------------------------------
aws s3 rm "s3://${BUCKET}/backup/${SRC}" --only-show-errors
rm -rf "${WORK}"
WORK=""

EXP_NOW="$(psql_q 'select count(*) from experiments')"
RUNS_NOW="$(psql_q 'select count(*) from runs')"
SUMMARY="$(s3_summary "s3://${BUCKET}/artifacts/")" || SUMMARY="? ?"
echo ""
echo "Restauracion terminada: ${SRC} (borrado de s3://${BUCKET}/backup/)"
echo "  experimentos   ${EXP_NOW}"
echo "  corridas       ${RUNS_NOW}"
echo "  artefactos     ${ART_FILES} del respaldo; ahora hay ${SUMMARY%% *} en s3://${BUCKET}/artifacts/"
echo "RESTAURADO=${SRC}"
