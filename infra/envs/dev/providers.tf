terraform {
  required_version = ">= 1.11.0" # use_lockfile (native S3 locking) requires >= 1.11

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Remote state — bucket created using ../../s3/notes.md.
  # use_lockfile enables Terraform's native S3 state locking (conditional
  # writes create a `.tflock` object) — no DynamoDB table needed.
  backend "s3" {
    bucket       = "banking-app-tfstate-439475769687"
    key          = "dev/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "banking-app"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
