output "backend_ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "frontend_ecr_repository_url" {
  value = aws_ecr_repository.frontend.repository_url
}

output "backend_ecr_repository_arn" {
  value = aws_ecr_repository.backend.arn
}

output "frontend_ecr_repository_arn" {
  value = aws_ecr_repository.frontend.arn
}
