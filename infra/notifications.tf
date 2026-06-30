# ---------------------------------------------------------------------------
# Ingestion notification path:  S3 ObjectCreated -> SNS -> SQS (+ DLQ)
#
# When CloudFront drops a new .gz log object in the logs bucket, S3 publishes a
# small "object created" event to an SNS topic, which fans it out to an SQS
# queue. The Splunk Add-on for AWS polls that queue (SQS-Based S3 input); each
# message is just a POINTER ("object X exists"), and Splunk then fetches the
# actual gzip from S3. A dead-letter queue catches messages that repeatedly fail.
#
# The fiddly part is the resource policies: each AWS service must be explicitly
# granted permission to call the next, scoped tightly with SourceArn conditions.
# ---------------------------------------------------------------------------

# --- SNS topic + who may publish to it -------------------------------------

resource "aws_sns_topic" "cf_logs" {
  name = "${var.project}-cf-logs-events"
  # Left unencrypted on purpose: SSE-KMS here would require granting S3
  # kms:GenerateDataKey on a CMK. These messages are object pointers, not log
  # data, so the added KMS plumbing isn't worth it. SQS below IS encrypted.
}

# Allow S3 (and ONLY our logs bucket, in our account) to publish to the topic.
# Without this, the S3 bucket notification below fails to create.
data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid     = "AllowS3Publish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sns_topic.cf_logs.arn]

    # Scope to our specific bucket + account so no other resource can publish.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.logs.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "cf_logs" {
  arn    = aws_sns_topic.cf_logs.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

# --- SQS dead-letter queue -------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name = "${var.project}-cf-logs-dlq"

  # Keep failed messages the maximum 14 days so there's time to investigate.
  message_retention_seconds = 1209600

  # Free, SQS-owned-key encryption at rest — no KMS key policy to manage, and
  # SNS can still deliver into it (unlike SSE-KMS, which needs extra grants).
  sqs_managed_sse_enabled = true
}

# Restrict which queues are allowed to dump into this DLQ (defence in depth).
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue",
    sourceQueueArns   = [aws_sqs_queue.cf_logs.arn]
  })
}

# --- SQS main queue (what Splunk polls) ------------------------------------

resource "aws_sqs_queue" "cf_logs" {
  name = "${var.project}-cf-logs"

  # Visibility timeout = how long a message is hidden after Splunk picks it up,
  # giving Splunk time to fetch + index the object before it could reappear.
  # 5 min comfortably covers fetching a small gzip; should exceed processing time.
  visibility_timeout_seconds = 300

  # Long polling: wait up to 20s for messages instead of returning instantly,
  # which cuts empty receives (and cost) without adding real latency.
  receive_wait_time_seconds = 20

  message_retention_seconds = 345600 # 4 days

  sqs_managed_sse_enabled = true

  # After maxReceiveCount failed processing attempts, SQS moves the message to
  # the DLQ instead of redelivering forever.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn,
    maxReceiveCount     = var.sqs_max_receive_count
  })
}

# Allow SNS (and ONLY our topic) to deliver messages into the main queue.
data "aws_iam_policy_document" "queue_policy" {
  statement {
    sid     = "AllowSNSDeliver"
    effect  = "Allow"
    actions = ["SQS:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    resources = [aws_sqs_queue.cf_logs.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.cf_logs.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "cf_logs" {
  queue_url = aws_sqs_queue.cf_logs.id
  policy    = data.aws_iam_policy_document.queue_policy.json
}

# --- Wire SNS -> SQS and S3 -> SNS -----------------------------------------

resource "aws_sns_topic_subscription" "cf_logs" {
  topic_arn = aws_sns_topic.cf_logs.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.cf_logs.arn

  # Deliver the raw S3 event as the SQS message body (no SNS envelope), which is
  # the canonical shape Splunk's SQS-Based S3 input expects. Flip to false if
  # Step 8 needs the SNS wrapper instead.
  raw_message_delivery = true
}

resource "aws_s3_bucket_notification" "cf_logs" {
  bucket = aws_s3_bucket.logs.id

  topic {
    topic_arn = aws_sns_topic.cf_logs.arn
    events    = ["s3:ObjectCreated:*"]
    # CloudFront standard logs are gzip; only notify on real log objects.
    filter_suffix = ".gz"
  }

  # S3 validates it can publish at creation time, so the topic policy must exist
  # first. Terraform can't infer this ordering from the topic_arn alone.
  depends_on = [aws_sns_topic_policy.cf_logs]
}
