# MLflow en AWS Learner Lab con Terraform y GitHub Actions

| Pieza | Qué hace |
|---|---|
| **ECR** | Imagen del servidor (`infra/mlflow-server`). El workflow la construye solo cuando esa carpeta cambia. |
| **EC2** | Amazon Linux 2023 con Docker Compose: MLflow + Postgres. Usa el `LabInstanceProfile` del lab (el Learner Lab no deja crear roles). Sin SSH: el deploy entra por SSM. |
| **S3** | Modelos y artefactos de MLflow (`s3://<bucket>/artifacts`) y estado de Terraform. |

No hay bootstrap: el workflow de deploy crea el bucket del estado si no existe y el de destroy lo borra al final.

## 1. Configurar GitHub (una vez)

En **Settings → Secrets and variables → Actions**:

- **Secrets** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN`: en el Learner Lab, **AWS Details → AWS CLI → Show**, copia cada valor.
- **Secret opcional** `MLFLOW_AUTH_PASSWORD`: activa usuario y clave en MLflow (usuario `admin`, clave de al menos 12 caracteres).
- **Variable opcional** `AWS_REGION`: `us-east-1` (por defecto) o `us-west-2`, las únicas que permite el lab.

## 2. En cada sesión del lab

Las credenciales cambian cada vez que inicias el lab y caducan cuando termina la sesión (unas 4 horas).

1. **Start Lab** y espera a que el indicador esté en verde.
2. Actualiza los tres secrets `AWS_*` con los valores nuevos de **AWS Details**.
3. Lanza el workflow que necesites.

## 3. Desplegar y destruir

- **Actions → deploy → Run workflow**: crea o actualiza todo y despliega. La URL aparece en el resumen del run. Si la sesión anterior detuvo la EC2, el deploy la vuelve a encender.
- **Actions → destroy → Run workflow**, escribiendo `destroy`: borra todo, incluidos runs, métricas, modelos, imágenes y el bucket del estado. La cuenta queda vacía.

Al terminar la sesión el lab detiene la EC2, pero la IP es fija (Elastic IP) y los datos se conservan. En la sesión siguiente, lanza deploy (o enciende la instancia desde la consola de EC2) y MLflow vuelve con la misma IP. La IP solo cambia después de un destroy o de un reset del lab.

Con clave activada, define en el notebook `MLFLOW_TRACKING_USERNAME=admin` y `MLFLOW_TRACKING_PASSWORD`. La clave se fija cuando se crea el servidor: cambiar el secret después no la cambia. MLflow va por HTTP, así que la clave viaja sin cifrar.

Gasto aproximado del crédito del lab: unos US$0.03 por hora con la EC2 encendida (t3.small, IP y disco) y menos de US$0.01 por hora con ella detenida (la IP y el disco se siguen cobrando). Haz destroy cuando ya no lo necesites.

Para entrar a la instancia: `aws ssm start-session --target <instance_id>` (requiere el plugin de Session Manager), o desde la consola de EC2 con **Connect → Session Manager**.
