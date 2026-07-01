# PROGRESS.md

Running log of completed roadmap steps. Append a short, dated note as each step lands so a fresh session can pick up where we left off. See the roadmap in [`README.md`](README.md) / [`CLAUDE.md`](CLAUDE.md).

## Status at a glance

| # | Step | Status |
|---|------|--------|
| 1 | Backend + providers | ✅ Done |
| 2 | Networking (VPC / subnet / SG) | ✅ Done |
| 3 | Splunk host (EC2 + gp3 EBS + Docker) | ✅ Applied — Splunk Web up |
| 4 | Logs bucket (private S3 + ACL for CF) | ✅ Applied |
| 5 | Ingestion plumbing (S3 → SNS → SQS + DLQ) | ✅ Applied |
| 6 | Instance role (least-privilege IAM + SSM) | ✅ Applied |
| 7 | blog-migration PR (`logging_config`) | ✅ Merged + applied (blog-migration #33) |
| 8 | Configure Splunk (AWS add-on, index, input) | ✅ Done — add-on installed, input draining SQS |
| 9 | Verify (traffic → `index=cloudfront`) | ✅ Done — 2,160 events, fields extracted |
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

### 2026-06-29 — Step 5: ingestion plumbing (code complete, NOT applied)
- Added `infra/notifications.tf`: the `S3 ObjectCreated(.gz) → SNS → SQS (+ DLQ)` path. Each SQS message is a POINTER; Splunk's SQS-Based S3 input polls the queue then fetches the gzip from S3.
- **SNS topic** `jhuk-tech-cf-logs-events` (unencrypted on purpose — SSE-KMS would need S3 `kms:GenerateDataKey`; messages are pointers not log data) + topic policy letting **only** s3.amazonaws.com publish, scoped via `aws:SourceArn`=bucket and `aws:SourceAccount`.
- **Main SQS** `jhuk-tech-cf-logs`: visibility 300s, long-poll 20s, retention 4d, SQS-managed SSE, redrive → DLQ after `sqs_max_receive_count` (5). **DLQ** `jhuk-tech-cf-logs-dlq`: 14d retention, SSE, `redrive_allow_policy` restricting source to the main queue. Queue policy lets **only** sns.amazonaws.com (our topic via `aws:SourceArn`) `SendMessage`.
- **Subscription** SNS→SQS with `raw_message_delivery = true` (SQS body = native S3 event, the canonical Splunk shape; flip to false in Step 8 if the SNS wrapper is wanted). **`aws_s3_bucket_notification`** topic block on `s3:ObjectCreated:*` + `filter_suffix=".gz"`, `depends_on` the topic policy (S3 validates publish perms at create time).
- New var `sqs_max_receive_count` (5). New outputs: `sns_topic_arn`, `sqs_queue_url`, `sqs_queue_arn` (→ Step 6 IAM), `sqs_dlq_url`.
- Validated: `terraform fmt -check -recursive` clean, `terraform validate` → Success. **Nothing applied.** SNS/SQS at this volume is effectively free; no ports/SG; doesn't touch blog-migration.
- **Next up: step 6 — instance role** (extend the existing `jhuk-tech-splunk-role` with least-privilege SQS-consume on the main queue + S3 read on the logs bucket).

### 2026-06-29 — Step 6: instance role ingest permissions (code complete, NOT applied)
- Extended the existing `jhuk-tech-splunk-role` (created in Step 3) with a new inline policy `jhuk-tech-splunk-ingest` in `infra/iam.tf` — no new role, no instance replacement (applies live to the running host).
- **Least privilege, exact ARNs:** SQS `ReceiveMessage`/`DeleteMessage`/`ChangeMessageVisibility`/`GetQueueAttributes`/`GetQueueUrl` on the **main queue only** (`aws_sqs_queue.cf_logs.arn`) — no SendMessage, no DLQ, no account-wide ListQueues. S3 read-only: `GetObject` on `<logs-bucket>/*`, `ListBucket`+`GetBucketLocation` on the bucket. No `kms:Decrypt` (bucket is SSE-S3, not KMS). Nothing touches the blog content bucket.
- Validated: `terraform fmt -check -recursive` clean, `terraform validate` → Success. **Nothing applied.** Free; no ports/SG; doesn't touch blog-migration.
- After this, the full pull pipeline is permission-complete; it just needs CloudFront to actually write logs (Step 7) and the Splunk-side input configured (Step 8).
- **Next up: step 7 — blog-migration PR** (add `logging_config` to the CloudFront distribution → this repo's logs bucket; separate repo, maintainer applies).

### 2026-06-29 — Step 7: blog-migration logging PR proposed
- Opened **blog-migration PR #33** (`feat/cloudfront-access-logging`) — the one coordinated cross-repo change. Adds a `logging_config` block to `aws_cloudfront_distribution.this`: `bucket = "${var.cf_logs_bucket_name}.s3.amazonaws.com"` (the bucket DOMAIN, not bare name), `include_cookies = false`, `prefix = "cloudfront/"`. New var `cf_logs_bucket_name` default `jhuk-tech-cf-logs-877995959706` (matches this repo's deterministic name). `fmt` + `validate` clean there; nothing applied (maintainer applies per blog-migration rules).
- ⚠️ **Apply order:** apply THIS repo first (so the logs bucket exists with ACLs + awslogsdelivery grant), then apply blog-migration #33. Logs land under the `cloudfront/` prefix; our S3 notification filters on `.gz` so the prefix is harmless.
- Reminder of unapplied infra in THIS repo before logs can flow: Steps 4 (logs bucket), 5 (SNS/SQS/DLQ), 6 (role ingest policy) are merged to `main` but **not yet `terraform apply`-ed**. Apply them, then merge+apply blog-migration #33, then do Step 8.
- **Next up: step 8 — configure Splunk** (install Splunk Add-on for AWS, create `index=cloudfront`, add the SQS-Based S3 input pointing at `sqs_queue_url`).

### 2026-06-29 — Step 8: configure-Splunk runbook + IAM ListQueues fix (code/docs; manual UI step is the maintainer's)
- Wrote `docs/step-8-configure-splunk.md`: click-by-click for installing the Splunk Add-on for AWS, creating `index=cloudfront`, and adding the **CloudFront Access Log → SQS-Based S3** input. Verified the flow against the add-on's github.io docs.
- **Auth = EC2 instance role, keyless:** the add-on **auto-discovers** the attached role and shows it under Configuration → Account → *Autodiscovered IAM Role*; you select `jhuk-tech-splunk-role` in the input. No keys, no assume-role.
- Input specifics: S3 File Decoder `CloudFrontAccessLogs` → sourcetype `aws:cloudfront:accesslogs`, region us-east-1, SQS Queue = `sqs_queue_url`, index `cloudfront`, interval 300. **SNS Signature Validation must stay UNCHECKED** because our subscription uses `raw_message_delivery=true` (SQS body is the raw S3 event, no SNS signature).
- **IAM fix (corrects Step 6):** added `sqs:ListQueues` (resource `*`) to `jhuk-tech-splunk-ingest` in `infra/iam.tf`. The add-on calls ListQueues during input creation (known `AccessDenied for sqs:listqueues` otherwise); it can't be ARN-scoped but only exposes queue names/URLs, not contents. Applies live (no instance replace).
- Validated: `terraform fmt -check -recursive` clean, `terraform validate` → Success.
- **Next up: step 9 — verify** (generate traffic → confirm parsed events in `index=cloudfront`; build starter searches) once the maintainer has applied infra + blog-migration #33 and run the runbook.

### 2026-06-29 — Step 9: verification runbook (docs)
- Wrote `docs/step-9-verify.md`: confirm-events search, field-extraction sanity check, and starter SPL (top paths, status breakdown, 4xx/5xx timechart, cache hit ratio via eventstats, top IPs, edge locations, bandwidth, slowest requests). Add-on field names are underscore form (`c_ip`, `cs_uri_stem`, `sc_status`, `x_edge_result_type`, `time_taken`, `sc_bytes`, …).
- Pipeline-health checks (ingest lag, `_internal source=*splunk_ta_aws*` errors, SQS/DLQ depth) and the **EBS-persistence test** (container restart = quick; instance replacement = full proof that data lives on the EBS volume).
- Phase-1 definition-of-done checklist: events within minutes, fields extracted, survives restart, no static creds.
- Docs only; no infra. **Roadmap code/docs all complete through Step 9.** Remaining is operational (maintainer): apply Steps 4–6, apply blog-migration #33, run Step 8 runbook, then verify with Step 9. Step 10 (WAF→HEC + CloudTrail) is optional/future.

### 2026-06-30 — Operational status: infra applied, Step 8 is the only thing left
- **Applied** Steps 4–6 (logs bucket, SNS/SQS/DLQ, role ingest policy incl. `sqs:ListQueues`). The apply **replaced the instance** (user_data had changed): now **`i-0b281283ba85f2793`**, public IP **`98.84.33.4`** → **Splunk Web at http://98.84.33.4:8000** (old `i-03d44c59678c305d0` gone; EBS data volume persisted across the swap).
- **Merged + applied blog-migration #33** — CloudFront (dist `EBSGZL0OM8XYI`) standard logging is on, writing to the bucket under `cloudfront/`.
- **Pipeline proven through SQS:** a real log object landed (`cloudfront/EBSGZL0OM8XYI.2026-06-30-00.*.gz`) and a message is sitting in the main queue (DLQ empty) — `S3 → SNS → SQS` works end to end.
- **➡️ NEXT (manual, not done):** run `docs/step-8-configure-splunk.md` in Splunk Web — install the Splunk Add-on for AWS, create `index=cloudfront`, add the CloudFront Access Log → SQS-Based S3 input (auth = auto-discovered EC2 role; SQS `jhuk-tech-cf-logs`; SNS Signature Validation **off**). The new instance currently has **no add-on, no `cloudfront` index, no input** — which is why the queued message is unconsumed. Then verify via `docs/step-9-verify.md`.
- Also open elsewhere: **blog-migration PR #34** — a hiring-manager blog post about this architecture (`draft:false`, publishes on merge).

### 2026-06-30 — Steps 8 & 9 complete: CloudFront logs flowing into Splunk (phase-1 DoD met)
- Verified on the live host (`i-0b281283ba85f2793`, `98.84.33.4`) that Step 8 already ran successfully: `Splunk_TA_aws` add-on installed, `index=cloudfront` populated, SQS-Based S3 input draining the queue.
- **CloudWatch confirmed the input's first poll:** at ~22:35 local the queue went 154 messages Received → 154 Deleted in one burst (backlog drain); queue has stayed at 0 since (DLQ empty), keeping pace with the ~3–8 objects/hr CloudFront delivers.
- **Step 9 verification:** `index=cloudfront` has **2,160 events** (latest current, `~03:29 GMT`); **2,006** have `sc_status` extracted (the ~154 unparsed are the `#Version`/`#Fields` header lines each CloudFront `.gz` carries). Fields resolve: `c_ip`, `cs_uri_stem`, `sc_status`, `x_edge_result_type`. Status mix: 301 (38%), 403 (31%), 404, 200, 304, 206 — the 403s hitting `/1ark.php`, `/a17.php` are bot vuln-scans (early security signal).
- **Phase-1 definition of done met:** searchable field-extracted CloudFront events in `index=cloudfront`; EBS persistence proven across the earlier instance replacement; zero static AWS creds (auto-discovered instance role).
- **Next up:** nothing required. Optional **Step 10** (WAF logs via Firehose → HEC, CloudTrail via the same SQS path) remains as a future/optional phase.
