# MLflow en AWS Learner Lab con Terraform y GitHub Actions

| Pieza | Qué hace |
|---|---|
| **ECR** | Imagen del servidor (`infra/mlflow-server`). El workflow la construye solo cuando esa carpeta cambia. |
| **EC2** | Amazon Linux 2023 con Docker Compose: MLflow + Postgres. Usa el `LabInstanceProfile` del lab (el Learner Lab no deja crear roles). Sin SSH: el deploy entra por SSM. |
| **S3** | Modelos y artefactos de MLflow (`s3://<bucket>/artifacts`) y estado de Terraform. |

No hay bootstrap: el workflow de deploy crea con la AWS CLI los dos buckets (estado y artefactos) si no existen, y el de destroy los borra al final. No los gestiona Terraform porque el provider de AWS lee siempre la configuración de Object Lock de los buckets y la política del Learner Lab lo prohíbe.

## 1. Configurar GitHub (una vez)

En **Settings → Secrets and variables → Actions**:

- **Secrets** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN`: en el Learner Lab, **AWS Details → AWS CLI → Show**, copia cada valor.
- **Secret** `POSTGRES_PASSWORD`: clave del usuario `mlflow` de Postgres (al menos 8 caracteres; solo letras, números y `. _ ~ -`, porque va dentro de la URL de conexión). Lo exige el deploy.
- **Variable opcional** `AWS_REGION`: `us-east-1` (por defecto) o `us-west-2`, las únicas que permite el lab.

## 2. En cada sesión del lab

Las credenciales cambian cada vez que inicias el lab y caducan cuando termina la sesión (unas 4 horas).

1. **Start Lab** y espera a que el indicador esté en verde.
2. Actualiza los tres secrets `AWS_*` con los valores nuevos de **AWS Details**.
3. Lanza el workflow que necesites.

## 3. Desplegar y destruir

- **Actions → deploy → Run workflow**: etapas `config` (credenciales y buckets) → `terraform` → `build` (imagen en ECR) → `deploy` (EC2 por SSM). La URL aparece en el resumen del run. Si la sesión anterior detuvo la EC2, el deploy la vuelve a encender.
- **Actions → destroy → Run workflow**, escribiendo `destroy`: etapas `config` → `terraform` → `buckets`. Borra todo, incluidos runs, métricas, modelos, imágenes, logs y el bucket del estado. La cuenta queda vacía.

Las dos etapas `config` fallan si las credenciales no sirven (caducadas, revocadas al reiniciar el lab o mal copiadas), en vez de seguir como si no hubiera nada desplegado.

## Registro en CloudWatch

### Accesos a MLflow

En el log group `/mlflow/server`, con 30 días de retención. Docker envía ahí la salida del contenedor de MLflow (driver `awslogs`, sin agente): una línea por petición con la IP remota, el método, la ruta y el código de respuesta, además de los avisos y errores del servidor.

Para consultarlos: CloudWatch → Logs Insights → **Saved queries**. Elige antes el rango de tiempo (arriba a la derecha).

| Consulta | Qué muestra |
|---|---|
| `mlflow/accesos-por-ip` | Cada IP pública con su número de accesos, cuántas rutas distintas pidió y su primer y último acceso |
| `mlflow/accesos-por-hora` | Accesos e IPs distintas por hora; en la pestaña **Visualization** se ve como gráfica |
| `mlflow/accesos-detalle` | Las últimas 1000 peticiones: hora, IP, método, ruta y código de respuesta |

Las consultas ignoran las IPs privadas: el healthcheck de Docker (cada 30 s) y las peticiones desde la propia instancia. MLflow no pide clave, así que cualquier IP que no sea tuya ni de Colab es un tercero o un escáner de internet. Solo quedan registradas las peticiones HTTP: una conexión que no llega a enviar una petición válida no aparece.

Destroy borra estos logs. Si quieres conservarlos, exporta antes los resultados desde Logs Insights (**Export results**).

### Errores de la EC2

En el log group `/mlflow/ec2`, con 7 días de retención:

- **Apagados** de la EC2 (`stopping`, `stopped`, `shutting-down`, `terminated`), vía EventBridge.
- **Falta de memoria** (líneas del OOM killer del kernel), en el stream `oom`, enviadas por un servicio de la EC2.

Para saber **quién** detuvo la instancia, usa CloudTrail → Historial de eventos (`StopInstances`), que es gratis.

### Costo

No hay métricas, alarmas ni agente de CloudWatch, que sí tienen costo fijo. CloudWatch Logs cobra US$0.50 por GB ingerido. Cada línea de acceso ocupa unos 150 bytes, así que 10 000 peticiones salen por menos de US$0.001, y el healthcheck suma unos 0.4 MB por día con la EC2 encendida. Cada consulta de Logs Insights cuesta US$0.005 por GB leído.

Al terminar la sesión el lab detiene la EC2, pero la IP es fija (Elastic IP) y los datos se conservan. En la sesión siguiente, lanza deploy (o enciende la instancia desde la consola de EC2) y MLflow vuelve con la misma IP. La IP solo cambia después de un destroy o de un reset del lab.

MLflow no pide usuario ni clave. La única clave es la de Postgres, que no se expone a internet (Postgres no publica puertos). Cada deploy aplica el valor actual del secret `POSTGRES_PASSWORD` a la base, aunque ya existiera con otra clave. Dentro de la instancia está en `/opt/mlflow/.env`, y en AWS en Parameter Store (`/mlflow/postgres-password`).

Gasto aproximado del crédito del lab: unos US$0.03 por hora con la EC2 encendida si es t3.small (IP y disco incluidos; una m7i-flex.large ronda los US$0.10 por hora) y menos de US$0.01 por hora con ella detenida (la IP y el disco se siguen cobrando). Haz destroy cuando ya no lo necesites.

Para entrar a la instancia: `aws ssm start-session --target <instance_id>` (requiere el plugin de Session Manager), o desde la consola de EC2 con **Connect → Session Manager**.
