#!/usr/bin/env bash
# Backs up the Postgres database and the synapse-data volume (signing key,
# secrets, media) into BACKUP_DIR/<timestamp>/, verifies both, prunes old
# sets, then optionally copies them off-host. Run on the server as root, e.g.
#   15 3 * * * /opt/zuno/scripts/backup.sh >>/var/log/zuno-backup.log 2>&1
# Env: BACKUP_DIR         default /var/backups/zuno
#      KEEP_DAYS          default 7
#      BACKUP_UPLOAD_CMD  run after success, e.g. 'rclone sync /var/backups/zuno r2:zuno-backups'
#      METRICS_DIR        default /var/lib/zuno/metrics (nothing reads it now;
#                         a node-exporter textfile collector would)
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

docker compose exec -T postgres pg_dump -U synapse -d synapse -Fc >"$work/synapse.dump"
docker compose exec -T synapse tar -C /data -czf - . >"$work/synapse-data.tar.gz"

# A dump that pg_restore cannot list, or an archive without the signing key,
# is not a backup.
docker compose exec -T postgres pg_restore --list <"$work/synapse.dump" >/dev/null
tar -tzf "$work/synapse-data.tar.gz" | grep -qx './signing.key'

mv "$work" "$BACKUP_DIR/$stamp"
trap - EXIT
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$KEEP_DAYS" -exec rm -rf {} +

if [ -n "${BACKUP_UPLOAD_CMD:-}" ]; then
  sh -c "$BACKUP_UPLOAD_CMD"
fi

# Kept for a returning node-exporter: no service scrapes it today, so nothing
# alerts on a missed backup. Written last, so a failed upload counts as a
# failed backup; world-readable, as node-exporter would run as nobody.
METRICS_DIR=${METRICS_DIR:-/var/lib/zuno/metrics}
(
  umask 022
  mkdir -p "$METRICS_DIR"
  printf '# HELP zuno_backup_last_success_timestamp_seconds Unix time of the last complete scripts/backup.sh run.\n# TYPE zuno_backup_last_success_timestamp_seconds gauge\nzuno_backup_last_success_timestamp_seconds %s\n' \
    "$(date +%s)" >"$METRICS_DIR/zuno_backup.prom.tmp"
  mv "$METRICS_DIR/zuno_backup.prom.tmp" "$METRICS_DIR/zuno_backup.prom"
)
echo "$(date -u +%FT%TZ) backup ok: $BACKUP_DIR/$stamp ($(du -sh "$BACKUP_DIR/$stamp" | cut -f1))"
