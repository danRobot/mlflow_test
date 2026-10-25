terraform {
  required_version = ">= 1.11" # write-only (value_wo) en el parametro SSM

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Estado en el bucket que crea infra/bootstrap. El workflow pasa bucket y
  # region con `terraform init -backend-config=...`.
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
