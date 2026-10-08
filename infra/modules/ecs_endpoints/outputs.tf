output "security_group_id" {
  value = aws_security_group.endpoints.id
}

output "s3_prefix_list_id" {
  value = aws_vpc_endpoint.s3.prefix_list_id
}
