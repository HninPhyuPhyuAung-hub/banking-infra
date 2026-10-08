variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "db_subnet_ids" {
  type = list(string)
}

variable "engine_version" {
  type    = string
  default = "15.19"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "db_name" {
  type    = string
  default = "banking"
}

variable "master_username" {
  type    = string
  default = "bankadmin"
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "allowed_security_group_ids" {
  description = "Security groups (e.g. the backend ASG SG) allowed to connect on 5432"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
