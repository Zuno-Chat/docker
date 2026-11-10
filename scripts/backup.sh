#!/usr/bin/env bash
# Backs up the synapse and mas databases and the synapse-data (signing key,
# secrets, media) and mas-data (MAS's encryption and signing keys) volumes into
# BACKUP_DIR/<timestamp>/, verifies all four, prunes old sets, then optionally
# copies them off-host. Run on the server as root, e.g.
#   15 3 * * * /opt/zuno/scripts/backup.sh >>/var/log/zuno-backup.log 2>&1
# Env: BACKUP_DIR         default /var/backups/zuno
#      KEEP_DAYS          default 7
#      BACKUP_UPLOAD_CMD  run after success, e.g. 'rclone sync /var/backups/zuno r2:zuno-backups'
#      METRICS_DIR        default /var/lib/zuno/metrics, where node-exporter
#                         reads the last success (monitoring profile)
# A backup holds every server secret: keep it, and its off-host copy, private.
set -euo pipefail
cd "$(dirname "$0")/.."

BACKUP_DIR=${BACKUP_DIR:-/var/backups/zuno}
KEEP_DAYS=${KEEP_DAYS:-7}
umask 077
stamp=$(date -u +%Y%m%dT%H%M%SZ)
work="$BACKUP_DIR/.partial-$stamp"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

# Not the monitoring schema: postgres-monitor-init recreates it, and its grants
# name zuno_monitor, which a fresh database lacks, so a restore would fail.
docker compose exec -T postgres pg_dump -U synapse -d synapse -Fc --exclude-schema=monitoring >"$work/synapse.dump"
docker compose exec -T synapse tar -C /data -czf - . >"$work/synapse-data.tar.gz"
docker compose exec -T postgres pg_dump -U synapse -d mas -Fc >"$work/mas.dump"
docker compose exec -T mas tar -C /data -czf - . >"$work/mas-data.tar.gz"

# A dump that pg_restore cannot list, or an archive without its keys, is not a
# backup.
docker compose exec -T postgres pg_restore --list <"$work/synapse.dump" >/dev/null
tar -tzf "$work/synapse-data.tar.gz" | grep -qx './signing.key'
docker compose exec -T postgres pg_restore --list <"$work/mas.dump" >/dev/null
tar -tzf "$work/mas-data.tar.gz" | grep -qx './keys.yaml'
tar -tzf "$work/mas-data.tar.gz" | grep -qx './password_pepper'

mv "$work" "$BACKUP_DIR/$stamp"
trap - EXIT
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$KEEP_DAYS" -exec rm -rf {} +

if [ -n "${BACKUP_UPLOAD_CMD:-}" ]; then
  sh -c "$BACKUP_UPLOAD_CMD"
fi

# For node-exporter's textfile collector: the Backup overdue alert fires when
# this is over 26 hours old. Written last, so a failed upload counts as a
# failed backup; world-readable, as node-exporter runs as nobody.
METRICS_DIR=${METRICS_DIR:-/var/lib/zuno/metrics}
(
  umask 022
  mkdir -p "$METRICS_DIR"
  printf '# HELP zuno_backup_last_success_timestamp_seconds Unix time of the last complete scripts/backup.sh run.\n# TYPE zuno_backup_last_success_timestamp_seconds gauge\nzuno_backup_last_success_timestamp_seconds %s\n' \
    "$(date +%s)" >"$METRICS_DIR/zuno_backup.prom.tmp"
  mv "$METRICS_DIR/zuno_backup.prom.tmp" "$METRICS_DIR/zuno_backup.prom"
)
echo "$(date -u +%FT%TZ) backup ok: $BACKUP_DIR/$stamp ($(du -sh "$BACKUP_DIR/$stamp" | cut -f1))"
