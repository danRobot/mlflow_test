#!/usr/bin/env bash
# Corre en la EC2 como root; lo lanza el workflow de deploy por SSM.
# Idempotente: la primera vez instala Docker, despues solo actualiza el stack.
set -euo pipefail

: "${MLFLOW_IMAGE:?}" "${MLFLOW_PUBLIC_HOST:?}" "${ARTIFACTS_BUCKET:?}" "${AWS_REGION:?}" "${POSTGRES_PARAMETER:?}"
LOG_GROUP="${LOG_GROUP:-}"
COMPOSE_VERSION=v2.40.3
export HOME="${HOME:-/root}" # SSM no siempre define HOME y docker lo necesita
cd /opt/mlflow

# 1) Docker y docker compose (solo la primera vez)
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

# 2) .env de compose. La clave de Postgres es la del secret POSTGRES_PASSWORD
#    (llega por SSM) y queda tambien aqui para usarla desde la instancia.
umask 077
POSTGRES_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$POSTGRES_PARAMETER" \
    --with-decryption --query Parameter.Value --output text)
rm -f secrets.env # clave aleatoria de versiones anteriores
{
    echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
    echo "MLFLOW_IMAGE=${MLFLOW_IMAGE}"
    echo "MLFLOW_PUBLIC_HOST=${MLFLOW_PUBLIC_HOST}"
    echo "ARTIFACTS_DESTINATION=s3://${ARTIFACTS_BUCKET}/artifacts"
    echo "AWS_DEFAULT_REGION=${AWS_REGION}"
} >.env

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

# 5) Espera a que MLflow responda (hasta 5 minutos)
for _ in $(seq 60); do
    if curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
        echo "MLflow listo: http://${MLFLOW_PUBLIC_HOST}:8080"
        exit 0
    fi
    sleep 5
done
docker compose logs --tail 50 mlflow
exit 1
