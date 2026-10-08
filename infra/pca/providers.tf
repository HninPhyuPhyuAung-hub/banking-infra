terraform {
  required_version = ">= 1.11.0" # use_lockfile (native S3 locking) requires >= 1.11

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Same state bucket created manually in Step 1 (see ../s3/notes.md), just a
  # different key — this is a separate, long-lived config from envs/dev so
  # the expensive Private CA isn't destroyed every time envs/dev is torn down.
  backend "s3" {
    bucket       = "banking-app-tfstate-439475769687"
    key          = "pca/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "banking-app"
      ManagedBy = "terraform"
      Component = "private-ca"
    }
  }
}
