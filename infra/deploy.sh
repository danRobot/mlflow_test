#!/usr/bin/env bash
# Corre en la EC2 como root; lo lanza el workflow de deploy por SSM.
# Idempotente: la primera vez instala Docker, despues solo actualiza el stack.
set -euo pipefail

: "${MLFLOW_IMAGE:?}" "${MLFLOW_PUBLIC_HOST:?}" "${ARTIFACTS_BUCKET:?}" "${AWS_REGION:?}"
AUTH_PARAMETER="${AUTH_PARAMETER:-}"
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

# 2) .env de compose. La clave de Postgres se genera una vez y no sale de la EC2.
umask 077
if [ ! -f secrets.env ]; then
    echo "POSTGRES_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_hex(24))')" >secrets.env
fi
AUTH_ENABLED=false
if [ -n "$AUTH_PARAMETER" ]; then
    AUTH_ENABLED=true
    # Va por el entorno y no por .env, donde compose interpretaria caracteres
    # de la clave como $.
    MLFLOW_AUTH_PASSWORD=$(aws ssm get-parameter --region "$AWS_REGION" --name "$AUTH_PARAMETER" \
        --with-decryption --query Parameter.Value --output text)
    export MLFLOW_AUTH_PASSWORD
fi
{
    cat secrets.env
    echo "MLFLOW_IMAGE=${MLFLOW_IMAGE}"
    echo "MLFLOW_PUBLIC_HOST=${MLFLOW_PUBLIC_HOST}"
    echo "ARTIFACTS_DESTINATION=s3://${ARTIFACTS_BUCKET}/artifacts"
    echo "AWS_DEFAULT_REGION=${AWS_REGION}"
    echo "MLFLOW_AUTH_ENABLED=${AUTH_ENABLED}"
} >.env

# 3) Imagen nueva de ECR y arranque
aws ecr get-login-password --region "$AWS_REGION" |
    docker login --username AWS --password-stdin "${MLFLOW_IMAGE%%/*}"
docker compose pull --quiet
docker compose up -d --remove-orphans
docker image prune -af >/dev/null # imagenes de deploys anteriores

# 4) Espera a que MLflow responda (hasta 5 minutos)
for _ in $(seq 60); do
    if curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
        echo "MLflow listo: http://${MLFLOW_PUBLIC_HOST}:8080"
        exit 0
    fi
    sleep 5
done
docker compose logs --tail 50 mlflow
exit 1
