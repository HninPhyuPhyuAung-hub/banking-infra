variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets to run tasks in (awsvpc networking)"
  type        = list(string)
}

variable "cluster_id" {
  description = "ECS cluster ARN (or name) used as the `cluster` argument on the service"
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster short name, used to build the App Auto Scaling resource_id"
  type        = string
}

variable "container_image" {
  description = "Full image URI including tag, e.g. <acct>.dkr.ecr.<region>.amazonaws.com/banking-api:latest"
  type        = string
}

variable "container_port" {
  type = number
}

variable "cpu" {
  description = "Fargate task CPU units (256 = .25 vCPU, 512 = .5 vCPU, ...)"
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 512
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 4
}

variable "environment" {
  description = "Plain-text environment variables for the container"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Env vars sourced from Secrets Manager/SSM at task start, map of env var name -> secret ARN"
  type        = map(string)
  default     = {}
}

variable "alb_security_group_id" {
  type = string
}

variable "alb_target_group_arn" {
  type = string
}

variable "extra_ingress_cidr_blocks" {
  description = "Additional CIDR blocks allowed to reach container_port (e.g. peer VPC CIDR when the ALB lives there)"
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
