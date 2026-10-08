output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  value = aws_subnet.database[*].id
}

output "public_route_table_id" {
  value = length(aws_route_table.public) > 0 ? aws_route_table.public[0].id : null
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}

output "database_route_table_ids" {
  value = aws_route_table.database[*].id
}

output "nat_gateway_ids" {
  value = aws_nat_gateway.this[*].id
}
