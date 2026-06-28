variable "aws_region" {
  description = "AWS region. Pinned to us-east-1 to sit with the blog's CloudFront + ACM cert."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project slug used in resource names. Shared with blog-migration."
  type        = string
  default     = "jhuk-tech"
}

variable "tags" {
  description = "Tags applied to all resources via the provider default_tags."
  type        = map(string)
  default = {
    Project   = "jhuk-tech"
    Component = "splunk-integration"
    ManagedBy = "terraform"
  }
}
