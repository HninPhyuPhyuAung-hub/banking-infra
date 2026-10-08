terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_region" "current" {}

resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-endpoints-"
  description = "Private AWS service endpoints; task ingress managed by root"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-endpoints" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(concat(
    ["ecr.api", "ecr.dkr", "logs", "ssmmessages"],
    var.enable_secrets_manager ? ["secretsmanager"] : [],
  ))

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-${each.value}" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "arn:aws:s3:::prod-${data.aws_region.current.region}-starport-layer-bucket/*"
    }]
  })

  tags = { Name = "${var.name}-ecr-image-layers" }
}
