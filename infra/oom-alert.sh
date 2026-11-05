#!/usr/bin/env bash
# Corre en la EC2 como servicio (mlflow-oom-alert, lo instala deploy.sh).
# Sigue los mensajes del kernel y envia a CloudWatch Logs solo los de falta de
# memoria (OOM killer). Nada mas sale de la instancia: el costo es casi cero.
set -uo pipefail
: "${LOG_GROUP:?}" "${AWS_REGION:?}"
STREAM=oom

aws logs create-log-stream --region "$AWS_REGION" --log-group-name "$LOG_GROUP" \
    --log-stream-name "$STREAM" >/dev/null 2>&1 || true

# -n 0: solo mensajes nuevos, para no reenviar los viejos al reiniciar.
journalctl -k -f -n 0 -o short-iso |
    grep --line-buffered -i -E 'out of memory|oom-kill|killed process' |
    while IFS= read -r line; do
        events=$(python3 -c 'import json, sys, time
print(json.dumps([{"timestamp": int(time.time() * 1000), "message": sys.argv[1]}]))' "$line")
        aws logs put-log-events --region "$AWS_REGION" --log-group-name "$LOG_GROUP" \
            --log-stream-name "$STREAM" --log-events "$events" >/dev/null ||
            echo "No se pudo enviar a CloudWatch: $line" >&2
    done
