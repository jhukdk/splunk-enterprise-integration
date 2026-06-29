# ---------------------------------------------------------------------------
# S3 logs bucket — destination for the blog's CloudFront access logs.
#
# This bucket is owned by THIS repo; blog-migration's distribution will point its
# logging_config at it (a separate, coordinated PR in that repo — Step 7). To
# avoid a chicken-and-egg on the name, it's deterministic: both repos compute the
# same "<project>-cf-logs-<accountid>", so the name is known before either applies.
#
# The non-obvious part is ACLs (see aws_s3_bucket_ownership_controls below):
# CloudFront *legacy standard logging* delivers files as a separate AWS account
# (awslogsdelivery) and hands ownership to us via a bucket ACL. Modern buckets
# disable ACLs by default, which makes log delivery fail *silently*. So we
# deliberately re-enable ACLs and grant that delivery account access.
# ---------------------------------------------------------------------------

locals {
  # Deterministic, collision-resistant name. Account-suffixed because S3 bucket
  # names are globally unique across all AWS customers.
  logs_bucket_name = var.logs_bucket_name != "" ? var.logs_bucket_name : "${var.project}-cf-logs-${data.aws_caller_identity.current.account_id}"
}

# Our own canonical user ID, needed as the "owner" in the ACL grant below.
data "aws_canonical_user_id" "current" {}

resource "aws_s3_bucket" "logs" {
  bucket = local.logs_bucket_name
  tags   = { Name = local.logs_bucket_name }
}

# Keep the bucket fully private. The CloudFront delivery grant is to a SPECIFIC
# account (not "public"), so it coexists with all four blocks staying on.
resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# THE gotcha. Default object ownership is "BucketOwnerEnforced", which turns ACLs
# OFF — and CloudFront legacy standard logging *requires* ACLs to deliver. Setting
# "BucketOwnerPreferred" re-enables ACLs while still making us the owner of every
# delivered object, so we can read/lifecycle them normally.
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Grant the CloudFront log-delivery account (awslogsdelivery) FULL_CONTROL via
# ACL, alongside our own ownership. Without this grant CloudFront cannot write
# logs; without the ownership_controls above, this ACL can't even be set.
resource "aws_s3_bucket_acl" "logs" {
  # ACLs must be ENABLED (ownership flipped) before an ACL can be applied.
  depends_on = [aws_s3_bucket_ownership_controls.logs]

  bucket = aws_s3_bucket.logs.id

  access_control_policy {
    owner {
      id = data.aws_canonical_user_id.current.id
    }

    # Us: keep full control of the bucket and its objects.
    grant {
      grantee {
        id   = data.aws_canonical_user_id.current.id
        type = "CanonicalUser"
      }
      permission = "FULL_CONTROL"
    }

    # CloudFront's delivery account: lets it write the gzip log objects.
    grant {
      grantee {
        id   = var.cloudfront_log_delivery_canonical_id
        type = "CanonicalUser"
      }
      permission = "FULL_CONTROL"
    }
  }
}

# CloudFront standard logs support ONLY SSE-S3 (AES256), never SSE-KMS — a KMS
# default here would make delivery fail. Set AES256 explicitly to be unambiguous.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Expire logs after a retention window so storage (and cost) stays bounded, and
# clean up stray partial uploads. Splunk ingests each object within minutes via
# the SQS path, so we don't need to keep them long in S3.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-old-cloudfront-logs"
    status = "Enabled"

    filter {} # whole bucket

    expiration {
      days = var.logs_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
