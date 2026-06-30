# Step 8 — Configure Splunk to ingest CloudFront logs

A click-by-click runbook for the Splunk-side setup: install the AWS add-on,
create the `cloudfront` index, and add the **SQS-Based S3** input that drains the
queue. This is the one step that isn't Terraform — it's done in Splunk Web (with
the option to fall back to an SSM shell). Everything you configure here is saved
under `/opt/splunk/etc`, which is on the **EBS volume**, so it survives container
and instance restarts.

> Sourced from the official add-on docs:
> [SQS-Based S3 input](https://splunk.github.io/splunk-add-on-for-amazon-web-services/SQS-basedS3/),
> [Configuration overview](https://splunk.github.io/splunk-add-on-for-amazon-web-services/ConfigurationOverview/).

---

## 0. Concepts (read once)

- **Splunk Add-on for AWS** (`Splunk_TA_aws`) — a Splunk app that knows how to
  pull from AWS and parse it. It provides the **SQS-Based S3** input type and the
  field extractions for CloudFront logs.
- **Index** (`cloudfront`) — a named on-disk store with its own retention. We
  isolate CloudFront data in its own index so it's easy to scope searches,
  retention, and access separately from Splunk's defaults.
- **Sourcetype** (`aws:cloudfront:accesslogs`) — tells Splunk how to parse the
  data. The add-on ships the parser that turns CloudFront's tab-separated W3C
  lines into fields (`cs_uri_stem`, `sc_status`, `c_ip`, `x_edge_result_type`, …).
- **SQS-Based S3 input** — polls our SQS queue; each message is a pointer, and the
  add-on then fetches the gzip object from S3 and indexes it.
- **Auth = the EC2 instance role (no keys).** When Splunk runs on an EC2 instance
  with an attached role, the add-on **auto-discovers** that role and lists it in
  Configuration → Account under the *Autodiscovered IAM Role* column. You select
  it in the input — there is **no access key/secret anywhere**.

---

## 1. Prerequisites (do these first or nothing flows)

1. **Apply this repo's infra** (Steps 4–6): logs bucket, SNS/SQS/DLQ, and the
   role ingest policy — including the `sqs:ListQueues` permission the add-on
   needs at input-creation time. Confirm with:
   ```
   cd infra && terraform output
   ```
   Note `sqs_queue_url` — it should be:
   ```
   https://sqs.us-east-1.amazonaws.com/877995959706/jhuk-tech-cf-logs
   ```
2. **Merge + apply `blog-migration` PR #33** (CloudFront `logging_config`), so the
   distribution actually writes logs to the bucket.
3. **Generate some blog traffic** — hit a few pages on `https://jhuk.tech`.
   CloudFront standard logs are delivered to S3 with a delay (usually minutes,
   occasionally up to ~an hour for the very first logs). Confirm objects land:
   ```
   aws s3 ls s3://jhuk-tech-cf-logs-877995959706/cloudfront/ --region us-east-1
   ```
4. **Log in to Splunk Web** at `http://<splunk_public_ip>:8000` as `admin`.

---

## 2. Install the Splunk Add-on for AWS

**Online (simplest — the instance has internet egress):**
1. Splunk Web → top-left **Apps** menu → **Find More Apps**.
2. Search **"Splunk Add-on for Amazon Web Services"** → **Install**.
3. Enter your **Splunkbase (splunk.com)** credentials when prompted → **Install**.
4. **Restart Splunk** if asked.

**Offline alternative:** download the add-on `.tgz` from Splunkbase on your
laptop, then Splunk Web → **Apps → Manage Apps → Install app from file** → upload
→ restart.

The app installs to `/opt/splunk/etc/apps/Splunk_TA_aws` (on EBS → persists).

---

## 3. Create the `cloudfront` index

1. **Settings → Indexes → New Index**.
2. **Index Name:** `cloudfront`  ·  **Index Data Type:** Events.
3. Leave the defaults (or set a max size / retention if you like) → **Save**.

(Index config lands in `etc`, data in `var` — both on EBS.)

---

## 4. Confirm the auto-discovered instance role

1. Splunk Web → **Splunk Add-on for AWS** (left nav) → **Configuration** →
   **Account** tab.
2. In the **Autodiscovered IAM Role** column you should see the instance role
   (`jhuk-tech-splunk-role`). It's read-only — you can't edit/delete it, and you
   don't need to. If it's **missing**, the instance metadata/role isn't reaching
   the add-on (check the instance profile is attached and IMDSv2 is reachable).

---

## 5. Create the SQS-Based S3 input

1. **Splunk Add-on for AWS → Inputs → Create New Input → CloudFront Access Log →
   SQS-Based S3**.
2. Fill in:

   | Field | Value |
   |---|---|
   | **Name** | `cloudfront-sqs-s3` |
   | **AWS Account** | the **auto-discovered IAM role** (`jhuk-tech-splunk-role`) |
   | **Assume Role** | *(leave empty)* |
   | **AWS Region** | US East (N. Virginia) / `us-east-1` |
   | **SQS Queue Name** | the full queue URL — `…/jhuk-tech-cf-logs` (from `terraform output sqs_queue_url`) |
   | **S3 File Decoder** | `CloudFrontAccessLogs` (auto-set by choosing CloudFront Access Log) |
   | **Source Type** | `aws:cloudfront:accesslogs` (auto) |
   | **Index** | `cloudfront` |
   | **Interval** | `300` (default) |

3. **SNS Signature Validation — leave UNCHECKED.** Our subscription uses
   `raw_message_delivery = true`, so the SQS body is the raw S3 event with **no
   SNS signature**. Enabling validation would reject every message. *(If you ever
   flip the Terraform subscription to `raw_message_delivery = false`, enable this
   box to match.)*
4. (Optional) enable **Force using DLQ** so malformed messages route to our DLQ
   for inspection rather than retrying.
5. **Save.**

---

## 6. First-look sanity checks (full verification is Step 9)

- **Events arriving:** search over Last 15 minutes:
  ```
  index=cloudfront sourcetype=aws:cloudfront:accesslogs | head 20
  ```
  You should see parsed fields like `cs_uri_stem`, `sc_status`, `c_ip`,
  `x_edge_result_type`.

- **If it's empty, work backwards:**
  1. **Add-on health / errors:**
     ```
     index=_internal source=*splunk_ta_aws* (ERROR OR WARN) | head 50
     ```
  2. **Are messages reaching SQS?** (should be >0 shortly after traffic, then
     drop to 0 as Splunk drains them):
     ```
     aws sqs get-queue-attributes --region us-east-1 \
       --queue-url https://sqs.us-east-1.amazonaws.com/877995959706/jhuk-tech-cf-logs \
       --attribute-names ApproximateNumberOfMessages
     ```
  3. **Anything stuck in the DLQ?** (means repeated processing failures):
     ```
     aws sqs get-queue-attributes --region us-east-1 \
       --queue-url https://sqs.us-east-1.amazonaws.com/877995959706/jhuk-tech-cf-logs-dlq \
       --attribute-names ApproximateNumberOfMessages
     ```
  4. **Did CloudFront actually deliver logs?**
     ```
     aws s3 ls s3://jhuk-tech-cf-logs-877995959706/cloudfront/ --region us-east-1
     ```
     If this is empty long after traffic, the issue is upstream (logging_config
     not applied, or the bucket ACL/ownership) — not Splunk.

---

## 7. Persistence note

The add-on (`etc/apps`), the index definition (`etc`), and the indexed events
(`var`) all live on the EBS data volume. A container restart or full instance
replacement keeps every bit of this configuration and data — that's the EBS
persistence guarantee in the phase-1 definition of done.
