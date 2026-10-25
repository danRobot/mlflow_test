#!/usr/bin/env bash
# Deja la cuenta de AWS como estaba antes del bootstrap. Se corre en tu maquina,
# con las mismas credenciales de administrador que usaste para el bootstrap:
#
#   bash infra/unapply.sh
#
# 1. Destruye el stack de MLflow si sigue en pie (lo mismo que el workflow
#    destroy; si ya lo corriste, no hace nada).
# 2. Vacia el bucket del estado de Terraform (es versionado: todas las versiones).
# 3. Destruye el bootstrap: bucket del estado, proveedor OIDC y roles IAM.
#
# Solo toca lo que crea este proyecto. Se puede repetir si falla a medias.
set -euo pipefail
cd "$(dirname "$0")"

for cmd in terraform aws; do
    command -v "$cmd" >/dev/null || { echo "Falta $cmd en el PATH"; exit 1; }
done

if [ -z "$(terraform -chdir=bootstrap state list 2>/dev/null)" ]; then
    echo "infra/bootstrap no tiene recursos en su estado: no hay nada que borrar."
    exit 0
fi

# Region, bucket y cuenta salen del estado local del bootstrap.
vars=$(terraform -chdir=bootstrap output -json github_variables | tr -d ' \n')
get() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<<"$vars"; }
REGION=$(get AWS_REGION)
BUCKET=$(get TF_STATE_BUCKET)
ACCOUNT=$(get AWS_ROLE_ARN | cut -d: -f5)

# Evita borrar en otra cuenta (por ejemplo, con credenciales del Learner Lab).
CURRENT=$(aws sts get-caller-identity --query Account --output text)
if [ "$CURRENT" != "$ACCOUNT" ]; then
    echo "Tus credenciales son de la cuenta $CURRENT, pero el bootstrap esta en $ACCOUNT. Cancelado."
    exit 1
fi

echo "Cuenta $ACCOUNT, region $REGION. Se borrara:"
echo "  - el stack de MLflow si sigue en pie: EC2, red, IP, modelos en S3 e imagenes en ECR"
echo "  - el bucket $BUCKET con el estado de Terraform"
echo "  - el proveedor OIDC de GitHub y los roles de GitHub Actions y de la EC2"
read -r -p 'Escribe "borrar" para continuar: ' ok
[ "$ok" = borrar ] || { echo "Cancelado."; exit 1; }

echo "== 1/3 Stack de MLflow"
if aws s3api head-object --bucket "$BUCKET" --key mlflow/terraform.tfstate \
    --region "$REGION" >/dev/null 2>&1; then
    export TF_VAR_region="$REGION"
    terraform -chdir=terraform init -input=false -reconfigure \
        -backend-config="bucket=$BUCKET" -backend-config="region=$REGION"
    terraform -chdir=terraform destroy -input=false -auto-approve
else
    echo "No hay estado del stack: nunca se desplego o ya se borro."
fi

echo "== 2/3 Vaciando $BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
    for kind in Versions DeleteMarkers; do
        while :; do
            objs=$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" \
                --max-items 1000 --query "${kind}[].{Key: Key, VersionId: VersionId}" --output json)
            if [ "$objs" = null ] || [ "$objs" = "[]" ]; then
                break
            fi
            aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" \
                --delete "{\"Objects\": $objs, \"Quiet\": true}" >/dev/null
        done
    done
else
    echo "El bucket ya no existe."
fi

echo "== 3/3 Bootstrap"
terraform -chdir=bootstrap init -input=false >/dev/null
# destroy no usa github_repo, pero la variable es obligatoria.
terraform -chdir=bootstrap destroy -input=false -auto-approve \
    -var "region=$REGION" -var "github_repo=x/x"

echo "Listo: la cuenta $ACCOUNT ya no tiene nada de este proyecto."
echo "Puedes borrar las variables AWS_* y TF_STATE_BUCKET del repo en GitHub."
