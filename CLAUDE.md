# CLAUDE.md — splunk-enterprise-integration

Persistent project instructions for Claude Code. Read this first in every session.

## What this project is

This repo provisions a **Splunk Enterprise** instance — running as a **Docker container on an EC2 instance** — and the AWS plumbing it needs to **receive and index logs from my existing blog infrastructure** in the sibling repo `blog-migration`.

Phase-1 goal: get **CloudFront access logs** from the blog (`jhuk.tech`) flowing into Splunk so they are searchable. Later phases extend the same pipeline to **AWS WAF** and **CloudTrail**.

Everything lives in **`us-east-1`** (the blog's CloudFront and ACM cert are pinned there).

## Teach me as I build  ← read this

I'm using this project to learn cloud + security engineering and Splunk, not just to end up with a working stack. So when you work in this repo:

- When you introduce a new building block — **VPC, subnet, route table, internet gateway, security group, IAM role / policy / instance profile, SNS topic, SQS queue, dead-letter queue, EBS volume, Docker volume mounts, Splunk HEC, indexes, sourcetypes** — stop and explain, in plain language, *what it is, why we need it here, and the main gotcha or tradeoff*, before or as you write the code.
- Explain the **why** behind each Terraform resource, not just the syntax.
- When there's a real choice (default VPC vs custom, SSH vs SSM Session Manager, pull-via-SQS vs push-via-HEC, instance size), lay out the options and your recommendation and let me decide — don't silently pick.
- Use analogies and concrete examples. Keep it tight: a short paragraph or a few bullets, then move on. Quiz me, or point me at the exact AWS / Splunk doc, when that's the better teacher.
- **Before anything that costs ongoing money or mutates infrastructure, show me the plan and wait for my go-ahead.**

## Tech stack

- **AWS EC2** — host for the Splunk container. Amazon Linux 2023, `t3.medium` to start (this is below Splunk's reference spec but fine for this tiny volume — explain the tradeoff when we size it; `t3.large` if search feels sluggish).
- **Docker** — runs the official `splunk/splunk` Enterprise image on the instance.
- **AWS EBS** — a dedicated **gp3** volume mounted into the container for Splunk's data and config, so indexed logs and settings **survive container and instance restarts**. This is the entire reason we use EBS — call it out and get the mounts right (`/opt/splunk/var` for indexed data, `/opt/splunk/etc` for config).
- **Terraform** — all AWS infra as code. Remote state in S3 (see Backend).
- **AWS SNS + SQS** — the notification path that tells Splunk new log files have landed, with a dead-letter queue for resilience.
- **AWS IAM** — an **EC2 instance role** (no static access keys, ever) granting Splunk least-privilege access to the queue and the logs bucket, plus SSM for shell access.
- **GitHub** — version control; branch + PR workflow, GitHub Actions for plan checks.
- **VS Code** — local editor.

Add other tools or providers as needed to reach the goal, but explain anything new before adding it.

## Architecture

```
blog-migration repo (owns CloudFront)
        │
        │  CloudFront standard access logs
        ▼
   S3 logs bucket  ──ObjectCreated──▶  SNS topic  ──▶  SQS queue (+ DLQ)
   (this repo)                                              │
        ▲                                                   │  1. add-on pulls the message
        │                                                   ▼
        └── 2. add-on fetches the log object ──────  Splunk Enterprise
                                                     (Docker on EC2, EBS-backed,
                                                      IAM instance role,
                                                      SQS-Based S3 input → index=cloudfront)
```

- **Primary path (pull):** CloudFront → S3 → SNS → SQS → the *Splunk Add-on for Amazon Web Services* using the **SQS-Based S3** input. The SQS message is only a pointer saying "a new log file exists"; the add-on then reads the actual gzip log object from S3. This is Splunk's recommended, scalable S3 ingestion method.
- **HEC (push) — for later:** the **HTTP Event Collector** is a token-authenticated HTTPS endpoint (port 8088) that lets sources *push* events into Splunk in real time. We don't need it for CloudFront, but we'll use it when we add **WAF logs via Kinesis Firehose → HEC**. Explain HEC tokens, TLS, and indexer acknowledgement when we get there.

## Repo boundaries (read carefully)

This repo and `blog-migration` must not fight over the same resources.

**This repo (`splunk-enterprise-integration`) owns:**
- The S3 **logs bucket** — private, lifecycle-expired, with **ACLs enabled** so CloudFront's log-delivery account can write to it (CloudFront legacy standard logging delivers via bucket ACL; a default ACL-disabled bucket silently fails — explain this when we build it).
- The **S3 event notification**, **SNS topic**, **SQS queue**, and **dead-letter queue**.
- The **EC2 instance, EBS volume, security group, networking** (or use of an existing VPC), the **IAM instance role**, and the **Docker / Splunk** configuration.

**`blog-migration` owns the CloudFront distribution**, so enabling access logging requires **one small, coordinated change there**: adding a `logging_config` block to the distribution that points at this repo's logs bucket. Propose that as a **separate PR in the `blog-migration` repo** — do not try to manage the distribution from here.

**Apply order:**
1. Apply this repo first (creates the logs bucket + SNS / SQS / DLQ + Splunk).
2. Then update `blog-migration`'s distribution `logging_config` to the now-existing logs bucket and apply that repo.
3. Generate some blog traffic and verify events land in `index=cloudfront`.

To avoid a chicken-and-egg on the bucket name, use a **deterministic logs-bucket name** defined as a variable in both repos (e.g. `jhuk-blog-cf-logs`, optionally account-suffixed).

## The sibling repo

`blog-migration` lives as a **sibling directory on my machine: `../blog-migration`**. You may read it to understand its structure and to pull values you need. Do **not** modify it except via the explicit `logging_config` PR described above.

What to get from it:
- CloudFront **distribution ID / ARN**, AWS **account ID**, region, and the content-bucket naming pattern.
- Its **Terraform S3 backend** config — we'll reuse the same state bucket with a different key.
- Its conventions (OAC-only bucket access, least-privilege CI role, OIDC keyless deploys) — mirror that ethos here.

Prefer reading those values via a `terraform_remote_state` data source against `blog-migration`'s backend rather than hardcoding them; explain that pattern when you set it up.

## Planned layout

```
infra/                 Terraform
  backend.tf           S3 remote state (reuse blog-migration's bucket, new key)
  providers.tf         pinned AWS provider, region us-east-1
  network.tf           VPC / subnet / SG (or data sources for an existing VPC)
  logs_bucket.tf       private S3 logs bucket + lifecycle + ACL for CF delivery
  notifications.tf     S3 notification → SNS → SQS (+ DLQ) + resource policies
  iam.tf               Splunk instance role / profile (SQS + S3 read, SSM)
  ec2.tf               instance, EBS volume + attachment, user-data
  variables.tf         logs bucket name, instance type, my-IP CIDR, etc.
  outputs.tf           splunk URL, queue URL, role ARN
docker/                Splunk container config (compose file or default.yml)
scripts/               bootstrap / helper scripts (e.g. EC2 user-data)
.github/workflows/     terraform fmt / validate / plan on PRs
docs/                  notes I write as I learn
PROGRESS.md            running log of completed roadmap steps
```

## Conventions & guardrails

Security:
- **No static AWS keys anywhere.** Splunk authenticates to AWS via its **EC2 instance role**. I authenticate locally via my own profile / SSO.
- **Least privilege** IAM: the instance role gets only SQS consume + S3 read on the logs bucket, plus `AmazonSSMManagedInstanceCore`. Nothing touches the blog content bucket or the deploy role.
- **Shell access via SSM Session Manager, not open SSH.** Keep port 22 closed and attach SSM to the role instead. If we genuinely need SSH, lock it to my IP only and say why.
- **Lock the Splunk Web UI (port 8000) to my IP** in the security group. Same for HEC (8088) when enabled — restrict to the expected source only.
- **Secrets are never committed.** The Splunk admin password comes from **AWS Secrets Manager or SSM Parameter Store (SecureString)**, fetched at container start. `.gitignore` must cover `*.tfstate*`, `*.tfvars` (except an `*.example`), `.terraform/`, and any `default.yml` that holds secrets.
- **Logs bucket stays private** with public access blocked.

Workflow:
- Work on **branches via pull requests; no direct pushes to `main`.**
- **Terraform applies and any `blog-migration` changes are done by me (the maintainer)** after reviewing the plan. You propose; I apply.
- CI runs `terraform fmt -check`, `validate`, and a **`plan` on PRs** so changes are reviewable before merge.
- **Pin** the AWS provider and Terraform versions. Parameterize everything — no hardcoded account IDs, bucket names, or CIDRs in resource bodies; use variables.
- **Keep `PROGRESS.md` current.** Append a short note as each roadmap step lands so a fresh session (or my Claude Chat) can pick up where we left off.

## Build roadmap

Work through these in order; teach as you go (see the directive up top):
1. **Backend + providers** — wire S3 remote state and the pinned AWS provider.
2. **Networking** — decide default vs custom VPC; create or locate the subnet and security group. (Explain VPC / subnet / IGW / route table / SG.)
3. **Splunk host** — EC2 instance + **gp3 EBS volume** + user-data that installs Docker and runs `splunk/splunk` with the EBS volume mounted for `/opt/splunk/var` and config. Pull the admin password from Secrets Manager / SSM.
4. **Logs bucket** — private S3 bucket with lifecycle + the ACL setup CloudFront standard logging needs.
5. **Ingestion plumbing** — S3 notification → SNS → SQS + DLQ, with the resource policies that let each step talk to the next.
6. **Instance role** — least-privilege policy for SQS + S3 read; attach SSM.
7. **blog-migration PR** — add `logging_config` to the distribution → the logs bucket (separate repo, I apply).
8. **Configure Splunk** — install the AWS add-on, create `index=cloudfront`, add the **CloudFront Access Log → SQS-Based S3** input pointing at the queue.
9. **Verify** — generate traffic, confirm parsed events (`cs_uri_stem`, `sc_status`, `c_ip`, `x_edge_result_type`, …) in `index=cloudfront`; build a couple of starter searches.
10. **(Optional) WAF + CloudTrail** — attach a WebACL, ship WAF logs via Firehose → **HEC**, and add CloudTrail through the same SQS path.

## Definition of done (phase 1)

Hitting the blog produces searchable, field-extracted CloudFront events in `index=cloudfront` within minutes; the Splunk data survives an instance / container restart (EBS persistence works); and no static AWS credentials exist anywhere in the stack.

## Check with me before you act when…

- a step **costs ongoing money** (EC2, EBS, Elastic IP), or
- a step **opens a port or changes a security group**, or
- a change touches **`blog-migration`**, or
- you're about to **`terraform apply`** — show the plan first.
