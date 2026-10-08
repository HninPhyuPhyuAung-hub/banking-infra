variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "azs" {
  type    = list(string)
  default = ["ap-southeast-1a", "ap-southeast-1b"]
}

# ---------------------------------------------------------------------------
# Frontend VPC (Blazor dashboard — web tier)
# ---------------------------------------------------------------------------
variable "frontend_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "frontend_public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.5.0/24"]
}

variable "frontend_private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.2.0/24", "10.0.6.0/24"]
}

# ---------------------------------------------------------------------------
# Backend VPC (ASP.NET Core API + RDS — app & data tier)
# ---------------------------------------------------------------------------
variable "backend_vpc_cidr" {
  type    = string
  default = "192.168.0.0/16"
}

variable "backend_public_subnet_cidrs" {
  description = "Only used for NAT Gateways so the API tier can reach the internet (e.g. pulling images, OS patches)"
  type        = list(string)
  default     = ["192.168.1.0/24", "192.168.5.0/24"]
}

variable "backend_private_subnet_cidrs" {
  type    = list(string)
  default = ["192.168.2.0/24", "192.168.6.0/24"]
}

variable "backend_database_subnet_cidrs" {
  type    = list(string)
  default = ["192.168.3.0/24", "192.168.4.0/24"]
}

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
variable "private_domain_name" {
  description = "Private DNS namespace used for the ALB's internal hostname + cert (e.g. dashboard.<this> is the cert's domain name)"
  type        = string
  default     = "dev.banking.internal"
}

variable "frontend_container_port" {
  type    = number
  default = 8081
}

variable "backend_container_port" {
  type    = number
  default = 8080
}

variable "image_tag" {
  description = "Tag to deploy for both ECR images. CI/CD pushes a new tag (e.g. the git SHA) and updates this before re-applying / forcing a new ECS deployment"
  type        = string
  default     = "latest"
}

variable "backend_fargate_cpu" {
  type    = number
  default = 256
}

variable "backend_fargate_memory" {
  type    = number
  default = 512
}

variable "frontend_fargate_cpu" {
  type    = number
  default = 256
}

variable "frontend_fargate_memory" {
  type    = number
  default = 512
}

variable "backend_desired_count" {
  type    = number
  default = 2
}

variable "frontend_desired_count" {
  type    = number
  default = 2
}
