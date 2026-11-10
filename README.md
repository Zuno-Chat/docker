# Zuno server deployment

Single source of truth for the production stack. One host, Docker Compose, Cloudflare in front.

```
client ─▶ Cloudflare ─▶ nginx:443 ─┬─▶ synapse:8008 (main: everything but sync; zuno_calls and zuno_register under /_synapse/client/zuno/)
                                   ├─▶ synapse-sync:8083 (/sync, /events, /initialSync)
                                   └─▶ api.maptiler.com (/maps/{z}/{x}/{y}: map tiles, the key added by nginx)
synapse-background: background jobs, user directory, push delivery ─▶ Cloudflare ─▶ nginx (push.zuno.chat) ─▶ sygnal ─▶ FCM, APNs
any other homeserver with Zuno app users ─▶ the same push.zuno.chat route
postgres, redis: backend network only (no internet, unreachable from nginx and sygnal)
monitoring profile: prometheus, grafana (loopback only) ─▶ alerts to ntfy
                    synapse-background ─▶ synapse-usage-exporter (usage totals, every 3 h)
                    node-exporter (the host), postgres-exporter (Postgres, read-only role)
admin: synapse:8008 on the server's loopback only, for an admin client over an SSH tunnel
```

| Path | What |
|---|---|
| `docker-compose.yml` | All services, image versions, networks, log rotation |
| `synapse/Dockerfile` | The Synapse image: official release plus Zuno's modules, built by `.github/workflows/synapse-image.yml`. Each module's CI publishes its wheel as `ghcr.io/zuno-chat/<module>-wheel:<tag>` on a `v*` tag; bump that tag in the Dockerfile and push; CI tags the build `latest`, which `docker-compose.yml` runs. `homeserver.yaml` loads the modules, so the official image no longer starts |
| `.env` (from `.env.example`) | Secrets and per-host values. Not in git |
| `nginx/` | The public edge, on the stock nginx image: `nginx.conf` (routing, refusals, limits; its header says how to test and reload an edit), `cloudflare.conf` (Cloudflare's ranges, for real client IPs and the direct-to-origin fence), `push-allow.sh` (the allow list for api.zuno.chat's older push route, from `.env`), `maptiler-key.sh` (the MapTiler key for `/maps/`, from `.env`) |
| `synapse/` | `homeserver.yaml` (shared), `workers/*.yaml`, `log.yaml`, `bootstrap.sh` |
| `postgres/postgresql.conf`, `redis/redis.conf`, `sygnal/sygnal.yaml` | Service configs |
| `monitoring/` | Prometheus config; Grafana datasources, dashboards and alert rules as files; postgres-exporter's role and count queries |
| `sygnal/service_account.json`, `sygnal/apns_auth_key.p8`, `sygnal/apns_auth_key_dev.p8` | Push credentials: Firebase (Android, every build) and the APNs auth keys (iOS: release builds, and debug builds through the sandbox `.dev` apps). Not in git |
| `ssl/` | Cloudflare Origin CA cert and key for `*.zuno.chat`. Key not in git |
| `scripts/` | `invite.sh`, `smoke-test.sh`, `backup.sh`: run from anywhere, they `cd` to the repo root |

## First deploy

1. **Host.** Docker Engine with the compose plugin (Docker's apt repo, not Ubuntu's `docker.io`), `python3`, 2 GB of swap on small hosts. Allow inbound 443 only from [Cloudflare's ranges](https://www.cloudflare.com/ips/), plus SSH. Use the provider's firewall: ports Docker publishes bypass `ufw`.
2. **Cloudflare.** Proxied DNS records for `api.zuno.chat` and `push.zuno.chat` to this host, SSL mode *Full (strict)*, Bot Fight Mode off for both (neither the app nor a homeserver can solve challenges), and the push WAF rule below.
3. **Files.** Clone this repo to e.g. `/opt/zuno`. Copy `.env`, `sygnal/service_account.json`, `sygnal/apns_auth_key.p8`, `sygnal/apns_auth_key_dev.p8` and `ssl/cf_origin_key.key` over separately (`scp`), then:
   ```sh
   chmod 600 .env sygnal/service_account.json sygnal/apns_auth_key.p8 sygnal/apns_auth_key_dev.p8 ssl/cf_origin_key.key
   ```
   nginx reads the key as root. Everything else stays world-readable (644): Synapse, Postgres and Redis read their configs as their own users.
4. **Synapse image.** One-time, for each module `synapse/Dockerfile` names (zuno_calls, zuno_register): push the `v*` tag it names to that repo, whose CI publishes `ghcr.io/zuno-chat/<module>-wheel`, and in that package's settings, *Manage Actions access*, add this repo with the *Read* role, so the workflow's own `GITHUB_TOKEN` can pull it. Run `.github/workflows/synapse-image.yml`; `x-synapse.image` runs the `latest` tag it pushes. In the `modules:` block at the end of `synapse/homeserver.yaml`, fill in zuno_calls' `app_id` and `turn_key_id` (Synapse refuses to start while they are empty), and set zuno_register's `sender_email` to an address Brevo has verified. The server needs `docker login ghcr.io` with a token that has `read:packages` if the image is private.
5. **Start.** `docker compose config -q && docker compose pull && docker compose up -d --wait`. The first start runs Synapse's schema migration.
6. **Once.**
   ```sh
   docker compose exec postgres psql -U synapse -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
   docker compose exec synapse register_new_matrix_user -c /config/homeserver.yaml --admin http://localhost:8008
   ```
7. **Verify.** `scripts/smoke-test.sh full` on the server, `scripts/smoke-test.sh public` from your laptop. Both must report 0 failures.

**Invite tokens:** `scripts/invite.sh [uses] [valid-days]` on the server (defaults: 1 use, 7 days). It prompts for the admin login; nginx refuses `/_synapse/admin`.

**Signup codes:** the app's own signup asks zuno_register (`POST /_synapse/client/zuno/register/token`) to email a single-use token through Brevo. Its sender and limits are in `homeserver.yaml`'s `modules:` block, its API key is `BREVO_API_KEY` in `.env`.

## Before launch

- [ ] **App uses refresh tokens.** `homeserver.yaml` gives sessions without one a 1-minute token. The app must pass `refreshToken: true` to `login`/`register` and set `onSoftLogout` on the SDK `Client`. Check: the app is still signed in after 10 idle minutes (catches a missing refresh token) and again the next day (catches a broken refresh: access tokens last 24h).
- [ ] **Push routes.** Every Zuno app registers its pushers at `push.zuno.chat` whatever its homeserver, so that host takes `POST /_matrix/push/v1/notify` from any address, rate-limited per address, with no allow list or WAF challenge in front. `api.zuno.chat`'s older route stays for app versions that registered there: nginx answers 403 to any address outside `PUSHER_ALLOWED_CIDRS`, and a Cloudflare WAF custom rule, action *Block*, stops the same requests at the edge:
  `(http.host eq "api.zuno.chat" and http.request.uri.path eq "/_matrix/push/v1/notify" and not ip.src in {SERVER_IPV4})`.
  `scripts/smoke-test.sh public` from outside checks both routes.
- [ ] `nginx/cloudflare.conf` holds Cloudflare's current ranges. nginx drops connections from outside them (and this host's private networks) without answering, so a stale list turns Cloudflare's newest edges away instead of just mislabeling client addresses.
- [ ] The CF Calls and TURN secrets and `BREVO_API_KEY` are set, and a signup code requested from the app reaches a real inbox.
- [ ] `https://zuno.chat/.well-known/matrix/client` names the tile route: `"im.zuno.tiles": {"url": "https://api.zuno.chat/maps/{z}/{x}/{y}", "attribution": "MapTiler © OpenStreetMap contributors"}`. The app reads a map with `url`, not a bare string, and falls back to a plain grid otherwise.
- [ ] `MAPTILER_API_KEY` is restricted to the User-Agent `im.zuno.chat` at MapTiler, and any key that was ever published in the well-known is revoked.
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

Optional, on the same host: add `monitoring` to `COMPOSE_PROFILES`. Five containers and a one-shot: Prometheus, Grafana, synapse-usage-exporter, node-exporter, postgres-exporter, and postgres-monitor-init, which creates the read-only `zuno_monitor` role postgres-exporter logs in as. Prometheus scrapes every Synapse process, Sygnal, the three exporters and itself; Grafana shows that and sends alerts to ntfy, urgent ones at max priority. It listens only on the server's loopback:

| UI | Reach it | Log in |
|---|---|---|
| Grafana: dashboards (folder *Zuno*), alert rules (*Zuno alerts*) | `ssh -L 3000:localhost:3000 <server>`, then http://localhost:3000 | `admin` / `GRAFANA_ADMIN_PASSWORD`, read on first start only |

Grafana opens on *Zuno overview*: firing alerts, a tile per area (each opens its dashboard), and every scrape target's up/down history. The *Zuno* menu at the top of every dashboard switches between them:

| Dashboard | Shows |
|---|---|
| *Zuno overview* | Alerts, headline tiles, scrape targets, CPU and memory per Synapse process |
| *Zuno host* | Disk, memory, swap, OOM kills, temperature, the last backup; Postgres connections, cache hit ratio, transactions and size |
| *Zuno calls* | Cloudflare Calls signaling and TURN (zuno_calls); iOS ringing: VoIP sends, ring latency, which zuno_push features are serving |
| *Zuno Sygnal* | Pushes per app, FCM and APNs responses and timing |
| *Zuno signup* | Codes mailed today against `daily_cap`, outcomes, Brevo responses (zuno_register) |
| *Zuno usage* | Accounts, active users, rooms and messages from the usage report |
| *Synapse* | Synapse's own dashboard, every subsystem |

Each alert rule is tied to the panel that shows it: that panel marks the alert's state, and the ntfy message ends with a link to it, which opens while the SSH tunnel is up.

**Usage totals, and nothing leaves the host.** Synapse's Prometheus metrics are operational only. Usage totals (accounts, active users, rooms, messages) exist solely as the report Synapse pushes to `report_stats_endpoint`, which defaults to matrix.org. `homeserver.yaml` points it at [synapse-usage-exporter](https://github.com/loelkes/synapse-usage-exporter) instead: the background worker PUTs the totals to it over the internal `monitoring` network, 5 minutes after it starts and then every 3 hours, and Prometheus scrapes the latest report for the *Zuno usage* dashboard. The privacy policy promises no analytics and names every third party: these are aggregate counts with no user or room identifiers, and no third party receives them. Keep `report_stats: true` and `report_stats_endpoint` together — without the endpoint line the totals go to matrix.org. If a stats or metrics destination outside this host is ever added, the privacy policy has to name it first.

**Alerts.** Urgent (max priority): a Synapse process down, Postgres down, a disk under 10% free. Warning: Synapse CPU saturated; push deliveries to Sygnal failing; Sygnal down; APNs or FCM refusing every push for 30 minutes (the `.p8` key or the service account); Cloudflare Calls unreachable; three iOS rings failing in 30 minutes; a zuno_push feature not serving; signup at `daily_cap`; three signup failures in 30 minutes; a disk under 20% free; host memory under 10%; an OOM kill; no backup in 26 hours; a Postgres transaction idle for over 5 minutes; node-exporter, postgres-exporter or synapse-usage-exporter down.

**Account and report notifications.** Besides alerts, ntfy gets *New account* (low priority) when someone registers and *New report* (high priority) when a message, room or user is reported, about a minute later and once per change: "A new account was created.", "2 new accounts were created.", "A room was reported. Review it in the admin client." They never say who registered, who reported whom, or why. postgres-exporter reads only counts, through two functions that return nothing else (`monitoring/postgres/monitor-role.sql`, `queries.yaml`), and the alert rules compare them with a minute earlier (`rules.yaml`, group *events*). They send no resolved message, and the *Alerts* list on *Zuno overview* leaves them out. ntfy learns only that and when an account or a report was created; if `NTFY_URL` is ntfy.sh, that is a third party. Review reports with the admin client (*Administration*).

**What is not covered.** There is no log collection and no error tracker, and nothing watches Redis, nginx or the public URL, so no alert can fire on them. Logs live only in Docker's rotated files: read them with `docker compose logs`, not in Grafana. node-exporter sits on the internal monitoring network, so it reports no host network traffic: its network collectors are off.

**Enable**, with the base stack running:
1. `.env`: fill in the Monitoring block from `.env.example`, and `COMPOSE_PROFILES=push,monitoring`.
2. `docker compose up -d --wait`.
3. Run `scripts/backup.sh` once if cron has not yet, so there is a backup timestamp to read.
4. `scripts/smoke-test.sh monitoring`: must report 0 failures. In Grafana, *Alerting* > *Contact points* > *ntfy-urgent* > *Test* must reach your phone.

**Changing things.** Dashboards and alert rules are files in `monitoring/grafana/`; Grafana refuses UI edits to them. Edit the file, then `docker compose restart grafana`. The Synapse dashboard and rules come from Synapse's `contrib/` at the pinned version, with two local edits to the dashboard: its deploy markers and version panel filter on this stack's `master|generic_worker` jobs instead of contrib's `synapse`, which matched nothing, and it carries the *Zuno* menu. The other dashboards are written here, against the metric names those services actually export. Two values are copied from other files and must move with them: *Zuno signup*'s and *Zuno overview*'s signup tiles assume `daily_cap: 100` (`homeserver.yaml`), and *Zuno host*'s pool limit assumes `cp_max: 10`.

**Limits.**
- Nothing pages if the host itself or Grafana is down, and nothing probes the public URL from outside: the outside uptime check in *Before launch* is not optional.
- The backup alert reads `/var/lib/zuno/metrics/zuno_backup.prom`, which `scripts/backup.sh` writes last. If cron sets another `METRICS_DIR`, change node-exporter's `--collector.textfile.directory` to match, or the alert fires every day.
- Signup, ring and push counters exist in Prometheus only from their first scrape, so the first event of each kind after a Synapse restart can go uncounted: the signup tiles are approximate, and the count-based alerts can need one failure more.
- Not backed up: Prometheus data. Grafana's dashboards and rules are the files above.
- Usage totals move once per report, so *Zuno usage* steps every 3 hours. The exporter keeps them in memory: after it restarts the dashboard reads *No data* until the next report, up to 3 hours later (5 minutes if `synapse-background` restarted too). The *Last report* tile shows their age. No alert watches them.
- With the monitoring profile off the exporter is not running, and `synapse-background` logs `Error reporting stats` every 3 hours. If monitoring stays off, set `report_stats: false` in `homeserver.yaml`.
- *Zuno calls* reads *No data* until the app has placed a call: the module's own series and Synapse's per-servlet ones exist only once a request has been served. Its alert matches only those series, so it stays silent until then.
- nginx is not scraped: the stock image exports no metrics. Its access log (`docker compose logs nginx`) is the only record of what the edge answered.
- synapse-usage-exporter's image is amd64 only. On an arm64 host such as a Raspberry Pi it runs only under QEMU emulation, and without it *Zuno usage* reads *No data* and the exporter-down alert fires.

**Adding a piece.** Each monitored service is self-contained: a container in `docker-compose.yml`, a scrape job in `monitoring/prometheus/prometheus.yml`, its dashboard in `monitoring/grafana/dashboards/` (tagged `zuno`, so it joins the *Zuno* menu), and its alert rules in `monitoring/grafana/provisioning/alerting/rules.yaml`.

## Administration

No admin UI runs in this stack. The `synapse` service publishes its client port on the server's loopback, so an admin client on your own machine (a local synapse-admin, a hosted admin platform's page in your browser, `curl`) reaches Synapse's admin API through an SSH tunnel:

```sh
ssh -L 8008:localhost:8008 <server>
```

Then give the client `http://localhost:8008` as the homeserver and log in with the admin account from *First deploy* step 6. The public URL will not work for this: nginx refuses `/_synapse/admin`.

**Server notices.** `POST /_synapse/admin/v1/send_server_notice` with `{"user_id": "@<user>:zuno.chat", "content": {"msgtype": "m.text", "body": "<text>"}}` messages one user from `@notices:zuno.chat`, in a room Synapse creates on the first notice and joins the user to. There is no broadcast: send one request per user. To give that room and its sender the logo, run `scripts/notice-avatar.sh <image>` on the server (square PNG, JPEG, WebP or GIF, 2 MB at most; an SVG will not do). It uploads the image, protects it from media retention and prints an `mxc://` URI. Put the URI in `system_mxid_avatar_url` and `room_avatar_url` under `server_notices` in `synapse/homeserver.yaml` and `docker compose restart synapse`. Each user's room picks the logo up with the next notice sent to them.

**What this exposes.** Anything running on the server can reach Synapse's client and admin APIs at `127.0.0.1:8008` directly, bypassing nginx and Cloudflare. Synapse's own auth and rate limits still apply; the edge protections do not. Nothing is reachable from off-host — `scripts/smoke-test.sh public` checks that the admin API is not public. An admin login can deactivate users, reset passwords and delete rooms and media, so never publish this port on a public interface.

## Updating

Most images in `docker-compose.yml` are pinned to a major version only (`postgres:18-alpine`, `redis:8-alpine`, `prom/prometheus:v3`, `prom/node-exporter:v1`), so `pull` fetches their newest minor and patch releases. nginx follows `stable-alpine`, since its major version never moves. Grafana publishes no major-only tag, so `13.2` gets patches only. Three stay exact: sygnal publishes no floating tag, postgres-exporter is 0.x (a minor release can rename metrics the dashboards read), and the usage exporter is held by digest. To hold an image at one version, pin its full tag. Synapse runs `zuno-synapse:latest`, so `pull` fetches the newest master build; to hold a version or roll back, pin one of its `sha-` tags in `x-synapse.image`. Synapse's version lives in `synapse/Dockerfile`'s `FROM`: read the release's upgrade notes, bump it (and in the `zuno_calls` and `zuno_register` repos, their dev `Twisted` and `matrix-synapse` pins and `tests/e2e/Dockerfile`'s `FROM`; zuno_register also reads two private Synapse attributes, so check its `synapse_private.py` against the new version), push, and let `.github/workflows/synapse-image.yml` build and tag it `latest`. Then: back up, `docker compose pull && docker compose up -d --wait`, `scripts/smoke-test.sh full` (and `monitoring` if enabled). Once it passes, `docker image prune -f` deletes the images the update replaced: it removes only untagged images, so other projects' images and anything still tagged stay.

With monitoring on, follow a Synapse or Postgres upgrade (any `pull` can bring a Postgres minor) with `docker compose restart synapse-usage-exporter`. It labels every series with both versions and keeps the old series beside the new ones until it restarts, which makes *Zuno usage* read stale numbers.

## Sizing

Values marked `SIZING` in `postgresql.conf`, `homeserver.yaml` and `sygnal.yaml` are for tier 1. Move up when the signals below say so, not on account count alone; the counts are rough guides for a chatty messaging app.

| Tier | Accounts | Host | postgresql.conf: shared_buffers / effective_cache_size / work_mem / maintenance_work_mem / autovacuum_work_mem / max_wal_size | homeserver.yaml: cache max / target, global_factor | Also |
|---|---|---|---|---|---|
| 1 | up to ~2k | 2 vCPU / 4 GB | 1GB / 2GB / 8MB / 256MB / 128MB / 2GB | 384M / 256M, 1.0 | as shipped |
| 2 | ~10k | 4 vCPU / 8 GB | 2GB / 4GB / 16MB / 512MB / 256MB / 4GB | 1G / 768M, 1.5 | |
| 3 | ~30k | 8 vCPU / 16 GB | 4GB / 8GB / 16MB / 1GB / 512MB / 8GB, `autovacuum_max_workers = 4` | 1536M / 1G, 2.0 | Step 2 below; Sygnal `max_connections: 50` |

Idle, the tier-1 stack uses about 500 MB: about 115 MB per Synapse process, 140 MB for Postgres. The monitoring profile adds roughly 430 MB idle, capped at 1.1 GB, and the kernel kills it first under memory pressure; tier 1 fits on 4 GB with it on. All but the last signal below are in Grafana; slow queries need the Postgres log, since there is no log collection.

**Signals to scale on:**
- A Synapse container at ~100% CPU at peak (*Zuno overview*, and it alerts). Each Synapse process is one Python thread, so a bigger host does not speed it up; only moving work to another process does.
- Postgres cache hit ratio under 99% (*Zuno host*).
- Swap being read back in, or OOM kills (*Zuno host*; OOM kills alert).
- Slow queries in the Postgres log, which logs anything over 500 ms: `docker compose logs postgres | grep duration:`. Or `pg_stat_statements` showing one query dominating.

**Step 2: event persister.** Moves database writes for new events off the main process. No routing change needed.
1. `homeserver.yaml`: uncomment `event_persister` under `instance_map`, and the `stream_writers` block. With monitoring, also its target in `monitoring/prometheus/prometheus.yml`.
2. `.env`: add `events` to `COMPOSE_PROFILES`, e.g. `push,monitoring,events`.
3. Every Synapse process must pick up the change together: `docker compose stop synapse synapse-sync synapse-background && docker compose up -d`.

**Past tier 3, toward 100k.** nginx sends everything except the sync family to the main process. Client reads, E2EE key traffic (`sendToDevice`, `keys/query`, `keys/claim`), receipts and typing therefore all share one core. Reaching 100k accounts needs:
- more paths routed to workers: several sync workers with each user pinned to one, client-reader workers, and stream writers for `to_device`, `receipts`, `typing` and `account_data` (a routing change in `nginx/nginx.conf`);
- Postgres on its own host with a streaming replica.
