output "db_endpoint" {
  value = aws_db_instance.this.address
}

output "db_instance_id" {
  value = aws_db_instance.this.id
}

output "security_group_id" {
  value = aws_security_group.db.id
}

output "secret_arn" {
  value = aws_secretsmanager_secret.db_credentials.arn
}
