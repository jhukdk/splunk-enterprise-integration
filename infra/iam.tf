# ---------------------------------------------------------------------------
# EC2 instance role for the Splunk host.
#
# An *instance role* lets the EC2 instance call AWS APIs using temporary,
# auto-rotated credentials delivered through the instance metadata service —
# so we never put static access keys on the box (a core guardrail).
#
# An instance role is attached to an instance via an *instance profile* (a thin
# wrapper IAM requires; one role per profile here).
#
# This is the MINIMAL version the host needs to boot in Step 3:
#   - SSM Session Manager core    → gives us a shell with port 22 closed
#   - read the admin-password SSM parameter (+ KMS decrypt) → for first-boot setup
# Step 6 extends THIS SAME role with SQS-consume + S3-read for log ingestion.
# ---------------------------------------------------------------------------

# Trust policy: only the EC2 service may assume this role (i.e. only an instance
# can wear it). Without this "who is allowed to assume me" statement, the role
# is unusable.
data "aws_iam_policy_document" "splunk_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "splunk" {
  name               = "${var.project}-splunk-role"
  description        = "Splunk EC2 host: SSM shell + admin-password read (extended for SQS/S3 in Step 6)."
  assume_role_policy = data.aws_iam_policy_document.splunk_assume_role.json
}

# AmazonSSMManagedInstanceCore is the AWS-managed policy that lets the SSM agent
# register the instance and broker Session Manager shells. This is what replaces
# open SSH: no inbound port, access is gated by IAM instead of a key pair.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.splunk.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Least-privilege read of ONLY the admin-password parameter, plus the KMS decrypt
# needed to unwrap a SecureString. KMS is scoped via the ViaService condition so
# the role can only use the key through SSM, not directly.
data "aws_iam_policy_document" "splunk_admin_password" {
  statement {
    sid       = "ReadAdminPasswordParameter"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.admin_password_parameter_name}"]
  }

  statement {
    sid       = "DecryptSecureStringViaSSM"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "splunk_admin_password" {
  name   = "${var.project}-splunk-admin-password-read"
  role   = aws_iam_role.splunk.id
  policy = data.aws_iam_policy_document.splunk_admin_password.json
}

# The instance profile is the container that actually attaches the role to the
# instance (see ec2.tf -> iam_instance_profile).
resource "aws_iam_instance_profile" "splunk" {
  name = "${var.project}-splunk-profile"
  role = aws_iam_role.splunk.name
}

# ---------------------------------------------------------------------------
# Step 6: ingest permissions — extend the SAME role so the Splunk Add-on for
# AWS can drain the SQS queue and read the log objects it points to.
#
# Least privilege in practice: scoped to the EXACT queue ARN and bucket ARN and
# to the minimal actions, not sqs:* / s3:* on "*". Read-only on S3 (Splunk never
# writes back), no DLQ access (it only consumes the live queue), no reach into
# the blog's content bucket. No kms:Decrypt — the bucket is SSE-S3, not KMS.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "splunk_ingest" {
  # Poll the queue, then delete each message once the object is indexed.
  statement {
    sid    = "ConsumeCloudFrontQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [aws_sqs_queue.cf_logs.arn]
  }

  # The Splunk Add-on for AWS calls sqs:ListQueues when you create/validate an
  # SQS-Based S3 input (it enumerates queues to resolve the one you picked).
  # ListQueues has no resource-level scoping in IAM — it's account-wide or
  # nothing — but it only exposes queue NAMES/URLs, not message contents. We
  # accept that narrow exception so input creation doesn't fail with AccessDenied.
  statement {
    sid       = "ListQueuesForAddonInputSetup"
    effect    = "Allow"
    actions   = ["sqs:ListQueues"]
    resources = ["*"]
  }

  # Fetch the gzip log object a message points to. GetObject is per-object;
  # ListBucket + GetBucketLocation are bucket-level, so they target the bucket
  # ARN itself rather than the /* object path.
  statement {
    sid       = "ReadLogObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]
  }

  statement {
    sid    = "ListLogsBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.logs.arn]
  }
}

resource "aws_iam_role_policy" "splunk_ingest" {
  name   = "${var.project}-splunk-ingest"
  role   = aws_iam_role.splunk.id
  policy = data.aws_iam_policy_document.splunk_ingest.json
}
