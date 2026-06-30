# Step 9 — Verify CloudFront logs in Splunk

The payoff step: confirm that hitting the blog produces **searchable,
field-extracted** CloudFront events in `index=cloudfront`, and that the data
**survives a restart** (the EBS-persistence half of the phase-1 done-bar). Run
these in Splunk Web → **Search & Reporting** (or the add-on's Search view).

> All searches assume sourcetype `aws:cloudfront:accesslogs`. The Splunk Add-on
> for AWS extracts CloudFront's W3C fields to underscore names: `c_ip`,
> `cs_method`, `cs_uri_stem`, `sc_status`, `x_edge_result_type`,
> `x_edge_response_result_type`, `cs_user_agent`, `time_taken`, `sc_bytes`,
> `x_edge_location`, …

---

## 1. Generate traffic, then confirm events arrive

1. Visit a few pages on `https://jhuk.tech` (and a deliberate 404, e.g.
   `https://jhuk.tech/nope`, to get a non-200 in the mix).
2. Wait a few minutes — CloudFront delivers standard logs to S3 on a delay, then
   the SQS→Splunk hop adds a little more. Set the time picker to **Last 60
   minutes** and run:

   ```spl
   index=cloudfront sourcetype=aws:cloudfront:accesslogs | stats count
   ```

   A non-zero count means the whole pipeline works end to end:
   CloudFront → S3 → SNS → SQS → add-on → index.

---

## 2. Field-extraction sanity check

Confirms the data is *parsed*, not just landing as raw text:

```spl
index=cloudfront sourcetype=aws:cloudfront:accesslogs
| table _time, c_ip, cs_method, cs_uri_stem, sc_status, x_edge_result_type, time_taken
| sort -_time
| head 20
```

Every column should be populated. If `sc_status`/`cs_uri_stem` are blank, the
sourcetype/decoder is wrong (should be `CloudFrontAccessLogs` →
`aws:cloudfront:accesslogs`).

---

## 3. Starter searches

**Top requested paths**
```spl
index=cloudfront | top limit=20 cs_uri_stem
```

**Status-code breakdown**
```spl
index=cloudfront | stats count by sc_status | sort -count
```

**Errors over time (4xx/5xx)**
```spl
index=cloudfront sc_status>=400
| timechart span=15m count by sc_status
```

**Cache hit ratio** (`x_edge_result_type` is `Hit`, `Miss`, `RefreshHit`,
`Error`, …)
```spl
index=cloudfront
| eval cache=if(x_edge_result_type IN ("Hit","RefreshHit"),"hit","miss_or_other")
| stats count by cache
| eventstats sum(count) as total
| eval pct=round(100*count/total,1)
```

**Top client IPs**
```spl
index=cloudfront | top limit=20 c_ip
```

**Top edge locations** (which CloudFront POPs served traffic)
```spl
index=cloudfront | top limit=10 x_edge_location
```

**Bandwidth served over time**
```spl
index=cloudfront | timechart span=1h sum(sc_bytes) as bytes_out
```

**Slowest requests**
```spl
index=cloudfront
| sort -time_taken
| table _time, cs_uri_stem, sc_status, time_taken, x_edge_result_type
| head 20
```

> Save any of these via **Save As → Report** if you want them one click away;
> reports persist in `etc` on EBS.

---

## 4. Pipeline-health checks (when something looks off)

**Ingest lag** — how fresh is the newest event:
```spl
index=cloudfront | stats max(_time) as latest | eval lag_seconds=now()-latest
```

**Add-on errors** (the first place to look if events stop):
```spl
index=_internal source=*splunk_ta_aws* (ERROR OR WARN) | head 50
```

**Queue depth** (from an SSM shell or your AWS CLI) — main queue should hover
near 0 as Splunk drains it; the DLQ should stay at 0:
```bash
aws sqs get-queue-attributes --region us-east-1 \
  --queue-url https://sqs.us-east-1.amazonaws.com/877995959706/jhuk-tech-cf-logs \
  --attribute-names ApproximateNumberOfMessages

aws sqs get-queue-attributes --region us-east-1 \
  --queue-url https://sqs.us-east-1.amazonaws.com/877995959706/jhuk-tech-cf-logs-dlq \
  --attribute-names ApproximateNumberOfMessages
```

A growing main queue = Splunk isn't consuming (role/input problem). A non-zero
DLQ = messages repeatedly failed (inspect one to see why).

---

## 5. EBS-persistence test (the other half of "done")

Phase-1 isn't done until the indexed data and config survive a restart. Two
levels, weakest to strongest:

**a) Container restart** (quick) — over an SSM session:
```bash
aws ssm start-session --target <splunk_instance_id>
sudo docker restart splunk
```
After Splunk comes back, re-run the §1 count and confirm the SQS-Based S3 input
is still configured. Same count + input present = `etc` and `var` persisted.

**b) Instance replacement** (full proof) — the strongest test, because it proves
the data lives on the **EBS volume**, not the instance disk. Any `terraform
apply` that changes `user_data` replaces the instance; the `aws_ebs_volume`
detaches and reattaches to the new instance, and user-data mounts it (formatting
is skipped because a filesystem already exists). After the new instance boots and
you re-point the input if needed, the historical `index=cloudfront` events should
still be searchable and the input config intact.

> Expected count after either restart: **unchanged**. If the count drops to 0,
> persistence is broken — check that `/opt/splunk/var` and `/opt/splunk/etc` are
> bind-mounted to the EBS mount (`/opt/splunk-data`), per `scripts/user-data.sh.tftpl`.

---

## 6. Definition of done (phase 1)

- [ ] Hitting the blog yields events in `index=cloudfront` within minutes.
- [ ] Fields are extracted (`cs_uri_stem`, `sc_status`, `c_ip`,
      `x_edge_result_type`, …).
- [ ] Data + config survive a container restart (and ideally an instance
      replacement) — EBS persistence proven.
- [ ] No static AWS credentials anywhere — the add-on uses the auto-discovered
      EC2 instance role.

When all four are checked, phase 1 is complete. Optional **Step 10** extends the
same pattern to **WAF logs (Firehose → HEC)** and **CloudTrail (same SQS path)**.
