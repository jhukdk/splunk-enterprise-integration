# splunk-enterprise-integration

Provisions a **Splunk Enterprise** instance — running as a Docker container on an EC2 host — and the AWS plumbing it needs to **receive and index logs from my blog infrastructure** (the sibling [`blog-migration`](https://github.com/jhukdk/blog-migration) repo that serves `jhuk.tech`).

This is a learning project as much as a working stack: the goal is to get hands-on with cloud + security engineering and Splunk, building the whole ingestion pipeline as infrastructure-as-code.

> **Status:** early scaffolding. Infrastructure is being built out against the roadmap below; see [`PROGRESS.md`](PROGRESS.md) for what has actually landed.

## Goal

**Phase 1:** get **CloudFront access logs** from the blog flowing into Splunk so they are searchable in `index=cloudfront`, surviving container and instance restarts, with **no static AWS credentials** anywhere in the stack.

**Later phases:** extend the same pipeline to **AWS WAF** (via Kinesis Firehose → HEC) and **CloudTrail**.

Everything lives in **`us-east-1`**, where the blog's CloudFront distribution and ACM cert are pinned.

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

- **Primary path (pull):** CloudFront → S3 → SNS → SQS → the *Splunk Add-on for Amazon Web Services* using the **SQS-Based S3** input. The SQS message is only a pointer that says "a new log file exists"; the add-on then reads the actual gzip log object from S3. This is Splunk's recommended, scalable S3 ingestion method.
- **HEC (push) — later:** the **HTTP Event Collector** is a token-authenticated HTTPS endpoint (port 8088) for pushing events in real time. Not needed for CloudFront, but it's how WAF logs will arrive via Kinesis Firehose.

## Tech stack

- **AWS EC2** — Amazon Linux 2023 host for the Splunk container (`t3.medium` to start; `t3.large` if search feels sluggish).
- **Docker** — runs the official `splunk/splunk` Enterprise image.
- **AWS EBS** — a dedicated **gp3** volume mounted into the container (`/opt/splunk/var` for indexed data, `/opt/splunk/etc` for config) so logs and settings **survive restarts**. This persistence is the entire reason EBS is here.
- **Terraform** — all AWS infra as code, with remote state in S3 (reusing `blog-migration`'s state bucket under a new key).
- **AWS SNS + SQS (+ DLQ)** — the notification path that tells Splunk new log files have landed, with a dead-letter queue for resilience.
- **AWS IAM** — an **EC2 instance role** (no static keys) granting Splunk least-privilege access to the queue, the logs bucket, and SSM.
- **GitHub** — branch + PR workflow with GitHub Actions for `fmt` / `validate` / `plan` checks.

## Repo layout (planned)

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
docs/                  notes written while learning
PROGRESS.md            running log of completed roadmap steps
```

## Repo boundaries

This repo and `blog-migration` must not fight over the same resources.

**This repo owns:**
- The S3 **logs bucket** — private, public-access-blocked, lifecycle-expired, with **ACLs enabled** so CloudFront's legacy standard-logging delivery account can write to it.
- The **S3 event notification**, **SNS topic**, **SQS queue**, and **dead-letter queue**.
- The **EC2 instance, EBS volume, security group, networking**, the **IAM instance role**, and the **Docker / Splunk** configuration.

**`blog-migration` owns the CloudFront distribution.** Enabling access logging requires one small, coordinated change there — adding a `logging_config` block pointing at this repo's logs bucket — proposed as a **separate PR in that repo**. This repo never manages the distribution.

To avoid a chicken-and-egg on the bucket name, both repos reference a **deterministic logs-bucket name** (e.g. `jhuk-blog-cf-logs`, optionally account-suffixed).

## Apply order

1. **Apply this repo first** — creates the logs bucket + SNS / SQS / DLQ + Splunk.
2. **Update `blog-migration`'s distribution** `logging_config` to the now-existing logs bucket and apply that repo.
3. **Generate blog traffic** and verify events land in `index=cloudfront`.

## Build roadmap

1. **Backend + providers** — wire S3 remote state and the pinned AWS provider.
2. **Networking** — default vs custom VPC; subnet + security group.
3. **Splunk host** — EC2 + gp3 EBS + user-data that installs Docker and runs `splunk/splunk` with EBS mounts; admin password from Secrets Manager / SSM.
4. **Logs bucket** — private S3 bucket with lifecycle + the ACL setup CloudFront standard logging needs.
5. **Ingestion plumbing** — S3 notification → SNS → SQS + DLQ, with resource policies.
6. **Instance role** — least-privilege policy for SQS + S3 read; attach SSM.
7. **blog-migration PR** — add `logging_config` to the distribution (separate repo).
8. **Configure Splunk** — install the AWS add-on, create `index=cloudfront`, add the CloudFront → SQS-Based S3 input.
9. **Verify** — generate traffic, confirm field-extracted events (`cs_uri_stem`, `sc_status`, `c_ip`, `x_edge_result_type`, …); build starter searches.
10. **(Optional) WAF + CloudTrail** — WebACL + WAF logs via Firehose → HEC, and CloudTrail through the same SQS path.

## Security guardrails

- **No static AWS keys anywhere.** Splunk authenticates via its EC2 instance role; the maintainer authenticates locally via SSO / profile.
- **Least-privilege IAM** — the instance role gets only SQS consume + S3 read on the logs bucket, plus `AmazonSSMManagedInstanceCore`.
- **Shell access via SSM Session Manager**, not open SSH — port 22 stays closed.
- **Splunk Web UI (8000) and HEC (8088) locked to a known source IP** in the security group.
- **Secrets are never committed.** The Splunk admin password comes from Secrets Manager / SSM SecureString, fetched at container start. `.gitignore` covers `*.tfstate*`, `*.tfvars` (except `*.example`), `.terraform/`, and any `default.yml` holding secrets.

## Workflow

- Work on **branches via pull requests** — no direct pushes to `main`.
- **Terraform applies (and any `blog-migration` changes) are done by the maintainer** after reviewing the plan. Claude proposes; the maintainer applies.
- CI runs `terraform fmt -check`, `validate`, and `plan` on PRs.
- AWS provider and Terraform versions are **pinned**; everything is parameterized — no hardcoded account IDs, bucket names, or CIDRs.

## Definition of done (phase 1)

Hitting the blog produces searchable, field-extracted CloudFront events in `index=cloudfront` within minutes; the Splunk data survives an instance / container restart (EBS persistence works); and no static AWS credentials exist anywhere in the stack.
