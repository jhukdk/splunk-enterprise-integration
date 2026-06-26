# PROGRESS.md

Running log of completed roadmap steps. Append a short, dated note as each step lands so a fresh session can pick up where we left off. See the roadmap in [`README.md`](README.md) / [`CLAUDE.md`](CLAUDE.md).

## Status at a glance

| # | Step | Status |
|---|------|--------|
| 1 | Backend + providers | ⬜ Not started |
| 2 | Networking (VPC / subnet / SG) | ⬜ Not started |
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
