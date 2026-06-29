# ---------------------------------------------------------------------------
# Splunk host: EC2 instance + dedicated gp3 EBS data volume.
#
# The instance is the always-on server running the Splunk Docker container.
# The EBS data volume is a separate virtual disk holding Splunk's indexed data
# and config, so the data survives the instance being stopped or replaced — the
# whole reason we use EBS rather than the ephemeral instance store.
# ---------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI, resolved from the public SSM parameter AWS
# maintains — so we never hardcode a stale, region-specific AMI id.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "splunk" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.splunk.id]

  # Attaches the instance role so SSM Session Manager works and user-data can
  # read the admin-password parameter — no static keys on the box.
  iam_instance_profile = aws_iam_instance_profile.splunk.name

  # Render the bootstrap script with Terraform-known values injected.
  user_data = templatefile("${path.module}/../scripts/user-data.sh.tftpl", {
    aws_region                    = data.aws_region.current.region
    admin_password_parameter_name = var.admin_password_parameter_name
    splunk_image                  = var.splunk_image
  })

  # Re-run bootstrap (by replacing the instance) when the script changes. Safe
  # here because all real state lives on the separate, retained EBS data volume.
  user_data_replace_on_change = true

  # Force IMDSv2: the instance metadata service (where the role's temporary
  # credentials come from) requires a session token, blocking the classic SSRF
  # credential-theft path.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # The OS disk. Small gp3 is plenty — Splunk's data lives on the data volume.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.project}-splunk" }
}

# Dedicated, encrypted gp3 volume for Splunk data + config. Lives in the same AZ
# as the instance (EBS volumes are AZ-bound). Default gp3 baseline (3000 IOPS /
# 125 MB/s) is ample for this volume of logs.
resource "aws_ebs_volume" "splunk_data" {
  availability_zone = var.availability_zone
  size              = var.splunk_data_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.project}-splunk-data" }
}

# Presents the volume to the instance as /dev/sdf. On Nitro it surfaces as a
# separate NVMe device, which user-data detects, formats once, and mounts.
resource "aws_volume_attachment" "splunk_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.splunk_data.id
  instance_id = aws_instance.splunk.id
}
