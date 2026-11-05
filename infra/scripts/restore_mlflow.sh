#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore_mlflow.sh - Restaura en la EC2 un respaldo de Google Drive creado
# por backup_mlflow.sh.
#
# DESTRUCTIVO: reemplaza la base actual por la del respaldo. Antes de borrar
# nada respalda en Drive el estado actual (respaldo de seguridad), salvo
# --no-safety-backup. Los artefactos no se borran: se copian a S3 los que
# falten, y los que ya estaban se quedan.
#
# Uso (misma deteccion del docker-compose.yml que backup_mlflow.sh):
#   /opt/mlflow/scripts/restore_mlflow.sh --list
#   /opt/mlflow/scripts/restore_mlflow.sh                    el mas reciente
#   /opt/mlflow/scripts/restore_mlflow.sh mlflow-backup-20261104-184100
#   /opt/mlflow/scripts/restore_mlflow.sh --if-empty --yes   lo usa el deploy
#
# Opciones:
#   --yes                no pedir confirmacion (obligatorio sin terminal, p. ej. SSM)
#   --close-running      marcar como KILLED las corridas que quedaron RUNNING
#   --no-safety-backup   no respaldar el estado actual antes de restaurar
#   --if-empty           restaurar solo si la base esta vacia (MLflow recien
#                        creado) y hay respaldos; si no, no hace nada
#   --list               listar los respaldos de Drive
#
# Si el respaldo viene de una version anterior de MLflow, el entrypoint
# ejecuta 'mlflow db upgrade' al arrancar y migra el esquema solo. Funciona
# aunque el bucket de S3 se llame distinto (otra cuenta o region): la base
# guarda los artefactos como mlflow-artifacts:/..., no con el nombre del bucket.
#
# Configuracion y variables: las mismas que backup_mlflow.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

PG_SVC="${PG_SERVICE:-postgres}"
ML_SVC="${MLFLOW_SERVICE:-mlflow}"
HELPER_IMG="${HELPER_IMAGE:-alpine:3.20}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=no
CLOSE_RUNNING=no
SAFETY=yes
IF_EMPTY=no
DO_LIST=no
SRC=""
# shellcheck source-path=SCRIPTDIR source=drive_common.sh
. "${SCRIPT_DIR}/drive_common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --yes | -y)         ASSUME_YES=yes ;;
        --close-running)    CLOSE_RUNNING=yes ;;
        --no-safety-backup) SAFETY=no ;;
        --if-empty)         IF_EMPTY=yes ;;
        --list)             DO_LIST=yes ;;
        -h | --help)        usage; exit 0 ;;
        -*)                 die "opcion desconocida: $1 (usa --help)" ;;
        *)                  SRC="${1%/}" ;;
    esac
    shift
done
if [ -n "${SRC}" ]; then
    SRC="$(basename "${SRC}")"
    case "${SRC}" in
        *.partial) die "${SRC} es un respaldo a medias: no se puede usar" ;;
        mlflow-backup-[0-9]*) ;;
        *) die "nombre de respaldo no valido: ${SRC} (usa --list)" ;;
    esac
fi

# --- Proyecto compose, configuracion y Drive -------------------------------
command -v docker >/dev/null || die "docker no esta instalado"
find_compose_dir
read_conf backup.env
if ! err="$(dc config --quiet 2>&1)"; then
    die "el docker-compose.yml de $(pwd) no es valido o falta su .env. Detalle: ${err}"
fi

WORK=""
STOPPED_ML=no
# shellcheck disable=SC2317 # la llama el trap
cleanup() {
    local status=$?
    if [ -n "${WORK}" ] && [ -d "${WORK}" ]; then rm -rf "${WORK}"; fi
    # Si algo fallo con MLflow detenido, se vuelve a levantar: con la base
    # vacia arranca como recien creado y el respaldo sigue intacto en Drive.
    if [ "${STOPPED_ML}" = yes ] && ! is_running "${ML_SVC}"; then
        log "Levantando de nuevo ${ML_SVC}"
        dc up -d "${ML_SVC}" >/dev/null || warn "no se pudo levantar ${ML_SVC}"
    fi
    cleanup_rclone
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

setup_rclone

# --- Listado -----------------------------------------------------------------
list_backups() {
    local found=no name m
    m="$(mktemp)"
    echo "Respaldos en ${DRIVE} (hora UTC):"
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        found=yes
        if rclone cat "${DRIVE}/${name}/manifest.txt" >"${m}" 2>/dev/null &&
            [ -n "$(rclone lsf "${DRIVE}/${name}/db.sql.gz" 2>/dev/null)" ]; then
            printf "  %-32s %s  exp=%s runs=%s artefactos=%s mlflow=%s\n" \
                "${name}" "$(mf created_at "${m}" | cut -c1-16)" "$(mf experiments "${m}")" \
                "$(mf runs "${m}")" "$(mf artifact_files "${m}")" "$(mf mlflow_version "${m}")"
        else
            printf "  %-32s INCOMPLETO (no usar)\n" "${name}"
        fi
    done < <(backup_names)
    rm -f "${m}"
    [ "${found}" = yes ] || echo "  (ninguno)"
}

if [ "${DO_LIST}" = yes ]; then
    list_backups
    exit 0
fi
take_lock 900

# --- Postgres arriba y, con --if-empty, ¿hace falta restaurar? ---------------
dc up -d "${PG_SVC}" >/dev/null
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

if [ "${IF_EMPTY}" = yes ] && ! db_is_empty; then
    echo "La base ya tiene datos ($(psql_q 'select count(*) from runs') corridas): no se restaura nada."
    exit 0
fi

# --- Resolver que se restaura ------------------------------------------------
if [ -z "${SRC}" ]; then
    SRC="$(backup_names | sed -n '1p')"
    if [ -z "${SRC}" ]; then
        if [ "${IF_EMPTY}" = yes ]; then
            echo "No hay respaldos en ${DRIVE}: MLflow arranca vacio."
            exit 0
        fi
        die "no hay respaldos en ${DRIVE} (usa --list)"
    fi
elif [ -z "$(backup_names | grep -x "${SRC}" || true)" ]; then
    die "no existe el respaldo '${SRC}' en ${DRIVE} (usa --list)"
fi

# --- Descargar y validar ANTES de tocar nada --------------------------------
WORK="$(mktemp -d "${WORK_DIR:-/var/tmp}/mlflow-restore.XXXXXX")"
log "Descargando ${SRC} de ${DRIVE}"
rclone copy "${DRIVE}/${SRC}" "${WORK}"
DB_FILE="${WORK}/db.sql.gz"
MANIFEST="${WORK}/manifest.txt"
AUTH_FILE=""
[ -f "${WORK}/auth.tar.gz" ] && AUTH_FILE="${WORK}/auth.tar.gz"
if [ ! -f "${DB_FILE}" ] || [ ! -f "${MANIFEST}" ]; then
    die "respaldo incompleto: faltan db.sql.gz o manifest.txt"
fi

log "Validando ${SRC}"
gzip -t "${DB_FILE}" || die "${DB_FILE} esta corrupto"
# '|| true': head corta la tuberia antes de que gunzip termine (SIGPIPE) y,
# con pipefail, eso abortaria el script sin mensaje.
HEAD="$(gunzip -c "${DB_FILE}" | head -c 4096 | tr -d '\0' || true)"
grep -q "PostgreSQL database dump" <<<"${HEAD}" || die "db.sql.gz no es un volcado SQL de pg_dump"
TAIL="$(gunzip -c "${DB_FILE}" | tail -n 20)"
grep -q "PostgreSQL database dump complete" <<<"${TAIL}" || die "db.sql.gz esta truncado: pg_dump no llego a terminar"
if [ -n "${AUTH_FILE}" ]; then gzip -t "${AUTH_FILE}" || die "auth.tar.gz esta corrupto"; fi

# --- Contenedor de MLflow y version ------------------------------------------
if [ -z "$(dc ps -a -q "${ML_SVC}" 2>/dev/null)" ]; then
    log "No existe el contenedor ${ML_SVC}: creandolo sin arrancarlo"
    dc up --no-start "${ML_SVC}"
fi
ML_CID="$(dc ps -a -q "${ML_SVC}")"
AUTH_VOL="$(docker inspect "${ML_CID}" --format \
    '{{range .Mounts}}{{if eq .Destination "/mlflow/auth"}}{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}')"

IMAGE_VERSION="$(docker run --rm --entrypoint python "$(docker inspect -f '{{.Image}}' "${ML_CID}")" -c \
    'import importlib.metadata as m; print(m.version("mlflow"))' 2>/dev/null || echo desconocida)"
BACKUP_VERSION="$(mf mlflow_version "${MANIFEST}")"
BACKUP_VERSION="${BACKUP_VERSION:-desconocida}"
NEWER=no
if [ "${BACKUP_VERSION}" != desconocida ] && [ "${IMAGE_VERSION}" != desconocida ] &&
    [ "${BACKUP_VERSION}" != "${IMAGE_VERSION}" ] &&
    [ "$(printf '%s\n%s\n' "${BACKUP_VERSION}" "${IMAGE_VERSION}" | sort -V | tail -n 1)" = "${BACKUP_VERSION}" ]; then
    NEWER=yes
fi

# --- Resumen y confirmacion ----------------------------------------------------
echo ""
echo "  Respaldo     : ${SRC} (${DRIVE})"
echo "  Creado       : $(mf created_at "${MANIFEST}") en $(mf host "${MANIFEST}")"
echo "  Contenido    : $(mf experiments "${MANIFEST}") experimentos, $(mf runs "${MANIFEST}") corridas, $(mf artifact_files "${MANIFEST}") artefactos"
echo "  MLflow       : respaldo ${BACKUP_VERSION}, imagen actual ${IMAGE_VERSION}"
echo "  Destino      : proyecto $(pwd), artefactos en ${ARTIFACTS_DESTINATION}"
echo ""
if [ "${NEWER}" = yes ]; then
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

# --- Respaldo de seguridad del estado actual -----------------------------------
CURRENT_RUNS="$(psql_q 'select count(*) from runs' 2>/dev/null || echo 0)"
SAFETY_NAME=""
if [ "${SAFETY}" = yes ] && ! db_is_empty; then
    log "Respaldo de seguridad del estado actual (${CURRENT_RUNS} corridas)"
    # Hereda el candado (MLFLOW_BACKUP_LOCK_HELD). KEEP=0: que la retencion no
    # borre justo el respaldo que se va a restaurar.
    SAFETY_OUT="$(KEEP=0 COMPOSE_DIR="$(pwd)" bash "${SCRIPT_DIR}/backup_mlflow.sh" --stop-server 2>&1)" ||
        { echo "${SAFETY_OUT}" >&2; die "fallo el respaldo de seguridad; no se toco nada"; }
    SAFETY_NAME="$(sed -n 's/^RESPALDO=//p' <<<"${SAFETY_OUT}")"
    log "Estado anterior guardado en ${SAFETY_NAME}"
fi

# --- Artefactos: los que falten, de Drive a S3 (con MLflow aun en marcha) ------
if has_files "${DRIVE}/artifacts"; then
    log "Copiando a S3 los artefactos que falten (${ARTIFACTS_DESTINATION})"
    rclone copy "${DRIVE}/artifacts" "${S3_ART}" --fast-list --transfers 4 --checkers 8 \
        "${RCLONE_PROGRESS[@]}"
else
    log "El respaldo no tiene artefactos"
fi

# --- A partir de aqui se modifican datos ---------------------------------------
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

log "Cargando el volcado SQL"
# --single-transaction: o entra todo o no entra nada.
gunzip -c "${DB_FILE}" |
    dc exec -T "${PG_SVC}" psql -U "${PGUSER}" -d "${PGDB}" -v ON_ERROR_STOP=1 \
        --single-transaction -q >/dev/null ||
    die "fallo la carga del volcado. La base quedo VACIA: vuelve a ejecutar el restore${SAFETY_NAME:+ (el estado anterior esta en ${SAFETY_NAME})}"

if [ "${CLOSE_RUNNING}" = yes ]; then
    CLOSED="$(psql_q "WITH c AS (UPDATE runs SET status = 'KILLED',
        end_time = COALESCE(end_time, (EXTRACT(EPOCH FROM now()) * 1000)::bigint)
        WHERE status = 'RUNNING' RETURNING 1) SELECT count(*) FROM c")"
    log "Corridas huerfanas cerradas como KILLED: ${CLOSED}"
fi

if [ -n "${AUTH_FILE}" ] && [ -n "${AUTH_VOL}" ]; then
    log "Restaurando usuarios de basic-auth"
    docker run --rm -v "${AUTH_VOL}":/data -v "${WORK}":/backup:ro "${HELPER_IMG}" \
        sh -c "find /data -mindepth 1 -delete && tar xzf /backup/auth.tar.gz -C /data"
fi

# --- Levantar MLflow (up, no start: asi recoge el .env actual) ---------------------
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
    die "MLflow no responde tras restaurar (logs arriba). Los datos estan cargados; revisa la configuracion."
fi

# --- Verificacion contra el manifiesto --------------------------------------------
EXP_NOW="$(psql_q 'select count(*) from experiments')"
RUNS_NOW="$(psql_q 'select count(*) from runs')"
RUNNING_NOW="$(psql_q "select count(*) from runs where status = 'RUNNING'")"
FILES_NOW=0
if has_files "${S3_ART}"; then
    FILES_NOW="$(rclone size --json --fast-list "${S3_ART}" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
fi

MISMATCH=no
check() { # $1 etiqueta, $2 actual, $3 esperado
    if [ -z "$3" ]; then
        printf "  %-14s %s\n" "$1" "$2"
    elif [ "$2" = "$3" ]; then
        printf "  %-14s %s  OK\n" "$1" "$2"
    else
        printf "  %-14s %s  ESPERADO %s\n" "$1" "$2" "$3"
        MISMATCH=yes
    fi
}
echo ""
echo "Restauracion terminada. Verificacion:"
check experimentos "${EXP_NOW}" "$(mf experiments "${MANIFEST}")"
check corridas "${RUNS_NOW}" "$(mf runs "${MANIFEST}")"
# En S3 puede haber mas artefactos que en el respaldo (los que ya estaban),
# nunca menos.
ART_EXPECTED="$(mf artifact_files "${MANIFEST}")"
if [ "${FILES_NOW}" -ge "${ART_EXPECTED:-0}" ]; then
    printf "  %-14s %s en S3 (respaldo: %s)  OK\n" artefactos "${FILES_NOW}" "${ART_EXPECTED:-?}"
else
    printf "  %-14s %s en S3  ESPERADOS al menos %s\n" artefactos "${FILES_NOW}" "${ART_EXPECTED}"
    MISMATCH=yes
fi
printf "  %-14s %s\n" "en RUNNING" "${RUNNING_NOW}"
if [ -n "${SAFETY_NAME}" ]; then echo "  Estado previo guardado en: ${SAFETY_NAME}"; fi
if [ "${RUNNING_NOW}" -gt 0 ] && [ "${CLOSE_RUNNING}" = no ]; then
    echo "  Hay corridas en RUNNING; si nadie entrena, cierralas con --close-running."
fi
[ "${MISMATCH}" = no ] || die "los conteos no coinciden con el manifiesto"

# El estado restaurado pasa a ser el ultimo respaldo. Si no, tras volver a un
# respaldo antiguo el mas reciente seria el de seguridad, y si el lab se
# reinicia antes del respaldo horario el deploy restauraria ese y no este.
# Si ya es el ultimo, el backup solo dice "sin cambios".
log "Guardando el estado restaurado como ultimo respaldo"
if POST_OUT="$(COMPOSE_DIR="$(pwd)" bash "${SCRIPT_DIR}/backup_mlflow.sh" 2>&1)"; then
    log "Ultimo respaldo: $(sed -n 's/^RESPALDO=//p' <<<"${POST_OUT}")"
else
    echo "${POST_OUT}" >&2
    warn "no se pudo respaldar el estado restaurado; lo hara el respaldo horario"
fi
echo "RESTAURADO=${SRC}"
exit 0
