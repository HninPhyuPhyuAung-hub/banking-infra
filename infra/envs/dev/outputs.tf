output "frontend_alb_dns_name" {
  description = "Public URL users hit (point Route 53 alias record at this)"
  value       = module.frontend_alb.alb_dns_name
}

output "backend_alb_dns_name" {
  description = "Internal DNS name of the API ALB (only resolvable/reachable from within the peered VPCs)"
  value       = module.backend_alb.alb_dns_name
}

output "backend_api_url" {
  description = "HTTPS API URL resolving in the associated VPCs; clients must trust the private CA"
  value       = "https://${aws_route53_record.api.fqdn}"
}

output "backend_certificate_arn" {
  value = aws_acm_certificate.api.arn
}

output "rds_endpoint" {
  value = module.rds.db_endpoint
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN holding the generated DB credentials"
  value       = module.rds.secret_arn
}

output "frontend_vpc_id" {
  value = module.frontend_vpc.vpc_id
}

output "backend_vpc_id" {
  value = module.backend_vpc.vpc_id
}

output "vpc_peering_connection_id" {
  value = module.vpc_peering.peering_connection_id
}

output "backend_ecr_repository_url" {
  description = "Push backend images here, e.g. docker push <this>:latest"
  value       = data.terraform_remote_state.ecr.outputs.backend_ecr_repository_url
}

output "frontend_ecr_repository_url" {
  description = "Push frontend images here, e.g. docker push <this>:latest"
  value       = data.terraform_remote_state.ecr.outputs.frontend_ecr_repository_url
}

output "backend_ecs_cluster_name" {
  value = aws_ecs_cluster.backend.name
}

output "frontend_ecs_cluster_name" {
  value = aws_ecs_cluster.frontend.name
}

output "backend_ecs_service_name" {
  value = module.backend_ecs_service.service_name
}

output "frontend_ecs_service_name" {
  value = module.frontend_ecs_service.service_name
}

output "backend_ecs_log_group_name" {
  description = "CloudWatch Logs group for backend container stdout/stderr"
  value       = module.backend_ecs_service.log_group_name
}

output "frontend_ecs_log_group_name" {
  description = "CloudWatch Logs group for frontend container stdout/stderr"
  value       = module.frontend_ecs_service.log_group_name
}
