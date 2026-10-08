variable "requester_vpc_id" {
  type = string
}

variable "accepter_vpc_id" {
  type = string
}

variable "requester_cidr_block" {
  description = "CIDR of the peer (accepter) VPC, used for routes added on the requester side"
  type        = string
}

variable "accepter_cidr_block" {
  description = "CIDR of the requester VPC, used for routes added on the accepter side"
  type        = string
}

variable "requester_route_table_ids" {
  description = "Ordered route tables on the requester side; keep order stable because route instance keys use list indices"
  type        = list(string)
  default     = []
}

variable "accepter_route_table_ids" {
  description = "Ordered route tables on the accepter side; keep order stable because route instance keys use list indices"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
