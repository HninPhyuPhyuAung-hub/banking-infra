resource "aws_kms_key" "ecr" {
  description         = "KMS key for ECR image encryption at rest"
  enable_key_rotation = true
  tags                = { Name = "banking-app-ecr-kms" }
}

resource "aws_ecr_repository" "backend" {
  name                 = "banking-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = { Tier = "app" }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "banking-dashboard"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = { Tier = "web" }
}

resource "aws_ecr_lifecycle_policy" "expire_untagged" {
  for_each   = { backend = aws_ecr_repository.backend.name, frontend = aws_ecr_repository.frontend.name }
  repository = each.value

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
