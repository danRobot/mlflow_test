# Se aplica UNA sola vez desde tu maquina, con credenciales de administrador:
#
#   terraform init
#   terraform apply -var github_repo=<owner>/<repo>
#
# Crea lo que debe existir antes de que corran los workflows: el bucket del
# estado de Terraform, el rol que asumen por OIDC (sin access keys) y el rol de
# la instancia EC2. El estado de este bootstrap queda en local (terraform.tfstate).

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "github_repo" {
  description = "Repositorio que podra desplegar: owner/repo, tal cual aparece en GitHub"
  type        = string

  validation {
    condition     = length(split("/", var.github_repo)) == 2
    error_message = "Usa el formato owner/repo."
  }
}

variable "github_branch" {
  description = "Rama desde la que se permite lanzar deploy y destroy"
  type        = string
  default     = "main"
}

variable "project" {
  description = "Mismo valor que en infra/terraform"
  type        = string
  default     = "mlflow"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "create_oidc_provider" {
  description = "false si la cuenta ya tiene el proveedor OIDC de GitHub (solo puede haber uno)"
  type        = bool
  default     = true
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  oidc    = "token.actions.githubusercontent.com"
  owner   = split("/", var.github_repo)[0]
  repo    = split("/", var.github_repo)[1]
  ref     = "ref:refs/heads/${var.github_branch}"
}

# --- Estado de Terraform -----------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tfstate-${local.account}-${var.region}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Rol de la instancia EC2 -------------------------------------------------
# Vive aqui y no en infra/terraform: asi GitHub Actions no necesita permisos
# para crear roles (con ellos podria darse permisos de administrador).
resource "aws_iam_role" "ec2" {
  name = "${var.project}-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Deploy por SSM. Incluye ssm:GetParameter, con el que se lee la clave de la UI.
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Bajar la imagen de su repositorio de ECR y guardar artefactos en S3. Escritura
# solo en artifacts/: el contenedor no puede modificar deploy/, que se ejecuta
# como root en la instancia.
resource "aws_iam_role_policy" "ec2" {
  name = "mlflow-server"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = "arn:aws:ecr:*:${local.account}:repository/${var.project}-server"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.project}-artifacts-${local.account}-*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${var.project}-artifacts-${local.account}-*/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = "arn:aws:s3:::${var.project}-artifacts-${local.account}-*/artifacts/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2"
  role = aws_iam_role.ec2.name
}

# --- Rol de GitHub Actions (OIDC) -------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.oidc}"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "github" {
  name = "github-actions-${var.project}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${local.account}:oidc-provider/${local.oidc}" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "${local.oidc}:aud" = "sts.amazonaws.com" }
        # Formato clasico y formato inmutable (owner@id/repo@id), que GitHub usa
        # en los repos creados o renombrados desde el 15/07/2026.
        StringLike = {
          "${local.oidc}:sub" = [
            "repo:${var.github_repo}:${local.ref}",
            "repo:${local.owner}@*/${local.repo}@*:${local.ref}",
          ]
        }
      }
    }]
  })

  depends_on = [aws_iam_openid_connect_provider.github]
}

# Lo que necesitan terraform apply/destroy y el deploy por SSM. De IAM solo
# puede pasar el rol de la instancia a EC2.
resource "aws_iam_role_policy" "github" {
  name = "deploy-${var.project}"
  role = aws_iam_role.github.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Infra"
        Effect   = "Allow"
        Action   = ["ec2:*", "ecr:*", "ssm:*"]
        Resource = "*"
      },
      {
        Sid      = "Buckets" # estado de Terraform y artefactos
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = ["arn:aws:s3:::${var.project}-*", "arn:aws:s3:::${var.project}-*/*"]
      },
      {
        Sid       = "PassInstanceRole"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.ec2.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      },
    ]
  })
}

output "github_variables" {
  description = "Crea estas variables en GitHub: Settings > Secrets and variables > Actions > Variables"
  value = {
    AWS_REGION      = var.region
    AWS_ROLE_ARN    = aws_iam_role.github.arn
    TF_STATE_BUCKET = aws_s3_bucket.tfstate.bucket
  }
}
