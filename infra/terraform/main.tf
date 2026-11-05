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
# El bucket de artefactos NO lo gestiona Terraform: el provider lee siempre su
# configuracion de Object Lock y la politica (SCP) del Learner Lab lo prohibe.
# Lo crea el workflow de deploy con la CLI y lo borra el de destroy.
#
# Estos bloques sacan del estado el bucket de versiones anteriores sin leerlo
# ni borrarlo. Se pueden quitar cuando ya no quede ningun estado antiguo.
# ---------------------------------------------------------------------------
removed {
  from = aws_s3_bucket.artifacts
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_public_access_block.artifacts
  lifecycle {
    destroy = false
  }
}

# ---------------------------------------------------------------------------
# Imagen del servidor en ECR. force_delete: destroy borra tambien las imagenes.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "mlflow" {
  name                 = "${var.project}-server"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
}

# Clave de Postgres (secret POSTGRES_PASSWORD). Write-only: no queda en el
# estado. La version sale de un hash de la clave, asi que cambiar el secret
# actualiza el parametro; deploy.sh lo lee y fija la clave en la base.
resource "aws_ssm_parameter" "postgres" {
  name             = "/${var.project}/postgres-password"
  type             = "SecureString"
  value_wo         = var.postgres_password
  value_wo_version = parseint(substr(sha256(var.postgres_password), 0, 8), 16)
}

# Acceso a Google Drive para los respaldos (secret GDRIVE_RCLONE_CONF): la
# configuracion de rclone con el token. Igual que la clave de Postgres:
# write-only y versionada por hash. Los scripts de infra/scripts lo leen en
# cada respaldo. Sin el secret no se crea y no hay respaldos.
resource "aws_ssm_parameter" "gdrive" {
  count = nonsensitive(var.gdrive_rclone_conf != "") ? 1 : 0

  name             = "/${var.project}/gdrive-rclone-conf"
  type             = "SecureString"
  value_wo         = var.gdrive_rclone_conf
  value_wo_version = parseint(substr(sha256(var.gdrive_rclone_conf), 0, 8), 16)
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
  iam_instance_profile   = "${var.project}-ec2" # lo crea infra/bootstrap

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

# IP fija mientras exista el stack (sobrevive a reinicios de la instancia).
resource "aws_eip" "mlflow" {
  domain   = "vpc"
  instance = aws_instance.mlflow.id
  tags     = { Name = "${var.project}-server" }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Registro de errores en CloudWatch Logs al minimo costo: sin metricas, sin
# alarmas y sin agente. Solo llegan eventos sueltos de ~1 KB, y CloudWatch Logs
# cobra US$0.50 por GB ingerido: fracciones de centavo al mes.
#   - Apagados de la EC2 (stopping, stopped, shutting-down, terminated):
#     EventBridge, gratis para eventos de AWS dentro de la misma cuenta.
#   - Falta de memoria (OOM killer): lo envia infra/oom-alert.sh desde la EC2.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ec2" {
  name              = "/${var.project}/ec2"
  retention_in_days = 7
}

resource "aws_cloudwatch_event_rule" "ec2_state" {
  name        = "${var.project}-ec2-apagado"
  description = "Apagados y terminaciones de la EC2 de MLflow"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
    detail = {
      "instance-id" = [aws_instance.mlflow.id]
      state         = ["stopping", "stopped", "shutting-down", "terminated"]
    }
  })
}

resource "aws_cloudwatch_event_target" "ec2_state" {
  rule = aws_cloudwatch_event_rule.ec2_state.name
  arn  = aws_cloudwatch_log_group.ec2.arn
}

# Permite a EventBridge escribir en el log group (politica de recurso, sin roles).
resource "aws_cloudwatch_log_resource_policy" "eventbridge" {
  policy_name = "${var.project}-eventbridge"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.ec2.arn}:*"
    }]
  })
}

# ---------------------------------------------------------------------------
# Accesos a MLflow. Docker envia aqui la salida del contenedor con su driver
# awslogs (sin agente): una linea por peticion con la IP remota, mas avisos y
# errores del servidor. Cada linea son ~150 bytes, asi que incluso con
# escaneos de internet son centavos al mes.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "server" {
  name              = "/${var.project}/server"
  retention_in_days = 30
}

# Consultas guardadas en CloudWatch > Logs Insights > Saved queries (gratis;
# cada ejecucion cobra US$0.005 por GB leido). Solo cuentan IPs publicas: asi
# quedan fuera el healthcheck de Docker (127.0.0.1) y las peticiones de la
# propia instancia, que llegan desde la red de Docker (172.16.0.0/12).
locals {
  # Linea de acceso de uvicorn (formato de MLflow 3.x):
  #   2026/11/02 22:41:43 INFO:     203.0.113.7:48740 - "GET /api/2.0/... HTTP/1.1" 200 OK
  accesos_publicos = trimspace(<<-EOT
    parse @message /(?<ip>\d+\.\d+\.\d+\.\d+):\d+ - "(?<metodo>\S+) (?<ruta>\S+) [^"]+" (?<estado>\d+)/
    | filter isPublicIP(ip)
  EOT
  )
}

resource "aws_cloudwatch_query_definition" "accesos_por_ip" {
  name            = "${var.project}/accesos-por-ip"
  log_group_names = [aws_cloudwatch_log_group.server.name]
  query_string    = <<-EOT
    ${local.accesos_publicos}
    | stats count(*) as accesos, countDistinct(ruta) as rutas, earliest(@timestamp) as primero, latest(@timestamp) as ultimo by ip
    | sort accesos desc
    | limit 1000
  EOT
}

resource "aws_cloudwatch_query_definition" "accesos_por_hora" {
  name            = "${var.project}/accesos-por-hora"
  log_group_names = [aws_cloudwatch_log_group.server.name]
  query_string    = <<-EOT
    ${local.accesos_publicos}
    | stats count(*) as accesos, countDistinct(ip) as ips by bin(1h)
  EOT
}

resource "aws_cloudwatch_query_definition" "accesos_detalle" {
  name            = "${var.project}/accesos-detalle"
  log_group_names = [aws_cloudwatch_log_group.server.name]
  query_string    = <<-EOT
    ${local.accesos_publicos}
    | fields @timestamp, ip, metodo, ruta, estado
    | sort @timestamp desc
    | limit 1000
  EOT
}
