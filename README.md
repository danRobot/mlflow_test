# MLflow en AWS Learner Lab con Terraform y GitHub Actions

| Pieza | Qué hace |
|---|---|
| **ECR** | Imagen del servidor (`infra/mlflow-server`). El workflow la construye solo cuando esa carpeta cambia. |
| **EC2** | Amazon Linux 2023 con Docker Compose: MLflow + Postgres. Usa el `LabInstanceProfile` del lab (el Learner Lab no deja crear roles). Sin SSH: el deploy entra por SSM. |
| **S3** | Modelos y artefactos de MLflow (`s3://<bucket>/artifacts`) y estado de Terraform. |
| **Respaldos** | La base y los artefactos en un solo `.7z`, en la carpeta `backup/` del bucket de artefactos. Ver [Respaldos en S3](#respaldos-en-s3). |

No hay bootstrap: el workflow de deploy crea con la AWS CLI los dos buckets (estado y artefactos) si no existen, y el de destroy los borra al final. No los gestiona Terraform porque el provider de AWS lee siempre la configuración de Object Lock de los buckets y la política del Learner Lab lo prohíbe. (`infra/bootstrap` e `infra/unapply.sh` son de la versión para una cuenta de AWS normal, con un rol que GitHub asume por OIDC; en el Learner Lab no se usan.)

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

- **Actions → deploy → Run workflow**: etapas `config` (credenciales, buckets y la carpeta `backup/`) → `terraform` → `build` (imagen en ECR) → `deploy` (EC2 por SSM). La URL aparece en el resumen del run. Si la sesión anterior detuvo la EC2, el deploy la vuelve a encender.
- **Actions → destroy → Run workflow**, escribiendo `destroy`: etapas `config` → `terraform` → `limpieza`. Borra todo, incluidos runs, métricas, modelos, los respaldos de `backup/`, imágenes, logs, los parámetros de Parameter Store que creó Terraform y el bucket del estado. La cuenta queda vacía: descarga antes el `.7z` que quieras conservar.
- **Actions → backup** y **Actions → restore**: ver [Respaldos en S3](#respaldos-en-s3).

Si reinicias el lab sin hacer destroy, el reinicio puede borrar el estado de Terraform y dejar parámetros como `/mlflow/postgres-password`. Entonces deploy falla con `ParameterAlreadyExists`. Lanza destroy una vez: busca los parámetros por las etiquetas que pone Terraform (`Project=mlflow`, `ManagedBy=terraform`) y los borra aunque no haya estado. El siguiente deploy los vuelve a crear a partir de los secrets. Los parámetros sin esas etiquetas, que no son de este proyecto, no se tocan.

Las dos etapas `config` fallan si las credenciales no sirven (caducadas, revocadas al reiniciar el lab o mal copiadas), en vez de seguir como si no hubiera nada desplegado.

## Respaldos en S3

Los datos de MLflow viven en la cuenta del lab: un reinicio del lab, el fin del curso o un destroy los borran. Un respaldo junta la base y los artefactos en un solo archivo `.7z` dentro del bucket de artefactos. Para que sobreviva a un destroy, descárgalo a tu computador.

### Respaldar

**Actions → backup → Run workflow**. Deja en `s3://<bucket>/backup/` un archivo `backup_mlflow_AAAAMMDD-HHMMSS.7z` (fecha y hora UTC), comprimido con 7-Zip al máximo (`-mx=9`), con:

```
db.sql          la base completa (pg_dump)
manifest.txt    fecha, versión de MLflow y conteos
artifacts/      copia de s3://<bucket>/artifacts
```

- **Sin llenar el disco de la EC2** (20 GB): la base se vuelca directo a S3, a una carpeta temporal `backup/backup_mlflow_<fecha>.tmp/`, y 7-Zip lee la base y los artefactos del bucket montado ([Mountpoint for Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mountpoint.html), en solo lectura y solo mientras dura el respaldo). En el disco solo se arma el `.7z`, porque 7-Zip necesita volver atrás en el archivo que escribe. Cuando el `.7z` está en `backup/`, se borran la copia del disco y la carpeta temporal.
- Antes de empezar comprueba que el `.7z` quepa en el disco aunque nada se comprima; si no, falla sin tocar nada.
- Con la base vacía (MLflow recién desplegado) no crea ningún respaldo: sería el más reciente y el restore lo tomaría antes que tus datos.
- Comprimir al máximo es lento: del orden de 5 MB por segundo de datos sin comprimir. Los modelos binarios casi no se comprimen; los CSV, los JSON y la base, mucho.
- Cada respaldo es completo e independiente, y no se borran solos: elimina desde la consola de S3 los que ya no quieras.

**Antes de un destroy o del fin del curso, descarga el `.7z`**: consola de S3 → bucket `mlflow-artifacts-<cuenta>-<región>` → `backup/` → marca el archivo → **Descargar**. Destroy borra la carpeta con todo lo que tenga.

### Restaurar

**Actions → restore → Run workflow**, escribiendo `restaurar`. Toma el `.7z` más reciente de `backup/` (por la fecha del nombre), lo descomprime en la EC2, sube los artefactos a S3, **reemplaza** la base actual por la del respaldo y levanta MLflow. Si todo sale bien, borra ese `.7z` de S3.

- **Instalación limpia** (después de un destroy o un reinicio del lab): lanza deploy, que crea la carpeta `backup/` vacía. Sube tu `.7z` a esa carpeta desde la consola de S3 (**Cargar**), con su nombre `backup_mlflow_<fecha>.7z`, y lanza restore. Si la carpeta no tiene ningún `.7z`, restore falla.
- Funciona aunque cambien la cuenta de AWS o el nombre del bucket, y con respaldos de una versión anterior de MLflow: al arrancar, MLflow migra la base.
- La EC2 necesita espacio libre para el contenido del `.7z` sin comprimir; si no lo hay, falla sin tocar nada.
- Los artefactos que ya estaban en S3 se quedan. Si algo falla, el `.7z` sigue en `backup/` y se puede reintentar.

Desde la instancia (Session Manager), los mismos scripts: `sudo /opt/mlflow/scripts/backup_mlflow.sh` y `sudo /opt/mlflow/scripts/restore_mlflow.sh` (`--help` en cada uno).

### Costo

S3 cobra US$0.023 por GB al mes por los `.7z` guardados y US$0.09 por GB al descargarlos a tu computador; subirlos es gratis. Mover datos entre la EC2 y S3 dentro de la misma región tampoco se cobra.

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

## Respaldo local

`scripts/backup_local.py` descarga a tu computador todo lo de MLflow, solo con la API de MLflow: experimentos, corridas (parámetros, tags, datasets de entrada y el historial completo de cada métrica), artefactos, logged models y modelos registrados con sus versiones y alias. Es más lento que un [respaldo en S3](#respaldos-en-s3), porque descarga los artefactos uno por uno. Con la EC2 encendida, desde la raíz del repo:

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
