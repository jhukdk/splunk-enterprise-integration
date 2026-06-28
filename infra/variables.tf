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

variable "vpc_cidr" {
  description = "CIDR block for the Splunk VPC. /16 gives ample room; 10.20 avoids the default VPC's 172.31 range."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet that hosts the Splunk instance."
  type        = string
  default     = "10.20.1.0/24"
}

variable "availability_zone" {
  description = "AZ for the public subnet. Single-AZ is fine for one non-HA host."
  type        = string
  default     = "us-east-1a"
}

variable "admin_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach Splunk Web (port 8000). Lock this to your own
    IP, e.g. ["203.0.113.4/32"]. No default: must be set in terraform.tfvars so
    we never accidentally expose the UI to the world.
  EOT
  type        = list(string)
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
