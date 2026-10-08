output "private_ca_arn" {
  description = "ARN of the activated Private CA — consumed by envs/dev via terraform_remote_state to request both ALB certificates"
  value       = aws_acmpca_certificate_authority.root.arn

  # Make sure anything reading this output only sees it after the CA is
  # actually activated, not just created (created-but-unactivated CAs
  # can't issue certificates yet).
  depends_on = [aws_acmpca_certificate_authority_certificate.root, aws_acmpca_permission.acm]
}

output "root_ca_certificate_pem" {
  description = "Public root CA certificate to install in client trust stores (not a private key)"
  value       = aws_acmpca_certificate.root.certificate
}
