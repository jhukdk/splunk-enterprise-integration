# PROGRESS.md

Running log of completed roadmap steps. Append a short, dated note as each step lands so a fresh session can pick up where we left off. See the roadmap in [`README.md`](README.md) / [`CLAUDE.md`](CLAUDE.md).

## Status at a glance

| # | Step | Status |
|---|------|--------|
| 1 | Backend + providers | ✅ Done |
| 2 | Networking (VPC / subnet / SG) | ✅ Done |
| 3 | Splunk host (EC2 + gp3 EBS + Docker) | ⬜ Not started |
| 4 | Logs bucket (private S3 + ACL for CF) | ⬜ Not started |
| 5 | Ingestion plumbing (S3 → SNS → SQS + DLQ) | ⬜ Not started |
| 6 | Instance role (least-privilege IAM + SSM) | ⬜ Not started |
| 7 | blog-migration PR (`logging_config`) | ⬜ Not started |
| 8 | Configure Splunk (AWS add-on, index, input) | ⬜ Not started |
| 9 | Verify (traffic → `index=cloudfront`) | ⬜ Not started |
| 10 | (Optional) WAF + CloudTrail | ⬜ Not started |

Legend: ⬜ Not started · 🟡 In progress · ✅ Done

## Log

### 2026-06-26 — Project bootstrapped
- Repo created with `CLAUDE.md` project instructions.
- Authored `README.md` (overview, architecture, repo boundaries, roadmap, security guardrails) and this `PROGRESS.md`.
- No AWS infrastructure provisioned yet — next up is **step 1: backend + providers**.

### 2026-06-27 — Step 1: backend + providers
- Read sibling `blog-migration` to pull shared facts: account `877995959706`, region `us-east-1`, state bucket `jhuk-tech-tfstate-877995959706`, TF `>= 1.10`, AWS provider `~> 6.50`, naming `jhuk-tech-<purpose>-<accountid>`, tags `{Project, ManagedBy}`.
- Added `infra/backend.tf` — reuses the shared state bucket under a **new key** `splunk/terraform.tfstate` (blog-migration uses `jhuk/...`), `use_lockfile = true` (S3-native locking, no DynamoDB).
- Added `infra/providers.tf` — single `us-east-1` provider with `default_tags`; plus `aws_caller_identity` / `aws_region` data sources so the account ID is never hardcoded.
- Added `infra/variables.tf` — `aws_region`, `project`, `tags`.
- Added repo `.gitignore` (state, `*.tfvars` except `*.example`, `docker/default.yml` except example, `.terraform/`, secrets, OS cruft); `.terraform.lock.hcl` is intentionally committed.
- Validated locally: `terraform fmt -check` clean, `terraform init -backend=false` + `terraform validate` → **Success** (no backend access, nothing applied).
- Deferred to later steps: `terraform_remote_state` data source against blog-migration (needs a CloudFront-ARN output added there in the Step 7 PR); the deterministic logs-bucket name variable (Step 4).
- **Next up: step 2 — networking (default vs custom VPC, subnet, security group).**

### 2026-06-27 — Step 2: networking (custom VPC)
- Chose **custom VPC** over default for isolation + learning. All resources here are free; first paid resource is the EC2 instance (step 3).
- Added `infra/network.tf`: VPC `10.20.0.0/16` (DNS hostnames on, needed for SSM), public subnet `10.20.1.0/24` in `us-east-1a` (`map_public_ip_on_launch` → free public IP, no Elastic IP), Internet Gateway, route table with `0.0.0.0/0 → IGW` + association.
- Security group `jhuk-tech-splunk-sg`: inbound **8000 (Splunk Web) from `admin_cidrs` only**, egress all. **No SSH (22)** — shell comes via SSM in step 3. HEC (8088) deferred to the WAF phase.
- New vars: `vpc_cidr`, `public_subnet_cidr`, `availability_zone`, `admin_cidrs` (no default — must be set in gitignored `terraform.tfvars`; added `terraform.tfvars.example`).
- Outputs: `vpc_id`, `public_subnet_id`, `splunk_security_group_id`.
- Validated: `terraform fmt -check` clean, `terraform validate` → Success. Nothing applied.
- **Next up: step 3 — Splunk host (EC2 + gp3 EBS + Docker user-data, admin password from Secrets Manager/SSM).** First paid step; will show the plan and the SSM-vs-SSH / instance-size choices before any apply.
