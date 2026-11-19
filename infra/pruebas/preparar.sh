#!/usr/bin/env bash
# preparar.sh - Deja lista la EC2 de pruebas (Ubuntu 24.04) para el usuario
# ubuntu: Google Colab CLI (colab) y runpodctl, una llave SSH para los dos, el
# repo EvidenCite en ~/EvidenCite y las variables del proyecto en ~/.bashrc.
#
# La lanza el workflow deploy por SSM, como root, despues de escribir
# /opt/pruebas/config (MLFLOW_TRACKING_URI y los nombres de los parametros).
# Se puede repetir a mano desde la instancia:
#   sudo bash /opt/pruebas/preparar.sh
#
# Los secretos vienen de Parameter Store, donde los deja Terraform con los
# secrets de GitHub. No se imprimen.
#
# Solo termina con error si no puede leer la configuracion o los secretos. Lo
# demas (instalar colab o runpodctl, clonar, `colab --help`, `runpodctl pod
# list`) deja un AVISO y sigue: el deploy de MLflow no depende de esta maquina.
set -uo pipefail

CONF=/opt/pruebas/config
USUARIO=ubuntu
REPO_URL=https://github.com/d-leandro/EvidenCite
SELF="$(readlink -f "$0")"
MARCA_INI="# >>> EC2 de pruebas: variables del deploy (las reescribe /opt/pruebas/preparar.sh) >>>"
MARCA_FIN="# <<< EC2 de pruebas <<<"
AVISOS=0

paso() { echo; echo "== $*"; }
aviso() { echo "AVISO: $*"; AVISOS=$((AVISOS + 1)); }
falla() { echo "ERROR: $*"; exit 1; }

# --- Como ubuntu: herramientas, llave, repo y comprobaciones ------------------
como_usuario() {
    cd "$HOME" || exit 1
    export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin"

    paso "uv y Google Colab CLI"
    if ! command -v uv >/dev/null; then
        # El binario oficial de GitHub (lo mismo que baja el instalador de astral.sh).
        mkdir -p "$HOME/.local/bin"
        if curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-$(uname -m)-unknown-linux-gnu.tar.gz" |
            tar -xz --strip-components=1 -C "$HOME/.local/bin"; then
            echo "$(uv --version) en ~/.local/bin"
        else
            aviso "no se pudo instalar uv"
        fi
    fi
    if command -v uv >/dev/null; then
        # Instala o actualiza; el ejecutable queda en ~/.local/bin/colab.
        if uv tool install --quiet --upgrade google-colab-cli; then
            echo "colab $(colab version 2>/dev/null | tail -n 1)"
        else
            aviso "no se pudo instalar google-colab-cli"
        fi
        uv cache clean --quiet >/dev/null 2>&1 || true
    fi

    paso "Llave SSH (colab ssh y pods de RunPod)"
    if [ -f "$HOME/.ssh/id_ed25519" ]; then
        echo "Ya existe ~/.ssh/id_ed25519."
    else
        install -d -m 700 "$HOME/.ssh"
        if ssh-keygen -q -t ed25519 -N "" -C "mlflow-pruebas-${INSTANCE_ID:-$(hostname)}" -f "$HOME/.ssh/id_ed25519"; then
            echo "Llave nueva: ~/.ssh/id_ed25519 (colab ssh la usa sin opciones)."
        else
            aviso "no se pudo crear la llave SSH"
        fi
    fi
    if [ -z "${RUNPOD_API_KEY:-}" ]; then
        aviso "sin RUNPOD_API_KEY: la llave no se registra en RunPod"
    elif ! command -v runpodctl >/dev/null; then
        aviso "runpodctl no esta instalado: la llave no se registra en RunPod"
    elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        cuerpo=$(awk '{print $2}' "$HOME/.ssh/id_ed25519.pub")
        if timeout 60 runpodctl ssh list-keys </dev/null 2>/dev/null | grep -qF "$cuerpo"; then
            echo "La llave ya esta registrada en RunPod."
        elif salida=$(timeout 60 runpodctl ssh add-key --key-file "$HOME/.ssh/id_ed25519.pub" </dev/null 2>&1) ||
            grep -qi 'already registered' <<<"$salida"; then
            echo "Llave registrada en tu cuenta de RunPod: los pods nuevos la aceptan."
        else
            aviso "no se pudo registrar la llave en RunPod: $(head -c 300 <<<"$salida")"
        fi
    fi

    paso "Repo EvidenCite"
    if [ -d "$HOME/EvidenCite/.git" ]; then
        if git -C "$HOME/EvidenCite" fetch --quiet --all --prune; then
            echo "Ya estaba en ~/EvidenCite: se actualizaron las ramas remotas (tu copia de trabajo no se toca)."
        else
            aviso "no se pudo actualizar ~/EvidenCite (git fetch)"
        fi
    elif git clone --quiet "$REPO_URL" "$HOME/EvidenCite"; then
        echo "Clonado en ~/EvidenCite ($(git -C "$HOME/EvidenCite" branch --show-current))."
    else
        aviso "no se pudo clonar $REPO_URL"
    fi

    paso "Comprobaciones"
    if salida=$(timeout 120 colab --help 2>&1); then
        echo "colab --help: OK. Falta autenticar (una vez, a mano): ver el final."
    else
        aviso "colab --help fallo: $(tail -n 3 <<<"$salida")"
    fi
    if [ -z "${RUNPOD_API_KEY:-}" ]; then
        aviso "runpodctl pod list no se probo: falta el secret RUNPOD_API_KEY"
    elif salida=$(timeout 60 runpodctl pod list </dev/null 2>&1); then
        pods=$(python3 -c 'import json, sys; print(len(json.load(sys.stdin)))' <<<"$salida" 2>/dev/null || echo "?")
        echo "runpodctl pod list: OK (${pods} pods en marcha)."
    else
        aviso "runpodctl pod list fallo: $(head -c 300 <<<"$salida")"
    fi
    exit "$((AVISOS > 100 ? 100 : AVISOS))"
}

# --- Como root ----------------------------------------------------------------
if [ "${1:-}" = --usuario ]; then
    como_usuario
fi

[ "$(id -u)" -eq 0 ] || falla "corre como root: sudo bash $SELF"
id "$USUARIO" >/dev/null 2>&1 || falla "no existe el usuario $USUARIO (la AMI debe ser de Ubuntu)"
[ -f "$CONF" ] || falla "falta $CONF: lo escribe el workflow deploy"
set -a # exporta lo que lea de la configuracion
# shellcheck source=/dev/null
. "$CONF"
set +a
: "${AWS_REGION:?falta AWS_REGION en $CONF}" "${ENV_PARAMETER:?falta ENV_PARAMETER en $CONF}"
export HOME=/root INSTANCE_ID="${INSTANCE_ID:-}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
CASA=$(getent passwd "$USUARIO" | cut -d: -f6)

paso "Swap de 1 GB (margen contra falta de memoria)"
if [ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]; then
    echo "Ya hay swap."
else
    if [ ! -f /swapfile ] && ! { fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null; }; then
        rm -f /swapfile
        aviso "no se pudo crear /swapfile"
    fi
    if swapon /swapfile 2>/dev/null; then
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
        echo "Swap activa."
    else
        aviso "no se pudo activar la swap: la maquina sigue, con menos margen de memoria"
    fi
fi

paso "AWS CLI"
if ! command -v aws >/dev/null; then
    snap install aws-cli --classic >/dev/null || falla "no se pudo instalar la AWS CLI (snap install aws-cli --classic)"
fi
aws --version

paso "Secretos (Parameter Store)"
param() { aws ssm get-parameter --region "$AWS_REGION" --name "$1" --with-decryption --query Parameter.Value --output text; }
SECRETOS=$(param "$ENV_PARAMETER") || falla "no se pudo leer $ENV_PARAMETER"
SA_JSON=""
if [ -n "${SA_PARAMETER:-}" ]; then
    SA_JSON=$(param "$SA_PARAMETER") || falla "no se pudo leer $SA_PARAMETER"
fi
export SECRETOS

# Llave de la service account de DVC: ~/claves/evidencitedvc-sa.json, solo para ubuntu.
LLAVE="$CASA/claves/evidencitedvc-sa.json"
CON_SA=0
if [ -z "$SA_JSON" ]; then
    rm -f "$LLAVE"
elif ! python3 -c 'import json, sys; json.loads(sys.stdin.read())' <<<"$SA_JSON" 2>/dev/null; then
    aviso "el secret GDRIVE_JSON no es un JSON valido: no se escribe $LLAVE"
else
    install -d -m 700 -o "$USUARIO" -g "$USUARIO" "$CASA/claves"
    (umask 077 && printf '%s\n' "$SA_JSON" >"$LLAVE") && chown "$USUARIO:" "$LLAVE" && CON_SA=1 &&
        echo "Llave de la service account en ~/claves/evidencitedvc-sa.json"
fi
unset SA_JSON

# Bloque de variables al principio de ~/.bashrc, antes del corte para shells no
# interactivas: asi tambien las ven los comandos por ssh o con `bash -lc`.
# Cada valor va entre comillas de shell (shlex.quote). Sin el secret, no hay linea.
FALTAN=$(CON_SA=$CON_SA python3 - "$CASA/.bashrc" "$MARCA_INI" "$MARCA_FIN" <<'PY'
import json, os, shlex, sys

ruta, ini, fin = sys.argv[1:4]
secretos = json.loads(os.environ.get("SECRETOS") or "{}")
lineas, faltan = [ini], []

def desde_secret(nombre, secret):
    valor = secretos.get(nombre, "")
    if valor:
        lineas.append(f"export {nombre}={shlex.quote(valor)}")
    else:
        faltan.append(f"{nombre} (secret {secret})")

desde_secret("HF_TOKEN", "HF_TOKEN")
desde_secret("MLFLOW_TRACKING_USERNAME", "MLFLOW_USER")
desde_secret("MLFLOW_TRACKING_PASSWORD", "MLFLOW_AUTH_PASSWORD")
uri = os.environ.get("MLFLOW_TRACKING_URI", "")
if uri:
    lineas += [
        f"export MLFLOW_TRACKING_URI={shlex.quote(uri)}",
        'export IP_MLFLOW="$MLFLOW_TRACKING_URI"',
        'export MLFLOW_IP="$MLFLOW_TRACKING_URI"',
    ]
else:
    faltan.append("MLFLOW_TRACKING_URI (IP del deploy)")
for nombre in ("RUNPOD_API_KEY", "ID_CARPETA", "GDRIVE_CLIENT_ID", "GDRIVE_CLIENT_SECRET"):
    desde_secret(nombre, nombre)
if os.environ.get("CON_SA") == "1":
    lineas.append('export GDRIVE_SA_JSON="$HOME/claves/evidencitedvc-sa.json"')
else:
    faltan.append("GDRIVE_SA_JSON (secret GDRIVE_JSON)")
lineas += [
    'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac',
    fin,
]

# Quita el bloque anterior (si lo hay) y pone el nuevo al principio.
try:
    with open(ruta, encoding="utf-8") as f:
        actual = f.read().splitlines()
except FileNotFoundError:
    actual = []
resto, dentro = [], False
for linea in actual:
    if linea == ini:
        dentro = True
    elif dentro and linea == fin:
        dentro = False
    elif not dentro:
        resto.append(linea)
while resto and not resto[0].strip():
    resto.pop(0)
with open(ruta + ".nuevo", "w", encoding="utf-8") as f:
    f.write("\n".join(lineas + [""] + resto) + "\n")
os.replace(ruta + ".nuevo", ruta)
print(", ".join(faltan))
PY
) || falla "no se pudo escribir $CASA/.bashrc"
# Tiene secretos: solo ubuntu lo lee.
chown "$USUARIO:" "$CASA/.bashrc" && chmod 600 "$CASA/.bashrc"
echo "Variables en ~/.bashrc (exportadas al principio del archivo)."
[ -z "$FALTAN" ] || aviso "faltan secrets, esas variables no quedan en ~/.bashrc: $FALTAN"

RUNPOD_API_KEY=$(python3 -c 'import json, os; print(json.loads(os.environ["SECRETOS"] or "{}").get("RUNPOD_API_KEY", ""))')
export RUNPOD_API_KEY
unset SECRETOS

paso "runpodctl"
if command -v runpodctl >/dev/null; then
    echo "Ya instalado: $(runpodctl version 2>/dev/null)"
else
    case "$(uname -m)" in
        x86_64) arq=amd64 ;;
        aarch64) arq=arm64 ;;
        *) arq="" ;;
    esac
    if [ -n "$arq" ] && curl -fsSL -o /usr/local/bin/runpodctl.nuevo \
        "https://github.com/runpod/runpodctl/releases/latest/download/runpodctl-linux-${arq}"; then
        chmod 755 /usr/local/bin/runpodctl.nuevo && mv /usr/local/bin/runpodctl.nuevo /usr/local/bin/runpodctl
        echo "Instalado: $(runpodctl version 2>/dev/null)"
    else
        rm -f /usr/local/bin/runpodctl.nuevo
        aviso "no se pudo instalar runpodctl"
    fi
fi

# El resto, como ubuntu (hereda RUNPOD_API_KEY por el entorno, no por argumentos).
runuser -u "$USUARIO" -- env HOME="$CASA" USER="$USUARIO" LOGNAME="$USUARIO" bash "$SELF" --usuario
AVISOS=$((AVISOS + $?))

paso "Resumen"
free -m | awk '/^Mem:/ { printf "Memoria: %d MB usados de %d MB", $3, $2 } /^Swap:/ { printf "; swap %d de %d MB\n", $3, $2 }'
df -h / | awk 'NR == 2 { print "Disco: " $3 " usados de " $2 " (" $5 ")" }'
echo "Para entrar: Session Manager y luego 'sudo -iu ubuntu'."
echo "Colab pide autenticar una vez: corre 'colab sessions', abre el enlace, autoriza y pega el codigo."
if [ "$AVISOS" -eq 0 ]; then
    echo "LISTO: EC2 de pruebas preparada."
else
    echo "LISTO CON AVISOS ($AVISOS): revisa las lineas AVISO de arriba."
fi
exit 0
