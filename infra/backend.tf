terraform {
  # use_lockfile (S3-native state locking) requires Terraform >= 1.10.
  # Matches the sibling blog-migration repo so both stacks share one toolchain floor.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.50"
    }
  }

  # Remote state in the SAME pre-existing bucket blog-migration uses, but under a
  # DIFFERENT key so the two stacks never read or lock each other's state.
  #   blog-migration -> jhuk/terraform.tfstate
  #   this repo       -> splunk/terraform.tfstate
  # The bucket itself was created manually (not by Terraform); we only consume it.
  backend "s3" {
    bucket       = "jhuk-tech-tfstate-877995959706"
    key          = "splunk/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
