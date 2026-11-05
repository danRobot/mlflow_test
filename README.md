# MLflow en AWS Learner Lab con Terraform y GitHub Actions

| Pieza | Qué hace |
|---|---|
| **ECR** | Imagen del servidor (`infra/mlflow-server`). El workflow la construye solo cuando esa carpeta cambia. |
| **EC2** | Amazon Linux 2023 con Docker Compose: MLflow + Postgres. Usa el `LabInstanceProfile` del lab (el Learner Lab no deja crear roles). Sin SSH: el deploy entra por SSM. |
| **S3** | Modelos y artefactos de MLflow (`s3://<bucket>/artifacts`) y estado de Terraform. |
| **Google Drive** | Respaldos de la base y los artefactos, fuera de AWS: sobreviven a un destroy o a un reinicio del lab y no gastan crédito. Ver [Respaldos en Google Drive](#respaldos-en-google-drive). |

No hay bootstrap: el workflow de deploy crea con la AWS CLI los dos buckets (estado y artefactos) si no existen, y el de destroy los borra al final. No los gestiona Terraform porque el provider de AWS lee siempre la configuración de Object Lock de los buckets y la política del Learner Lab lo prohíbe.

## 1. Configurar GitHub (una vez)

En **Settings → Secrets and variables → Actions**:

- **Secrets** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN`: en el Learner Lab, **AWS Details → AWS CLI → Show**, copia cada valor.
- **Secret** `POSTGRES_PASSWORD`: clave del usuario `mlflow` de Postgres (al menos 8 caracteres; solo letras, números y `. _ ~ -`, porque va dentro de la URL de conexión). Lo exige el deploy.
- **Secret opcional** `GDRIVE_RCLONE_CONF`: acceso a tu Google Drive para los respaldos. Sin él todo funciona, pero sin respaldos. Cómo obtenerlo: [Configurar Google Drive](#configurar-google-drive-una-vez).
- **Variable opcional** `AWS_REGION`: `us-east-1` (por defecto) o `us-west-2`, las únicas que permite el lab.

## 2. En cada sesión del lab

Las credenciales cambian cada vez que inicias el lab y caducan cuando termina la sesión (unas 4 horas).

1. **Start Lab** y espera a que el indicador esté en verde.
2. Actualiza los tres secrets `AWS_*` con los valores nuevos de **AWS Details**.
3. Lanza el workflow que necesites.

## 3. Desplegar y destruir

- **Actions → deploy → Run workflow**: etapas `config` (credenciales y buckets) → `terraform` → `build` (imagen en ECR) → `deploy` (EC2 por SSM) → `restaurar`. La URL aparece en el resumen del run. Si la sesión anterior detuvo la EC2, el deploy la vuelve a encender. Si la base de MLflow está vacía (stack nuevo, lab reiniciado o tras un destroy), `restaurar` trae el último respaldo de Google Drive; si ya tiene datos, no hace nada.
- **Actions → destroy → Run workflow**, escribiendo `destroy`: etapas `config` → `respaldo` → `terraform` → `limpieza`. Primero respalda en Google Drive con MLflow detenido; si el respaldo falla, no borra nada. Después borra todo lo de AWS, incluidos runs, métricas, modelos, imágenes, logs, los parámetros de Parameter Store que creó Terraform y el bucket del estado. La cuenta queda vacía; Google Drive no se toca.
- **Actions → backup** y **Actions → restore**: respaldo y restauración a mano (ver [Respaldos en Google Drive](#respaldos-en-google-drive)).

Si reinicias el lab sin hacer destroy, el reinicio puede borrar el estado de Terraform y dejar parámetros como `/mlflow/postgres-password`. Entonces deploy falla con `ParameterAlreadyExists`. Lanza destroy una vez: busca los parámetros por las etiquetas que pone Terraform (`Project=mlflow`, `ManagedBy=terraform`) y los borra aunque no haya estado. El siguiente deploy los vuelve a crear a partir de los secrets. Los parámetros sin esas etiquetas, que no son de este proyecto, no se tocan.

Las dos etapas `config` fallan si las credenciales no sirven (caducadas, revocadas al reiniciar el lab o mal copiadas), en vez de seguir como si no hubiera nada desplegado.

## Respaldos en Google Drive

Los datos de MLflow viven en la cuenta del lab: un reinicio del lab, el fin del curso o un destroy los borran. Los respaldos los copian a tu Google Drive personal, que es gratis hasta 15 GB, y el deploy los trae de vuelta.

### Qué se guarda y cuándo

En Drive, carpeta `mlflow-backups`:

```
mlflow-backups/
  mlflow-backup-20261104-221300/   un respaldo (fecha y hora UTC)
    manifest.txt                   versión de MLflow, conteos y huella de la base
    db.sql.gz                      la base completa (pg_dump)
  artifacts/                       copia de s3://<bucket>/artifacts, común a todos
```

- **La base** se vuelca completa en cada respaldo; comprimida ocupa poco.
- **Los artefactos** (modelos, archivos) no se empaquetan cada vez. rclone copia a `artifacts/` solo los archivos nuevos y ahí nunca borra nada, así que cada respaldo encuentra los suyos. De AWS sale solo lo nuevo.

Los respaldos se hacen solos:

| Cuándo | Quién |
|---|---|
| Cada hora con la EC2 encendida (el primero, 20 minutos después de arrancar) | Timer `mlflow-backup` de la EC2 |
| Al apagarse la EC2, por ejemplo al terminar la sesión del lab | Servicio `mlflow-backup-shutdown` de la EC2 |
| Antes de borrar todo | Etapa `respaldo` de destroy |
| Cuando quieras | **Actions → backup** |

Si la base no cambió desde el último respaldo, no se crea otra carpeta (solo se copian los artefactos nuevos). Con la base vacía no se respalda nada, para que un MLflow recién creado no tape tu último respaldo con datos. Se conservan los 24 respaldos más recientes; los anteriores van a la papelera de Drive.

### Restaurar

- **Después de un reinicio del lab o un destroy**: lanza deploy y listo. Encuentra la base vacía y restaura el último respaldo, con sus artefactos. Funciona aunque cambie la cuenta de AWS o el nombre del bucket.
- **Volver a un respaldo anterior**: **Actions → restore**. Sin llenar nada, solo lista los respaldos en el resumen del run. Para restaurar, escribe el nombre del respaldo (vacío = el más reciente) y `restaurar` en la confirmación. Antes de reemplazar la base guarda el estado actual como un respaldo más, así que se puede deshacer.

Desde la instancia (Session Manager), los mismos scripts: `sudo /opt/mlflow/scripts/restore_mlflow.sh --list`, `sudo /opt/mlflow/scripts/backup_mlflow.sh` y `--help` en cada uno.

### Configurar Google Drive (una vez)

El acceso a Drive se hace con [rclone](https://rclone.org/drive/) y un cliente OAuth de Google **propio**. El cliente compartido que trae rclone deja de funcionar durante 2026, porque Google empezará a cobrar las peticiones hechas con él ([anuncio de rclone](https://forum.rclone.org/t/google-drive-and-google-photos-users-action-required/54005)).

1. **Proyecto y API.** En [Google Cloud Console](https://console.cloud.google.com/), con tu cuenta personal, crea un proyecto (por ejemplo `mlflow-respaldos`). En **APIs y servicios → Biblioteca**, busca **Google Drive API** y habilítala.
2. **Pantalla de consentimiento** (**Google Auth Platform**):
   - **Branding**: nombre de la app (por ejemplo `rclone`), tu correo de soporte, y una página principal y una de política de privacidad. Google exige las dos URL para publicar la app; puedes poner la de este repositorio en ambas.
   - **Audience**: tipo **External**.
   - **Data access**: agrega el permiso `https://www.googleapis.com/auth/drive.file` (solo los archivos que crea rclone).
3. **Cliente**: en **Clients → Create client**, tipo **Desktop app**. Copia el **Client ID** y el **Client secret**.
4. **Publica la app**: en **Audience → Publish app**. Es importante: mientras la app esté en *Testing*, Google invalida el token a los 7 días y los respaldos dejarían de funcionar en silencio.
5. **Token, en tu computador** (con navegador). Instala rclone ([rclone.org/install](https://rclone.org/install/)) y ejecuta:

   ```bash
   rclone config create gdrive drive client_id=TU_CLIENT_ID client_secret=TU_CLIENT_SECRET scope=drive.file
   ```

   Se abre el navegador: entra con tu cuenta de Google y acepta. Si aparece "Google no verificó esta app", es tu propia app: **Configuración avanzada → Ir a rclone**.
6. **Secret**: ejecuta `rclone config show gdrive` y copia **toda** la salida, desde `[gdrive]` hasta la línea `token = ...`. Pégala en GitHub como secret `GDRIVE_RCLONE_CONF`.
7. Lanza **deploy**. En el resumen del run debe decir "Respaldos en Google Drive: activados".

Con el permiso `drive.file`, rclone solo ve y modifica lo que creó él mismo: el resto de tu Drive queda fuera de su alcance, aunque alguien obtuviera el token. Por lo mismo, no borres ese proyecto de Google Cloud: con otro cliente, rclone ya no vería los respaldos anteriores. Si el token se revoca (por ejemplo, quitando el acceso de la app en tu cuenta de Google), los respaldos fallan con "no se pudo acceder a Google Drive": ejecuta `rclone config reconnect gdrive:` en tu computador y repite los pasos 6 y 7.

La configuración se guarda en Parameter Store (`/mlflow/gdrive-rclone-conf`, cifrada) y la EC2 la lee en cada respaldo; nunca queda en el disco.

### Costo y límites

- **Google Drive**: gratis hasta 15 GB, compartidos con Gmail y Fotos.
- **AWS**: los respaldos no ocupan nada en S3. Lo único que se cobra es la transferencia de datos que sale de AWS hacia Drive: [US$0.09 por GB](https://egresscost.com/aws/data-transfer-pricing), y AWS regala los primeros [100 GB al mes](https://aws.amazon.com/blogs/aws/aws-free-tier-data-transfer-expansion-100-gb-from-regions-and-1-tb-from-amazon-cloudfront-per-month/), aunque puede que eso no aplique en una cuenta del lab. Como los artefactos se copian solo una vez, cada respaldo transfiere la base comprimida y los modelos nuevos. Restaurar (datos que entran a AWS) no se cobra.
- El respaldo al apagar es "mejor esfuerzo": si AWS fuerza el apagado antes de que termine, cuenta el del último respaldo horario.
- `artifacts/` en Drive no borra nada, ni siquiera lo que borres en MLflow (`mlflow gc`): si ocupa demasiado, bórrala desde Drive y el siguiente respaldo la vuelve a llenar con lo que haya en S3.

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
