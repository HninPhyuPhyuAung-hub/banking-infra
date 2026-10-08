data "aws_caller_identity" "current" {}

# Reads the Private CA ARN from the separate, long-lived ../../pca config so
# this environment can request its own ACM certificate without redoing (or
# depending directly on) that config.
data "terraform_remote_state" "pca" {
  backend = "s3"
  config = {
    bucket = "banking-app-tfstate-439475769687" # must match providers.tf backend bucket
    key    = "pca/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

data "terraform_remote_state" "ecr" {
  backend = "s3"
  config = {
    bucket = "banking-app-tfstate-439475769687"
    key    = "ecr/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# =============================================================================
# Frontend VPC — Blazor dashboard (web tier)
# =============================================================================
module "frontend_vpc" {
  source = "../../modules/vpc"

  name                  = "frontend"
  cidr_block            = var.frontend_vpc_cidr
  azs                   = var.azs
  public_subnet_cidrs   = var.frontend_public_subnet_cidrs
  private_subnet_cidrs  = var.frontend_private_subnet_cidrs
  database_subnet_cidrs = []
  enable_nat_gateway    = false

  tags = { Tier = "web" }
}

# =============================================================================
# Backend VPC — ASP.NET Core API + RDS (app & data tier)
# =============================================================================
module "backend_vpc" {
  source = "../../modules/vpc"

  name                  = "backend"
  cidr_block            = var.backend_vpc_cidr
  azs                   = var.azs
  public_subnet_cidrs   = []
  private_subnet_cidrs  = var.backend_private_subnet_cidrs
  database_subnet_cidrs = var.backend_database_subnet_cidrs
  enable_nat_gateway    = false

  tags = { Tier = "app" }
}

# =============================================================================
# VPC Peering — frontend private subnets <-> backend internal ALB/API subnets
# =============================================================================
module "vpc_peering" {
  source = "../../modules/vpc_peering"

  requester_vpc_id     = module.frontend_vpc.vpc_id
  accepter_vpc_id      = module.backend_vpc.vpc_id
  requester_cidr_block = var.backend_vpc_cidr
  accepter_cidr_block  = var.frontend_vpc_cidr

  requester_route_table_ids = module.frontend_vpc.private_route_table_ids
  accepter_route_table_ids  = module.backend_vpc.private_route_table_ids

  tags = { Name = "frontend-backend-peering" }
}

# =============================================================================
# ECS clusters — one per tier/VPC
# =============================================================================
resource "aws_ecs_cluster" "frontend" {
  name = "frontend-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Tier = "web" }
}

resource "aws_ecs_cluster" "backend" {
  name = "backend-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Tier = "app" }
}

# =============================================================================
# Private certificate for the public ALB's HTTPS listener — issued directly
# by the Private CA (../../pca), no DNS validation step needed since trust
# comes from the CA itself, not proof of domain ownership.
# =============================================================================
resource "aws_acm_certificate" "dashboard" {
  domain_name               = "dashboard.${var.private_domain_name}"
  certificate_authority_arn = data.terraform_remote_state.pca.outputs.private_ca_arn

  options {
    certificate_transparency_logging_preference = "DISABLED" # not applicable to private certs
  }

  tags = { Name = "banking-app-dashboard-dev" }
}

resource "aws_acm_certificate" "api" {
  domain_name               = "api.${var.private_domain_name}"
  certificate_authority_arn = data.terraform_remote_state.pca.outputs.private_ca_arn

  options {
    certificate_transparency_logging_preference = "DISABLED"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "banking-app-api-dev" }
}

# =============================================================================
# Public ALB — fronts the Blazor dashboard (HTTPS from the internet)
# =============================================================================
module "frontend_alb" {
  source = "../../modules/alb"

  name                = "frontend"
  vpc_id              = module.frontend_vpc.vpc_id
  subnet_ids          = module.frontend_vpc.public_subnet_ids
  internal            = false
  listener_port       = 443
  listener_protocol   = "HTTPS"
  certificate_arn     = aws_acm_certificate.dashboard.arn
  target_port         = var.frontend_container_port
  health_check_path   = "/health"
  ingress_cidr_blocks = ["0.0.0.0/0"]

  tags = { Tier = "web" }
}

# =============================================================================
# Private hosted zone — resolves dashboard.<private_domain_name> to the
# public ALB from inside the VPC. Private (not internet-facing) namespace;
# this is just for a friendly internal hostname matching the cert above,
# the ALB itself is still reachable from the internet via its public IPs.
# =============================================================================
resource "aws_route53_zone" "private" {
  name = var.private_domain_name

  vpc {
    vpc_id = module.frontend_vpc.vpc_id
  }

  vpc {
    vpc_id = module.backend_vpc.vpc_id
  }

  tags = { Name = "banking-app-private-zone" }
}

resource "aws_route53_record" "dashboard" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "dashboard.${var.private_domain_name}"
  type    = "A"

  alias {
    name                   = module.frontend_alb.alb_dns_name
    zone_id                = module.frontend_alb.alb_zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# Internal ALB — fronts the ASP.NET Core API, reachable only from the
# frontend VPC across the peering connection
# =============================================================================
module "backend_alb" {
  source = "../../modules/alb"

  name                = "backend"
  vpc_id              = module.backend_vpc.vpc_id
  subnet_ids          = module.backend_vpc.private_subnet_ids
  internal            = true
  listener_port       = 443
  listener_protocol   = "HTTPS"
  certificate_arn     = aws_acm_certificate.api.arn
  target_port         = var.backend_container_port
  health_check_path   = "/health"
  ingress_cidr_blocks = []

  tags = { Tier = "app" }

}

resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "api.${var.private_domain_name}"
  type    = "A"

  alias {
    name                   = module.backend_alb.alb_dns_name
    zone_id                = module.backend_alb.alb_zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# RDS Postgres — Multi-AZ, in the backend VPC's database subnets
# =============================================================================
module "rds" {
  source = "../../modules/rds"

  name          = "banking"
  vpc_id        = module.backend_vpc.vpc_id
  db_subnet_ids = module.backend_vpc.database_subnet_ids
  multi_az      = true

  allowed_security_group_ids = [module.backend_ecs_service.security_group_id]

  tags = { Tier = "data" }
}

# =============================================================================
# Backend ECS service — ASP.NET Core API, Fargate, in backend VPC
# =============================================================================
module "backend_ecs_service" {
  source = "../../modules/ecs_service"

  name         = "banking-api"
  vpc_id       = module.backend_vpc.vpc_id
  subnet_ids   = module.backend_vpc.private_subnet_ids
  cluster_id   = aws_ecs_cluster.backend.arn
  cluster_name = aws_ecs_cluster.backend.name

  container_image = "${data.terraform_remote_state.ecr.outputs.backend_ecr_repository_url}:${var.image_tag}"
  container_port  = var.backend_container_port
  cpu             = var.backend_fargate_cpu
  memory          = var.backend_fargate_memory
  desired_count   = var.backend_desired_count
  min_capacity    = 1
  max_capacity    = 4

  environment = {
    ASPNETCORE_URLS = "http://+:${var.backend_container_port}"
  }
  secrets = {
    ConnectionStrings__DefaultConnection = module.rds.secret_arn
  }

  alb_security_group_id = module.backend_alb.security_group_id
  alb_target_group_arn  = module.backend_alb.target_group_arn

  tags = { Tier = "app" }

  depends_on = [module.backend_endpoints]
}

# =============================================================================
# Frontend ECS service — Blazor dashboard, Fargate, in frontend VPC
# =============================================================================
module "frontend_ecs_service" {
  source = "../../modules/ecs_service"

  name         = "banking-dashboard"
  vpc_id       = module.frontend_vpc.vpc_id
  subnet_ids   = module.frontend_vpc.private_subnet_ids
  cluster_id   = aws_ecs_cluster.frontend.arn
  cluster_name = aws_ecs_cluster.frontend.name

  container_image = "${data.terraform_remote_state.ecr.outputs.frontend_ecr_repository_url}:${var.image_tag}"
  container_port  = var.frontend_container_port
  cpu             = var.frontend_fargate_cpu
  memory          = var.frontend_fargate_memory
  desired_count   = var.frontend_desired_count
  min_capacity    = 1
  max_capacity    = 4

  environment = {
    ASPNETCORE_URLS = "http://+:${var.frontend_container_port}"
    ApiBaseUrl      = "https://${aws_route53_record.api.fqdn}"
  }

  alb_security_group_id = module.frontend_alb.security_group_id
  alb_target_group_arn  = module.frontend_alb.target_group_arn

  tags = { Tier = "web" }

  depends_on = [module.vpc_peering, module.frontend_endpoints]
}
