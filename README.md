# MLflow en AWS con Terraform y GitHub Actions

| Pieza | Qué hace |
|---|---|
| **ECR** | Imagen del servidor (`infra/mlflow-server`). El workflow la construye solo cuando esa carpeta cambia. |
| **EC2** | Amazon Linux 2023 con Docker Compose: MLflow + Postgres. Sin SSH: el deploy entra por SSM. |
| **S3** | Modelos y artefactos de MLflow (`s3://<bucket>/artifacts`) y estado de Terraform. |

## 1. Bootstrap (una sola vez, desde tu máquina)

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

- **Variables**: `AWS_REGION`, `AWS_ROLE_ARN` y `TF_STATE_BUCKET`, con los valores del output `github_variables` del bootstrap.
- **Secret opcional** `MLFLOW_AUTH_PASSWORD`: activa usuario y clave en MLflow (usuario `admin`, clave de al menos 12 caracteres).

## 3. Desplegar y destruir

- **Actions → deploy → Run workflow**: crea o actualiza todo y despliega. La URL aparece en el resumen del run.
- **Actions → destroy → Run workflow**, escribiendo `destroy`: borra todo, incluidos runs, métricas, modelos e imágenes. El bootstrap (estado y roles, sin costo) se queda.

Después de un destroy, el siguiente deploy tiene IP nueva: cámbiala en el notebook (`ip='<IP>:8080'`).

Con clave activada, define en el notebook `MLFLOW_TRACKING_USERNAME=admin` y `MLFLOW_TRACKING_PASSWORD`. La clave se fija cuando se crea el servidor: cambiar el secret después no la cambia (haz destroy y deploy, o cámbiala desde MLflow). MLflow va por HTTP, así que la clave viaja sin cifrar.

Costo aproximado en us-east-1 con el stack desplegado: unos US$20 al mes (t3.small, IP pública y 20 GB de disco). Después de destroy, casi cero (solo el bucket del estado).

El rol de GitHub puede gestionar EC2, ECR y SSM en toda la cuenta (de IAM solo pasar el rol de la instancia): lo ideal es una cuenta dedicada a esto.

## 4. Dejar la cuenta vacía

Desde tu máquina, con las mismas credenciales de administrador del bootstrap:

```bash
bash infra/unapply.sh
```

Borra el stack de MLflow si sigue en pie, vacía y borra el bucket del estado, y destruye el bootstrap (proveedor OIDC y roles). Pide escribir `borrar` y se cancela si tus credenciales son de otra cuenta. Se puede repetir si falla a medias. No toca nada que no haya creado este proyecto.

Para entrar a la instancia: `aws ssm start-session --target <instance_id>` (requiere el plugin de Session Manager).
