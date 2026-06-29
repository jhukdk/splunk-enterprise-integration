# docker/ — Splunk container configuration

The Splunk Enterprise container is **launched by the EC2 host's user-data**, not
by a compose file applied from your laptop. The authoritative definition lives in
[`../scripts/user-data.sh.tftpl`](../scripts/user-data.sh.tftpl); this README
documents what it runs and why.

## What runs on the host

```
docker run -d --name splunk --restart unless-stopped --hostname splunk \
  -p 8000:8000 \
  -e SPLUNK_START_ARGS=--accept-license \
  -e SPLUNK_PASSWORD="<fetched from SSM at boot>" \
  -v /opt/splunk-data/var:/opt/splunk/var \   # indexed data  (persistent)
  -v /opt/splunk-data/etc:/opt/splunk/etc \   # configuration  (persistent)
  splunk/splunk:10.2.4
```

- **Image** — official `splunk/splunk`, pinned by tag (the `splunk_image`
  variable). Its entrypoint runs `splunk-ansible` on first boot to install and
  configure Splunk into the mounted `etc`.
- **`SPLUNK_START_ARGS=--accept-license`** — required, or the container exits.
- **`SPLUNK_PASSWORD`** — the initial `admin` password. Read from SSM Parameter
  Store at boot using the instance role; never baked into the image or state.
- **Volumes** — both `/opt/splunk/var` and `/opt/splunk/etc` are bind-mounted to
  `/opt/splunk-data/*` on the **EBS data volume**, so indexed events and config
  survive container restarts *and* instance replacement. Those host dirs are
  `chown`ed to uid:gid `41812:41812` (the image's runtime user) so first-boot
  provisioning can write to them — the classic permissions gotcha with this image.
- **Ports** — only `8000` (Splunk Web) is published, and the security group
  restricts it to `admin_cidrs`. HEC (`8088`) is added in the WAF phase.

## Where settings live

After first boot, all Splunk config (indexes, the AWS add-on, the SQS-Based S3
input) lives under `/opt/splunk-data/etc` on EBS. You configure it through the
web UI / SSM session in later steps; nothing here needs editing by hand.
