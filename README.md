# MLflow en AWS con Terraform y GitHub Actions

| Pieza | Qué hace |
|---|---|
| **ECR** | Imagen del servidor (`infra/mlflow-server`). El workflow la construye solo cuando esa carpeta cambia. |
| **EC2** | Amazon Linux 2023 con Docker Compose: MLflow + Postgres. Sin SSH: el deploy entra por SSM. |
| **S3** | Modelos y artefactos de MLflow (`s3://<bucket>/artifacts`) y estado de Terraform. |

No hay bootstrap: el workflow de deploy crea con la AWS CLI los dos buckets (estado y artefactos) si no existen, y el de destroy los borra al final. No los gestiona Terraform porque el provider de AWS lee siempre la configuración de Object Lock de los buckets y la política del Learner Lab lo prohíbe.

Crea el bucket del estado, el rol que GitHub Actions asume por OIDC (sin access keys) y el rol de la instancia EC2.
Necesitas Terraform 1.11 o superior y credenciales de administrador de la cuenta.

```bash
cd infra/bootstrap
terraform init
terraform apply -var github_repo=<owner>/<repo>
```

- Si la cuenta ya tiene el proveedor OIDC de GitHub, añade `-var create_oidc_provider=false`.
- Si tu rama principal no es `main`, añade `-var github_branch=<rama>`.
- Guarda el `terraform.tfstate` que queda en esa carpeta. No se sube al repo.

## 2. Configurar GitHub

En **Settings → Secrets and variables → Actions**:

- **Secrets** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN`: en el Learner Lab, **AWS Details → AWS CLI → Show**, copia cada valor.
- **Secret** `POSTGRES_PASSWORD`: clave del usuario `mlflow` de Postgres (al menos 8 caracteres; solo letras, números y `. _ ~ -`, porque va dentro de la URL de conexión). Lo exige el deploy.
- **Variable opcional** `AWS_REGION`: `us-east-1` (por defecto) o `us-west-2`, las únicas que permite el lab.

## 3. Desplegar y destruir

- **Actions → deploy → Run workflow**: crea o actualiza todo y despliega. La URL aparece en el resumen del run.
- **Actions → destroy → Run workflow**, escribiendo `destroy`: borra todo, incluidos runs, métricas, modelos e imágenes. El bootstrap (estado y roles, sin costo) se queda.

Después de un destroy, el siguiente deploy tiene IP nueva: cámbiala en el notebook (`ip='<IP>:8080'`).

Con clave activada, define en el notebook `MLFLOW_TRACKING_USERNAME=admin` y `MLFLOW_TRACKING_PASSWORD`. La clave se fija cuando se crea el servidor: cambiar el secret después no la cambia (haz destroy y deploy, o cámbiala desde MLflow). MLflow va por HTTP, así que la clave viaja sin cifrar.

Costo aproximado en us-east-1 con el stack desplegado: unos US$20 al mes (t3.small, IP pública y 20 GB de disco). Después de destroy, casi cero (solo el bucket del estado).

El rol de GitHub puede gestionar EC2, ECR y SSM en toda la cuenta (de IAM solo pasar el rol de la instancia): lo ideal es una cuenta dedicada a esto.

- **Actions → deploy → Run workflow**: etapas `config` (credenciales y buckets) → `terraform` → `build` (imagen en ECR) → `deploy` (EC2 por SSM). La URL aparece en el resumen del run. Si la sesión anterior detuvo la EC2, el deploy la vuelve a encender.
- **Actions → destroy → Run workflow**, escribiendo `destroy`: etapas `config` → `terraform` → `limpieza`. Borra todo, incluidos runs, métricas, modelos, imágenes, logs, los parámetros de Parameter Store que creó Terraform y el bucket del estado. La cuenta queda vacía.

Si reinicias el lab sin hacer destroy, el reinicio puede borrar el estado de Terraform y dejar parámetros como `/mlflow/postgres-password`. Entonces deploy falla con `ParameterAlreadyExists`. Lanza destroy una vez: busca los parámetros por las etiquetas que pone Terraform (`Project=mlflow`, `ManagedBy=terraform`) y los borra aunque no haya estado. El siguiente deploy los vuelve a crear a partir de los secrets. Los parámetros sin esas etiquetas, que no son de este proyecto, no se tocan.

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

Desde tu máquina, con las mismas credenciales de administrador del bootstrap:

MLflow no pide usuario ni clave. La única clave es la de Postgres, que no se expone a internet (Postgres no publica puertos). Cada deploy aplica el valor actual del secret `POSTGRES_PASSWORD` a la base, aunque ya existiera con otra clave. Dentro de la instancia está en `/opt/mlflow/.env`, y en AWS en Parameter Store (`/mlflow/postgres-password`).

Gasto aproximado del crédito del lab: unos US$0.03 por hora con la EC2 encendida si es t3.small (IP y disco incluidos; una m7i-flex.large ronda los US$0.10 por hora) y menos de US$0.01 por hora con ella detenida (la IP y el disco se siguen cobrando). Haz destroy cuando ya no lo necesites.

Para entrar a la instancia: `aws ssm start-session --target <instance_id>` (requiere el plugin de Session Manager), o desde la consola de EC2 con **Connect → Session Manager**.

## Respaldo local

`scripts/backup_local.py` descarga a tu computador todo lo de MLflow, solo con la API de MLflow: experimentos, corridas (parámetros, tags, datasets de entrada y el historial completo de cada métrica), artefactos, logged models y modelos registrados con sus versiones y alias. Con la EC2 encendida, desde la raíz del repo:

```bash
uv run scripts/backup_local.py --tracking-uri http://<IP>:8080
```

`uv` instala solo las dependencias: `mlflow-skinny==3.17.0` (la misma versión que el servidor) y `tqdm` para las barras de progreso. Sin uv: `pip install mlflow-skinny==3.17.0 tqdm==4.70.1` y `python scripts/backup_local.py --tracking-uri http://<IP>:8080`.

Mientras corre muestra dos barras: una de metadatos (corridas y modelos) y otra de artefactos con los MB descargados, la velocidad y el tiempo restante.

Cada respaldo queda en `~/mlflow-backups/mlflow-backup-AAAAMMDD-HHMMSS/` (hora UTC), con un `manifest.json` de conteos y un JSON por experimento, corrida y modelo junto a sus artefactos. Se conservan los 5 más recientes (`--keep`). `--dest` cambia la carpeta y `--no-artifacts` guarda solo los metadatos. `--help` muestra todas las opciones.

- Los artefactos que no cambiaron desde el respaldo anterior no se vuelven a descargar: se enlazan desde él, así que tampoco ocupan disco dos veces. AWS cobra la descarga (US$0.09 por GB), y solo se paga la primera vez.
- Si el respaldo falla o lo cortas con Ctrl+C, no queda ninguna carpeta a medias.
- No incluye lo que está en la papelera de MLflow, las trazas de GenAI ni los prompts.

### Cargar un respaldo en un MLflow limpio

Tras un reinicio del lab o un destroy: lanza deploy (MLflow arranca vacío) y, con la IP nueva:

```bash
uv run scripts/restore_local.py --tracking-uri http://<IP>:8080
```

Carga el respaldo más reciente de `~/mlflow-backups`; para otro, pasa su carpeta como argumento. Recrea experimentos, corridas (con sus fechas, estado, parámetros, tags, datasets y el historial de métricas), artefactos, logged models y modelos registrados con versiones y alias, y al final compara los conteos con el manifiesto del respaldo. Muestra las mismas dos barras que el respaldo, con los MB subidos.

- Si el servidor ya tiene datos no hace nada, para no duplicarlos: tiene que ser un MLflow recién desplegado.
- Experimentos, corridas y logged models reciben IDs nuevos (MLflow no deja elegirlos). Lo que use nombres sigue igual, incluidos los alias como `models:/mi-modelo@champion`. La correspondencia entre IDs viejos y nuevos queda en `id-map-*.json`, dentro de la carpeta del respaldo.
- Si la carga falla a mitad, el servidor queda con datos parciales: vuelve a desplegarlo limpio (destroy y deploy) antes de reintentar.
