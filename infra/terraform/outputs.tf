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

output "postgres_parameter" {
  description = "Parametro SSM con la clave de Postgres"
  value       = aws_ssm_parameter.postgres.name
}

output "auth_parameter" {
  description = "Parametro SSM con usuario:clave de MLflow (vacio sin autenticacion)"
  value       = try(aws_ssm_parameter.mlflow_auth[0].name, "")
}

output "log_group" {
  description = "Log group de CloudWatch con apagados y errores de memoria de la EC2"
  value       = aws_cloudwatch_log_group.ec2.name
}

output "pruebas_instance_id" {
  description = "EC2 de pruebas (vacio con la variable PRUEBAS en N)"
  value       = try(aws_instance.pruebas[0].id, "")
}

output "pruebas_env_parameter" {
  description = "Parametro SSM con los secretos de la EC2 de pruebas"
  value       = try(aws_ssm_parameter.pruebas_env[0].name, "")
}

output "pruebas_sa_parameter" {
  description = "Parametro SSM con la llave de la service account de DVC (vacio sin el secret GDRIVE_JSON)"
  value       = try(aws_ssm_parameter.pruebas_sa[0].name, "")
}

output "server_log_group" {
  description = "Log group de CloudWatch con la salida de MLflow: accesos con IP remota y errores"
  value       = aws_cloudwatch_log_group.server.name
}
