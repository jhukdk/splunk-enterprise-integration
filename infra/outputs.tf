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
