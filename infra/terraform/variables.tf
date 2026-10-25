variable "project" {
  description = "Prefijo de los nombres de los recursos"
  type        = string
  default     = "mlflow"
}

variable "region" {
  description = "El Learner Lab solo permite us-east-1 y us-west-2"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "El Learner Lab solo permite us-east-1 y us-west-2."
  }
}

variable "instance_type" {
  type    = string
  default = "m7i-flex.large"
}

variable "instance_profile" {
  description = "Perfil de instancia ya creado por el Learner Lab (rol LabRole)"
  type        = string
  default     = "LabInstanceProfile"
}

variable "allowed_cidrs" {
  description = "Origenes permitidos en el puerto 8080. Abierto por defecto porque Colab usa IPs dinamicas."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "postgres_password" {
  description = "Clave del usuario mlflow de Postgres. Viene del secret POSTGRES_PASSWORD de GitHub (el deploy lo exige; destroy no lo necesita)."
  type        = string
  default     = ""
  sensitive   = true

  # Va dentro de la URL de conexion de MLflow: se limitan los caracteres para
  # no tener que escaparla.
  validation {
    condition     = var.postgres_password == "" || can(regex("^[A-Za-z0-9._~-]{8,}$", var.postgres_password))
    error_message = "POSTGRES_PASSWORD: al menos 8 caracteres, solo letras, numeros y . _ ~ -"
  }
}
