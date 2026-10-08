variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "ca_common_name" {
  description = "Common name (CN) for the root Private CA, e.g. a name identifying your org/app"
  type        = string
  default     = "Banking App Dev Root CA"
}

variable "ca_organization" {
  type    = string
  default = "Banking App"
}

variable "ca_country" {
  description = "2-letter country code for the CA's distinguished name"
  type        = string
  default     = "SG"
}

variable "permanent_deletion_window_days" {
  description = "How long a deleted CA is retained before permanent deletion (7-30). Keep this low in dev so you're not billed for a lingering disabled CA."
  type        = number
  default     = 7
}
