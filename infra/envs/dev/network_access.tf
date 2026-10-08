module "frontend_endpoints" {
  source = "../../modules/ecs_endpoints"

  name            = "frontend"
  vpc_id          = module.frontend_vpc.vpc_id
  subnet_ids      = module.frontend_vpc.private_subnet_ids
  route_table_ids = module.frontend_vpc.private_route_table_ids
}

module "backend_endpoints" {
  source = "../../modules/ecs_endpoints"

  name                   = "backend"
  vpc_id                 = module.backend_vpc.vpc_id
  subnet_ids             = module.backend_vpc.private_subnet_ids
  route_table_ids        = module.backend_vpc.private_route_table_ids
  enable_secrets_manager = true
}

# Standalone rules avoid circular dependencies between ALBs, tasks and RDS.
resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  for_each = {
    frontend = {
      alb_id  = module.frontend_alb.security_group_id
      task_id = module.frontend_ecs_service.security_group_id
      port    = var.frontend_container_port
    }
    backend = {
      alb_id  = module.backend_alb.security_group_id
      task_id = module.backend_ecs_service.security_group_id
      port    = var.backend_container_port
    }
  }

  security_group_id            = each.value.alb_id
  referenced_security_group_id = each.value.task_id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "frontend_to_api" {
  security_group_id            = module.frontend_ecs_service.security_group_id
  referenced_security_group_id = module.backend_alb.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443

  depends_on = [module.vpc_peering]
}

resource "aws_vpc_security_group_ingress_rule" "api_from_frontend" {
  security_group_id            = module.backend_alb.security_group_id
  referenced_security_group_id = module.frontend_ecs_service.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443

  depends_on = [module.vpc_peering]
}

resource "aws_vpc_security_group_egress_rule" "backend_to_db" {
  security_group_id            = module.backend_ecs_service.security_group_id
  referenced_security_group_id = module.rds.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

locals {
  task_endpoint_access = {
    frontend = {
      task_id     = module.frontend_ecs_service.security_group_id
      endpoint_id = module.frontend_endpoints.security_group_id
      s3_prefix   = module.frontend_endpoints.s3_prefix_list_id
    }
    backend = {
      task_id     = module.backend_ecs_service.security_group_id
      endpoint_id = module.backend_endpoints.security_group_id
      s3_prefix   = module.backend_endpoints.s3_prefix_list_id
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_endpoints" {
  for_each = local.task_endpoint_access

  security_group_id            = each.value.task_id
  referenced_security_group_id = each.value.endpoint_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_tasks" {
  for_each = local.task_endpoint_access

  security_group_id            = each.value.endpoint_id
  referenced_security_group_id = each.value.task_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_image_layers" {
  for_each = local.task_endpoint_access

  security_group_id = each.value.task_id
  prefix_list_id    = each.value.s3_prefix
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
