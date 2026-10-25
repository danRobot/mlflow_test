output "mlflow_url" {
  value = "http://${aws_eip.mlflow.public_ip}:8080"
}

# Los siguientes los usa el workflow de deploy.
output "public_ip" {
  value = aws_eip.mlflow.public_ip
}

output "instance_id" {
  value = aws_instance.mlflow.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.mlflow.repository_url
}

output "auth_parameter" {
  description = "Parametro SSM con la clave de la UI (vacio si no hay auth)"
  value       = try(aws_ssm_parameter.auth[0].name, "")
}
