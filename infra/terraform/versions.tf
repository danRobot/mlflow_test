terraform {
  required_version = ">= 1.11" # write-only (value_wo) en el parametro SSM

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Estado en S3, en un bucket que crea el workflow de deploy y borra el de
  # destroy. El workflow pasa bucket y region con `terraform init -backend-config=...`.
  backend "s3" {
    key          = "mlflow/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
