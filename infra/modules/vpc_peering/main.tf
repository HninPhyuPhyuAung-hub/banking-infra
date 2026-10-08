terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# Same account + same region peering, so auto_accept works in one resource.
resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.requester_vpc_id
  peer_vpc_id = var.accepter_vpc_id
  auto_accept = true

  tags = merge(var.tags, { Name = "frontend-backend-peering" })
}

# Allow the frontend side to resolve the backend's private/internal DNS
# names (e.g. the internal ALB) across the peering connection, and vice versa.
resource "aws_vpc_peering_connection_options" "this" {
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

# Routes on the requester side (e.g. frontend private subnets) pointing at
# the accepter VPC's CIDR (backend).
resource "aws_route" "requester_to_accepter" {
  for_each                  = { for index, id in var.requester_route_table_ids : tostring(index) => id }
  route_table_id            = each.value
  destination_cidr_block    = var.requester_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# Routes on the accepter side (e.g. backend subnets) pointing back at the
# requester VPC's CIDR (frontend).
resource "aws_route" "accepter_to_requester" {
  for_each                  = { for index, id in var.accepter_route_table_ids : tostring(index) => id }
  route_table_id            = each.value
  destination_cidr_block    = var.accepter_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}
