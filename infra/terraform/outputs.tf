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

output "log_group" {
  description = "Log group de CloudWatch con apagados y errores de memoria de la EC2"
  value       = aws_cloudwatch_log_group.ec2.name
}
