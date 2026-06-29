# PROGRESS.md

Running log of completed roadmap steps. Append a short, dated note as each step lands so a fresh session can pick up where we left off. See the roadmap in [`README.md`](README.md) / [`CLAUDE.md`](CLAUDE.md).

## Status at a glance

| # | Step | Status |
|---|------|--------|
| 1 | Backend + providers | ✅ Done |
| 2 | Networking (VPC / subnet / SG) | ✅ Done |
| 3 | Splunk host (EC2 + gp3 EBS + Docker) | ✅ Applied — Splunk Web up |
| 4 | Logs bucket (private S3 + ACL for CF) | 🟡 Code complete — not applied |
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

### 2026-06-29 — Step 3: Splunk host (code complete, NOT applied)
- User chose: **SSM Session Manager only** (port 22 stays closed), **admin password in SSM Parameter Store SecureString**, **30 GB gp3** separate data volume.
- **Instance type: `m7i-flex.large`** (2 vCPU / 8 GB). First `apply` attempt with `t3.medium` failed — the account is on the AWS **Free plan**, which rejects non-free-tier-eligible types at `RunInstances` (`InvalidParameterCombination`). `m7i-flex.large` is free-tier-eligible, x86_64 (AMI unchanged), and 8 GB > the 4 GB t3.medium plan. On a paid plan, t3.medium (~$34/mo all-in) is the cheaper long-term option; flex types list at ~$66–74/mo but draw down free credits ($0 out of pocket until they run out).
- Added `infra/iam.tf`: EC2 instance **role + instance profile**. Minimal for now — `AmazonSSMManagedInstanceCore` (Session Manager shell) + a least-privilege inline policy reading only the admin-password SSM parameter (+ `kms:Decrypt` scoped via `kms:ViaService=ssm`). **Note the deviation from the roadmap:** the role must exist at launch for SSM/password-fetch, so it lands here in Step 3; **Step 6 extends this same role** with SQS-consume + S3-read.
- Added `infra/ec2.tf`: AL2023 AMI via public SSM parameter (no hardcoded AMI); `aws_instance` (t3.medium, in the public subnet + splunk SG, instance profile attached, **IMDSv2 required**, 20 GB encrypted gp3 root, `user_data_replace_on_change=true`); separate **30 GB encrypted gp3** `aws_ebs_volume` + `aws_volume_attachment` at `/dev/sdf`.
- Added `scripts/user-data.sh.tftpl`: installs Docker; detects + (idempotently) formats xfs + mounts the EBS data volume at `/opt/splunk-data` by UUID in fstab; `chown 41812:41812`; fetches admin password from SSM; `docker run splunk/splunk:10.2.4` with `var`+`etc` bind-mounted onto EBS, only port 8000 published.
- Added `docker/README.md` documenting the container (user-data is authoritative; no separate compose to avoid drift).
- New vars: `instance_type`, `splunk_data_volume_gb`, `splunk_image`, `admin_password_parameter_name`. New outputs: `splunk_instance_id`, `splunk_public_ip`, `splunk_web_url`, `splunk_role_arn`.
- Validated: `terraform fmt -check -recursive` clean, `terraform validate` → Success. **Nothing applied — first paid step; awaiting maintainer to set the SSM password + tfvars, then review `terraform plan` before apply.**
- **Pre-apply checklist (maintainer):** (1) `aws ssm put-parameter --name /jhuk-tech/splunk/admin_password --type SecureString --value '...' --region us-east-1`; (2) create gitignored `infra/terraform.tfvars` with real `admin_cidrs` (your IP /32); (3) `terraform init` (real backend) → `terraform plan` → review → `apply`.
- **2026-06-29 (applied):** maintainer ran `terraform apply`. Instance `i-03d44c59678c305d0` (m7i-flex.large) came up healthy, SSM Online, EBS volume mounted at `/opt/splunk-data` (etc/var owned by 41812). **Splunk container initially crash-looped: "License not accepted."** Splunk **10.x** requires a second acceptance env var, `SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com`, in addition to `SPLUNK_START_ARGS=--accept-license` (9.x needed only the latter). Fixed user-data + docker/README to set both; hot-patched the live container via SSM so Splunk came up without an instance replace. **Splunk Web now serving on :8000 (HTTP 303 → login), reachable from `admin_cidrs` at http://3.236.176.220:8000.** The SGT fix is on branch/PR for the merged-code source of truth.
- ⚠️ Next `terraform apply` will **replace the instance** (user_data text changed + `user_data_replace_on_change=true`); EBS data volume persists across the replace, so it doubles as an EBS-persistence test. New instance will get a new public IP.
- Still to verify for full phase-1 DoD: EBS persistence across a restart, and (later steps) events landing in `index=cloudfront`.
- **Next up: step 4 — logs bucket** (private S3 + lifecycle + ACL for CloudFront standard logging).

### 2026-06-29 — Step 4: CloudFront logs bucket (code complete, NOT applied)
- Added `infra/logs_bucket.tf`: private S3 bucket for the blog's CloudFront access logs. Deterministic name `local.logs_bucket_name` = `<project>-cf-logs-<accountid>` (= `jhuk-tech-cf-logs-877995959706`) so blog-migration can target it without a name chicken-and-egg.
- **The ACL gotcha (the whole point of this step):** CloudFront *legacy standard logging* delivers files as a separate AWS account (`awslogsdelivery`) and grants us ownership via a **bucket ACL**. Modern buckets default to `BucketOwnerEnforced` which DISABLES ACLs → delivery fails **silently**. So: `aws_s3_bucket_ownership_controls` = `BucketOwnerPreferred` (re-enables ACLs) + `aws_s3_bucket_acl` granting `FULL_CONTROL` to the awslogsdelivery canonical ID (`c4c1ede6…d2d0`) alongside our own. `aws_s3_bucket_acl` `depends_on` the ownership controls.
- Other gotchas handled: **SSE-S3 (AES256) only** — CloudFront standard logs don't support SSE-KMS; bucket stays fully private (`aws_s3_bucket_public_access_block` all-true — the awslogsdelivery grant is account-scoped, not public); lifecycle rule expires logs after `logs_retention_days` (90) + aborts stale multipart uploads.
- New vars: `logs_bucket_name` (empty ⇒ derive), `logs_retention_days`, `cloudfront_log_delivery_canonical_id`. New outputs: `logs_bucket_name`, `logs_bucket_arn`, `logs_bucket_domain_name` (the last feeds blog-migration's `logging_config` in Step 7).
- Validated: `terraform fmt -check -recursive` clean, `terraform validate` → Success. **Nothing applied.** S3 cost is negligible; no ports/SG changes; doesn't touch blog-migration.
- **Next up: step 5 — ingestion plumbing** (S3 ObjectCreated → SNS → SQS + DLQ, with the resource policies wiring each hop).
