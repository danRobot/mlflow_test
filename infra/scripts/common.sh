# shellcheck shell=bash
# ---------------------------------------------------------------------------
# common.sh - Funciones comunes de backup_mlflow.sh y restore_mlflow.sh.
# No se ejecuta solo: lo cargan los dos scripts con '.'.
# ---------------------------------------------------------------------------

log()  { echo "==> $*"; }
warn() { echo "AVISO: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }
dc()   { docker compose "$@"; }
is_running() { [ -n "$(dc ps --status running -q "$1" 2>/dev/null)" ]; }
mf()   { sed -n "s/^$1=//p" "$2" 2>/dev/null | sed -n '1p'; }
mb()   { awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1048576 }'; }

has_compose() {
    local f
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        [ -f "$1/$f" ] && return 0
    done
    return 1
}

# El .env se lee del directorio de proyecto del compose, asi que hay que estar
# ahi. En la EC2 los scripts estan en /opt/mlflow/scripts y el compose en
# /opt/mlflow.
find_compose_dir() {
    if [ -n "${COMPOSE_DIR:-}" ]; then
        has_compose "${COMPOSE_DIR}" || die "COMPOSE_DIR=${COMPOSE_DIR} no contiene un docker-compose.yml"
        cd "${COMPOSE_DIR}" || die "no se pudo entrar en ${COMPOSE_DIR}"
        return
    fi
    has_compose "." && return
    local d="${SCRIPT_DIR}"
    while [ "${d}" != "/" ]; do
        if has_compose "${d}"; then
            cd "${d}" || die "no se pudo entrar en ${d}"
            return
        fi
        d="$(dirname "${d}")"
    done
    die "no encuentro el docker-compose.yml. Ejecuta el script desde su carpeta o usa COMPOSE_DIR=/ruta"
}

# backup.env lo escribe deploy.sh junto al docker-compose.yml. Se lee linea a
# linea sin ejecutarlo (no se hace 'source'), y el entorno tiene prioridad.
read_conf() {
    local file="${1:-backup.env}" key value
    [ -f "${file}" ] || return 0
    while IFS='=' read -r key value || [ -n "${key}" ]; do
        case "${key}" in
            ARTIFACTS_DESTINATION | AWS_REGION)
                [ -n "${!key:-}" ] || printf -v "${key}" '%s' "${value}"
                ;;
        esac
    done <"${file}"
}

# Un solo respaldo o restauracion a la vez.
take_lock() {
    exec 9>"${MLFLOW_BACKUP_LOCK:-/run/mlflow-backup.lock}"
    flock -w 60 9 || die "hay otro respaldo o restauracion en curso"
}

# Bucket de MLflow, a partir de ARTIFACTS_DESTINATION (s3://<bucket>/artifacts).
# Los respaldos van en la carpeta backup/ del mismo bucket.
BUCKET=""
setup_s3() {
    command -v aws >/dev/null || die "falta la AWS CLI"
    [ -n "${AWS_REGION:-}" ] || die "falta AWS_REGION en backup.env"
    case "${ARTIFACTS_DESTINATION:-}" in
        s3://?*/artifacts) ;;
        *) die "ARTIFACTS_DESTINATION debe ser s3://<bucket>/artifacts (es '${ARTIFACTS_DESTINATION:-}')" ;;
    esac
    BUCKET="${ARTIFACTS_DESTINATION#s3://}"
    BUCKET="${BUCKET%/artifacts}"
    export AWS_DEFAULT_REGION="${AWS_REGION}"
    aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1 ||
        die "no se puede acceder al bucket ${BUCKET} (no existe o el rol de la EC2 no tiene permiso)"
}

# Archivos y bytes bajo un prefijo de S3: "archivos bytes".
s3_summary() {
    aws s3 ls "$1" --recursive --summarize |
        awk '/^ *Total Objects:/ { n = $3 } /^ *Total Size:/ { b = $3 } END { print n + 0, b + 0 }'
}

# Respaldos en s3://<bucket>/backup/, del mas nuevo al mas viejo POR NOMBRE
# (lleva la fecha). Solo los .7z de la carpeta, no los de subcarpetas.
backup_names() {
    aws s3api list-objects-v2 --bucket "${BUCKET}" --prefix backup/backup_mlflow_ \
        --query "Contents[?ends_with(Key, '.7z')].Key" --output text |
        tr '\t' '\n' | sed -n 's#^backup/\([^/]*\)$#\1#p' | sort -r
}

# 7-Zip: deploy.sh instala el paquete 7zip de Amazon Linux (comando 7z).
SEVENZ=""
find_7z() {
    local c
    for c in 7z 7zz 7za; do
        if command -v "${c}" >/dev/null; then
            SEVENZ="${c}"
            return
        fi
    done
    die "falta 7-Zip (lo instala deploy.sh: dnf install 7zip)"
}
# Con baja prioridad de CPU y disco: MLflow sigue atendiendo mientras tanto.
sz() { nice -n 19 ionice -c 2 -n 7 "${SEVENZ}" "$@"; }

# El bucket se monta en solo lectura (Mountpoint for Amazon S3) solo mientras
# dura el respaldo o la restauracion. mount-s3 usa el rol de la EC2.
MNT="${MOUNT_DIR:-/mnt/mlflow-s3}"
MOUNTED=no
# Por /proc/mounts y no con mountpoint: si mount-s3 murio (por ejemplo, al
# cancelar), el montaje queda colgado y mountpoint dice que no esta montado.
is_mounted() { grep -qs " ${MNT} " /proc/mounts; }
mount_bucket() {
    command -v mount-s3 >/dev/null || die "falta mount-s3 (lo instala deploy.sh: dnf install mount-s3)"
    # Resto de una ejecucion cortada de golpe (antes de mkdir: en un montaje
    # colgado, mkdir falla con "Transport endpoint is not connected").
    if is_mounted; then umount "${MNT}" 2>/dev/null || umount -l "${MNT}"; fi
    mkdir -p "${MNT}"
    log "Montando s3://${BUCKET} en ${MNT} (solo lectura, mientras dura el proceso)"
    mount-s3 --read-only --region "${AWS_REGION}" "${BUCKET}" "${MNT}" >/dev/null ||
        die "no se pudo montar s3://${BUCKET} en ${MNT}"
    MOUNTED=yes
}
unmount_bucket() {
    [ "${MOUNTED}" = yes ] || return 0
    if is_mounted; then
        umount "${MNT}" 2>/dev/null || umount -l "${MNT}" || warn "no se pudo desmontar ${MNT}"
    fi
    MOUNTED=no
}

# Espacio libre en el disco de $1, en bytes.
free_bytes() { df -PB1 "$1" | awk 'NR == 2 { print $4 }'; }
need_space() { # $1 carpeta, $2 bytes necesarios, $3 para que
    local free
    free="$(free_bytes "$1")"
    if [ "${free}" -lt "$2" ]; then
        die "no hay espacio en el disco de la EC2 (${1}): hacen falta $(mb "$2") para $3 y quedan $(mb "${free}") libres"
    fi
}

# --- Postgres (pg_dump y psql corren dentro del contenedor) ------------------
wait_postgres() {
    for _ in $(seq 1 30); do
        dc exec -T "${PG_SVC}" pg_isready -q >/dev/null 2>&1 && break
        sleep 2
    done
    dc exec -T "${PG_SVC}" pg_isready -q >/dev/null 2>&1 || die "${PG_SVC} no acepta conexiones"
    PGUSER="$(dc exec -T "${PG_SVC}" printenv POSTGRES_USER 2>/dev/null || true)"
    PGUSER="${PGUSER:-postgres}"
    PGDB="$(dc exec -T "${PG_SVC}" printenv POSTGRES_DB 2>/dev/null || true)"
    PGDB="${PGDB:-${PGUSER}}"
}
psql_q() { dc exec -T "${PG_SVC}" psql -U "${PGUSER}" -d "${PGDB}" -tAc "$1"; }

# Una base "vacia" es la de un MLflow recien creado: sin corridas, sin modelos
# registrados y solo con el experimento Default.
db_is_empty() {
    [ "$(psql_q "select to_regclass('public.runs') is not null")" = t ] || return 0
    [ "$(psql_q "select (select count(*) from runs)
        + (select count(*) from experiments where name <> 'Default')
        + (select count(*) from registered_models)")" = 0 ]
}

# Version de MLflow de la imagen del contenedor (aunque este detenido).
image_mlflow_version() {
    local cid
    cid="$(dc ps -a -q "${ML_SVC}" 2>/dev/null || true)"
    [ -n "${cid}" ] || { echo desconocida; return; }
    docker run --rm --entrypoint python "$(docker inspect -f '{{.Image}}' "${cid}")" -c \
        'import importlib.metadata as m; print(m.version("mlflow"))' 2>/dev/null || echo desconocida
}
