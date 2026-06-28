# ---------------------------------------------------------------------------
# Custom VPC for the Splunk host.
#
# A VPC is our own private, isolated slice of the AWS network. We build a custom
# one (rather than using the account's default VPC) for isolation and to learn
# the moving parts. Everything here is free; the first paid resource is the EC2
# instance in step 3.
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # DNS support + hostnames are required for SSM Session Manager and for the
  # instance to resolve AWS service endpoints (S3, SQS, SSM) by name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-splunk-vpc" }
}

# A single public subnet, pinned to one Availability Zone. "Public" only becomes
# true once we add an internet route below. One AZ is fine: this is a single
# non-HA host, not a multi-AZ fleet.
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zone

  # Auto-assign a public IPv4 so the instance can reach the internet (and we can
  # reach Splunk Web) without a paid Elastic IP. The address changes if the
  # instance is replaced, which is acceptable here.
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-splunk-public-a" }
}

# The Internet Gateway is the on-ramp between the VPC and the public internet.
# It does nothing until a route table points traffic at it.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-splunk-igw" }
}

# Route table = the signposts for the subnet. The local route (VPC CIDR) is
# implicit; we add a default route sending everything else to the IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-splunk-public-rt" }
}

# Associating the route table with the subnet is what actually makes the subnet
# "public". Without this association the subnet would have no internet route.
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security group for the Splunk host: a stateful firewall around the instance.
# Default-deny inbound; we open only what we need. No SSH (22) — shell access
# comes via SSM Session Manager in step 3, which needs no inbound ports at all.
# ---------------------------------------------------------------------------
resource "aws_security_group" "splunk" {
  name        = "${var.project}-splunk-sg"
  description = "Splunk host: Splunk Web from admin IP only; all egress."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-splunk-sg" }
}

# Inbound: Splunk Web UI (8000), restricted to the admin CIDR(s). HEC (8088)
# will be added in a later phase when we ship WAF logs, similarly restricted.
resource "aws_vpc_security_group_ingress_rule" "splunk_web" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.splunk.id
  description       = "Splunk Web UI"
  ip_protocol       = "tcp"
  from_port         = 8000
  to_port           = 8000
  cidr_ipv4         = each.value
}

# Outbound: allow all. The instance needs to reach S3, SQS, SSM, and Docker Hub.
# Egress is the safe direction to leave open for a single trusted host.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.splunk.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
