# Zuno server deployment

Single source of truth for the production stack. One host, Docker Compose, Cloudflare in front.

```
client ─▶ Cloudflare ─▶ gateway:443 ─┬─▶ synapse:8008 (main: everything but sync)
                                     └─▶ synapse-sync:8083 (/sync, /events, /initialSync)
synapse-background: background jobs, user directory, push delivery ─▶ gateway ─▶ sygnal ─▶ FCM
postgres, redis: backend network only (no internet, unreachable from gateway and sygnal)
monitoring profile: prometheus, grafana (loopback only) ─▶ alerts to ntfy
                    synapse-background ─▶ synapse-usage-exporter (usage totals, every 3 h)
admin: synapse:8008 on the server's loopback only, for an admin client over an SSH tunnel
```

| Path | What |
|---|---|
| `docker-compose.yml` | All services, pinned image versions, networks, log rotation |
| `.env` (from `.env.example`) | Secrets and per-host values. Not in git |
| `synapse/` | `homeserver.yaml` (shared), `workers/*.yaml`, `log.yaml`, `bootstrap.sh` |
| `postgres/postgresql.conf`, `redis/redis.conf`, `sygnal/sygnal.yaml` | Service configs |
| `monitoring/` | Prometheus config; Grafana datasources, dashboards and alert rules as files |
| `sygnal/service_account.json` | Firebase credentials for push. Not in git |
| `ssl/` | Cloudflare Origin CA cert and key for `*.zuno.chat`. Key not in git |
| `scripts/` | `invite.sh`, `smoke-test.sh`, `backup.sh`: run from anywhere, they `cd` to the repo root |

## First deploy

1. **Host.** Docker Engine with the compose plugin (Docker's apt repo, not Ubuntu's `docker.io`), `python3`, 2 GB of swap on small hosts. Allow inbound 443 only from [Cloudflare's ranges](https://www.cloudflare.com/ips/), plus SSH. Use the provider's firewall: ports Docker publishes bypass `ufw`.
2. **Cloudflare.** Proxied DNS record for `api.zuno.chat`, SSL mode *Full (strict)*, Bot Fight Mode off for that host (the app cannot solve challenges), and the push WAF rule below.
3. **Files.** Clone this repo to e.g. `/opt/zuno`. Copy `.env`, `sygnal/service_account.json` and `ssl/cf_origin_key.key` over separately (`scp`), then:
   ```sh
   chmod 600 .env sygnal/service_account.json
   sudo chgrp 65532 ssl/cf_origin_key.key && chmod 640 ssl/cf_origin_key.key   # gateway runs as uid/gid 65532
   ```
   Everything else stays world-readable (644): Synapse, Postgres and Redis read their configs as their own users.
4. **Start.** `docker compose config -q && docker compose pull && docker compose up -d --wait`. The first start runs Synapse's schema migration.
5. **Once.**
   ```sh
   docker compose exec postgres psql -U synapse -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
   docker compose exec synapse register_new_matrix_user -c /config/homeserver.yaml --admin http://localhost:8008
   ```
6. **Verify.** `scripts/smoke-test.sh full` on the server, `scripts/smoke-test.sh public` from your laptop. Both must report 0 failures.

**Invite tokens:** `scripts/invite.sh [uses] [valid-days]` on the server (defaults: 1 use, 7 days). It prompts for the admin login; the gateway does not expose `/_synapse/admin`.

## Before launch

- [ ] **App uses refresh tokens.** `homeserver.yaml` gives sessions without one a 1-minute token. The app must pass `refreshToken: true` to `login`/`register` and set `onSoftLogout` on the SDK `Client`. Check: the app is still signed in after 10 idle minutes (catches a missing refresh token) and again the next day (catches a broken refresh: access tokens last 24h).
- [ ] **Push route fenced at Cloudflare.** The gateway does not enforce `PUSHER_ALLOWED_CIDRS` (tested on `sha-0d7b560`). Add a WAF custom rule, action *Block*:
  `(http.host eq "api.zuno.chat" and http.request.uri.path eq "/_matrix/push/v1/notify" and not ip.src in {SERVER_IPV4})`.
  `scripts/smoke-test.sh public` from outside checks it.
- [ ] `TRUSTED_PROXY_CIDRS` holds Cloudflare's current ranges.
- [ ] `TILES_UPSTREAM_URL` points at a provider that allows app traffic; the CF Calls and TURN credentials are set.
- [ ] `https://zuno.chat/.well-known/matrix/client` returns the JSON in `.env.example`.
- [ ] A real push reaches a phone while the app is in the background.
- [ ] Backups run from cron, the first set has reached off-host storage, and a restore has been tested (below).
- [ ] Monitoring is on, `scripts/smoke-test.sh monitoring` reports 0 failures, and an alert has reached your phone.
- [ ] **An uptime check outside this host** watches `https://api.zuno.chat/_matrix/client/versions`. Nothing in the stack probes the public URL any more, so this is the only thing that catches a dead edge (below).

## Backups and restore

`scripts/backup.sh` writes `BACKUP_DIR/<timestamp>/` with `synapse.dump` (Postgres) and `synapse-data.tar.gz` (signing key, secrets, media). It verifies both, keeps `KEEP_DAYS`, then runs `BACKUP_UPLOAD_CMD` to copy them off-host. Root crontab:

```
15 3 * * * BACKUP_UPLOAD_CMD='rclone sync /var/backups/zuno remote:zuno-backups' /opt/zuno/scripts/backup.sh >>/var/log/zuno-backup.log 2>&1
```

Each set holds every server secret: keep the remote private. Media is archived in full every night; move to an incremental tool (restic, borg) once media reaches a few GB.

**Restore** (tested end to end). `B` is one backup set:

```sh
docker compose down
docker volume rm zuno_postgres-data zuno_synapse-data
docker compose up -d --wait postgres
docker compose exec -T postgres pg_restore -U synapse -d synapse --no-owner --exit-on-error <"$B/synapse.dump"
docker compose run --rm --no-deps -T --entrypoint tar synapse -C /data -xzf - <"$B/synapse-data.tar.gz"
docker compose up -d --wait && scripts/smoke-test.sh full
```

## Monitoring

Optional, on the same host: add `monitoring` to `COMPOSE_PROFILES`. Three containers: Prometheus, Grafana and synapse-usage-exporter. Prometheus scrapes every Synapse process, Sygnal, the gateway, the usage exporter and itself; Grafana shows that and sends alerts to ntfy, urgent ones at max priority. It listens only on the server's loopback:

| UI | Reach it | Log in |
|---|---|---|
| Grafana: dashboards (folder *Zuno*), alert rules (*Zuno alerts*) | `ssh -L 3000:localhost:3000 <server>`, then http://localhost:3000 | `admin` / `GRAFANA_ADMIN_PASSWORD`, read on first start only |

**Usage totals, and nothing leaves the host.** Synapse's Prometheus metrics are operational only. Usage totals (accounts, active users, rooms, messages) exist solely as the report Synapse pushes to `report_stats_endpoint`, which defaults to matrix.org. `homeserver.yaml` points it at [synapse-usage-exporter](https://github.com/loelkes/synapse-usage-exporter) instead: the background worker PUTs the totals to it over the internal `monitoring` network, 5 minutes after it starts and then every 3 hours, and Prometheus scrapes the latest report for the *Zuno usage* dashboard. The privacy policy promises no analytics and names every third party: these are aggregate counts with no user or room identifiers, and no third party receives them. Keep `report_stats: true` and `report_stats_endpoint` together — without the endpoint line the totals go to matrix.org. If a stats or metrics destination outside this host is ever added, the privacy policy has to name it first.

**What is not covered.** There are no host or database exporters, no log collection and no error tracker, so nothing watches the host (disk, memory, swap, OOM kills), Postgres, Redis, or the public URL, and no alert can fire on any of them. Logs live only in Docker's rotated files: read them with `docker compose logs`, not in Grafana. Four alert rules exist — Synapse process down, Synapse CPU saturated, push deliveries failing, Sygnal down.

**Enable**, with the base stack running:
1. `.env`: fill in the Monitoring block from `.env.example`, and `COMPOSE_PROFILES=push,monitoring`.
2. `docker compose up -d --wait`.
3. `scripts/smoke-test.sh monitoring`: must report 0 failures, except the `gateway` scrape target while it is still down (below). In Grafana, *Alerting* > *Contact points* > *ntfy-urgent* > *Test* must reach your phone.

**Changing things.** Dashboards and alert rules are files in `monitoring/grafana/`; Grafana refuses UI edits to them. Edit the file, then `docker compose restart grafana`. The Synapse dashboard and rules come from Synapse's `contrib/` at the pinned version; *Zuno overview*, *Zuno gateway*, *Zuno Sygnal* and *Zuno usage* are written here, against the metric names those services actually export.

**Limits.**
- Nothing pages if the host itself or Grafana is down, and nothing probes the public URL from outside: the outside uptime check in *Before launch* is not optional.
- `scripts/backup.sh` still writes `/var/lib/zuno/metrics/zuno_backup.prom`, but nothing reads it, so a missed backup does not alert.
- Not backed up: Prometheus data. Grafana's dashboards and rules are the files above.
- Usage totals move once per report, so *Zuno usage* steps every 3 hours. The exporter keeps them in memory: after it restarts the dashboard reads *No data* until the next report, up to 3 hours later (5 minutes if `synapse-background` restarted too). The *Last report* tile shows their age. No alert watches them.
- With the monitoring profile off the exporter is not running, and `synapse-background` logs `Error reporting stats` every 3 hours. If monitoring stays off, set `report_stats: false` in `homeserver.yaml`.
- The `gateway` scrape target reports **down** until an image exposing `METRICS_LISTEN_ADDR` is deployed, so `scripts/smoke-test.sh monitoring` fails on it and the *Zuno gateway* dashboard reads *No data* until then. No alert fires on it — the rules match only `job=~"master|generic_worker"` and `job="sygnal"`.

**Adding a piece back.** Each removed service was self-contained: a container in `docker-compose.yml`, a scrape job in `monitoring/prometheus/prometheus.yml`, and its alert rules in `monitoring/grafana/provisioning/alerting/rules.yaml`. node-exporter is the highest value of them — 64 MB, and it alone restores disk, swap, OOM-kill and backup-overdue alerting.

## Administration

No admin UI runs in this stack. The `synapse` service publishes its client port on the server's loopback, so an admin client on your own machine (a local synapse-admin, a hosted admin platform's page in your browser, `curl`) reaches Synapse's admin API through an SSH tunnel:

```sh
ssh -L 8008:localhost:8008 <server>
```

Then give the client `http://localhost:8008` as the homeserver and log in with the admin account from *First deploy* step 5. The public URL will not work for this: the gateway does not route `/_synapse/admin`.

**What this exposes.** Anything running on the server can reach Synapse's client and admin APIs at `127.0.0.1:8008` directly, bypassing the gateway and Cloudflare. Synapse's own auth and rate limits still apply; the edge protections do not. Nothing is reachable from off-host — `scripts/smoke-test.sh public` checks that the admin API is not public. An admin login can deactivate users, reset passwords and delete rooms and media, so never publish this port on a public interface.

## Updating

Every image is pinned in `docker-compose.yml`; nothing changes on `pull` until a tag is edited. The gateway uses CI's `sha-<commit>` tags, never `latest`. Synapse's tag lives once, in `x-synapse`; read the release's upgrade notes first. Then: back up, `docker compose pull && docker compose up -d --wait`, `scripts/smoke-test.sh full` (and `monitoring` if enabled).

With monitoring on, follow a Synapse or Postgres upgrade with `docker compose restart synapse-usage-exporter`. It labels every series with both versions and keeps the old series beside the new ones until it restarts, which makes *Zuno usage* read stale numbers.

## Sizing

Values marked `SIZING` in `postgresql.conf`, `homeserver.yaml` and `sygnal.yaml` are for tier 1. Move up when the signals below say so, not on account count alone; the counts are rough guides for a chatty messaging app.

| Tier | Accounts | Host | postgresql.conf: shared_buffers / effective_cache_size / work_mem / maintenance_work_mem / autovacuum_work_mem / max_wal_size | homeserver.yaml: cache max / target, global_factor | Also |
|---|---|---|---|---|---|
| 1 | up to ~2k | 2 vCPU / 4 GB | 1GB / 2GB / 8MB / 256MB / 128MB / 2GB | 384M / 256M, 1.0 | as shipped |
| 2 | ~10k | 4 vCPU / 8 GB | 2GB / 4GB / 16MB / 512MB / 256MB / 4GB | 1G / 768M, 1.5 | |
| 3 | ~30k | 8 vCPU / 16 GB | 4GB / 8GB / 16MB / 1GB / 512MB / 8GB, `autovacuum_max_workers = 4` | 1536M / 1G, 2.0 | Step 2 below; Sygnal `max_connections: 50` |

Idle, the tier-1 stack uses about 500 MB: about 115 MB per Synapse process, 140 MB for Postgres. The monitoring profile adds roughly 400 MB idle, capped at 1 GB, and the kernel kills it first under memory pressure; tier 1 fits on 4 GB with it on. Only the first signal below is visible in Grafana — the rest are manual checks now that there are no host or database exporters and no log collection.

**Signals to scale on:**
- A Synapse container at ~100% CPU at peak (*Zuno overview*, and it alerts). Each Synapse process is one Python thread, so a bigger host does not speed it up; only moving work to another process does.
- Postgres cache hit ratio under 99%: `select round(sum(blks_hit)*100.0/sum(blks_hit+blks_read),2) from pg_stat_database;`
- Swap in use (`free -m`), or OOM kills (`dmesg`).
- Slow queries in the Postgres log, which logs anything over 500 ms: `docker compose logs postgres | grep duration:`. Or `pg_stat_statements` showing one query dominating.

**Step 2: event persister.** Moves database writes for new events off the main process. No routing change needed.
1. `homeserver.yaml`: uncomment `event_persister` under `instance_map`, and the `stream_writers` block. With monitoring, also its target in `monitoring/prometheus/prometheus.yml`.
2. `.env`: add `events` to `COMPOSE_PROFILES`, e.g. `push,monitoring,events`.
3. Every Synapse process must pick up the change together: `docker compose stop synapse synapse-sync synapse-background && docker compose up -d`.

**Past tier 3, toward 100k.** The gateway sends everything except the sync family to the main process. Client reads, E2EE key traffic (`sendToDevice`, `keys/query`, `keys/claim`), receipts and typing therefore all share one core. Reaching 100k accounts needs:
- more paths routed to workers: several sync workers with each user pinned to one, client-reader workers, and stream writers for `to_device`, `receipts`, `typing` and `account_data` (a gateway routing change);
- Postgres on its own host with a streaming replica.
