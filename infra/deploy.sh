#!/usr/bin/env bash
# Corre en la EC2 como root; lo lanza el workflow de deploy por SSM.
# Idempotente: la primera vez instala Docker, despues solo actualiza el stack.
set -euo pipefail

: "${MLFLOW_IMAGE:?}" "${MLFLOW_PUBLIC_HOST:?}" "${ARTIFACTS_BUCKET:?}" "${AWS_REGION:?}" "${POSTGRES_PARAMETER:?}"
: "${SERVER_LOG_GROUP:?}" # accesos de MLflow en CloudWatch (driver awslogs del compose)
LOG_GROUP="${LOG_GROUP:-}"
AUTH_PARAMETER="${AUTH_PARAMETER:-}" # vacio: MLflow sin autenticacion
COMPOSE_VERSION=v2.40.3
export HOME="${HOME:-/root}" # SSM no siempre define HOME y docker lo necesita
cd /opt/mlflow

# 1) Docker, docker compose, 7-Zip y Mountpoint para S3 (solo si faltan)
if ! command -v docker >/dev/null; then
    dnf install -y -q docker
    systemctl enable --now docker
fi
if ! docker compose version >/dev/null 2>&1; then
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL --retry 5 -o /usr/local/lib/docker/cli-plugins/docker-compose \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64"
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi
# Para los respaldos en S3 (scripts/): 7z comprime y mount-s3 monta el bucket
# mientras dura un respaldo o una restauracion. Los dos estan en los
# repositorios de Amazon Linux 2023; si la AMI es anterior a esos paquetes,
# se toman de la ultima version de los repositorios.
if ! command -v 7z >/dev/null || ! command -v mount-s3 >/dev/null; then
    dnf install -y -q 7zip mount-s3 || dnf install -y -q --releasever=latest 7zip mount-s3
fi

# 2) .env de compose. La clave de Postgres es la del secret POSTGRES_PASSWORD
#    (llega por SSM) y queda tambien aqui para usarla desde la instancia.
umask 077
POSTGRES_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$POSTGRES_PARAMETER" \
    --with-decryption --query Parameter.Value --output text)
rm -f secrets.env # clave aleatoria de versiones anteriores

# Autenticacion de MLflow: con AUTH_PARAMETER (variable AUTH en S y los
# secrets MLFLOW_USER y MLFLOW_AUTH_PASSWORD), "usuario:clave" va al archivo
# que compose monta como secret; sin el, el archivo queda vacio. MLFLOW_AUTH
# es una huella de las credenciales: si cambian, o se activa o desactiva la
# autenticacion, compose recrea el contenedor de MLflow.
if [ -n "$AUTH_PARAMETER" ]; then
    MLFLOW_CREDENTIALS=$(aws ssm get-parameter --region "$AWS_REGION" --name "$AUTH_PARAMETER" \
        --with-decryption --query Parameter.Value --output text)
    printf '%s' "$MLFLOW_CREDENTIALS" >mlflow-auth
    MLFLOW_AUTH="on-$(printf '%s' "$MLFLOW_CREDENTIALS" | sha256sum | cut -c1-16)"
    unset MLFLOW_CREDENTIALS
else
    : >mlflow-auth
    MLFLOW_AUTH=off
fi
{
    echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
    echo "MLFLOW_IMAGE=${MLFLOW_IMAGE}"
    echo "MLFLOW_PUBLIC_HOST=${MLFLOW_PUBLIC_HOST}"
    echo "ARTIFACTS_DESTINATION=s3://${ARTIFACTS_BUCKET}/artifacts"
    echo "AWS_DEFAULT_REGION=${AWS_REGION}"
    echo "SERVER_LOG_GROUP=${SERVER_LOG_GROUP}"
    echo "MLFLOW_AUTH=${MLFLOW_AUTH}"
} >.env
# Configuracion de los scripts de respaldo (infra/scripts).
{
    echo "ARTIFACTS_DESTINATION=s3://${ARTIFACTS_BUCKET}/artifacts"
    echo "AWS_REGION=${AWS_REGION}"
} >backup.env
if [ -d scripts ]; then chmod 0755 scripts/*.sh; fi # S3 no conserva los permisos

# 3) Imagen nueva de ECR y arranque
aws ecr get-login-password --region "$AWS_REGION" |
    docker login --username AWS --password-stdin "${MLFLOW_IMAGE%%/*}"
docker compose pull --quiet
# Postgres solo usa POSTGRES_PASSWORD al crear la base. Si ya existia (con
# otra clave), se fija con ALTER USER por el socket local, que no pide clave.
docker compose up -d --wait postgres
docker compose exec -T postgres psql -q -U mlflow -d mlflow -v ON_ERROR_STOP=1 \
    -v pw="$POSTGRES_PASSWORD" <<'SQL'
ALTER USER mlflow PASSWORD :'pw';
SQL
docker compose up -d --remove-orphans
docker image prune -af >/dev/null # imagenes de deploys anteriores

# 4) Servicio que envia a CloudWatch Logs los avisos de falta de memoria (OOM)
if [ -n "$LOG_GROUP" ]; then
    cat >/etc/systemd/system/mlflow-oom-alert.service <<EOF
[Unit]
Description=Envia a CloudWatch Logs los avisos de falta de memoria (OOM)
After=network-online.target
Wants=network-online.target

[Service]
Environment=LOG_GROUP=${LOG_GROUP} AWS_REGION=${AWS_REGION}
ExecStart=/bin/bash /opt/mlflow/oom-alert.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mlflow-oom-alert >/dev/null 2>&1
    systemctl restart mlflow-oom-alert
fi

# 5) Los respaldos automaticos en Google Drive de versiones anteriores (cada
#    hora y al apagar) ya no existen: se respalda con el workflow backup.
#    Parar el de apagado lanza el script nuevo con --shutdown, que solo falla.
removed=no
for unit in mlflow-backup.timer mlflow-backup.service mlflow-backup-shutdown.service; do
    if [ -f "/etc/systemd/system/$unit" ]; then
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$unit"
        removed=yes
    fi
done
if [ "$removed" = yes ]; then systemctl daemon-reload; fi

# 6) Espera a que MLflow responda (hasta 5 minutos)
for _ in $(seq 60); do
    if curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
        echo "MLflow listo: http://${MLFLOW_PUBLIC_HOST}:8080"
        exit 0
    fi
    sleep 5
done
docker compose logs --tail 50 mlflow
exit 1
