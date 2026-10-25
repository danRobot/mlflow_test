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

variable "mlflow_auth_password" {
  description = "Si no esta vacio activa usuario y clave en MLflow (usuario admin). Viene del secret de GitHub."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.mlflow_auth_password == "" || length(var.mlflow_auth_password) >= 12
    error_message = "MLFLOW_AUTH_PASSWORD debe tener al menos 12 caracteres (lo exige MLflow)."
  }
}
