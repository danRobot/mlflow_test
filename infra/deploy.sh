#!/usr/bin/env bash
# Corre en la EC2 como root; lo lanza el workflow de deploy por SSM.
# Idempotente: la primera vez instala Docker, despues solo actualiza el stack.
set -euo pipefail

: "${MLFLOW_IMAGE:?}" "${MLFLOW_PUBLIC_HOST:?}" "${ARTIFACTS_BUCKET:?}" "${AWS_REGION:?}" "${POSTGRES_PARAMETER:?}"
: "${SERVER_LOG_GROUP:?}" # accesos de MLflow en CloudWatch (driver awslogs del compose)
LOG_GROUP="${LOG_GROUP:-}"
GDRIVE_PARAMETER="${GDRIVE_PARAMETER:-}" # vacio: sin respaldos en Google Drive
COMPOSE_VERSION=v2.40.3
# rclone para los respaldos. El hash es el de rclone-v1.75.2-linux-amd64.zip
# en el SHA256SUMS de la release: un binario distinto no se instala.
RCLONE_VERSION=v1.75.2
RCLONE_SHA256=349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702
export HOME="${HOME:-/root}" # SSM no siempre define HOME y docker lo necesita
cd /opt/mlflow

# 1) Docker, docker compose y rclone (solo si faltan o cambia la version)
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
# rclone solo hace falta con los respaldos en Google Drive activados.
if [ -n "$GDRIVE_PARAMETER" ] &&
    [ "$(/usr/local/bin/rclone version 2>/dev/null | sed -n '1s/^rclone //p')" != "$RCLONE_VERSION" ]; then
    tmp=$(mktemp -d)
    pkg="rclone-${RCLONE_VERSION}-linux-amd64"
    curl -fsSL --retry 5 -o "$tmp/$pkg.zip" \
        "https://github.com/rclone/rclone/releases/download/${RCLONE_VERSION}/${pkg}.zip"
    echo "${RCLONE_SHA256}  $tmp/$pkg.zip" | sha256sum -c --quiet -
    python3 -m zipfile -e "$tmp/$pkg.zip" "$tmp" # zipfile no conserva el bit de ejecucion
    install -m 0755 "$tmp/$pkg/rclone" /usr/local/bin/rclone
    rm -rf "$tmp"
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
    echo "SERVER_LOG_GROUP=${SERVER_LOG_GROUP}"
} >.env
# Configuracion de los scripts de respaldo (infra/scripts). Sin la clave de
# Drive: esa la leen de Parameter Store en cada respaldo.
{
    echo "GDRIVE_PARAMETER=${GDRIVE_PARAMETER}"
    echo "GDRIVE_FOLDER=mlflow-backups"
    echo "ARTIFACTS_DESTINATION=s3://${ARTIFACTS_BUCKET}/artifacts"
    echo "AWS_REGION=${AWS_REGION}"
    echo "KEEP=24"
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

# 5) Respaldos automaticos en Google Drive (scripts/backup_mlflow.sh):
#    - mlflow-backup.timer: cada hora con la EC2 encendida (el primero, 20
#      minutos despues de arrancar).
#    - mlflow-backup-shutdown: uno mas al apagarse la EC2, por ejemplo cuando
#      termina la sesion del lab. Al apagar, systemd detiene las unidades en
#      orden inverso: esta termina antes que Docker y la red, asi que Postgres
#      sigue arriba mientras respalda.
if [ -n "$GDRIVE_PARAMETER" ]; then
    cat >/etc/systemd/system/mlflow-backup.service <<'EOF'
[Unit]
Description=Respaldo de MLflow en Google Drive
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/mlflow/scripts/backup_mlflow.sh
Nice=10
TimeoutStartSec=2h
EOF
    cat >/etc/systemd/system/mlflow-backup.timer <<'EOF'
[Unit]
Description=Respaldo de MLflow en Google Drive cada hora

[Timer]
OnBootSec=20min
OnUnitActiveSec=1h
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
    cat >/etc/systemd/system/mlflow-backup-shutdown.service <<'EOF'
[Unit]
Description=Ultimo respaldo de MLflow en Google Drive al apagar la EC2
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/bin/bash /opt/mlflow/scripts/backup_mlflow.sh --shutdown
TimeoutStopSec=10min

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now mlflow-backup.timer mlflow-backup-shutdown.service >/dev/null
    echo "Respaldos en Google Drive activados: cada hora y al apagar la EC2."
else
    # Sin el secret GDRIVE_RCLONE_CONF. Parar mlflow-backup-shutdown lanza su
    # ExecStop, que con GDRIVE_PARAMETER vacio en backup.env no hace nada.
    for unit in mlflow-backup.timer mlflow-backup-shutdown.service; do
        if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            systemctl disable --now "$unit" >/dev/null 2>&1
        fi
    done
fi

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
