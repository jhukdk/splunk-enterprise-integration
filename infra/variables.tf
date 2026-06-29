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

# --- Step 3: Splunk host -----------------------------------------------------

variable "instance_type" {
  description = <<-EOT
    EC2 instance type for the Splunk host. m7i-flex.large (2 vCPU / 8 GB) is
    free-tier-eligible, so it launches under the AWS Free plan (which blocks
    non-eligible types like t3.medium outright) and draws down free credits
    rather than billing. 8 GB suits Splunk better than the 4 GB we first planned.
    On a paid plan, t3.medium (~$34/mo all-in) is the cheaper long-term choice.
  EOT
  type        = string
  default     = "m7i-flex.large"
}

variable "splunk_data_volume_gb" {
  description = <<-EOT
    Size of the dedicated gp3 EBS data volume (GiB) holding /opt/splunk/var
    (indexed data) and /opt/splunk/etc (config). Separate from the root volume
    so Splunk's data survives instance replacement. gp3 can be grown later.
  EOT
  type        = number
  default     = 30
}

variable "splunk_image" {
  description = <<-EOT
    Splunk Enterprise container image, pinned to a full patch version for
    reproducible builds (a rolling tag like "10.2" silently moves under you).
    10.2.4 is the current stable line; use 10.0.x for the conservative
    patched line or 10.4.x for newest. The Splunk Add-on for AWS supports 10.x.
  EOT
  type        = string
  default     = "splunk/splunk:10.2.4"
}

variable "admin_password_parameter_name" {
  description = <<-EOT
    Name of the SSM Parameter Store SecureString holding the Splunk admin
    password. Terraform NEVER reads or writes this value (so it stays out of
    state) — you create it out-of-band once, and the instance fetches it at
    boot via its role. Create it with:

      aws ssm put-parameter --name /jhuk-tech/splunk/admin_password \
        --type SecureString --value 'YOUR_STRONG_PASSWORD' --region us-east-1
  EOT
  type        = string
  default     = "/jhuk-tech/splunk/admin_password"
}

# --- Step 4: CloudFront logs bucket -----------------------------------------

variable "logs_bucket_name" {
  description = <<-EOT
    Exact name of the CloudFront logs bucket, shared verbatim with
    blog-migration's logging_config. Leave empty to derive the deterministic
    name "<project>-cf-logs-<accountid>" (both repos compute the same value).
    Set explicitly only if you need a different name in both places.
  EOT
  type        = string
  default     = ""
}

variable "logs_retention_days" {
  description = <<-EOT
    Days to keep CloudFront log objects before lifecycle-expiring them. Splunk
    ingests each object within minutes via the SQS path, so a short window is
    fine; 90 leaves room to re-ingest or investigate.
  EOT
  type        = number
  default     = 90
}

variable "cloudfront_log_delivery_canonical_id" {
  description = <<-EOT
    Canonical user ID of AWS's CloudFront log-delivery account (awslogsdelivery),
    granted FULL_CONTROL via bucket ACL so legacy standard logging can write.
    This is a fixed, AWS-published value — the same for every customer.
  EOT
  type        = string
  default     = "c4c1ede66af53448b93c283ce9448c4ba468c9432aa01d700d3878632f77d2d0"
}
