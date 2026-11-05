# shellcheck shell=bash
# ---------------------------------------------------------------------------
# drive_common.sh - Funciones comunes de backup_mlflow.sh y restore_mlflow.sh.
# No se ejecuta solo: lo cargan los dos scripts con '.'.
# ---------------------------------------------------------------------------

# rclone lo instala deploy.sh en /usr/local/bin, que SSM no siempre tiene en
# el PATH.
case ":${PATH}:" in *:/usr/local/bin:*) ;; *) PATH="/usr/local/bin:${PATH}" ;; esac

log()  { echo "==> $*"; }
warn() { echo "AVISO: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }
dc()   { docker compose "$@"; }
is_running() { [ -n "$(dc ps --status running -q "$1" 2>/dev/null)" ]; }
mf()   { sed -n "s/^$1=//p" "$2" 2>/dev/null | sed -n '1p'; }

# Resumen de rclone: una linea al final y otra por minuto si tarda.
# shellcheck disable=SC2034 # lo usan los scripts que cargan este archivo
RCLONE_PROGRESS=(--stats-one-line --stats-log-level NOTICE --stats 1m)

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
            GDRIVE_PARAMETER | GDRIVE_FOLDER | ARTIFACTS_DESTINATION | AWS_REGION | KEEP)
                [ -n "${!key:-}" ] || printf -v "${key}" '%s' "${value}"
                ;;
        esac
    done <"${file}"
}

# Un solo respaldo o restauracion a la vez (timer, apagado, workflows). Un
# script lanzado por otro que ya tiene el candado no lo vuelve a pedir.
take_lock() {
    [ "${MLFLOW_BACKUP_LOCK_HELD:-}" = 1 ] && return 0
    local lock="${MLFLOW_BACKUP_LOCK:-/run/mlflow-backup.lock}"
    exec 9>"${lock}"
    flock -w "${1:-900}" 9 || die "hay otro respaldo o restauracion en curso (${lock})"
    export MLFLOW_BACKUP_LOCK_HELD=1
}

# Prepara las dos puntas de rclone:
#   DRIVE  = <remote>:<GDRIVE_FOLDER>. La configuracion de rclone (secret
#            GDRIVE_RCLONE_CONF) se lee de Parameter Store a un archivo en
#            /run, que esta en memoria, y se borra al terminar.
#   S3_ART = los artefactos de MLflow en S3, con el rol de la EC2.
RCLONE_TMP=""
setup_rclone() {
    [ -n "${GDRIVE_PARAMETER:-}" ] ||
        die "Google Drive no esta configurado: crea el secret GDRIVE_RCLONE_CONF (ver README) y vuelve a lanzar deploy"
    command -v rclone >/dev/null || die "rclone no esta instalado (lo instala deploy.sh)"
    command -v aws >/dev/null || die "falta la AWS CLI"
    [ -n "${AWS_REGION:-}" ] || die "falta AWS_REGION en backup.env"
    case "${ARTIFACTS_DESTINATION:-}" in
        s3://?*) ;;
        *) die "ARTIFACTS_DESTINATION debe ser s3://bucket/ruta (es '${ARTIFACTS_DESTINATION:-}')" ;;
    esac

    RCLONE_TMP="$(mktemp -d "${RCLONE_TMPDIR:-/run}/mlflow-rclone.XXXXXX")"
    export RCLONE_CONFIG="${RCLONE_TMP}/rclone.conf"
    if ! (umask 077 && aws ssm get-parameter --region "${AWS_REGION}" --name "${GDRIVE_PARAMETER}" \
        --with-decryption --query Parameter.Value --output text >"${RCLONE_CONFIG}"); then
        die "no se pudo leer ${GDRIVE_PARAMETER} de Parameter Store"
    fi
    local remote
    remote="$(sed -n 's/^[[:space:]]*\[\([^]]*\)\][[:space:]]*$/\1/p' "${RCLONE_CONFIG}" | sed -n '1p')"
    [ -n "${remote}" ] ||
        die "GDRIVE_RCLONE_CONF no es una configuracion de rclone: debe empezar con [nombre] (copia la salida completa de 'rclone config show')"
    DRIVE="${remote}:${GDRIVE_FOLDER:-mlflow-backups}"

    # rclone no distingue "el bucket no existe" de "no hay artefactos todavia"
    # (los dos son "directory not found"), asi que el bucket se comprueba aparte.
    local bucket="${ARTIFACTS_DESTINATION#s3://}"
    bucket="${bucket%%/*}"
    aws s3api head-bucket --region "${AWS_REGION}" --bucket "${bucket}" >/dev/null 2>&1 ||
        die "no se puede acceder al bucket ${bucket} (no existe o el rol de la EC2 no tiene permiso)"
    export RCLONE_CONFIG_S3ART_TYPE=s3 RCLONE_CONFIG_S3ART_PROVIDER=AWS \
        RCLONE_CONFIG_S3ART_ENV_AUTH=true RCLONE_CONFIG_S3ART_REGION="${AWS_REGION}" \
        RCLONE_CONFIG_S3ART_NO_CHECK_BUCKET=true
    # shellcheck disable=SC2034 # lo usan los scripts que cargan este archivo
    S3_ART="s3art:${ARTIFACTS_DESTINATION#s3://}"

    # Comprueba el acceso (token valido) y crea la carpeta si no existe.
    rclone mkdir "${DRIVE}" ||
        die "no se pudo acceder a Google Drive (${DRIVE}). Si el token caduco o se revoco, genera de nuevo el secret GDRIVE_RCLONE_CONF (ver README) y lanza deploy"
}

cleanup_rclone() {
    if [ -n "${RCLONE_TMP}" ]; then
        rm -rf "${RCLONE_TMP}"
    fi
}

# Respaldos completos en Drive, del mas nuevo al mas viejo POR NOMBRE (lleva
# la fecha). Las carpetas .partial son respaldos a medias y no cuentan.
backup_names() {
    rclone lsf --dirs-only "${DRIVE}" |
        sed -n 's#^\(mlflow-backup-[0-9]\{8\}-[0-9]\{6\}\)/$#\1#p' | sort -r
}

# ¿Hay archivos en esa ruta de rclone? Una carpeta que no existe (o un prefijo
# de S3 sin objetos) da "directory not found", codigo 3: eso es "no hay".
# Cualquier otro error (permisos, red, token) detiene el script: no se puede
# confundir con "no hay artefactos" y seguir con un respaldo incompleto.
has_files() {
    local out status=0
    out="$(rclone lsf --max-depth 1 "$1" 2>&1)" || status=$?
    case "${status}" in
        0) [ -n "${out}" ] ;;
        3) return 1 ;;
        *) die "no se pudo leer $1: ${out}" ;;
    esac
}

# Una base "vacia" es la de un MLflow recien creado: sin corridas, sin modelos
# registrados y solo con el experimento Default. Necesita psql_q.
db_is_empty() {
    [ "$(psql_q "select to_regclass('public.runs') is not null")" = t ] || return 0
    [ "$(psql_q "select (select count(*) from runs)
        + (select count(*) from experiments where name <> 'Default')
        + (select count(*) from registered_models)")" = 0 ]
}
