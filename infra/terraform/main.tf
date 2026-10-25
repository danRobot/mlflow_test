data "aws_caller_identity" "current" {}

# Amazon Linux 2023: trae el agente de SSM y la AWS CLI instalados.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# Zonas estandar (sin Local ni Wavelength Zones) que ofrecen el tipo de instancia.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ec2_instance_type_offerings" "this" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

locals {
  az = sort(setintersection(
    data.aws_availability_zones.available.names,
    data.aws_ec2_instance_type_offerings.this.locations,
  ))[0]
}

# ---------------------------------------------------------------------------
# Red: VPC propia con una subred publica. Destroy la borra entera.
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = var.project }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.project }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public" }

  # La zona se fija en el primer apply: si despues cambia la elegida, no se
  # recrea la subred (ni la instancia con Postgres).
  lifecycle {
    ignore_changes = [availability_zone]
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Solo el puerto de MLflow. Sin SSH: a la instancia se entra por SSM.
resource "aws_security_group" "mlflow" {
  name        = "${var.project}-server"
  description = "MLflow UI y API"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "MLflow"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# Artefactos (modelos) en S3. force_destroy: destroy lo vacia y lo borra.
#   artifacts/ -> lo que guarda MLflow
#   deploy/    -> compose y deploy.sh que sube el workflow
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project}-artifacts-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# Imagen del servidor en ECR. force_delete: destroy borra tambien las imagenes.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "mlflow" {
  name                 = "${var.project}-server"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
}

# Clave de la UI (opcional). Write-only: no queda guardada en el estado.
# La instancia la lee en cada deploy.
resource "aws_ssm_parameter" "auth" {
  count            = nonsensitive(var.mlflow_auth_password != "") ? 1 : 0
  name             = "/${var.project}/auth-password"
  type             = "SecureString"
  value_wo         = var.mlflow_auth_password
  value_wo_version = 1
}

# ---------------------------------------------------------------------------
# Servidor. Sin user_data: Docker y el stack los instala deploy.sh por SSM,
# asi cada deploy aplica los cambios sin recrear la instancia.
# ---------------------------------------------------------------------------
resource "aws_instance" "mlflow" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.mlflow.id]
  iam_instance_profile   = var.instance_profile # el Learner Lab no deja crear roles

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # los contenedores obtienen el rol via IMDS
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = { Name = "${var.project}-server" }

  # Una AMI nueva no debe recrear el servidor: se perderia Postgres.
  lifecycle {
    ignore_changes = [ami]
  }
}

# El Learner Lab detiene la EC2 al terminar la sesion: cada deploy la enciende.
resource "aws_ec2_instance_state" "mlflow" {
  instance_id = aws_instance.mlflow.id
  state       = "running"
}

# IP fija mientras exista el stack: se mantiene aunque la sesion detenga la EC2.
resource "aws_eip" "mlflow" {
  domain   = "vpc"
  instance = aws_instance.mlflow.id
  tags     = { Name = "${var.project}-server" }

  depends_on = [aws_internet_gateway.this]
}
