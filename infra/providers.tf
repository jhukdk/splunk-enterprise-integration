# Single default provider: every resource in this stack (logs bucket, SNS/SQS,
# EC2/EBS, IAM) lives in us-east-1 alongside the blog's CloudFront distribution.
provider "aws" {
  region = var.aws_region

  # default_tags stamps these onto every taggable resource automatically, so we
  # never hand-tag individual resources. Mirrors blog-migration's convention.
  default_tags {
    tags = var.tags
  }
}

# Local, zero-coupling lookups for identity/region. Preferred over hardcoding the
# account ID: these resolve from whatever credentials/profile is running Terraform.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
