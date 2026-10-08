variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets to place the ALB in (public subnets for internet-facing, private for internal)"
  type        = list(string)
}

variable "internal" {
  description = "true = internal ALB (app tier), false = internet-facing ALB (web tier)"
  type        = bool
  default     = false
}

variable "listener_port" {
  type    = number
  default = 443
}

variable "listener_protocol" {
  type    = string
  default = "HTTPS"
}

variable "certificate_arn" {
  description = "ACM certificate ARN, required when listener_protocol = HTTPS"
  type        = string
  default     = null
}

variable "target_port" {
  type = number
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "ingress_cidr_blocks" {
  description = "CIDR blocks allowed to reach the ALB listener (e.g. 0.0.0.0/0 for public, peer VPC CIDR for internal)"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
