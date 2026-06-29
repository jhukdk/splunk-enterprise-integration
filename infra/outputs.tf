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
