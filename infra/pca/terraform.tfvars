aws_region      = "ap-southeast-1"
ca_common_name  = "Banking App Dev Root CA"
ca_organization = "Banking App"
ca_country      = "SG"

# Keep short in dev so a destroyed CA stops billing sooner. AWS allows 7-30.
permanent_deletion_window_days = 7
