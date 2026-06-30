output "vpc_id" {
  description = "ID of the Splunk VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet hosting the Splunk instance."
  value       = aws_subnet.public.id
}

output "splunk_security_group_id" {
  description = "ID of the Splunk host security group."
  value       = aws_security_group.splunk.id
}

output "splunk_instance_id" {
  description = "EC2 instance ID of the Splunk host (use with: aws ssm start-session --target <id>)."
  value       = aws_instance.splunk.id
}

output "splunk_public_ip" {
  description = "Public IPv4 of the Splunk host. Changes if the instance is replaced."
  value       = aws_instance.splunk.public_ip
}

output "splunk_web_url" {
  description = "Splunk Web UI URL. Reachable only from admin_cidrs; allow a few minutes after apply for first-boot provisioning."
  value       = "http://${aws_instance.splunk.public_ip}:8000"
}

output "splunk_role_arn" {
  description = "ARN of the Splunk instance role (extended with SQS/S3 access in Step 6)."
  value       = aws_iam_role.splunk.arn
}

output "logs_bucket_name" {
  description = "Name of the CloudFront logs bucket — set this verbatim in blog-migration's logging_config (Step 7)."
  value       = aws_s3_bucket.logs.bucket
}

output "logs_bucket_arn" {
  description = "ARN of the CloudFront logs bucket (used by the S3 notification + Splunk S3-read policy in later steps)."
  value       = aws_s3_bucket.logs.arn
}

output "logs_bucket_domain_name" {
  description = "Regional domain name of the logs bucket (the bucket target CloudFront logging_config expects)."
  value       = aws_s3_bucket.logs.bucket_domain_name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic S3 publishes ObjectCreated events to."
  value       = aws_sns_topic.cf_logs.arn
}

output "sqs_queue_url" {
  description = "URL of the main SQS queue — this is what the Splunk SQS-Based S3 input polls (Step 8)."
  value       = aws_sqs_queue.cf_logs.url
}

output "sqs_queue_arn" {
  description = "ARN of the main SQS queue — granted to the Splunk instance role in Step 6."
  value       = aws_sqs_queue.cf_logs.arn
}

output "sqs_dlq_url" {
  description = "URL of the dead-letter queue — check here for messages Splunk failed to process."
  value       = aws_sqs_queue.dlq.url
}
