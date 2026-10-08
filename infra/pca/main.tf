# =============================================================================
# Private Certificate Authority (root CA)
#
# This is a long-lived, separately-managed piece of infra: ~$400/month while
# active, so it intentionally lives in its own Terraform config (not inside
# envs/dev) — you apply it once and leave it running, rather than tearing it
# down/recreating it every time you destroy/recreate the dev environment.
#
# envs/dev consumes this CA's ARN (via terraform_remote_state) to request a
# private ACM certificate for the frontend ALB — no DNS validation needed,
# since certs issued through a Private CA are trusted by whoever trusts the
# CA itself, not by proving domain ownership.
# =============================================================================

resource "aws_acmpca_certificate_authority" "root" {
  type = "ROOT"

  certificate_authority_configuration {
    key_algorithm     = "RSA_2048"
    signing_algorithm = "SHA256WITHRSA"

    subject {
      common_name  = var.ca_common_name
      organization = var.ca_organization
      country      = var.ca_country
    }
  }

  # How long a disabled/deleted CA lingers (and keeps billing) before AWS
  # permanently removes it. Keep this short in dev.
  permanent_deletion_time_in_days = var.permanent_deletion_window_days

  tags = { Name = "banking-app-root-ca" }
}

# A ROOT CA has to sign its own certificate to activate — AWS gives us the
# CSR, we ask the CA to issue a cert from it, then import that cert back
# onto the CA in the next resource. This three-step dance is exactly why
# Terraform (not manual CLI) is the better fit for this piece.
resource "aws_acmpca_certificate" "root" {
  certificate_authority_arn   = aws_acmpca_certificate_authority.root.arn
  certificate_signing_request = aws_acmpca_certificate_authority.root.certificate_signing_request
  signing_algorithm           = "SHA256WITHRSA"
  template_arn                = "arn:aws:acm-pca:::template/RootCACertificate/V1"

  validity {
    type  = "YEARS"
    value = 10
  }
}

# Activates the CA by importing its own self-signed root certificate.
resource "aws_acmpca_certificate_authority_certificate" "root" {
  certificate_authority_arn = aws_acmpca_certificate_authority.root.arn
  certificate               = aws_acmpca_certificate.root.certificate
}

resource "aws_acmpca_permission" "acm" {
  certificate_authority_arn = aws_acmpca_certificate_authority.root.arn
  principal                 = "acm.amazonaws.com"
  actions                   = ["IssueCertificate", "GetCertificate", "ListPermissions"]

  depends_on = [aws_acmpca_certificate_authority_certificate.root]
}
